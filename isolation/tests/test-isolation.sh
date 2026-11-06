#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
SKIPPED=()
FAILED=0

echo "== isolation: syntax first =="
ISO_ROOT="${ISO_ROOT}" "${TEST_DIR}/test-syntax.sh"

have() { command -v "$1" >/dev/null 2>&1; }

cleanup_netns() {
    sudo ip netns del iso-ks-app 2>/dev/null || true
    sudo ip netns del iso-ks-int 2>/dev/null || true
}

run_netns_isolation() {
    echo "== isolation: netns kill-switch (proxy-down primitives) =="
    if ! have sudo || ! sudo -n true 2>/dev/null; then
        SKIPPED+=("netns: sudo not available")
        return 0
    fi
    sudo apt-get update -qq >/dev/null 2>&1 || true
    sudo apt-get install -y -qq iproute2 nftables iputils-ping >/dev/null
    if ! have nft && [ ! -x /usr/sbin/nft ]; then
        SKIPPED+=("netns: nftables not available")
        return 0
    fi
    PATH="/usr/sbin:/sbin:${PATH}"
    cleanup_netns
    trap cleanup_netns EXIT

    sudo ip netns add iso-ks-int
    sudo ip netns add iso-ks-app
    sudo ip link add veth-ks-a type veth peer name veth-ks-i
    sudo ip link set veth-ks-a netns iso-ks-app
    sudo ip link set veth-ks-i netns iso-ks-int
    sudo ip netns exec iso-ks-int ip link set lo up
    sudo ip netns exec iso-ks-int ip link set veth-ks-i up
    sudo ip netns exec iso-ks-int ip addr add 192.0.2.1/24 dev veth-ks-i
    sudo ip netns exec iso-ks-app ip link set lo up
    sudo ip netns exec iso-ks-app ip link set veth-ks-a up
    sudo ip netns exec iso-ks-app ip addr add 192.0.2.2/24 dev veth-ks-a
    sudo ip netns exec iso-ks-app ip route add default via 192.0.2.1

    sudo ip netns exec iso-ks-app env \
        TROJAN_IP=192.0.2.1 TROJAN_PORT=443 VNC_PORT=5900 \
        KILLSWITCH_IFACE=veth-ks-a KILLSWITCH_GW=192.0.2.1 \
        ISO_SKIP_RESOLV=1 \
        /bin/sh -c '. "'"${ISO_ROOT}"'/egress/killswitch.sh"; apply_killswitch'

    if sudo ip netns exec iso-ks-app ip -4 route show default | grep -v 'dev tun0' | grep -q default; then
        echo "FAIL: leaky IPv4 default still present" >&2
        FAILED=1
    else
        echo "  no leaky IPv4 default"
    fi
    if sudo ip netns exec iso-ks-app ip -6 route show default 2>/dev/null | grep -q default; then
        echo "FAIL: IPv6 default present" >&2
        FAILED=1
    else
        echo "  no IPv6 default"
    fi
    if sudo ip netns exec iso-ks-app ip route get 1.1.1.1 >/dev/null 2>&1; then
        via="$(sudo ip netns exec iso-ks-app ip route get 1.1.1.1 | tr '\n' ' ')"
        if echo "${via}" | grep -q 'dev veth-ks-a'; then
            echo "FAIL: 1.1.1.1 still routed via veth (direct path): ${via}" >&2
            FAILED=1
        fi
    else
        echo "  1.1.1.1 has no route (closed)"
    fi
    if sudo ip netns exec iso-ks-app ping -n -c 1 -W 1 1.1.1.1 >/dev/null 2>&1; then
        echo "FAIL: ICMP to 1.1.1.1 succeeded while proxy down" >&2
        FAILED=1
    else
        echo "  ICMP to 1.1.1.1 failed closed"
    fi
    if sudo ip netns exec iso-ks-app ping -n -c 1 -W 1 -6 2001:4860:4860::8888 >/dev/null 2>&1; then
        echo "FAIL: IPv6 ping succeeded" >&2
        FAILED=1
    else
        echo "  IPv6 ping failed closed"
    fi
    if sudo ip netns exec iso-ks-app timeout 2 sh -c 'echo leak >/dev/udp/1.1.1.1/53' 2>/dev/null; then
        if sudo ip netns exec iso-ks-app ip route get 1.1.1.1 >/dev/null 2>&1 && \
           sudo ip netns exec iso-ks-app ip route get 1.1.1.1 | grep -q 'dev veth-ks-a'; then
            echo "FAIL: UDP still has a direct path" >&2
            FAILED=1
        else
            echo "  UDP has no direct route"
        fi
    else
        echo "  UDP send failed closed"
    fi
    echo "  LIMITATION: netns test does not run Chromium or a live Trojan"

    cleanup_netns
    trap - EXIT
}

