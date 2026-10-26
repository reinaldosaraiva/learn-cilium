# Build & load into kind sandbox:
#   docker build -t p003-authz:1.0.0 poc-k8s-fabric/studies/p003/fixtures/auth
#   kind load docker-image p003-authz:1.0.0 --name p003-gw
FROM golang:1.24.1-bookworm AS builder

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download && go mod verify
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/p003-authz .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /out/p003-authz /usr/local/bin/p003-authz
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/p003-authz"]
