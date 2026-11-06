#!/bin/sh
# Network-layer kill-switch for the egress netns.
# Sharing this netns with Chromium is NOT the kill-switch; these rules are.
# Requires NET_ADMIN. Safe to re-run.

set -eu

iso_is_ipv4() {
    echo "$1" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
}

iso_detect_default_v4() {
    # Prints: "<iface> <gateway-or-empty>"
    line="$(ip -4 route show default 2>/dev/null | head -n 1 || true)"
    if [ -z "${line}" ]; then
        echo ""
        return 0
    fi
    iface="$(echo "${line}" | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}')"
    gw="$(echo "${line}" | awk '{for (i = 1; i <= NF; i++) if ($i == "via") { print $(i + 1); exit }}')"
    echo "${iface} ${gw:-}"
}

iso_in_container() {
    [ -f /.dockerenv ] || [ -f /run/.containerenv ] || [ "${ISO_WRITE_RESOLV:-0}" = "1" ]
}

iso_write_resolv_conf() {
    if [ "${ISO_SKIP_RESOLV:-0}" = "1" ] || ! iso_in_container; then
        echo "killswitch: skipping resolv.conf rewrite (not in container)"
        return 0
    fi
    tmp="$(mktemp)"
    printf 'nameserver 127.0.0.1\noptions ndots:0 timeout:2 attempts:1\n' > "${tmp}"
    if [ -e /etc/resolv.conf ]; then
        if ! cat "${tmp}" > /etc/resolv.conf 2>/dev/null; then
            echo "WARN: could not replace /etc/resolv.conf (no SYS_ADMIN for bind-mount)" >&2
        fi
    else
        cp "${tmp}" /etc/resolv.conf
    fi
    rm -f "${tmp}"
}

# Bootstrap: fail-closed except Docker embedded DNS used to resolve Trojan once.
iso_apply_nft_bootstrap() {
    nft delete table inet iso_killswitch 2>/dev/null || true
    nft -f - <<'EOF'
table inet iso_killswitch {
    chain input {
        type filter hook input priority filter; policy drop;
        iif lo accept
        ct state established,related accept
    }
    chain forward {
        type filter hook forward priority filter; policy drop;
    }
    chain output {
        type filter hook output priority filter; policy drop;
        oif lo ip daddr 127.0.0.11 udp dport 53 accept
        oif lo ip daddr 127.0.0.11 tcp dport 53 accept
        oif lo ip daddr 127.0.0.0/8 accept
        ct state established,related accept
    }
}
EOF
}

iso_apply_nft() {
    trojan_ip="$1"
    trojan_port="$2"
    vnc_port="$3"

    nft delete table inet iso_killswitch 2>/dev/null || true

    nft -f - <<EOF
table inet iso_killswitch {
    chain input {
        type filter hook input priority filter; policy drop;
        iif lo accept
        iifname "tun0" accept
        ct state established,related accept
        tcp dport ${vnc_port} accept
    }
    chain forward {
        type filter hook forward priority filter; policy drop;
    }
    chain output {
        type filter hook output priority filter; policy drop;
        ip daddr 127.0.0.11 drop
        oif lo accept
        oifname "tun0" accept
        ct state established,related accept
        ip daddr ${trojan_ip} tcp dport ${trojan_port} accept
    }
}
EOF
}

iso_delete_defaults() {
    n=0
    while [ "${n}" -lt 16 ]; do
        if ! ip -4 route del default 2>/dev/null; then
            break
        fi
        n=$((n + 1))
    done
    n=0
    while [ "${n}" -lt 16 ]; do
        if ! ip -6 route del default 2>/dev/null; then
            break
        fi
        n=$((n + 1))
    done
}

iso_add_trojan_host_route() {
    trojan_ip="$1"
    iface="$2"
    gw="$3"

    ip -4 route del "${trojan_ip}/32" 2>/dev/null || true
    if [ -n "${gw}" ]; then
        ip -4 route add "${trojan_ip}/32" via "${gw}" dev "${iface}"
    else
        ip -4 route add "${trojan_ip}/32" dev "${iface}"
    fi
}

