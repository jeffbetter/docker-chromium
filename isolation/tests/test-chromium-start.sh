#!/usr/bin/env bash
# Start the official jlesage/chromium image with production cap_drop.
# Require a real Chromium process, not only Xvnc/RFB.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
IMG="${CHROMIUM_IMAGE:-jlesage/chromium:v26.10.1@sha256:71e2e8468eb00519a1f90cbb82a12651c2541c6f5e85030faf9c8dd2ec2cc831}"
NAME="iso-jlesage-start-reg"

have() { command -v "$1" >/dev/null 2>&1; }
if ! have docker || ! docker info >/dev/null 2>&1; then
    echo "FAIL: docker required to launch official jlesage/chromium" >&2
    exit 1
fi

docker rm -f "${NAME}" >/dev/null 2>&1 || true
tmpd="$(mktemp -d)"
cleanup() {
    docker rm -f "${NAME}" >/dev/null 2>&1 || true
    rm -rf "${tmpd}"
}
trap cleanup EXIT

# Production-equivalent privileges (compose chromium service).
if ! docker run -d --name "${NAME}" \
        --restart=no \
        --privileged=false \
        --security-opt no-new-privileges:true \
        --cap-drop NET_ADMIN \
        --cap-drop NET_RAW \
        --cap-drop SYS_MODULE \
        --cap-drop SYS_PTRACE \
        --shm-size 256m \
        -e USER_ID=1000 \
        -e GROUP_ID=1000 \
        -e KEEP_APP_RUNNING=0 \
        -e WEB_LISTENING_PORT=-1 \
        -e VNC_LISTENING_PORT=5900 \
        -e VNC_LOCALHOST_ONLY=0 \
        -e SECURE_CONNECTION=0 \
        -e ENABLE_CJK_FONT=0 \
        -e CHROMIUM_REMOTE_DEBUGGING=0 \
        -v "${tmpd}:/config:rw" \
        -v "${ISO_ROOT}/chromium/11-nginx-listen-fix.sh:/etc/cont-init.d/11-nginx-listen-fix.sh:ro" \
        "${IMG}" >/dev/null; then
    echo "FAIL: could not create official chromium container" >&2
    exit 1
fi

ok=0
for i in $(seq 1 40); do
    if ! docker inspect -f '{{.State.Running}}' "${NAME}" 2>/dev/null | grep -q true; then
        echo "FAIL: chromium container exited during startup" >&2
        docker logs "${NAME}" 2>&1 | tail -40 >&2 || true
        exit 1
    fi
    if docker logs "${NAME}" 2>&1 | grep -q 'Operation not permitted'; then
        echo "FAIL: nginx/filecap EPERM in logs (NET_BIND_SERVICE dropped?)" >&2
        docker logs "${NAME}" 2>&1 | tail -40 >&2
        exit 1
    fi
    if docker exec "${NAME}" sh -c 'pgrep -f "/usr/lib/chromium/chromium" >/dev/null 2>&1 || pgrep -x chromium >/dev/null 2>&1 || pgrep -x chromium-browser >/dev/null 2>&1'; then
        ok=1
        break
    fi
    sleep 1
done

if [ "${ok}" -ne 1 ]; then
    echo "FAIL: Chromium process never appeared (Xvnc-only is not enough)" >&2
    docker exec "${NAME}" sh -c 'ps -ef | head -40' >&2 || true
    docker logs "${NAME}" 2>&1 | tail -50 >&2 || true
    exit 1
fi

# Stay up past the observed ~10s supervisor restart window.
sleep 12
if ! docker inspect -f '{{.State.Running}}' "${NAME}" | grep -q true; then
    echo "FAIL: container died after Chromium appeared" >&2
    docker logs "${NAME}" 2>&1 | tail -40 >&2 || true
    exit 1
fi
restarts="$(docker inspect -f '{{.RestartCount}}' "${NAME}")"
if [ "${restarts}" != "0" ]; then
    echo "FAIL: RestartCount=${restarts}" >&2
    exit 1
fi
if ! docker exec "${NAME}" sh -c 'pgrep -f "/usr/lib/chromium/chromium" >/dev/null 2>&1 || pgrep -x chromium >/dev/null 2>&1 || pgrep -x chromium-browser >/dev/null 2>&1'; then
    echo "FAIL: Chromium process gone after wait" >&2
    docker exec "${NAME}" sh -c 'ps -ef | head -40' >&2 || true
    exit 1
fi
if docker logs "${NAME}" 2>&1 | grep -q 'Operation not permitted'; then
    echo "FAIL: EPERM appeared after Chromium start" >&2
    exit 1
fi

# VNC must be listening; RFB banner alone was true during the restart loop, so
# this is in addition to the Chromium process check above.
if ! docker exec "${NAME}" sh -c 'ss -ltn 2>/dev/null | grep -q ":5900" || netstat -ltn 2>/dev/null | grep -q ":5900"'; then
    echo "FAIL: nothing listening on 5900" >&2
    docker exec "${NAME}" sh -c 'ss -ltn || netstat -ltn || true' >&2 || true
    exit 1
fi

echo "  official jlesage/chromium: Chromium process stable, :5900 listen, no nginx EPERM"
echo "  LIMITATION: did not open an RFB client session or a live website"
