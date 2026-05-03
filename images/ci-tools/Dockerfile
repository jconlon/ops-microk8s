FROM alpine:3.21

RUN apk add --no-cache git bash curl ca-certificates

# gh CLI v2.69.0
RUN curl -fsSL https://github.com/cli/cli/releases/download/v2.69.0/gh_2.69.0_linux_amd64.tar.gz \
    | tar -xz -C /usr/local --strip-components=1 gh_2.69.0_linux_amd64/bin/gh

# yq v4.45.1
RUN curl -fsSL https://github.com/mikefarah/yq/releases/download/v4.45.1/yq_linux_amd64 \
    -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq

RUN git --version && gh --version && yq --version
