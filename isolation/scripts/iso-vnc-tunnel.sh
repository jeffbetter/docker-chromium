#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ -z "${1:-}" ]; then
    cat <<'EOF'
Usage: iso-vnc-tunnel.sh <identity.env> [user@host]

Prints (or runs, if user@host is given) a loopback-bound SSH tunnel for native VNC.
Does not open 0.0.0.0 on the US Linux server. Does not log into Gmail/Yahoo/Claude.
EOF
    exit 0
fi

ENV_FILE="$1"
TARGET="${2:-}"
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

cmd=(ssh -N -L "127.0.0.1:${HOST_VNC_PORT}:127.0.0.1:${HOST_VNC_PORT}")
if [ -n "${TARGET}" ]; then
    cmd+=("${TARGET}")
else
    cmd+=("USER@US_LINUX_SERVER")
fi

echo "Native VNC: after the tunnel is up, connect a VNC client to 127.0.0.1:${HOST_VNC_PORT}"
echo "Command:"
printf '  %q' "${cmd[@]}"
echo

if [ -z "${TARGET}" ]; then
    echo "Replace USER@US_LINUX_SERVER and re-run with that argument to open the tunnel."
    exit 0
fi

echo "Opening tunnel (Ctrl-C to stop). This host is not probed beyond SSH."
exec "${cmd[@]}"
