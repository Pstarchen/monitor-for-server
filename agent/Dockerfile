FROM golang:1.24-alpine AS build
WORKDIR /src
ENV GOPROXY=https://goproxy.cn,direct
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
ARG TARGETOS=linux
ARG TARGETARCH=amd64
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w" -o /out/guanlan-agent ./cmd/agent

FROM alpine:3.22 AS artifact
RUN apk add --no-cache ca-certificates
COPY --from=build /out/guanlan-agent /guanlan-agent
