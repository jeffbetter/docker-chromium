#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${ISO_ROOT}/.." && pwd)"
export ISO_ROOT
fail=0

echo "== prerequisites (do not hide) =="
echo "  required for this script: bash, python3 (stdlib only; PyYAML is NOT required)"
echo "  required for generate-config test: jq"
echo "  required for compose interpolation test: docker compose v2"
echo "  required for netns isolation: sudo, iproute2, nftables"
echo "  required for docker isolation: docker engine, /dev/net/tun"
echo "  not tested here: live Trojan nodes, browser traffic, public egress IPs, SSH to the US server"

if ! command -v python3 >/dev/null 2>&1; then
    echo "missing python3" >&2
    exit 1
fi

echo "== syntax: shell =="
while IFS= read -r f; do
    if head -n 1 "${f}" | grep -q bash; then
        bash -n "${f}" || fail=1
    else
        sh -n "${f}" || fail=1
    fi
    echo "  ok ${f#"${REPO_ROOT}/"}"
done < <(find "${ISO_ROOT}/scripts" "${ISO_ROOT}/egress" "${ISO_ROOT}/tests" -type f \( -name '*.sh' \) | sort)

echo "== syntax: compose yaml (stdlib; no PyYAML) =="
python3 - <<'PY'
from pathlib import Path
import os
p = Path(os.environ["ISO_ROOT"]) / "compose.yaml"
text = p.read_text()
assert 'network_mode: "service:egress"' in text
assert "127.0.0.1:${HOST_VNC_PORT}:5900" in text
assert "0.0.0.0:" not in text
assert "/var/run/docker.sock" not in text
assert "network_mode: host" not in text
assert "privileged: false" in text
assert "TROJAN_PASSWORD: ${TROJAN_PASSWORD}" not in text
assert "VNC_PASSWORD: ${VNC_PASSWORD}" not in text
assert "env_file:" in text
assert "ISO_ENV_FILE" in text
chrome = text.split("\n  chromium:\n", 1)[1]
assert "- NET_ADMIN" in chrome.split("\nnetworks:\n", 1)[0]
egress = text.split("\n  egress:\n", 1)[1].split("\n  chromium:\n", 1)[0]
assert "- NET_ADMIN" in egress
print("  compose structure ok (no PyYAML)")
PY

echo "== syntax: json policies =="
python3 -m json.tool "${ISO_ROOT}/chromium/isolation-policies.json" >/dev/null
python3 - <<'PY'
import json, pathlib, os
p = pathlib.Path(os.environ["ISO_ROOT"]) / "chromium/isolation-policies.json"
data = json.loads(p.read_text())
assert data["WebRtcIPHandling"] == "disable_non_proxied_udp"
print("  policy ok")
PY

echo "== syntax: examples must not disable TLS verify =="
if grep -RInE 'TROJAN_INSECURE=|insecure:\s*true|skip-cert-verify:\s*true' \
        "${ISO_ROOT}/identities" "${ISO_ROOT}/compose.yaml" "${ISO_ROOT}/egress"; then
    echo "production overlay files must not disable certificate verification" >&2
    fail=1
else
    echo "  no insecure TLS in overlay sources"
fi

