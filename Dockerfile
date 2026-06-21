FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl xz-utils ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENV RAD_HOME=/var/lib/radicle
ENV RAD_PASSPHRASE=

ENTRYPOINT ["docker-entrypoint.sh"]
