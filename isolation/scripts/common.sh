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

# KEY=VALUE only. Does not eval, so $(...) in values stays literal.
iso_env_get() {
    local file="$1" want="$2" line key val
    while IFS= read -r line || [ -n "${line}" ]; do
        case "${line}" in
            ''|\#*) continue ;;
        esac
        key="${line%%=*}"
        val="${line#*=}"
        if [ "${key}" = "${line}" ]; then
            continue
        fi
        if [ "${key}" = "${want}" ]; then
            if [[ "${val}" =~ ^\".*\"$ ]] || [[ "${val}" =~ ^\'.*\'$ ]]; then
                val="${val:1:${#val}-2}"
            fi
            printf '%s' "${val}"
            return 0
        fi
    done < "${file}"
    return 1
}

iso_load_env() {
    local file="$1" line key val
    if [ ! -f "${file}" ]; then
        echo "env file not found: ${file}" >&2
        return 1
    fi
    while IFS= read -r line || [ -n "${line}" ]; do
        case "${line}" in
            ''|\#*) continue ;;
        esac
        key="${line%%=*}"
        val="${line#*=}"
        if [ "${key}" = "${line}" ]; then
            echo "illegal env line (need KEY=VALUE): ${line}" >&2
            return 1
        fi
        if [[ ! "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "illegal env key: ${key}" >&2
            return 1
        fi
        if [[ "${val}" =~ ^\".*\"$ ]] || [[ "${val}" =~ ^\'.*\'$ ]]; then
            val="${val:1:${#val}-2}"
        fi
        printf -v "${key}" '%s' "${val}"
        export "${key}"
    done < "${file}"
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
    export ISO_ENV_FILE="${file}"
}

iso_project() {
    echo "iso-${ISO_IDENTITY}"
}

# Compose interpolates $ in both --env-file and service env_file.
# Double dollars so a password like ab$cd${HOME}ef survives as literals.
iso_escape_env_file() {
    local src="$1" dest="$2" line key val
    mkdir -p "$(dirname "${dest}")"
    : > "${dest}"
    while IFS= read -r line || [ -n "${line}" ]; do
        case "${line}" in
            ''|\#*)
                printf '%s\n' "${line}" >> "${dest}"
                continue
                ;;
        esac
        key="${line%%=*}"
        val="${line#*=}"
        if [ "${key}" = "${line}" ]; then
            printf '%s\n' "${line}" >> "${dest}"
            continue
        fi
        val="${val//\$/\$\$}"
        printf '%s=%s\n' "${key}" "${val}" >> "${dest}"
    done < "${src}"
    chmod 600 "${dest}"
}

iso_compose() {
    iso_need_cmd docker
    : "${ISO_ENV_FILE:?ISO_ENV_FILE is required (use iso-up.sh, do not interpolate secrets in compose.yaml)}"
    local safe="${ISO_ROOT}/data/${ISO_IDENTITY}/.compose.env"
    iso_escape_env_file "${ISO_ENV_FILE}" "${safe}"
    ISO_ENV_FILE="${safe}"
    export ISO_ENV_FILE
    docker compose \
        --project-directory "${ISO_ROOT}" \
        --env-file "${safe}" \
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
