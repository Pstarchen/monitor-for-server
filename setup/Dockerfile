FROM golang:1.24-alpine AS build
WORKDIR /src
ENV GOPROXY=https://goproxy.cn,direct
COPY go.mod go.sum* ./
RUN go mod download
COPY main.go controller_update.go controller_release.go controller_backup.go agent_release.go ./
ARG TARGETOS=linux
ARG TARGETARCH=amd64
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags='-s -w' -o /out/setup .

FROM docker:27-cli
ARG VERSION=dev
LABEL org.opencontainers.image.version=$VERSION
RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories \
    && apk add --no-cache bash docker-cli-compose util-linux
COPY --from=build /out/setup /usr/local/bin/xingchen-setup
EXPOSE 8090
ENTRYPOINT ["/usr/local/bin/xingchen-setup"]
