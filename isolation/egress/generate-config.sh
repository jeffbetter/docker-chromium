#!/bin/sh
# Map official Trojan client fields onto a maintained sing-box config.
# Official trojan-gfw client.json-example:
#   remote_addr, remote_port, password[], ssl.verify, ssl.verify_hostname,
#   ssl.sni, ssl.alpn
# sing-box equivalents (insecure=false preserves certificate verification):
#   server, server_port, password, tls.enabled, tls.insecure=false,
#   tls.server_name, tls.alpn

set -eu

iso_is_true() {
    v="$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')"
    [ "${v}" = "1" ] || [ "${v}" = "true" ] || [ "${v}" = "yes" ]
}

generate_singbox_config() {
    out="${1:-/run/iso/sing-box.json}"
    server_ip="${TROJAN_IP:?}"
    server_port="${TROJAN_PORT:?}"
    password="${TROJAN_PASSWORD:?}"
    sni="${TROJAN_SNI:-}"
    alpn_csv="${TROJAN_ALPN:-h2,http/1.1}"
    bind_iface="${TROJAN_BIND_INTERFACE:-${KILLSWITCH_IFACE:-eth0}}"
    cert_path="${TROJAN_CERTIFICATE_PATH:-}"

    if [ -z "${sni}" ]; then
        echo "TROJAN_SNI is required so TLS Server Name Indication is sent and verified" >&2
        return 1
    fi
    if iso_is_true "${TROJAN_INSECURE:-0}"; then
        echo "Refusing TROJAN_INSECURE: certificate verification must stay enabled." >&2
        echo "This overlay will not set tls.insecure=true (official ssl.verify=true)." >&2
        return 1
    fi
    if [ -z "${bind_iface}" ]; then
        echo "bind/default interface is empty; auto_detect_interface cannot see a default route after kill-switch" >&2
        return 1
    fi

    alpn_json="$(printf '%s' "${alpn_csv}" | awk -F, '{
        printf "["
        for (i = 1; i <= NF; i++) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
            if ($i == "") continue
            if (n++) printf ", "
            printf "\"%s\"", $i
        }
        printf "]"
    }')"

    jq -n \
        --arg server "${server_ip}" \
        --argjson port "${server_port}" \
        --arg password "${password}" \
        --arg sni "${sni}" \
        --argjson alpn "${alpn_json}" \
        --arg bind_iface "${bind_iface}" \
        --arg cert_path "${cert_path}" \
        '{
          log: { level: "info", timestamp: true },
          dns: {
            servers: [
              {
                type: "https",
                tag: "remote-doh",
                server: "1.1.1.1",
                server_port: 443,
                path: "/dns-query",
                detour: "trojan-out"
              }
            ],
            strategy: "ipv4_only",
            final: "remote-doh"
          },
          inbounds: [
            {
              type: "direct",
              tag: "dns-in",
              listen: "127.0.0.1",
              listen_port: 53
            },
            {
              type: "tun",
              tag: "tun-in",
              interface_name: "tun0",
              address: ["10.255.254.1/30"],
              mtu: 1500,
              auto_route: true,
              strict_route: true,
              auto_redirect: false,
              stack: "gvisor",
              dns_mode: "hijack",
              dns_address: ["10.255.254.2"]
            }
          ],
          outbounds: [
            {
              type: "trojan",
              tag: "trojan-out",
              server: $server,
              server_port: $port,
              password: $password,
              tls: {
                enabled: true,
                insecure: false,
                disable_sni: false,
                server_name: $sni,
                alpn: $alpn
              },
              bind_interface: $bind_iface
            }
          ],
          route: {
            rules: [
              { inbound: "dns-in", action: "hijack-dns" },
              { action: "sniff" },
              { protocol: "dns", action: "hijack-dns" }
            ],
            final: "trojan-out",
            auto_detect_interface: false,
            default_interface: $bind_iface,
            default_domain_resolver: "remote-doh"
          }
        }
        | if $cert_path != "" then
            .outbounds[0].tls.certificate_path = $cert_path
          else .
          end' > "${out}"

    if command -v sing-box >/dev/null 2>&1; then
        sing-box check -c "${out}"
    fi
}
