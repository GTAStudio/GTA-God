#!/bin/sh

CONFIG_PATH="/tmp/gtacore-config.json"

if [ ! -f "$CONFIG_PATH" ]; then
    CONFIG_PATH="/etc/gtacore/config.json"
fi

# gtagate must always be running
pgrep -x gtagate >/dev/null 2>&1 || { echo "healthcheck: gtagate not running" >&2; exit 1; }

# A zero-byte nc probe can be closed by the default REALITY decoy backend and
# return non-zero even though gtagate accepted it. Fall back to the authoritative
# LISTEN socket state in the shared network namespace to avoid that false alarm.
PORT_443_READY=false
if command -v nc >/dev/null 2>&1 \
    && nc -z -w 3 127.0.0.1 443 >/dev/null 2>&1; then
    PORT_443_READY=true
fi
if [ "$PORT_443_READY" != "true" ] \
    && { [ -r /proc/net/tcp ] || [ -r /proc/net/tcp6 ]; } \
    && awk 'BEGIN{rc=1} $2 ~ /:01BB$/ && $4=="0A"{rc=0} END{exit rc}' \
        /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
    PORT_443_READY=true
fi
[ "$PORT_443_READY" = "true" ] \
    || { echo "healthcheck: no accepting/LISTEN socket on :443" >&2; exit 1; }

if [ -f /tmp/gtagod-gtacore-required ]; then
    pgrep -x gtacore >/dev/null 2>&1 || { echo "healthcheck: gtacore required but not running" >&2; exit 1; }
fi

socket_port_present() {
    _protocol="$1"
    _port="$2"
    _hex=$(printf '%04X' "$_port" 2>/dev/null) || return 1

    case "$_protocol" in
        tcp)
            _files="/proc/net/tcp"
            [ -r /proc/net/tcp6 ] && _files="$_files /proc/net/tcp6"
            awk -v pat=":${_hex}\$" '$2 ~ pat && $4 == "0A" {found=1} END {exit !found}' \
                $_files 2>/dev/null
            ;;
        udp)
            _files="/proc/net/udp"
            [ -r /proc/net/udp6 ] && _files="$_files /proc/net/udp6"
            awk -v pat=":${_hex}\$" '$2 ~ pat {found=1} END {exit !found}' \
                $_files 2>/dev/null
            ;;
        *) return 1 ;;
    esac
}

if pgrep -x gtacore >/dev/null 2>&1 && [ -f "$CONFIG_PATH" ]; then
    TCP_PORTS=$(jq -r '
      .inbounds[]?
      | select(
          .type == "naive"
          or .type == "anytls"
          or .type == "vless"
          or (.type == "mieru" and ((.network // ["tcp"]) | index("tcp") != null))
        )
      | .listen_port
    ' "$CONFIG_PATH" 2>/dev/null)
    for _port in $TCP_PORTS; do
        socket_port_present tcp "$_port" \
            || { echo "healthcheck: configured TCP inbound not listening on :$_port" >&2; exit 1; }
    done

    UDP_PORTS=$(jq -r '
            [
                (.inbounds[]?
                    | select(
                            .type == "hysteria2"
                            or (.type == "mieru" and ((.network // []) | index("udp") != null))
                        )
                    | .listen_port),
                (.endpoints[]?
                    | select(.type == "wireguard" and .listen_port? != null)
                    | .listen_port)
            ]
            | .[]
    ' "$CONFIG_PATH" 2>/dev/null)
    for _port in $UDP_PORTS; do
        socket_port_present udp "$_port" \
            || { echo "healthcheck: configured UDP inbound not listening on :$_port" >&2; exit 1; }
    done
fi

# Verify certificate files once gtacore is running.
if pgrep -x gtacore >/dev/null 2>&1; then
    # gtacore is running, verify certificate if configured
    if [ -f "$CONFIG_PATH" ]; then
        CERT_PATH=$(jq -r '..|.certificate_path? // empty' "$CONFIG_PATH" 2>/dev/null | head -n 1)
        if [ -n "$CERT_PATH" ]; then
            [ -f "$CERT_PATH" ] || { echo "healthcheck: certificate not found: $CERT_PATH" >&2; exit 1; }
            [ -f "${CERT_PATH%.crt}.key" ] || { echo "healthcheck: key not found for: $CERT_PATH" >&2; exit 1; }
        fi
    fi
fi

exit 0