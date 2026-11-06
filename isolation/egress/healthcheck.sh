#!/bin/sh
set -eu

if [ ! -f /usr/local/bin/killswitch.sh ]; then
    echo "killswitch helper missing"
    exit 1
fi
# shellcheck disable=SC1091
. /usr/local/bin/killswitch.sh

nft list table inet iso_killswitch >/dev/null

if killswitch_has_leaky_v4_default; then
    echo "leaky IPv4 default route present"
    exit 1
fi

if ip -6 route show default 2>/dev/null | grep -q default; then
    echo "IPv6 default route present"
    exit 1
fi

if grep -q '127.0.0.11' /etc/resolv.conf 2>/dev/null; then
    echo "Docker embedded DNS still in resolv.conf"
    exit 1
fi

if ! pgrep -x sing-box >/dev/null 2>&1; then
    echo "sing-box not running"
    exit 1
fi

if ! ip link show tun0 >/dev/null 2>&1; then
    echo "tun0 missing"
    exit 1
fi

exit 0
