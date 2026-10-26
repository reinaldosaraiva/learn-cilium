// SPDX-License-Identifier: Apache-2.0
package main

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	authv3 "github.com/envoyproxy/go-control-plane/envoy/service/auth/v3"
	"google.golang.org/grpc/codes"
)

func TestHTTPMuxDecisions(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	h := newHTTPMux(logger, "test-pod")

	tests := []struct {
		name       string
		decision   string
		wantStatus int
		wantUser   string
	}{
		{name: "allow", decision: "allow", wantStatus: http.StatusOK, wantUser: labUser},
		{name: "deny", decision: "deny", wantStatus: http.StatusForbidden, wantUser: ""},
		{name: "absent", decision: "", wantStatus: http.StatusUnauthorized, wantUser: ""},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "/", nil)
			if tc.decision != "" {
				req.Header.Set("X-Lab-Decision", tc.decision)
			}
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			if rec.Code != tc.wantStatus {
				t.Fatalf("got status %d, want %d", rec.Code, tc.wantStatus)
			}
			if got := rec.Header().Get("X-Lab-User"); got != tc.wantUser {
				t.Fatalf("got X-Lab-User %q, want %q", got, tc.wantUser)
			}
		})
	}
}

func TestGRPCCheckDecisions(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	srv := &server{logger: logger, pod: "test-pod"}

	makeReq := func(decision string) *authv3.CheckRequest {
		headers := map[string]string{}
		if decision != "" {
			headers["x-lab-decision"] = decision
		}
		return &authv3.CheckRequest{
			Attributes: &authv3.AttributeContext{
				Request: &authv3.AttributeContext_Request{
					Http: &authv3.AttributeContext_HttpRequest{
						Headers: headers,
					},
				},
			},
		}
	}

	respAllow, err := srv.Check(context.Background(), makeReq("allow"))
	if err != nil || respAllow.GetStatus().GetCode() != int32(codes.OK) {
		t.Fatalf("allow Check failed: err=%v status=%v", err, respAllow.GetStatus())
	}

	respDeny, err := srv.Check(context.Background(), makeReq("deny"))
	if err != nil || respDeny.GetStatus().GetCode() != int32(codes.PermissionDenied) {
		t.Fatalf("deny Check failed: err=%v status=%v", err, respDeny.GetStatus())
	}

	respAbsent, err := srv.Check(context.Background(), makeReq(""))
	if err != nil || respAbsent.GetStatus().GetCode() != int32(codes.Unauthenticated) {
		t.Fatalf("absent Check failed: err=%v status=%v", err, respAbsent.GetStatus())
	}
}
