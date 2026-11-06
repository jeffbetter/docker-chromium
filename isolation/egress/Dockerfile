# Egress helper only. Chromium still uses the unmodified jlesage image.
# Pin the official sing-box v1.14.4 *OCI index* (tag is mutable). This digest
# is the multi-arch list (linux/amd64 + linux/arm64 + …), not a single-arch
# image. Engine selects the native platform; do not use qemu/amd64 emulation.
# linux/arm64 manifest: sha256:5b9f53448637c7d3874e571758f0968f2c0959815494aca938569b40a0a4e752
# GitHub release linux tarballs are glibc-linked and will not run on Alpine.
FROM ghcr.io/sagernet/sing-box:v1.14.4@sha256:0788ffbddab2c68a99a2dd4780bbc50902f159af6f589df3ee74a8389d278279

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
    && sing-box version | grep -F 'sing-box version 1.14.4'

STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
