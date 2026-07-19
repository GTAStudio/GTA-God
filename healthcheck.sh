#!/bin/sh

CONFIG_PATH="/tmp/gtacore-config.json"

if [ ! -f "$CONFIG_PATH" ]; then
    CONFIG_PATH="/etc/gtacore/config.json"
fi

# gtagate must always be running
GATE_PID=$(pgrep -xo gtagate 2>/dev/null) \
    || { echo "healthcheck: gtagate not running" >&2; exit 1; }

socket_port_owned_by_pid() {
    _pid="$1"
    _protocol="$2"
    _port="$3"
    _hex=$(printf '%04X' "$_port" 2>/dev/null) || return 1
    _inodes=""
    for _fd in "/proc/$_pid/fd"/*; do
        _target=$(readlink "$_fd" 2>/dev/null) || continue
        case "$_target" in
            socket:\[*\])
                _inode=${_target#socket:[}
                _inode=${_inode%]}
                _inodes="${_inodes}${_inode} "
                ;;
        esac
    done
    [ -n "$_inodes" ] || return 1

    case "$_protocol" in
        tcp)
            _files="/proc/net/tcp"
            [ -r /proc/net/tcp6 ] && _files="$_files /proc/net/tcp6"
            awk -v pat=":${_hex}\$" -v inode_list="$_inodes" '
                BEGIN {
                    count = split(inode_list, values, /[[:space:]]+/)
                    for (item = 1; item <= count; item++)
                        if (values[item] != "") owned[values[item]] = 1
                }
                $2 ~ pat && $4 == "0A" && ($10 in owned) { found = 1 }
                END { exit !found }
            ' $_files 2>/dev/null
            ;;
        udp)
            _files="/proc/net/udp"
            [ -r /proc/net/udp6 ] && _files="$_files /proc/net/udp6"
            awk -v pat=":${_hex}\$" -v inode_list="$_inodes" '
                BEGIN {
                    count = split(inode_list, values, /[[:space:]]+/)
                    for (item = 1; item <= count; item++)
                        if (values[item] != "") owned[values[item]] = 1
                }
                $2 ~ pat && ($10 in owned) { found = 1 }
                END { exit !found }
            ' $_files 2>/dev/null
            ;;
        *) return 1 ;;
    esac
}

GATE_PORT=$(jq -er '.listen | capture(":(?<port>[0-9]+)$").port | tonumber' \
    /etc/gtagate/config.json 2>/dev/null) \
    || { echo "healthcheck: cannot determine gtagate listen port" >&2; exit 1; }
socket_port_owned_by_pid "$GATE_PID" tcp "$GATE_PORT" \
    || { echo "healthcheck: gtagate does not own LISTEN socket :$GATE_PORT" >&2; exit 1; }

if [ -f /tmp/gtagod-gtacore-required ]; then
    [ -f "$CONFIG_PATH" ] \
        || { echo "healthcheck: gtacore runtime config missing" >&2; exit 1; }
    CORE_PID=$(pgrep -xo gtacore 2>/dev/null) \
        || { echo "healthcheck: gtacore required but not running" >&2; exit 1; }
fi

if [ -n "$CORE_PID" ] && [ -f "$CONFIG_PATH" ]; then
    if ! TCP_PORTS=$(jq -r '
      .inbounds[]?
      | select(
                    .type == "direct"
                    or .type == "http"
                    or .type == "socks"
                    or .type == "mixed"
                    or .type == "shadowsocks"
                    or .type == "shadowtls"
                    or .type == "trojan"
                    or .type == "vmess"
                    or .type == "naive"
          or .type == "anytls"
          or .type == "vless"
                    or .type == "mieru"
        )
            | select(((.network // ["tcp"]) | index("tcp") != null))
            | select(.transport?.type != "quic")
      | .listen_port
            | select(type == "number" and . >= 1 and . <= 65535)
        ' "$CONFIG_PATH" 2>/dev/null); then
                echo "healthcheck: failed to parse configured TCP inbounds" >&2
                exit 1
        fi
    for _port in $TCP_PORTS; do
                socket_port_owned_by_pid "$CORE_PID" tcp "$_port" \
                        || { echo "healthcheck: gtacore does not own TCP LISTEN socket :$_port" >&2; exit 1; }
    done

        if ! UDP_PORTS=$(jq -r '
            [
                (.inbounds[]?
                    | select(
                            .type == "hysteria"
                            or .type == "hysteria2"
                            or .type == "tuic"
                            or (.type == "naive" and ((.network // []) | index("udp") != null))
                            or (.type == "vless" and .transport?.type == "quic")
                            or (.type == "mieru" and ((.network // []) | index("udp") != null))
                        )
                    | .listen_port),
                (.endpoints[]?
                    | select(.type == "wireguard" and .listen_port? != null)
                    | .listen_port)
            ]
            | .[]
            | select(type == "number" and . >= 1 and . <= 65535)
    ' "$CONFIG_PATH" 2>/dev/null); then
        echo "healthcheck: failed to parse configured UDP inbounds/endpoints" >&2
        exit 1
    fi
    for _port in $UDP_PORTS; do
        socket_port_owned_by_pid "$CORE_PID" udp "$_port" \
            || { echo "healthcheck: gtacore does not own UDP socket :$_port" >&2; exit 1; }
    done
fi

# Verify every configured certificate/key pair once gtacore is running.
if [ -n "$CORE_PID" ]; then
    CERT_PAIRS="/tmp/gtagod-health-cert-pairs.$$"
    if ! jq -r '
        .inbounds[]?
        | select(.tls?.certificate_path != null)
        | [.tls.certificate_path, .tls.key_path]
        | @tsv
    ' "$CONFIG_PATH" > "$CERT_PAIRS" 2>/dev/null; then
        rm -f "$CERT_PAIRS"
        echo "healthcheck: failed to parse TLS certificate pairs" >&2
        exit 1
    fi
    while IFS="$(printf '\t')" read -r CERT_PATH KEY_PATH; do
        [ -n "$CERT_PATH" ] && [ -f "$CERT_PATH" ] \
            || { rm -f "$CERT_PAIRS"; echo "healthcheck: certificate not found: $CERT_PATH" >&2; exit 1; }
        [ -n "$KEY_PATH" ] && [ -f "$KEY_PATH" ] \
            || { rm -f "$CERT_PAIRS"; echo "healthcheck: key not found: $KEY_PATH" >&2; exit 1; }
    done < "$CERT_PAIRS"
    rm -f "$CERT_PAIRS"
fi

exit 0