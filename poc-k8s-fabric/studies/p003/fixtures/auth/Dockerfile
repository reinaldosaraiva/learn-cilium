FROM golang:1.24 AS builder

WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY main.go ./
RUN go mod tidy && CGO_ENABLED=0 go build -o /out/p003-authz .

FROM cgr.dev/chainguard/static:latest
COPY --from=builder /out/p003-authz /usr/local/bin/p003-authz
ENTRYPOINT ["/usr/local/bin/p003-authz"]
