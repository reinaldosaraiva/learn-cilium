// SPDX-License-Identifier: Apache-2.0
// Copyright Authors of Cilium
//
// Adapted from cilium/cilium v1.20.2 examples/kubernetes/gateway/external-authz/main.go
// Upstream commit: v1.20.2 tag
//
// Adaptations for P003-S005:
//   - Decision logic based on X-Lab-Decision header (allow/deny/delay)
//   - Logs: request ID, decision, protocol, timestamp, duration, pod (not all headers)
//   - Sets X-Lab-User: lab-user-a on allow responses
//   - Absent/unknown decision → 401/UNAUTHENTICATED (default deny)
//   - Delay decision → 15s wait before responding
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	corev3 "github.com/envoyproxy/go-control-plane/envoy/config/core/v3"
	authv3 "github.com/envoyproxy/go-control-plane/envoy/service/auth/v3"
	typev3 "github.com/envoyproxy/go-control-plane/envoy/type/v3"
	"golang.org/x/sync/errgroup"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	grpc_health_v1 "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/status"
)

const (
	defaultHTTPPort = 8080
	defaultGRPCPort = 9000
	shutdownTimeout = 5 * time.Second
	delayDuration   = 15 * time.Second
	labUser         = "lab-user-a"
)

type server struct {
	authv3.UnimplementedAuthorizationServer
	logger *slog.Logger
	pod    string
}

func main() {
	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))

	pod := os.Getenv("POD_NAME")
	if pod == "" {
		pod = "unknown"
	}

	httpPort := getenvInt("HTTP_PORT", defaultHTTPPort)
	grpcPort := getenvInt("GRPC_PORT", defaultGRPCPort)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	srv := &server{logger: logger, pod: pod}

	httpSrv := &http.Server{
		Addr:              fmt.Sprintf(":%d", httpPort),
		Handler:           newHTTPMux(logger, pod),
		ReadHeaderTimeout: 5 * time.Second,
	}

	grpcLis, err := net.Listen("tcp", fmt.Sprintf(":%d", grpcPort))
	if err != nil {
		logger.Error("failed to listen for gRPC", "error", err)
		os.Exit(1)
	}

	grpcSrv := grpc.NewServer()
	authv3.RegisterAuthorizationServer(grpcSrv, srv)
	grpc_health_v1.RegisterHealthServer(grpcSrv, healthServer{})

	g, gctx := errgroup.WithContext(ctx)
	g.Go(func() error {
		logger.Info("starting HTTP auth service", "port", httpPort, "pod", pod)
		err := httpSrv.ListenAndServe()
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			return err
		}
		return nil
	})
	g.Go(func() error {
		logger.Info("starting gRPC auth service", "port", grpcPort, "pod", pod)
		if err := grpcSrv.Serve(grpcLis); err != nil && gctx.Err() == nil {
			return err
		}
		return nil
	})

	<-ctx.Done()
	logger.Info("shutdown requested")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()

	grpcSrv.GracefulStop()
	if err := httpSrv.Shutdown(shutdownCtx); err != nil {
		logger.Error("HTTP shutdown failed", "error", err)
	}

	if err := g.Wait(); err != nil && !errors.Is(err, grpc.ErrServerStopped) {
		logger.Error("server exited with error", "error", err)
		os.Exit(1)
	}
}

func newHTTPMux(logger *slog.Logger, pod string) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		requestID := r.Header.Get("X-Lab-Request-ID")
		decision := r.Header.Get("X-Lab-Decision")

		// Delay decision: wait before responding
		if decision == "delay" {
			select {
			case <-time.After(delayDuration):
			case <-r.Context().Done():
				logger.Info("http ext_authz",
					"request_id", requestID,
					"decision", "delay-cancelled",
					"protocol", "http",
					"pod", pod,
					"duration_ms", time.Since(start).Milliseconds(),
				)
				w.WriteHeader(http.StatusServiceUnavailable)
				return
			}
		}

		switch decision {
		case "allow":
			logger.Info("http ext_authz",
				"request_id", requestID,
				"decision", "allow",
				"protocol", "http",
				"pod", pod,
				"duration_ms", time.Since(start).Milliseconds(),
			)
			w.Header().Set("X-Test-Authz", "allowed-http")
			w.Header().Set("X-Lab-User", labUser)
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte("allowed\n"))

		case "deny":
			logger.Info("http ext_authz",
				"request_id", requestID,
				"decision", "deny",
				"protocol", "http",
				"pod", pod,
				"duration_ms", time.Since(start).Milliseconds(),
			)
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte("denied\n"))

		default:
			// Absent or unknown decision → default deny
			logger.Info("http ext_authz",
				"request_id", requestID,
				"decision", fmt.Sprintf("absent(%q)", decision),
				"protocol", "http",
				"pod", pod,
				"duration_ms", time.Since(start).Milliseconds(),
			)
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = w.Write([]byte("unauthorized\n"))
		}
	})
	return mux
}

