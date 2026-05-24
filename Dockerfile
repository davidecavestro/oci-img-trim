FROM alpine:3.21 AS base

RUN apk add --no-cache \
    bash \
    bc \
    curl \
    docker-cli \
    fzf \
    jq \
    zstd \
    && REGCTL_VER=$(curl -s https://api.github.com/repos/regclient/regclient/releases/latest | grep '"tag_name"' | sed 's/.*"tag_name": "\(.*\)".*/\1/') \
    && curl -fsSL "https://github.com/regclient/regclient/releases/download/${REGCTL_VER}/regctl-linux-amd64" \
       -o /usr/local/bin/regctl \
    && chmod +x /usr/local/bin/regctl

WORKDIR /app
COPY main.sh ./
RUN chmod +x main.sh

ENTRYPOINT ["./main.sh"]


FROM base AS dev
RUN apk add --no-cache procps less

# final stage
FROM base
