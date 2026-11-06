#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${ISO_ROOT}/.." && pwd)"
export ISO_ROOT
fail=0

echo "== syntax: shell =="
while IFS= read -r f; do
    if head -n 1 "${f}" | grep -q bash; then
        bash -n "${f}" || fail=1
    else
        sh -n "${f}" || fail=1
    fi
    echo "  ok ${f#"${REPO_ROOT}/"}"
done < <(find "${ISO_ROOT}/scripts" "${ISO_ROOT}/egress" "${ISO_ROOT}/tests" -type f \( -name '*.sh' \) | sort)

echo "== syntax: compose yaml =="
python3 - <<PY
import sys, pathlib
try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required")
p = pathlib.Path("${ISO_ROOT}/compose.yaml")
docs = list(yaml.safe_load_all(p.read_text()))
assert docs and docs[0]["services"]["egress"]
assert docs[0]["services"]["chromium"]["network_mode"] == "service:egress"
assert docs[0]["services"]["chromium"].get("ports") in (None, [])
caps = docs[0]["services"]["chromium"].get("cap_add") or []
assert "NET_ADMIN" not in caps
assert "NET_ADMIN" in (docs[0]["services"]["chromium"].get("cap_drop") or [])
assert "NET_ADMIN" in (docs[0]["services"]["egress"].get("cap_add") or [])
assert docs[0]["services"]["egress"].get("privileged") is False
assert docs[0]["services"]["chromium"].get("privileged") is False
ports = docs[0]["services"]["egress"]["ports"]
assert ports[0].startswith("127.0.0.1:")
pub = str(docs[0]["services"]["egress"]["ports"])
assert "0.0.0.0" not in pub
assert "/var/run/docker.sock" not in p.read_text()
assert "host" not in str(docs[0]["services"]["chromium"].get("network_mode"))
print("  compose structure ok")
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

echo "== generate sing-box config from official Trojan fields =="
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
assert c["inbounds"][0]["strict_route"] is True
assert c["inbounds"][0]["auto_redirect"] is False
assert c["route"]["final"]=="trojan-out"
print("  mapped config ok")
PY
if command -v sing-box >/dev/null 2>&1; then
    sing-box check -c "${tmp}"
    echo "  sing-box check ok"
elif [ -x /tmp/sing-box ]; then
    /tmp/sing-box check -c "${tmp}"
    echo "  sing-box check ok (/tmp/sing-box)"
else
    echo "  sing-box binary not present; JSON assertions only"
fi
rm -f "${tmp}"

echo "== generate-config refuses TROJAN_INSECURE =="
if TROJAN_IP=192.0.2.10 TROJAN_PORT=443 TROJAN_PASSWORD='x' TROJAN_SNI='s.example.invalid' TROJAN_INSECURE=true \
    sh -c '. "'"${ISO_ROOT}"'/egress/generate-config.sh"; generate_singbox_config /tmp/should-not-exist.json' \
    2>/dev/null; then
    echo "generate-config should refuse TROJAN_INSECURE" >&2
    fail=1
else
    echo "  insecure refused"
fi

echo "== validate-exits =="
if "${ISO_ROOT}/scripts/validate-exits.sh" \
        "${TEST_DIR}/fixtures/dup-a.env" "${TEST_DIR}/fixtures/dup-b.env"; then
    echo "duplicate exits should fail" >&2
    fail=1
else
    echo "  duplicate exits rejected"
fi
if ! "${ISO_ROOT}/scripts/validate-exits.sh" \
        "${TEST_DIR}/fixtures/ok-a.env" "${TEST_DIR}/fixtures/ok-b.env"; then
    echo "distinct exits should pass" >&2
    fail=1
else
    echo "  distinct exits accepted"
fi
if "${ISO_ROOT}/scripts/validate-exits.sh" "${TEST_DIR}/fixtures/insecure.env"; then
    echo "insecure env should fail" >&2
    fail=1
else
    echo "  insecure env rejected"
fi

if [ "${fail}" -ne 0 ]; then
    echo "syntax tests FAILED"
    exit 1
fi
echo "syntax tests passed"
