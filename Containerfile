FROM debian:bookworm-slim

WORKDIR /docker-plugin

COPY lib ./lib
COPY ingress ./ingress
COPY plugin ./plugin
COPY template ./template
COPY build/build.sh /build.sh

RUN chmod u+x /build.sh && /build.sh && rm /build.sh

RUN mkdir -p /context
WORKDIR /context

ENTRYPOINT ["/docker-plugin/plugin/docker-control"]
