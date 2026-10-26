# Build & load into kind sandbox:
#   docker build -t p003-tlsecho:1.0.0 poc-k8s-fabric/studies/p003/fixtures/tlsecho
#   kind load docker-image p003-tlsecho:1.0.0 --name p003-gw
FROM golang:1.24.1-bookworm AS builder

WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/p003-tlsecho main.go

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /out/p003-tlsecho /usr/local/bin/p003-tlsecho
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/p003-tlsecho"]
