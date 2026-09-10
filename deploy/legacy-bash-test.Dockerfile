FROM bash:4.2@sha256:326c3fb7e7009e1aa6aad242056abc11c372ac0a2b57dcb29ca5bc8feedf5579
RUN apk add --no-cache bash coreutils curl findutils gawk git grep sed tar util-linux \
    && /usr/local/bin/bash --version | grep -F 'version 4.2.'
RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.cloud.tencent.com/g' /etc/apk/repositories \
    && apk add --no-cache openssl procps-ng
WORKDIR /workspace
ENV XINGCHEN_TEST_BASH=/usr/local/bin/bash
ENTRYPOINT ["/bin/bash"]
