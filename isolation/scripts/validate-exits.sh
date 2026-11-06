#!/usr/bin/env bash
# Compare configured Trojan *endpoint tuples* (host:port) and optional
# TROJAN_PUBLIC_EXIT_CLAIM labels.
#
# This is NOT proof of distinct public egress IPs. Two different host:port
# values can still land on the same provider exit / NAT / anycast IP.
# This script does not probe live IPs and does not claim unlinkability.

set -euo pipefail

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
    cat <<'EOF'
Usage: validate-exits.sh [env-file ...]
If no files are given, all isolation/identities/*.env (not *.example) are checked.

Checks:
  - duplicate ISO_IDENTITY / HOST_VNC_PORT
  - duplicate TROJAN_SERVER:TROJAN_PORT (same endpoint tuple)
  - duplicate TROJAN_PUBLIC_EXIT_CLAIM (operator-declared same public exit)
  - placeholder passwords, docs hostnames, TROJAN_INSECURE

Does not:
  - resolve hostnames
  - measure public IPs
  - prove two endpoints have different exits
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
declare -A seen_claims=()
status=0
missing_claim=0

for file in "${files[@]}"; do
    if [ ! -f "${file}" ]; then
        echo "missing: ${file}" >&2
        status=1
        continue
    fi
    ident="$(iso_env_get "${file}" ISO_IDENTITY || true)"
    server="$(iso_env_get "${file}" TROJAN_SERVER || true)"
    port="$(iso_env_get "${file}" TROJAN_PORT || true)"
    pass="$(iso_env_get "${file}" TROJAN_PASSWORD || true)"
    sni="$(iso_env_get "${file}" TROJAN_SNI || true)"
    vnc="$(iso_env_get "${file}" HOST_VNC_PORT || true)"
    insecure="$(iso_env_get "${file}" TROJAN_INSECURE || true)"
    claim="$(iso_env_get "${file}" TROJAN_PUBLIC_EXIT_CLAIM || true)"
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
        file_bad=1
    fi
    seen_identities[${ident}]="${file}"

    if [ -n "${vnc}" ]; then
        if [ -n "${seen_ports[${vnc}]:-}" ]; then
            echo "REFUSE: HOST_VNC_PORT ${vnc} reused by ${file} and ${seen_ports[${vnc}]}" >&2
            status=1
            file_bad=1
        fi
        seen_ports[${vnc}]="${file}"
    fi

    key="${server}:${port}"
    if [ -n "${seen_exits[${key}]:-}" ]; then
        echo "REFUSE: ${file} and ${seen_exits[${key}]} share Trojan endpoint tuple ${key}" >&2
        echo "A shared endpoint tuple is the same server. This is still not a public-IP probe." >&2
        status=1
        file_bad=1
    else
        seen_exits[${key}]="${file}"
    fi

    if [ -z "${claim}" ]; then
        missing_claim=1
        echo "WARN: ${file} has no TROJAN_PUBLIC_EXIT_CLAIM; ${key} uniqueness is NOT a distinct public IP." >&2
    else
        if [ -n "${seen_claims[${claim}]:-}" ]; then
            echo "REFUSE: ${file} and ${seen_claims[${claim}]} share TROJAN_PUBLIC_EXIT_CLAIM=${claim}" >&2
            echo "Operator declared the same public exit. Different host:port does not split that IP." >&2
            status=1
            file_bad=1
        else
            seen_claims[${claim}]="${file}"
        fi
    fi

    if [ "${file_bad}" -eq 0 ]; then
        echo "OK endpoint-tuple ${key} -> ${ident} (not a public-IP proof)"
    fi
done

echo "NOTE: endpoint tuples / claims are config-level only. Two Trojan host:port values MAY share one public exit. Live IPs were not probed."
if [ "${missing_claim}" -ne 0 ]; then
    echo "NOTE: set distinct TROJAN_PUBLIC_EXIT_CLAIM values only when you independently know the exits differ."
fi
if [ "${status}" -eq 0 ]; then
    echo "Config check passed for ${#files[@]} identity file(s). This is not proof of distinct public IPs."
fi
exit "${status}"
