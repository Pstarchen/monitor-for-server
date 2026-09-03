FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS build
WORKDIR /src
ENV GOPROXY=https://goproxy.cn,direct
COPY setup/go.mod setup/go.sum* ./
RUN go mod download
COPY setup/main.go setup/controller_update.go setup/controller_release.go setup/controller_backup.go setup/agent_release.go ./
ARG TARGETOS=linux
ARG TARGETARCH=amd64
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags='-s -w' -o /out/setup .

FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS agent-release
WORKDIR /src/agent
ENV GOPROXY=https://goproxy.cn,direct
RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories \
    && apk add --no-cache zip
COPY agent/go.mod agent/go.sum ./
RUN go mod download
COPY agent/ ./
COPY setup/cmd/release-manifest /src/release-manifest
ARG VERSION=dev
RUN set -eux; \
    mkdir -p /out/release/assets /out/stage; \
    if printf '%s' "$VERSION" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then \
      release_version="${VERSION#v}"; \
      build_agent() { \
        target_os="$1"; target_arch="$2"; extension="$3"; \
        rm -rf /out/stage/*; \
        CGO_ENABLED=0 GOOS="$target_os" GOARCH="$target_arch" go build -trimpath -ldflags="-s -w -X main.version=$VERSION" -o /out/stage/xingchen-agent ./cmd/agent; \
        archive="/out/release/assets/xingchen-agent_${release_version}_${target_os}_${target_arch}.${extension}"; \
        if [ "$extension" = tar.gz ]; then \
          tar -C /out/stage -czf "$archive" xingchen-agent; \
        else \
          mv /out/stage/xingchen-agent /out/stage/xingchen-agent.exe; \
          (cd /out/stage && zip -q "$archive" xingchen-agent.exe); \
        fi; \
      }; \
      build_agent linux amd64 tar.gz; \
      build_agent linux arm64 tar.gz; \
      build_agent windows amd64 zip; \
      build_agent windows arm64 zip; \
      (cd /out/release/assets && sha256sum xingchen-agent_* > checksums.txt); \
      go run /src/release-manifest/main.go -version "$VERSION" -assets /out/release/assets -output /out/release/manifest.json -minimum-controller v1.20.0; \
      (cd /out/release && sha256sum manifest.json > manifest.json.sha256); \
    fi

FROM docker:27-cli
ARG VERSION=dev
LABEL org.opencontainers.image.version=$VERSION
RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories \
    && apk add --no-cache bash docker-cli-compose util-linux
COPY --from=build /out/setup /usr/local/bin/xingchen-setup
COPY deploy/install-agent.sh deploy/install-agent.ps1 /usr/local/share/xingchen/installers/
COPY --from=agent-release /out/release /usr/local/share/xingchen/release/
RUN chmod 0444 /usr/local/share/xingchen/installers/install-agent.sh /usr/local/share/xingchen/installers/install-agent.ps1
EXPOSE 8090
ENTRYPOINT ["/usr/local/bin/xingchen-setup"]
