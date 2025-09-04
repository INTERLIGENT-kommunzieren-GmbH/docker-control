FROM alpine:latest

RUN apk add --no-cache \
    bash \
    openssh-client \
    git \
    gum \
    netcat-openbsd \
    docker-cli \
    docker-cli-compose \
    nano \
    rsync \
    p7zip \
    socat \
    util-linux \
    jq \
    && rm -rf /var/cache/apk/*

# Configure SSH to auto-accept host keys
RUN mkdir -p /etc/ssh && \
    echo "Host *" > /etc/ssh/ssh_config && \
    echo "    StrictHostKeyChecking no" >> /etc/ssh/ssh_config && \
    echo "    UserKnownHostsFile /dev/null" >> /etc/ssh/ssh_config && \
    echo "    LogLevel ERROR" >> /etc/ssh/ssh_config

WORKDIR /app

COPY lib ./lib
COPY ingress ./ingress
COPY plugin ./plugin
COPY template ./template
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
