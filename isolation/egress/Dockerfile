# Egress helper only. Chromium still uses the unmodified jlesage image.
# Base is the maintained official sing-box image (Alpine + musl binary).
# GitHub release tarballs are glibc-linked and will not run on Alpine.
FROM ghcr.io/sagernet/sing-box:v1.14.4

USER root
RUN apk add --no-cache \
        ca-certificates \
        curl \
        iproute2 \
        iptables \
        jq \
        nftables \
        bind-tools \
        procps-ng \
        iputils

COPY killswitch.sh generate-config.sh entrypoint.sh healthcheck.sh /usr/local/bin/
RUN chmod 0755 /usr/local/bin/killswitch.sh \
               /usr/local/bin/generate-config.sh \
               /usr/local/bin/entrypoint.sh \
               /usr/local/bin/healthcheck.sh \
    && command -v sing-box \
    && sing-box version

STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