iso_disable_ipv6_best_effort() {
    for p in /proc/sys/net/ipv6/conf/all/disable_ipv6 \
             /proc/sys/net/ipv6/conf/default/disable_ipv6; do
        { echo 1 > "${p}"; } 2>/dev/null || true
    done
}

iso_install_tun_default() {
    # sing-box 1.14.4 auto_route does not install a tun default once the Docker
    # default route is gone ("missing default interface"), even with
    # route.default_interface set. Own the default ourselves.
    n=0
    while [ "${n}" -lt 50 ]; do
        if ip link show tun0 >/dev/null 2>&1; then
            # Prefer the TUN peer (sing-box auto_route table 2022 uses this).
            # Point-to-point "dev tun0" alone can black-hole kernel TCP.
            if ip -4 addr show tun0 | grep -q '10.255.254.1'; then
                ip -4 route replace default via 10.255.254.2 dev tun0
            else
                ip -4 route replace default dev tun0
            fi
            return 0
        fi
        n=$((n + 1))
        sleep 0.1
    done
    echo "tun0 did not appear; no tun default installed" >&2
    return 1
}

iso_capture_egress_iface() {
    iface="${KILLSWITCH_IFACE:-}"
    gw="${KILLSWITCH_GW:-}"
    if [ -z "${iface}" ]; then
        detected="$(iso_detect_default_v4)"
        if [ -n "${detected}" ]; then
            iface="$(echo "${detected}" | awk '{print $1}')"
            gw="$(echo "${detected}" | awk '{print $2}')"
        fi
    fi
    if [ -z "${iface}" ]; then
        echo "Unable to detect egress interface (need a default route before kill-switch)" >&2
        return 1
    fi
    export KILLSWITCH_IFACE="${iface}"
    export KILLSWITCH_GW="${gw}"
}

apply_bootstrap_filter() {
    iso_capture_egress_iface
    iso_disable_ipv6_best_effort
    iso_apply_nft_bootstrap
    echo "killswitch: bootstrap filter on (Docker DNS 127.0.0.11:53 only); iface=${KILLSWITCH_IFACE}"
}

apply_killswitch() {
    trojan_ip="${TROJAN_IP:?TROJAN_IP is required}"
    trojan_port="${TROJAN_PORT:?TROJAN_PORT is required}"
    vnc_port="${VNC_PORT:-5900}"

    if ! iso_is_ipv4 "${trojan_ip}"; then
        echo "TROJAN_IP must be IPv4, got: ${trojan_ip}" >&2
        return 1
    fi
    if ! echo "${trojan_port}" | grep -Eq '^[0-9]+$' || [ "${trojan_port}" -lt 1 ] || [ "${trojan_port}" -gt 65535 ]; then
        echo "TROJAN_PORT must be an integer 1-65535" >&2
        return 1
    fi
    if ! echo "${vnc_port}" | grep -Eq '^[0-9]+$'; then
        echo "VNC_PORT must be an integer" >&2
        return 1
    fi

    iso_capture_egress_iface
    iface="${KILLSWITCH_IFACE}"
    gw="${KILLSWITCH_GW:-}"

    echo "killswitch: iface=${iface} gw=${gw:-none} trojan=${trojan_ip}:${trojan_port} vnc=${vnc_port}"

    iso_disable_ipv6_best_effort
    iso_apply_nft "${trojan_ip}" "${trojan_port}" "${vnc_port}"
    iso_add_trojan_host_route "${trojan_ip}" "${iface}" "${gw}"
    iso_delete_defaults
    iso_write_resolv_conf

    mkdir -p /run/iso
    printf '%s\n' "${iface}" > /run/iso/iface
    printf '%s\n' "${gw}" > /run/iso/gw
    printf '%s\n' "${trojan_ip}" > /run/iso/trojan_ip
    printf '%s\n' "${trojan_port}" > /run/iso/trojan_port
}

killswitch_has_leaky_v4_default() {
    if ip -4 route show default 2>/dev/null | grep -v 'dev tun0' | grep -q default; then
        return 0
    fi
    return 1
}

killswitch_has_tun_default() {
    ip -4 route show default 2>/dev/null | grep -q 'dev tun0'
}
