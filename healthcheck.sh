#!/bin/sh

CONFIG_PATH="/tmp/gtacore-config.json"
GATE_CONFIG_PATH="/tmp/gtagate-config.json"
GTAGOD_CERTIFICATE_HEALTH_LIB=${GTAGOD_CERTIFICATE_HEALTH_LIB:-/usr/local/lib/gtagod-certificate-health.sh}

[ -r "$GTAGOD_CERTIFICATE_HEALTH_LIB" ] \
    || { echo "healthcheck: certificate health library missing" >&2; exit 1; }
# shellcheck source=certificate-health-lib.sh
. "$GTAGOD_CERTIFICATE_HEALTH_LIB"

if [ ! -f "$CONFIG_PATH" ]; then
    CONFIG_PATH="/etc/gtacore/config.json"
fi
if [ ! -f "$GATE_CONFIG_PATH" ]; then
    GATE_CONFIG_PATH="/etc/gtagate/config.json"
fi

process_state_is_healthy() {
    case "$1" in
        Z|X|x|T|t) return 1 ;;
        *) return 0 ;;
    esac
}

probe_gtacore_health() {
    _port_file="/tmp/gtagod-gtacore-daemon-port"
    [ -f "$_port_file" ] || return 1
    _port=$(cat "$_port_file" 2>/dev/null) || return 1
    case "$_port" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$_port" -ge 1 ] && [ "$_port" -le 65535 ] || return 1
    _response=$(printf 'GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n' \
        | nc -w 2 127.0.0.1 "$_port" 2>/dev/null) || return 1
    printf '%s\n' "$_response" | grep -Eq '^HTTP/1\.[01] 200' || return 1
    printf '%s\n' "$_response" | grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' || return 1
    printf '%s\n' "$_response" | grep -Eq '"running"[[:space:]]*:[[:space:]]*true'
}

# gtagate must always be running
GATE_PID=$(pgrep -xo gtagate 2>/dev/null) \
    || { echo "healthcheck: gtagate not running" >&2; exit 1; }
GATE_STATE=$(awk '{ print $3 }' "/proc/$GATE_PID/stat" 2>/dev/null) \
    || { echo "healthcheck: cannot inspect gtagate process" >&2; exit 1; }
process_state_is_healthy "$GATE_STATE" \
    || { echo "healthcheck: gtagate process state is unhealthy: $GATE_STATE" >&2; exit 1; }

socket_port_owned_by_pid() {
    _pid="$1"
    _protocol="$2"
    _port="$3"
    _hex=$(printf '%04X' "$_port" 2>/dev/null) || return 1
    if [ "${SOCKET_INODE_CACHE_PID:-}" = "$_pid" ] \
        && [ -n "${SOCKET_INODE_CACHE_VALUE:-}" ]; then
        _inodes=${SOCKET_INODE_CACHE_VALUE:-}
    else
        _inodes=""
        _fd_targets=$(find "/proc/$_pid/fd" -mindepth 1 -maxdepth 1 \
            -printf '%l\n' 2>/dev/null || true)
        while IFS= read -r _target; do
            case "$_target" in
                socket:\[*\])
                    _inode=${_target#socket:[}
                    _inode=${_inode%]}
                    _inodes="${_inodes}${_inode}
"
                    ;;
            esac
        done <<EOF
$_fd_targets
EOF
        SOCKET_INODE_CACHE_PID=$_pid
        SOCKET_INODE_CACHE_VALUE=$_inodes
    fi
    [ -n "$_inodes" ] || return 1

    case "$_protocol" in
        tcp)
            _files="/proc/net/tcp"
            [ -r /proc/net/tcp6 ] && _files="$_files /proc/net/tcp6"
            awk -v pat=":${_hex}\$" '
                FNR == NR { if ($1 != "") owned[$1] = 1; next }
                $2 ~ pat && $4 == "0A" && ($10 in owned) { found = 1 }
                END { exit !found }
            ' - $_files 2>/dev/null <<EOF
$_inodes
EOF
            ;;
        udp)
            _files="/proc/net/udp"
            [ -r /proc/net/udp6 ] && _files="$_files /proc/net/udp6"
            awk -v pat=":${_hex}\$" '
                FNR == NR { if ($1 != "") owned[$1] = 1; next }
                $2 ~ pat && ($10 in owned) { found = 1 }
                END { exit !found }
            ' - $_files 2>/dev/null <<EOF
