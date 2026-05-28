# syntax=docker/dockerfile:1.7

FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS builder
ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT
ARG VERSION=dev
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    set -eux; \
    case "$TARGETVARIANT" in v7) GOARM=7 ;; v6) GOARM=6 ;; *) GOARM= ;; esac; \
    CGO_ENABLED=0 GOOS="$TARGETOS" GOARCH="$TARGETARCH" GOARM="$GOARM" \
    go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" \
        -o /out/snell-server ./cmd/snell-server

FROM alpine:3.20
RUN apk add --no-cache ca-certificates tini && \
    adduser -D -H -u 10001 snell
COPY --from=builder /out/snell-server /usr/local/bin/snell-server
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
EXPOSE 2333/tcp 2333/udp
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["snell-server"]
