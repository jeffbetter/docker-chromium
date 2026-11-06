#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ -z "${1:-}" ]; then
    cat <<'EOF'
Usage: iso-up.sh <identity.env> [--dry-run]

Starts one isolated Chromium + Trojan egress stack.
Each identity is its own Compose project, /config volume, and VNC loopback port.
EOF
    exit 0
fi

ENV_FILE="$1"
shift || true
DRY=0
if [ "${1:-}" = "--dry-run" ]; then
    DRY=1
fi

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

if iso_placeholder_password "${TROJAN_PASSWORD}"; then
    echo "Refusing placeholder TROJAN_PASSWORD. Edit ${ENV_FILE} first." >&2
    exit 1
fi

# Cross-check every real identity env so two stacks cannot silently share an exit.
shopt -s nullglob
all_envs=("${ISO_ROOT}/identities"/*.env)
shopt -u nullglob
if [ "${#all_envs[@]}" -gt 0 ]; then
    "${ISO_SCRIPTS_DIR}/validate-exits.sh" "${all_envs[@]}"
fi

mkdir -p "${ISO_DATA_DIR}"

echo "Identity: ${ISO_IDENTITY}"
echo "Compose project: $(iso_project)"
echo "Persistent /config: ${ISO_DATA_DIR}"
echo "Host VNC: 127.0.0.1:${HOST_VNC_PORT} (not published on 0.0.0.0)"
echo "Trojan exit (config): ${TROJAN_SERVER}:${TROJAN_PORT} SNI=${TROJAN_SNI} verify=on"
echo "Live public IP is NOT probed by this script."

if [ "${DRY}" -eq 1 ]; then
    iso_need_cmd docker
    iso_compose "${ENV_FILE}" config >/dev/null
    echo "dry-run: compose config OK"
    exit 0
fi

iso_need_cmd docker
iso_compose "${ENV_FILE}" up -d --build
iso_compose "${ENV_FILE}" ps
echo
echo "Access (native VNC over SSH tunnel), from your laptop:"
echo "  ssh -N -L 127.0.0.1:${HOST_VNC_PORT}:127.0.0.1:${HOST_VNC_PORT} USER@US_LINUX_SERVER"
echo "  then point a VNC client at 127.0.0.1:${HOST_VNC_PORT}"
echo "Web GUI is disabled (WEB_LISTENING_PORT=-1)."
