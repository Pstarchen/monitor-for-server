FROM golang:1.24-alpine AS build
WORKDIR /src
ARG GOPROXY=https://mirrors.cloud.tencent.com/go
ENV GOPROXY=$GOPROXY
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
ARG TARGETOS=linux
ARG TARGETARCH=amd64
ARG VERSION=dev
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w -X main.version=$VERSION" -o /out/xingchen-agent ./cmd/agent

FROM alpine:3.22 AS artifact
ARG VERSION=dev
LABEL org.opencontainers.image.version=$VERSION
# smartmontools is optional at runtime: the collector reports UNKNOWN when
# host devices or the required privileges are not exposed to the container.
RUN set -eux; \
    for attempt in 1 2 3; do \
      apk add --no-cache ca-certificates smartmontools && break; \
      [ "$attempt" -lt 3 ]; \
      sleep $((attempt * 2)); \
    done
COPY --from=build /out/xingchen-agent /xingchen-agent
ENTRYPOINT ["/xingchen-agent"]
