#!/bin/sh
set -eu

# shellcheck disable=SC1091
. /usr/local/bin/killswitch.sh
# shellcheck disable=SC1091
. /usr/local/bin/generate-config.sh

iso_is_ipv4() {
    echo "$1" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
}

iso_resolve_ipv4() {
    host="$1"
    if iso_is_ipv4 "${host}"; then
        echo "${host}"
        return 0
    fi
    # Resolve once via current DNS (Docker embedded DNS) before kill-switch.
    ipaddr="$(getent ahostsv4 "${host}" 2>/dev/null | awk '{print $1; exit}' || true)"
    if [ -z "${ipaddr}" ]; then
        ipaddr="$(dig +short +time=3 +tries=2 "${host}" A 2>/dev/null | awk 'NR==1 {print; exit}' || true)"
    fi
    if [ -z "${ipaddr}" ] || ! iso_is_ipv4 "${ipaddr}"; then
        echo "Failed to resolve TROJAN_SERVER=${host} to IPv4" >&2
        return 1
    fi
    echo "${ipaddr}"
}

term_handler() {
    echo "egress stopping; leaving kill-switch in place until netns exits"
    if pgrep -x sing-box >/dev/null 2>&1; then
        pkill -TERM -x sing-box || true
        sleep 1
        pkill -KILL -x sing-box 2>/dev/null || true
    fi
    exit 0
}
trap term_handler TERM INT

: "${TROJAN_SERVER:?TROJAN_SERVER is required}"
: "${TROJAN_PORT:?TROJAN_PORT is required}"
: "${TROJAN_PASSWORD:?TROJAN_PASSWORD is required}"
: "${TROJAN_SNI:?TROJAN_SNI is required}"
VNC_PORT="${VNC_PORT:-5900}"

case "${TROJAN_PASSWORD}" in
    ""|change-me|replace-me|password1|yourpsk|changeme)
        echo "TROJAN_PASSWORD looks like a placeholder; refusing to start" >&2
        exit 1
        ;;
esac

mkdir -p /run/iso
TROJAN_IP="$(iso_resolve_ipv4 "${TROJAN_SERVER}")"
export TROJAN_IP VNC_PORT

echo "Resolved Trojan server ${TROJAN_SERVER} -> ${TROJAN_IP} (SNI=${TROJAN_SNI}, verify=on)"

apply_killswitch
generate_singbox_config /run/iso/sing-box.json

if [ "${ISO_SKIP_SINGBOX:-0}" = "1" ]; then
    echo "ISO_SKIP_SINGBOX=1: sing-box not started; kill-switch remains (test mode)"
    # Keep the netns alive so leak probes can run against a down proxy.
    while true; do
        sleep 3600
    done
fi

echo "Starting sing-box; if it exits the kill-switch stays and there is no direct fallback"
while true; do
    sing-box run -c /run/iso/sing-box.json || true
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) sing-box exited; not restoring default routes" >&2
    sleep 2
done