echo "== syntax: example secrets are placeholders =="
if grep -RInE 'TROJAN_PASSWORD=.+' "${ISO_ROOT}/identities"/*.example | grep -vE 'change-me'; then
    echo "example env files must not contain non-placeholder passwords" >&2
    fail=1
else
    echo "  example passwords are placeholders"
fi

echo "== syntax: Dockerfile pins sing-box digest =="
if grep -q 'sha256:0788ffbddab2c68a99a2dd4780bbc50902f159af6f589df3ee74a8389d278279' \
        "${ISO_ROOT}/egress/Dockerfile"; then
    echo "  digest pin present"
else
    echo "sing-box image is not digest-pinned" >&2
    fail=1
fi

echo "== generate sing-box config from official Trojan fields =="
if ! command -v jq >/dev/null 2>&1; then
    echo "missing jq; generate-config test cannot run" >&2
    fail=1
else
    # shellcheck disable=SC1091
    . "${ISO_ROOT}/egress/generate-config.sh"
    tmp="$(mktemp)"
    TROJAN_IP=192.0.2.10
    TROJAN_PORT=443
    TROJAN_PASSWORD='test-only-not-a-real-secret'
    TROJAN_SNI='exit-a.example.invalid'
    TROJAN_ALPN='h2,http/1.1'
    TROJAN_BIND_INTERFACE='eth0'
    generate_singbox_config "${tmp}"
    python3 - <<PY
import json
c=json.load(open("${tmp}"))
tls=c["outbounds"][0]["tls"]
assert c["outbounds"][0]["type"]=="trojan"
assert tls["enabled"] is True
assert tls["insecure"] is False
assert tls["disable_sni"] is False
assert tls["server_name"]=="exit-a.example.invalid"
assert c["inbounds"][1]["strict_route"] is True
assert c["inbounds"][1]["auto_redirect"] is False
assert c["inbounds"][0]["listen_port"]==53
assert c["route"]["final"]=="trojan-out"
assert c["route"]["auto_detect_interface"] is False
assert c["route"]["default_interface"]=="eth0"
print("  mapped config ok")
PY
    if command -v sing-box >/dev/null 2>&1; then
        sing-box check -c "${tmp}"
        echo "  sing-box check ok"
    elif [ -x /tmp/sing-box ]; then
        /tmp/sing-box check -c "${tmp}"
        echo "  sing-box check ok (/tmp/sing-box)"
    else
        echo "  sing-box binary not on host; JSON assertions only"
    fi
    rm -f "${tmp}"
fi

echo "== generate-config refuses TROJAN_INSECURE =="
if TROJAN_IP=192.0.2.10 TROJAN_PORT=443 TROJAN_PASSWORD='x' TROJAN_SNI='s.example.invalid' TROJAN_INSECURE=true \
    sh -c '. "'"${ISO_ROOT}"'/egress/generate-config.sh"; generate_singbox_config /tmp/should-not-exist.json' \
    2>/dev/null; then
    echo "generate-config should refuse TROJAN_INSECURE" >&2
    fail=1
else
    echo "  insecure refused"
fi

echo "== env loader does not eval values =="
rm -f /tmp/iso-env-pwned
# shellcheck disable=SC1091
. "${ISO_ROOT}/scripts/common.sh"
iso_load_env "${TEST_DIR}/fixtures/inject.env"
if [ -e /tmp/iso-env-pwned ]; then
    echo "env loader executed command substitution" >&2
    fail=1
    rm -f /tmp/iso-env-pwned
else
    echo "  injection stayed literal"
fi
if [ "${TROJAN_PASSWORD}" != '$(touch /tmp/iso-env-pwned)' ]; then
    echo "password was rewritten: ${TROJAN_PASSWORD}" >&2
    fail=1
fi

echo "== validate-exits =="
if "${ISO_ROOT}/scripts/validate-exits.sh" \
        "${TEST_DIR}/fixtures/dup-a.env" "${TEST_DIR}/fixtures/dup-b.env"; then
    echo "duplicate endpoint tuples should fail" >&2
    fail=1
else
    echo "  duplicate endpoint tuples rejected"
fi
if ! "${ISO_ROOT}/scripts/validate-exits.sh" \
        "${TEST_DIR}/fixtures/ok-a.env" "${TEST_DIR}/fixtures/ok-b.env"; then
    echo "distinct endpoint tuples should pass config check" >&2
    fail=1
else
    echo "  distinct tuples accepted (NOT a public-IP proof)"
fi
if "${ISO_ROOT}/scripts/validate-exits.sh" "${TEST_DIR}/fixtures/insecure.env"; then
    echo "insecure env should fail" >&2
    fail=1
else
    echo "  insecure env rejected"
fi
if "${ISO_ROOT}/scripts/validate-exits.sh" \
        "${TEST_DIR}/fixtures/claim-same-a.env" "${TEST_DIR}/fixtures/claim-same-b.env"; then
    echo "same TROJAN_PUBLIC_EXIT_CLAIM with different host:port must fail" >&2
    fail=1
else
    echo "  same public-exit claim rejected despite different host:port"
fi

echo "== compose must not expand \$ in TROJAN_PASSWORD =="
if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    echo "  skipped (docker compose not available)"
else
    tmpd="$(mktemp -d)"
    cp "${TEST_DIR}/fixtures/dollar.env" "${tmpd}/dollar.env"
    echo "ISO_DATA_DIR=${tmpd}" >> "${tmpd}/dollar.env"
    # shellcheck disable=SC1091
    . "${ISO_ROOT}/scripts/common.sh"
    ISO_IDENTITY=dollar
    ISO_ENV_FILE="${tmpd}/dollar.env"
    iso_escape_env_file "${tmpd}/dollar.env" "${tmpd}/.compose.env"
    export ISO_ENV_FILE="${tmpd}/.compose.env" ISO_IDENTITY=dollar HOST_VNC_PORT=5951 ISO_DATA_DIR="${tmpd}"
    rendered="$(docker compose --project-directory "${ISO_ROOT}" --env-file "${tmpd}/.compose.env" \
        -f "${ISO_ROOT}/compose.yaml" -p iso-dollar-test config 2>/dev/null)"
    if echo "${rendered}" | grep -q '/home/'; then
        echo "password HOME was expanded in compose output" >&2
        echo "${rendered}" | grep PASSWORD >&2 || true
        fail=1
    elif echo "${rendered}" | grep -E 'TROJAN_PASSWORD: ab(\$\$|\$)cd' >/dev/null; then
        echo "  compose preserved dollar characters in TROJAN_PASSWORD (not expanded to HOME)"
    else
        echo "could not find preserved password in compose config" >&2
        echo "${rendered}" | grep PASSWORD >&2 || true
        fail=1
    fi
    rm -rf "${tmpd}"
    unset ISO_ENV_FILE
fi

if [ "${fail}" -ne 0 ]; then
    echo "syntax tests FAILED"
    exit 1
fi
echo "syntax tests passed"