$_inodes
EOF
            ;;
        *) return 1 ;;
    esac
}

socket_port_is_listening() {
    _protocol="$1"
    _port="$2"
    _hex=$(printf '%04X' "$_port" 2>/dev/null) || return 1

    case "$_protocol" in
        tcp)
            _files="/proc/net/tcp"
            [ -r /proc/net/tcp6 ] && _files="$_files /proc/net/tcp6"
            awk -v pat=":${_hex}\$" '
                $2 ~ pat && $4 == "0A" { found = 1 }
                END { exit !found }
            ' $_files 2>/dev/null
            ;;
        *) return 1 ;;
    esac
}

GATE_PORT=$(jq -er '.listen | capture(":(?<port>[0-9]+)$").port | tonumber' \
    "$GATE_CONFIG_PATH" 2>/dev/null) \
    || { echo "healthcheck: cannot determine gtagate listen port" >&2; exit 1; }
# gtagate carries cap_net_bind_service so Linux marks it non-dumpable. A same-UID,
# non-root HEALTHCHECK may therefore be denied readlink(/proc/PID/fd/*), even though
# the process owns the socket. Keep the inode check when available; otherwise require
# both the exact gtagate process above and a kernel LISTEN entry for its configured port.
if ! socket_port_owned_by_pid "$GATE_PID" tcp "$GATE_PORT" \
    && ! socket_port_is_listening tcp "$GATE_PORT"; then
    echo "healthcheck: gtagate LISTEN socket missing :$GATE_PORT" >&2
    exit 1
fi

if [ -f /tmp/gtagod-gtacore-required ]; then
    [ -f "$CONFIG_PATH" ] \
        || { echo "healthcheck: gtacore runtime config missing" >&2; exit 1; }
    CORE_PID=$(pgrep -xo gtacore 2>/dev/null) \
        || { echo "healthcheck: gtacore required but not running" >&2; exit 1; }
    CORE_STATE=$(awk '{ print $3 }' "/proc/$CORE_PID/stat" 2>/dev/null) \
        || { echo "healthcheck: cannot inspect gtacore process" >&2; exit 1; }
    process_state_is_healthy "$CORE_STATE" \
        || { echo "healthcheck: gtacore process state is unhealthy: $CORE_STATE" >&2; exit 1; }
    probe_gtacore_health \
        || { echo "healthcheck: gtacore active health probe failed" >&2; exit 1; }
fi

if [ -n "$CORE_PID" ] && [ -f "$CONFIG_PATH" ]; then
    if ! TCP_PORTS=$(jq -r '
            def effective_networks:
                if .type == "hysteria" or .type == "hysteria2" or .type == "tuic"
                     or .transport?.type == "quic" then ["udp"]
                elif .network? != null then
                    (if (.network | type) == "array" then .network else [.network] end)
                elif .type == "shadowsocks" then ["tcp", "udp"]
                else ["tcp"]
                end;
      .inbounds[]?
            | select(.type != "tun" and .type != "cloudflared")
            | select((effective_networks | index("tcp")) != null)
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
            def effective_networks:
                if .type == "hysteria" or .type == "hysteria2" or .type == "tuic"
                   or .transport?.type == "quic" then ["udp"]
                elif .network? != null then
                  (if (.network | type) == "array" then .network else [.network] end)
                elif .type == "shadowsocks" then ["tcp", "udp"]
                else ["tcp"]
                end;
            [
                (.inbounds[]?
                    | select(.type != "tun" and .type != "cloudflared")
                    | select((effective_networks | index("udp")) != null)
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
        | [.tls.certificate_path, .tls.key_path, (.tls.server_name // "")]
        | @tsv
    ' "$CONFIG_PATH" > "$CERT_PAIRS" 2>/dev/null; then
        rm -f "$CERT_PAIRS"
        echo "healthcheck: failed to parse TLS certificate pairs" >&2
        exit 1
    fi
    while IFS="$(printf '\t')" read -r CERT_PATH KEY_PATH SERVER_NAME; do
        certificate_pair_is_healthy "$CERT_PATH" "$KEY_PATH" "$SERVER_NAME" \
            || { rm -f "$CERT_PAIRS"; echo "healthcheck: certificate is expired, not yet valid, unreadable, or key-mismatched: $CERT_PATH" >&2; exit 1; }
    done < "$CERT_PAIRS"
    rm -f "$CERT_PAIRS"
fi

exit 0