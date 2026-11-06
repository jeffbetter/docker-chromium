#!/usr/bin/env bash
# Shared helpers for iso-*.sh. Source only; do not execute.

set -euo pipefail

ISO_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISO_ROOT="$(cd "${ISO_SCRIPTS_DIR}/.." && pwd)"

iso_need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "missing command: $1" >&2
        return 1
    }
}

iso_load_env() {
    local file="$1"
    if [ ! -f "${file}" ]; then
        echo "env file not found: ${file}" >&2
        return 1
    fi
    set -a
    # shellcheck disable=SC1090
    . "${file}"
    set +a
    : "${ISO_IDENTITY:?ISO_IDENTITY is required}"
    : "${HOST_VNC_PORT:?HOST_VNC_PORT is required}"
    : "${TROJAN_SERVER:?TROJAN_SERVER is required}"
    : "${TROJAN_PORT:?TROJAN_PORT is required}"
    : "${TROJAN_PASSWORD:?TROJAN_PASSWORD is required}"
    : "${TROJAN_SNI:?TROJAN_SNI is required}"
    ISO_DATA_DIR="${ISO_DATA_DIR:-${ISO_ROOT}/data/${ISO_IDENTITY}}"
    if [ "${ISO_DATA_DIR#/}" = "${ISO_DATA_DIR}" ]; then
        ISO_DATA_DIR="${ISO_ROOT}/${ISO_DATA_DIR#./}"
    fi
    case "${ISO_IDENTITY}" in
        ''|*[!A-Za-z0-9_-]*)
            echo "ISO_IDENTITY must be [A-Za-z0-9_-]: ${ISO_IDENTITY}" >&2
            return 1
            ;;
    esac
    export ISO_DATA_DIR
}

iso_project() {
    echo "iso-${ISO_IDENTITY}"
}

iso_compose() {
    iso_need_cmd docker
    docker compose \
        --project-directory "${ISO_ROOT}" \
        --env-file "$1" \
        -f "${ISO_ROOT}/compose.yaml" \
        -p "$(iso_project)" \
        "${@:2}"
}

iso_placeholder_password() {
    case "$1" in
        ''|change-me|replace-me|password1|yourpsk|changeme) return 0 ;;
        *) return 1 ;;
    esac
}

iso_chromium_container() {
    echo "iso-${ISO_IDENTITY}-chromium"
}

iso_egress_container() {
    echo "iso-${ISO_IDENTITY}-egress"
}
