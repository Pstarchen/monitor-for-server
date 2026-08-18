FROM golang:1.24-alpine AS build
WORKDIR /src
ENV GOPROXY=https://goproxy.cn,direct
COPY go.mod go.sum* ./
RUN go mod download
COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o /out/setup .

FROM docker:27-cli
RUN apk add --no-cache docker-cli-compose
COPY --from=build /out/setup /usr/local/bin/guanlan-setup
EXPOSE 8090
ENTRYPOINT ["/usr/local/bin/guanlan-setup"]
