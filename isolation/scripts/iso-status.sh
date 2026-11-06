#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ -z "${1:-}" ]; then
    cat <<'EOF'
Usage: iso-status.sh <identity.env>
Prints lifecycle state. Does not probe the live public IP or any login.
EOF
    exit 0
fi

ENV_FILE="$1"
if [ ! -f "${ENV_FILE}" ]; then
    if [ -f "${ISO_ROOT}/${ENV_FILE}" ]; then
        ENV_FILE="${ISO_ROOT}/${ENV_FILE}"
    elif [ -f "${ISO_ROOT}/identities/${ENV_FILE}" ]; then
        ENV_FILE="${ISO_ROOT}/identities/${ENV_FILE}"
    else
        echo "env file not found: ${ENV_FILE}" >&2
        exit 1
    fi
fi
ENV_FILE="$(cd "$(dirname "${ENV_FILE}")" && pwd)/$(basename "${ENV_FILE}")"
iso_load_env "${ENV_FILE}"
iso_need_cmd docker

echo "identity: ${ISO_IDENTITY}"
echo "project: $(iso_project)"
echo "config volume: ${ISO_DATA_DIR}"
echo "vnc listen (host): 127.0.0.1:${HOST_VNC_PORT}"
echo "trojan (config, unverified live): ${TROJAN_SERVER}:${TROJAN_PORT} sni=${TROJAN_SNI}"
echo
iso_compose "${ENV_FILE}" ps || true
echo

egress="$(iso_egress_container)"
if docker inspect -f '{{.State.Running}}' "${egress}" 2>/dev/null | grep -q true; then
    echo "--- egress netns (kill-switch) ---"
    docker exec "${egress}" ip -4 route || true
    echo "--- default IPv4 ---"
    docker exec "${egress}" ip -4 route show default || true
    echo "--- default IPv6 ---"
    docker exec "${egress}" ip -6 route show default || true
    echo "--- resolv.conf ---"
    docker exec "${egress}" cat /etc/resolv.conf || true
    echo "--- nft ---"
    docker exec "${egress}" nft list table inet iso_killswitch || true
    echo "--- tun ---"
    docker exec "${egress}" ip link show tun0 || echo "tun0 absent"
else
    echo "egress container not running"
fi

echo
echo "UNVERIFIED: live public egress IP was not measured in this status output."
echo "UNVERIFIED: no mailbox/chat login was attempted."
echo "UNVERIFIED: account unlinkability is not implied even if exits differ in config."
