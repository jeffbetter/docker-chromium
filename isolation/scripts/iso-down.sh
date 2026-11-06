#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ -z "${1:-}" ]; then
    cat <<'EOF'
Usage: iso-down.sh <identity.env>

Graceful Chromium shutdown (SIGTERM, wait for cookie/profile flush), then egress.
Persistent /config is kept.
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

chrome="$(iso_chromium_container)"
grace=20

if docker inspect -f '{{.State.Running}}' "${chrome}" 2>/dev/null | grep -q true; then
    echo "Sending SIGTERM to Chromium in ${chrome} (graceful profile shutdown)"
    docker exec "${chrome}" sh -c '
        pids="$(pgrep -f /usr/bin/chromium-browser || true)"
        if [ -n "${pids}" ]; then
            kill -TERM ${pids} 2>/dev/null || true
        fi
    ' || true
    end=$((SECONDS + grace))
    while [ "${SECONDS}" -lt "${end}" ]; do
        if ! docker exec "${chrome}" sh -c 'pgrep -f /usr/bin/chromium-browser >/dev/null 2>&1' 2>/dev/null; then
            echo "Chromium process exited"
            break
        fi
        sleep 1
    done
fi

echo "Stopping compose project $(iso_project) (volumes preserved)"
iso_compose "${ENV_FILE}" stop chromium || true
iso_compose "${ENV_FILE}" stop egress || true
iso_compose "${ENV_FILE}" ps || true
echo "Stopped. Data remains at ${ISO_DATA_DIR}"