func (s *server) Check(ctx context.Context, req *authv3.CheckRequest) (*authv3.CheckResponse, error) {
	start := time.Now()
	httpAttrs := req.GetAttributes().GetRequest().GetHttp()

	// Extract headers
	headers := httpAttrs.GetHeaders()
	requestID := headers["x-lab-request-id"]
	decision := headers["x-lab-decision"]

	// Delay decision: wait before responding
	if decision == "delay" {
		select {
		case <-time.After(delayDuration):
		case <-ctx.Done():
			s.logger.InfoContext(ctx, "grpc ext_authz",
				"request_id", requestID,
				"decision", "delay-cancelled",
				"protocol", "grpc",
				"pod", s.pod,
				"duration_ms", time.Since(start).Milliseconds(),
			)
			return &authv3.CheckResponse{
				Status: status.New(codes.Unavailable, "delay cancelled").Proto(),
			}, nil
		}
	}

	switch decision {
	case "allow":
		s.logger.InfoContext(ctx, "grpc ext_authz",
			"request_id", requestID,
			"decision", "allow",
			"protocol", "grpc",
			"pod", s.pod,
			"duration_ms", time.Since(start).Milliseconds(),
		)
		return &authv3.CheckResponse{
			Status: status.New(codes.OK, "").Proto(),
			HttpResponse: &authv3.CheckResponse_OkResponse{
				OkResponse: &authv3.OkHttpResponse{
					Headers: []*corev3.HeaderValueOption{
						{Header: &corev3.HeaderValue{Key: "x-test-authz", Value: "allowed-grpc"}},
						{Header: &corev3.HeaderValue{Key: "x-lab-user", Value: labUser}},
					},
				},
			},
		}, nil

	case "deny":
		s.logger.InfoContext(ctx, "grpc ext_authz",
			"request_id", requestID,
			"decision", "deny",
			"protocol", "grpc",
			"pod", s.pod,
			"duration_ms", time.Since(start).Milliseconds(),
		)
		return &authv3.CheckResponse{
			Status: status.New(codes.PermissionDenied, "denied").Proto(),
			HttpResponse: &authv3.CheckResponse_DeniedResponse{
				DeniedResponse: &authv3.DeniedHttpResponse{
					Status: &typev3.HttpStatus{Code: typev3.StatusCode(403)},
					Body:   "denied\n",
				},
			},
		}, nil

	default:
		s.logger.InfoContext(ctx, "grpc ext_authz",
			"request_id", requestID,
			"decision", fmt.Sprintf("absent(%q)", decision),
			"protocol", "grpc",
			"pod", s.pod,
			"duration_ms", time.Since(start).Milliseconds(),
		)
		return &authv3.CheckResponse{
			Status: status.New(codes.Unauthenticated, "no decision").Proto(),
			HttpResponse: &authv3.CheckResponse_DeniedResponse{
				DeniedResponse: &authv3.DeniedHttpResponse{
					Status: &typev3.HttpStatus{Code: typev3.StatusCode(401)},
					Body:   "unauthorized\n",
				},
			},
		}, nil
	}
}

type healthServer struct {
	grpc_health_v1.UnimplementedHealthServer
}

func (healthServer) Check(_ context.Context, _ *grpc_health_v1.HealthCheckRequest) (*grpc_health_v1.HealthCheckResponse, error) {
	return &grpc_health_v1.HealthCheckResponse{Status: grpc_health_v1.HealthCheckResponse_SERVING}, nil
}

func (healthServer) Watch(_ *grpc_health_v1.HealthCheckRequest, srv grpc.ServerStreamingServer[grpc_health_v1.HealthCheckResponse]) error {
	return srv.Send(&grpc_health_v1.HealthCheckResponse{Status: grpc_health_v1.HealthCheckResponse_SERVING})
}

func getenvInt(key string, fallback int) int {
	raw := os.Getenv(key)
	if raw == "" {
		return fallback
	}
	v, err := strconv.Atoi(raw)
	if err != nil {
		return fallback
	}
	return v
}
