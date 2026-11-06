#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ -z "${1:-}" ]; then
    cat <<'EOF'
Usage: iso-restart.sh <identity.env>
Graceful Chromium stop, then start the same identity again. Volume is reused.
EOF
    exit 0
fi

ENV_FILE="$1"
"${ISO_SCRIPTS_DIR}/iso-down.sh" "${ENV_FILE}"
"${ISO_SCRIPTS_DIR}/iso-up.sh" "${ENV_FILE}"
