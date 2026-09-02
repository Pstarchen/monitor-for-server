FROM golang:1.24-alpine AS build
WORKDIR /src
ENV GOPROXY=https://goproxy.cn,direct
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
ARG TARGETOS=linux
ARG TARGETARCH=amd64
ARG VERSION=dev
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w -X main.version=$VERSION" -o /out/xingchen-agent ./cmd/agent

FROM alpine:3.22 AS artifact
# smartmontools is optional at runtime: the collector reports UNKNOWN when
# host devices or the required privileges are not exposed to the container.
RUN apk add --no-cache ca-certificates smartmontools
COPY --from=build /out/xingchen-agent /xingchen-agent
ENTRYPOINT ["/xingchen-agent"]
