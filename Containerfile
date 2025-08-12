FROM alpine:latest

RUN apk add --no-cache \
    bash \
    openssh-client \
    git \
    gum \
    netcat-openbsd \
    docker-cli \
    rsync \
    p7zip \
    && rm -rf /var/cache/apk/*

WORKDIR /app

COPY lib ./lib
COPY ingress ./ingress
COPY plugin ./plugin
COPY template ./template

RUN mkdir -p /context
WORKDIR /context

ENTRYPOINT ["/app/plugin/docker-control"]
