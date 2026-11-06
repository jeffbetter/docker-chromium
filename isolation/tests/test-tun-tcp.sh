#!/usr/bin/env bash
# Positive TUN TCP through a local Trojan TLS server. Not a live user node.
# Fail-closed after proxy death is only asserted if the positive path passed.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
SB="${ISO_SINGBOX_BIN:-}"
if [ -z "${SB}" ]; then
    for c in sing-box /tmp/sb1144/sing-box /tmp/sing-box; do
        if command -v "${c}" >/dev/null 2>&1; then SB="$(command -v "${c}")"; break; fi
        if [ -x "${c}" ]; then SB="${c}"; break; fi
    done
fi

have() { command -v "$1" >/dev/null 2>&1; }

if [ -z "${SB}" ]; then
    echo "SKIP: no sing-box binary for TUN TCP fixture (set ISO_SINGBOX_BIN)"
    exit 0
fi
if ! have sudo || ! sudo -n true 2>/dev/null; then
    echo "SKIP: sudo required for TUN TCP netns fixture"
    exit 0
fi
if ! have nft && [ ! -x /usr/sbin/nft ]; then
    echo "SKIP: nftables required for TUN TCP fixture"
    exit 0
fi
if ! have openssl || ! have python3 || ! have jq; then
    echo "SKIP: openssl/python3/jq required for TUN TCP fixture"
    exit 0
fi

PATH="/usr/sbin:/sbin:${PATH}"
WORKDIR="$(mktemp -d)"
SRV=iso-tcp-srv
CLI=iso-tcp-cli
cleanup() {
    sudo ip netns del "${CLI}" 2>/dev/null || true
    sudo ip netns del "${SRV}" 2>/dev/null || true
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

sudo ip netns del "${CLI}" 2>/dev/null || true
sudo ip netns del "${SRV}" 2>/dev/null || true
sudo ip netns add "${SRV}"
sudo ip netns add "${CLI}"
sudo ip link add veth-tcp-s type veth peer name veth-tcp-c
sudo ip link set veth-tcp-s netns "${SRV}"
sudo ip link set veth-tcp-c netns "${CLI}"
sudo ip netns exec "${SRV}" ip link set lo up
sudo ip netns exec "${SRV}" ip link set veth-tcp-s up
sudo ip netns exec "${SRV}" ip addr add 192.0.2.1/24 dev veth-tcp-s
# Origin is NOT the Trojan address and NOT the veth subnet (those stay on-link
# and must not be the TUN TCP probe, matching public-IP app traffic).
sudo ip netns exec "${SRV}" ip addr add 198.51.100.1/32 dev lo
sudo ip netns exec "${CLI}" ip link set lo up
sudo ip netns exec "${CLI}" ip link set veth-tcp-c up
sudo ip netns exec "${CLI}" ip addr add 192.0.2.2/24 dev veth-tcp-c
sudo ip netns exec "${CLI}" ip route add default via 192.0.2.1

openssl req -x509 -newkey rsa:2048 -keyout "${WORKDIR}/key.pem" -out "${WORKDIR}/cert.pem" \
    -days 1 -nodes -subj '/CN=trojan.test' \
    -addext 'subjectAltName=DNS:trojan.test' >/dev/null 2>&1
printf 'tun-tcp-ok\n' > "${WORKDIR}/index.html"

cat > "${WORKDIR}/server.json" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [{
    "type": "trojan",
    "listen": "0.0.0.0",
    "listen_port": 443,
    "users": [{ "name": "t", "password": "test-only-not-a-real-secret" }],
    "tls": {
      "enabled": true,
      "certificate_path": "${WORKDIR}/cert.pem",
      "key_path": "${WORKDIR}/key.pem"
    }
  }],
  "outbounds": [{ "type": "direct" }]
}
EOF

sudo ip netns exec "${SRV}" python3 -m http.server 8080 --directory "${WORKDIR}" \
    >"${WORKDIR}/http.log" 2>&1 &
http_pid=$!
sudo ip netns exec "${SRV}" "${SB}" run -c "${WORKDIR}/server.json" \
    >"${WORKDIR}/server.log" 2>&1 &
srv_pid=$!
sleep 0.4

# shellcheck disable=SC1091
. "${ISO_ROOT}/egress/killswitch.sh"
# shellcheck disable=SC1091
. "${ISO_ROOT}/egress/generate-config.sh"