wait_nft() {
    local name="$1" i
    for i in $(seq 1 30); do
        if docker exec "${name}" nft list table inet iso_killswitch >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

run_docker_isolation() {
    echo "== isolation: docker egress primitives =="
    if ! have docker; then
        SKIPPED+=("docker: docker not installed")
        return 0
    fi
    if ! docker info >/dev/null 2>&1; then
        SKIPPED+=("docker: daemon not reachable")
        return 0
    fi
    img="iso-chromium-egress:test"
    docker build -t "${img}" "${ISO_ROOT}/egress"

    echo "-- proxy-down (ISO_SKIP_SINGBOX=1) --"
    name="iso-isolation-test-down"
    docker rm -f "${name}" >/dev/null 2>&1 || true
    docker run -d --name "${name}" \
        --cap-drop=ALL --cap-add=NET_ADMIN \
        --device /dev/net/tun \
        --sysctl net.ipv6.conf.all.disable_ipv6=1 \
        --sysctl net.ipv6.conf.default.disable_ipv6=1 \
        -e TROJAN_SERVER=192.0.2.1 \
        -e TROJAN_PORT=443 \
        -e TROJAN_PASSWORD=test-only-not-a-real-secret \
        -e TROJAN_SNI=test.example.invalid \
        -e ISO_SKIP_SINGBOX=1 \
        --publish 127.0.0.1:15900:5900 \
        "${img}" >/dev/null
    wait_nft "${name}" || { echo "FAIL: nft table never appeared" >&2; FAILED=1; docker rm -f "${name}" >/dev/null; return 0; }

    if docker exec "${name}" ip -4 route show default | grep -v 'dev tun0' | grep -q default; then
        echo "FAIL: docker egress still has leaky default" >&2
        FAILED=1
    else
        echo "  docker down: no leaky IPv4 default"
    fi
    if docker exec "${name}" ping -n -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
        echo "FAIL: docker egress ICMP leaked while proxy skipped" >&2
        FAILED=1
    else
        echo "  docker down: ICMP failed closed"
    fi
    if docker exec "${name}" ping -n -c 1 -W 2 -6 2001:4860:4860::8888 >/dev/null 2>&1; then
        echo "FAIL: docker egress IPv6 leaked" >&2
        FAILED=1
    else
        echo "  docker down: IPv6 failed closed"
    fi
    if docker exec "${name}" sh -c 'dig +time=2 +tries=1 @8.8.8.8 google.com >/dev/null'; then
        echo "FAIL: docker egress DNS to 8.8.8.8 succeeded while proxy down" >&2
        FAILED=1
    else
        echo "  docker down: DNS to 8.8.8.8 failed closed"
    fi
    if docker exec "${name}" sh -c 'dig +time=2 +tries=1 @127.0.0.11 google.com >/dev/null'; then
        echo "FAIL: docker embedded DNS leaked" >&2
        FAILED=1
    else
        echo "  docker down: 127.0.0.11 DNS failed closed"
    fi
    if docker exec "${name}" cat /etc/resolv.conf | grep -q '127.0.0.11'; then
        echo "FAIL: resolv.conf still has 127.0.0.11" >&2
        FAILED=1
    else
        echo "  docker down: resolv.conf pinned off 127.0.0.11"
    fi
    gw="$(docker exec "${name}" ip -4 route show | awk '/dev eth0/ && /proto kernel/ {print}' | head -n1)"
    echo "  docker down: connected eth0 route remains (${gw:-none}); nft must drop it"
    if docker exec "${name}" curl -sS -m 3 -o /dev/null http://172.17.0.1:80 >/dev/null 2>&1; then
        echo "FAIL: TCP to docker gateway succeeded (connected-route leak)" >&2
        FAILED=1
    else
        echo "  docker down: TCP to docker gateway failed closed"
    fi
    if ss -ltn | grep -q '127.0.0.1:15900'; then
        echo "  docker down: VNC publish is 127.0.0.1:15900"
    else
        echo "FAIL: host did not bind 127.0.0.1:15900" >&2
        FAILED=1
    fi
    if ss -ltn | grep 15900 | grep -q '0.0.0.0:15900'; then
        echo "FAIL: VNC published on 0.0.0.0" >&2
        FAILED=1
    fi
    docker rm -f "${name}" >/dev/null

    echo "-- sing-box up (blackhole Trojan) then process death --"
    echo "  LIMITATION: blackhole is not a live proxy; this is not failover through a real node"
    name="iso-isolation-test-sb"
    docker rm -f "${name}" >/dev/null 2>&1 || true
    docker run -d --name "${name}" \
        --cap-drop=ALL --cap-add=NET_ADMIN \
        --device /dev/net/tun \
        --sysctl net.ipv6.conf.all.disable_ipv6=1 \
        --sysctl net.ipv6.conf.default.disable_ipv6=1 \
        -e TROJAN_SERVER=192.0.2.1 \
        -e TROJAN_PORT=443 \
        -e TROJAN_PASSWORD=test-only-not-a-real-secret \
        -e TROJAN_SNI=test.example.invalid \
        --publish 127.0.0.1:15901:5900 \
        "${img}" >/dev/null

    tun_ok=0
    for _ in $(seq 1 40); do
        if docker exec "${name}" ip link show tun0 >/dev/null 2>&1 \
           && docker exec "${name}" ip -4 route show default 2>/dev/null | grep -q 'dev tun0'; then
            tun_ok=1
            break
        fi
        sleep 0.5
    done
    if [ "${tun_ok}" -ne 1 ]; then
        echo "FAIL: tun0 default never appeared (auto_route/default_interface)" >&2
        docker logs "${name}" >&2 || true
        FAILED=1
    else
        echo "  docker up: IPv4 default via tun0"
    fi
    if docker exec "${name}" ip -4 route show default | grep -v 'dev tun0' | grep -q default; then
        echo "FAIL: leaky default present while tun is up" >&2
        FAILED=1
    fi
    if docker exec "${name}" sh -c 'ss -ulnp | grep -q 127.0.0.1:53 || ss -tlnp | grep -q 127.0.0.1:53'; then
        echo "  docker up: sing-box listening on 127.0.0.1:53"
    else
        echo "FAIL: no DNS listener on 127.0.0.1:53" >&2
        docker exec "${name}" sh -c 'ss -ulnp; ss -tlnp' >&2 || true
        FAILED=1
    fi
    # Listener present: query should not be 'connection refused'. Timeout/SERVFAIL is OK (blackhole).
    dns_out="$(docker exec "${name}" sh -c 'dig +time=2 +tries=1 @127.0.0.1 google.com 2>&1' || true)"
    if echo "${dns_out}" | grep -qi 'connection refused'; then
        echo "FAIL: 127.0.0.1:53 connection refused while sing-box up" >&2
        echo "${dns_out}" >&2
        FAILED=1
    else
        echo "  docker up: 127.0.0.1:53 is not connection-refused (backend may still fail closed)"
    fi

    docker exec "${name}" sh -c 'pkill -KILL -x sing-box || true'
    sleep 0.4
    if docker exec "${name}" ip -4 route show default | grep -v 'dev tun0' | grep -q default; then
        echo "FAIL: eth0 default returned after sing-box death" >&2
        docker exec "${name}" ip -4 route >&2 || true
        FAILED=1
    else
        echo "  docker death: no leaky IPv4 default restored"
    fi
    if docker exec "${name}" ping -n -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
        echo "FAIL: ICMP leaked after sing-box death" >&2
        FAILED=1
    else
        echo "  docker death: ICMP failed closed"
    fi
    if docker exec "${name}" nft list table inet iso_killswitch >/dev/null 2>&1; then
        echo "  docker death: nft table still present"
    else
        echo "FAIL: nft table gone after process death" >&2
        FAILED=1
    fi
    docker rm -f "${name}" >/dev/null
    echo "  LIMITATION: did not start jlesage/chromium; no end-to-end browser packet capture"
    echo "  LIMITATION: proxy-down / process-death != live Trojan failover"
}

run_netns_isolation
run_docker_isolation

echo
if [ "${#SKIPPED[@]}" -gt 0 ]; then
    echo "Skipped (runtime not available):"
    for s in "${SKIPPED[@]}"; do
        echo "  - ${s}"
    done
fi
if [ "${FAILED}" -ne 0 ]; then
    echo "isolation tests FAILED"
    exit 1
fi
echo "isolation tests passed (kill-switch primitives only; live public IP / logins / browser traffic were not probed)"
