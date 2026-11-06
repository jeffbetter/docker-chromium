#!/usr/bin/env bash
# Fail-fast host compatibility. Does not install Docker, nft, or kernels.
# Does not weaken the nft kill-switch or TLS verify to fit old distros.
set -euo pipefail

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
    cat <<'EOF'
Usage: iso-preflight.sh [--live]

Refuse to start on CentOS/RHEL 7, kernel < 4.18, missing Docker Compose v2,
missing /dev/net/tun, or MemTotal < 2048 MiB.

Does not: install packages, load firewall modules, rewrite iptables, disable TLS.
See isolation/HOST.md.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

KERNEL_REL="${ISO_PREFLIGHT_KERNEL:-$(uname -r)}"
OS_RELEASE_FILE="${ISO_PREFLIGHT_OS_RELEASE:-/etc/os-release}"
MEMINFO_FILE="${ISO_PREFLIGHT_MEMINFO:-/proc/meminfo}"
TUN_PATH="${ISO_PREFLIGHT_TUN:-/dev/net/tun}"
SKIP_LIVE_DOCKER="${ISO_PREFLIGHT_SKIP_LIVE_DOCKER:-0}"
NFT_KERNEL_OVERRIDE="${ISO_PREFLIGHT_NFT_KERNEL:-}"

blockers=0
warnings=0

say() { printf '%s\n' "$*"; }
block() { say "BLOCKER: $*"; blockers=$((blockers + 1)); }
warn() { say "WARN: $*"; warnings=$((warnings + 1)); }
ok() { say "OK: $*"; }

kernel_major() { echo "${KERNEL_REL}" | awk -F. '{print $1+0}'; }
kernel_minor() { echo "${KERNEL_REL}" | awk -F. '{print $2+0}'; }

read_os() {
    os_id=""
    os_version=""
    os_pretty=""
    if [ -f "${OS_RELEASE_FILE}" ]; then
        # shellcheck disable=SC1090
        os_id="$(. "${OS_RELEASE_FILE}"; printf '%s' "${ID:-}")"
        # shellcheck disable=SC1090
        os_version="$(. "${OS_RELEASE_FILE}"; printf '%s' "${VERSION_ID:-}")"
        # shellcheck disable=SC1090
        os_pretty="$(. "${OS_RELEASE_FILE}"; printf '%s' "${PRETTY_NAME:-}")"
    fi
}

mem_total_kib() {
    awk '/^MemTotal:/ {print $2; exit}' "${MEMINFO_FILE}" 2>/dev/null || echo 0
}

has_el7() {
    [[ "${KERNEL_REL}" == *.el7* ]] && return 0
    case "${os_id}" in
        centos|rhel|ol|scientific|almalinux|rocky)
            case "${os_version}" in
                7|7.*) return 0 ;;
            esac
            ;;
    esac
    return 1
}

nft_kernel_signal() {
    if [ -n "${NFT_KERNEL_OVERRIDE}" ]; then
        [ "${NFT_KERNEL_OVERRIDE}" = "1" ] || [ "${NFT_KERNEL_OVERRIDE}" = "yes" ]
        return $?
    fi
    [ -d /sys/module/nf_tables ] && return 0
    grep -qw '^nf_tables' /proc/modules 2>/dev/null && return 0
    if command -v nft >/dev/null 2>&1 && nft list tables >/dev/null 2>&1; then
        return 0
    fi
    local kver="${KERNEL_REL}"
    for p in \
        "/lib/modules/${kver}/kernel/net/netfilter/nf_tables.ko" \
        "/lib/modules/${kver}/kernel/net/netfilter/nf_tables.ko.xz" \
        "/lib/modules/${kver}/kernel/net/netfilter/nf_tables.ko.zst"; do
        [ -e "${p}" ] && return 0
    done
    if [ -r "/boot/config-${kver}" ] && grep -q '^CONFIG_NF_TABLES=y' "/boot/config-${kver}"; then
        return 0
    fi
    # Distro kernels 5.x+ ship nf_tables; absence of a module file is not proof of missing support.
    local maj min
    maj="$(kernel_major)"
    min="$(kernel_minor)"
    if [ "${maj}" -gt 5 ] || { [ "${maj}" -eq 5 ] && [ "${min}" -ge 4 ]; }; then
        return 0
    fi
    return 1
}