sudo ip netns exec "${CLI}" env \
    TROJAN_IP=192.0.2.1 TROJAN_PORT=443 VNC_PORT=5900 \
    KILLSWITCH_IFACE=veth-tcp-c KILLSWITCH_GW=192.0.2.1 \
    ISO_SKIP_RESOLV=1 \
    /bin/sh -c '. "'"${ISO_ROOT}"'/egress/killswitch.sh"; apply_killswitch'

sudo ip netns exec "${CLI}" env \
    TROJAN_IP=192.0.2.1 TROJAN_PORT=443 TROJAN_PASSWORD='test-only-not-a-real-secret' \
    TROJAN_SNI=trojan.test TROJAN_CERTIFICATE_PATH="${WORKDIR}/cert.pem" \
    TROJAN_BIND_INTERFACE=veth-tcp-c KILLSWITCH_IFACE=veth-tcp-c \
    /bin/sh -c '. "'"${ISO_ROOT}"'/egress/generate-config.sh"; generate_singbox_config "'"${WORKDIR}"'/client.json"'

sudo ip netns exec "${CLI}" "${SB}" run -c "${WORKDIR}/client.json" \
    >"${WORKDIR}/client.log" 2>&1 &
cli_pid=$!

tun_ok=0
for _ in $(seq 1 40); do
    if sudo ip netns exec "${CLI}" ip link show tun0 >/dev/null 2>&1; then
        sudo ip netns exec "${CLI}" env \
            /bin/sh -c '. "'"${ISO_ROOT}"'/egress/killswitch.sh"; iso_install_tun_default' || true
        tun_ok=1
        break
    fi
    sleep 0.1
done
if [ "${tun_ok}" -ne 1 ]; then
    echo "FAIL: tun0 never appeared in TUN TCP fixture" >&2
    cat "${WORKDIR}/client.log" >&2 || true
    exit 1
fi
body=""
tcp_ok=0
for _ in $(seq 1 20); do
    body="$(sudo ip netns exec "${CLI}" python3 - <<'PY' 2>/dev/null || true
import socket, sys
s = socket.create_connection(("198.51.100.1", 8080), timeout=2)
s.sendall(b"GET /index.html HTTP/1.0\r\nHost: origin.test\r\n\r\n")
data = b""
while True:
    chunk = s.recv(4096)
    if not chunk:
        break
    data += chunk
sys.stdout.buffer.write(data)
s.close()
PY
)"
    if echo "${body}" | grep -q 'tun-tcp-ok'; then
        tcp_ok=1
        break
    fi
    sleep 0.25
done

if [ "${tcp_ok}" -ne 1 ]; then
    echo "FAIL: application TCP through TUN did not reach origin via local Trojan TLS" >&2
    sudo ip netns exec "${CLI}" ip -4 route show >&2 || true
    python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); print("stack", c["inbounds"][1].get("stack"), "insecure", c["outbounds"][0]["tls"]["insecure"])' "${WORKDIR}/client.json" >&2 || true
    echo "---- client.log ----" >&2
    cat "${WORKDIR}/client.log" >&2 || true
    echo "---- server.log ----" >&2
    cat "${WORKDIR}/server.log" >&2 || true
    echo "---- http body ----" >&2
    echo "${body}" >&2
    echo "LIMITATION: blackhole/proxy-down curl is NOT a kill-switch pass while TUN TCP baseline is broken" >&2
    exit 1
fi
echo "  TUN TCP via local Trojan TLS: got tun-tcp-ok"

sudo kill -KILL "${cli_pid}" 2>/dev/null || true
sudo ip netns exec "${CLI}" pkill -KILL -x sing-box 2>/dev/null || true
sleep 1
closed=1
if sudo ip netns exec "${CLI}" python3 - <<'PY' 2>/dev/null
import socket
s = socket.create_connection(("198.51.100.1", 8080), timeout=2)
s.close()
raise SystemExit(0)
PY
then
    echo "FAIL: TCP to origin:8080 still succeeded after sing-box death" >&2
    sudo ip netns exec "${CLI}" ip -4 route show >&2 || true
    closed=0
fi
if [ "${closed}" -ne 1 ]; then
    exit 1
fi
echo "  after proxy death: origin:8080 failed closed (positive baseline had passed)"

kill "${http_pid}" "${srv_pid}" 2>/dev/null || true
echo "TUN TCP fixture passed (local Trojan TLS; not a user node)"
