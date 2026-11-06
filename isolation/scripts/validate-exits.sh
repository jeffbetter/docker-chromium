#!/usr/bin/env bash
# Fail if two identity env files share the same Trojan exit.
# Distinct public IPs require distinct actual proxy exits. This script does
# not probe live IPs and does not claim account unlinkability.

set -euo pipefail

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
    cat <<'EOF'
Usage: validate-exits.sh [env-file ...]
If no files are given, all isolation/identities/*.env (not *.example) are checked.
EOF
}

files=()
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ "$#" -gt 0 ]; then
    files=("$@")
else
    shopt -s nullglob
    files=("${ISO_ROOT}/identities"/*.env)
    shopt -u nullglob
fi

if [ "${#files[@]}" -eq 0 ]; then
    echo "No identity .env files to validate (copy identities/*.env.example first)."
    exit 0
fi

declare -A seen_exits=()
declare -A seen_identities=()
declare -A seen_ports=()
status=0

for file in "${files[@]}"; do
    if [ ! -f "${file}" ]; then
        echo "missing: ${file}" >&2
        status=1
        continue
    fi
    # Load in a subshell-friendly way without leaking into caller loop state.
    ident="$(awk -F= '/^ISO_IDENTITY=/ {gsub(/["'\'' ]/, "", $2); print $2; exit}' "${file}")"
    server="$(awk -F= '/^TROJAN_SERVER=/ {gsub(/["'\'' ]/, "", $2); print $2; exit}' "${file}")"
    port="$(awk -F= '/^TROJAN_PORT=/ {gsub(/["'\'' ]/, "", $2); print $2; exit}' "${file}")"
    pass="$(awk -F= '/^TROJAN_PASSWORD=/ {gsub(/["'\'' ]/, "", $2); print $2; exit}' "${file}")"
    sni="$(awk -F= '/^TROJAN_SNI=/ {gsub(/["'\'' ]/, "", $2); print $2; exit}' "${file}")"
    vnc="$(awk -F= '/^HOST_VNC_PORT=/ {gsub(/["'\'' ]/, "", $2); print $2; exit}' "${file}")"
    insecure="$(awk -F= '/^TROJAN_INSECURE=/ {gsub(/["'\'' ]/, "", $2); print $2; exit}' "${file}")"
    file_bad=0

    if [ -z "${ident}" ] || [ -z "${server}" ] || [ -z "${port}" ] || [ -z "${sni}" ]; then
        echo "incomplete identity fields in ${file}" >&2
        status=1
        continue
    fi
    if [ -n "${insecure}" ] && echo "${insecure}" | grep -Eiq '^(1|true|yes)$'; then
        echo "REFUSE: ${file} sets TROJAN_INSECURE — certificate verification must stay on" >&2
        status=1
        file_bad=1
    fi
    if iso_placeholder_password "${pass}"; then
        echo "REFUSE: ${file} still has a placeholder TROJAN_PASSWORD" >&2
        status=1
        file_bad=1
    fi
    if [[ "${server}" == *.example.invalid ]] || [[ "${server}" == example.com ]]; then
        echo "REFUSE: ${file} still has a documentation TROJAN_SERVER (${server})" >&2
        status=1
        file_bad=1
    fi
    if [ -n "${seen_identities[${ident}]:-}" ]; then
        echo "REFUSE: duplicate ISO_IDENTITY=${ident} (${file} and ${seen_identities[${ident}]})" >&2
        status=1
    fi
    seen_identities[${ident}]="${file}"

    if [ -n "${vnc}" ]; then
        if [ -n "${seen_ports[${vnc}]:-}" ]; then
            echo "REFUSE: HOST_VNC_PORT ${vnc} reused by ${file} and ${seen_ports[${vnc}]}" >&2
            status=1
        fi
        seen_ports[${vnc}]="${file}"
    fi

    key="${server}:${port}"
    if [ -n "${seen_exits[${key}]:-}" ]; then
        echo "REFUSE: ${file} and ${seen_exits[${key}]} share Trojan exit ${key}" >&2
        echo "A shared exit shares the public IP. This overlay will not invent a second IP." >&2
        echo "Account unlinkability is NOT provided by Compose isolation alone." >&2
        status=1
    else
        seen_exits[${key}]="${file}"
        if [ "${file_bad}" -eq 0 ]; then
            echo "OK exit ${key} -> ${ident} (${file})"
        fi
    fi
done

if [ "${status}" -eq 0 ]; then
    echo "Exit check passed for ${#files[@]} identity file(s)."
    echo "NOTE: this did not probe public IPs or logins; uniqueness is config-level only."
fi
exit "${status}"