say "== isolation host preflight =="
say "kernel=${KERNEL_REL}"
read_os
say "os=${os_pretty:-unknown} id=${os_id:-?} version=${os_version:-?}"
say "ref: isolation/HOST.md (will not install Docker on EL7 or rewrite iptables 1.4)"

if has_el7; then
    block "RHEL/CentOS/OL 7 (or *.el7 kernel) is unsupported. CentOS 7 EOL 2024-06-30; Docker CE stopped EL7 packages at v27 (docker-ce-packaging 88a6cdc). Kernel ${KERNEL_REL} is not a supported nft/TUN/cgroup host for this overlay."
else
    ok "not an EL7 distro/kernel string"
fi

maj="$(kernel_major)"
min="$(kernel_minor)"
if [ "${maj}" -lt 4 ] || { [ "${maj}" -eq 4 ] && [ "${min}" -lt 18 ]; }; then
    block "kernel ${KERNEL_REL} < 4.18. Kill-switch uses nft 'table inet' from an Alpine userspace; Docker dropped EL7 kernel special-cases (moby#49184). Will not fall back to iptables 1.4.21."
else
    ok "kernel ${KERNEL_REL} >= 4.18"
fi

if [ ! -e "${TUN_PATH}" ]; then
    block "TUN device missing at ${TUN_PATH}"
else
    ok "TUN device exists (${TUN_PATH})"
fi

kib="$(mem_total_kib)"
mib=$((kib / 1024))
say "MemTotal=${mib} MiB (swap is not counted as usable RAM)"
if [ "${kib}" -lt $((2048 * 1024)) ]; then
    block "MemTotal ${mib} MiB < 2048 MiB. Chromium + Docker + sing-box was not measured at ~1 GiB; 8 GiB swap does not make a desktop. Refusing to try."
elif [ "${kib}" -lt $((4096 * 1024)) ]; then
    warn "MemTotal ${mib} MiB < 4096 MiB. Single-identity Chromium RAM need is unmeasured; expect swap or OOM. Not a pass for production."
else
    ok "MemTotal ${mib} MiB >= 4096 MiB (Chromium RSS still unmeasured by this overlay)"
fi

if nft_kernel_signal; then
    ok "kernel nf_tables signal present (or assumed on 5.4+)"
else
    block "no nf_tables signal. Overlay kill-switch is nft inside the egress netns, not host iptables."
fi

if [ "${SKIP_LIVE_DOCKER}" = "1" ]; then
    warn "skipping live Docker checks (ISO_PREFLIGHT_SKIP_LIVE_DOCKER=1)"
else
    if ! command -v docker >/dev/null 2>&1; then
        block "docker CLI missing. Do not install an unsupported Engine on EL7 to bypass this."
    elif ! docker info >/dev/null 2>&1; then
        block "docker daemon not reachable"
    else
        ok "docker daemon reachable ($(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown))"
        cg="$(docker info --format '{{.CgroupVersion}}' 2>/dev/null || true)"
        if [ -n "${cg}" ]; then
            say "docker cgroup version=${cg}"
        fi
    fi
    if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
        block "docker compose v2 missing (need 'docker compose', not only docker-compose 1.x)"
    else
        ok "compose $(docker compose version --short 2>/dev/null || docker compose version | head -n1)"
    fi
fi

say "NOTE: host iptables/ip6tables is not the kill-switch. Presence of iptables 1.4.21 does not qualify the host."
say "NOTE: live Trojan / public IP / Chromium desktop are not probed here."

if [ "${blockers}" -ne 0 ]; then
    say "preflight FAILED (${blockers} blocker(s), ${warnings} warning(s)). See isolation/HOST.md."
    exit 1
fi
if [ "${warnings}" -ne 0 ]; then
    say "preflight passed with ${warnings} warning(s)."
    exit 0
fi
say "preflight passed."
exit 0
