FROM alpine:latest

RUN apk add --no-cache \
    bash \
    openssh-client \
    git \
    gum \
    netcat-openbsd \
    docker-cli \
    docker-cli-compose \
    rsync \
    p7zip \
    util-linux \
    && rm -rf /var/cache/apk/*

WORKDIR /app

COPY lib ./lib
COPY ingress ./ingress
COPY plugin ./plugin
COPY template ./template

ENTRYPOINT ["/app/plugin/docker-control"]
