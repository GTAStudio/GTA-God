#!/bin/sh
# 不使用 set -e，手动处理错误
# set -e 会导致任何非零返回值立即退出，不适合长时间运行的服务

# =========================================
# GTAGod Docker Entrypoint
# 版本: 0.2.2
# 更新: 2026-07-18
# =========================================
# 
# GTACore (Rust) 统一架构:
#   - gtagate (Rust): L4 SNI 分流 + ACME 证书申请
#   - gtacore (Rust): 七协议稳定组合 + VLESS Vision REALITY / AmneziaWG 扩展轴
#
# 支持的部署模式:
#   - NaiveProxy Only (gtacore naive inbound)
#   - NaiveProxy + AnyTLS (gtacore naive + anytls)
#   - NaiveProxy + AnyReality (gtacore naive + anyreality)
#   - L4/Portfolio/Full 多协议 (TLS 类共享 443，UDP/免 TLS 协议独立监听)
#
# =========================================

VERSION="${GTAGOD_VERSION:-0.2.2}"
GTACORE_MOUNTED_CONFIG="/etc/gtacore/config.json"
GTACORE_RUNTIME_CONFIG="/tmp/gtacore-config.json"
GTACORE_LOG_FILE="/var/log/gtacore/gtacore.log"
GTAGATE_CONFIG="/etc/gtagate/config.json"

echo "========================================="
echo "GTAGod Container v${VERSION}"
echo "GTACore (Rust) unified architecture"
echo "Starting gtagate + gtacore services..."
echo "========================================="

# 收紧默认权限：后续 cat/jq>tmp 创建的运行时配置(含 reality 私钥)默认即 0600，
# 关闭“先 0644 再 chmod”之间的瞬时世界可读窗口。
umask 077

# 尽力提升文件描述符软上限（只抬软上限，不降 docker run --ulimit 设好的硬上限）。
ulimit -Sn 65536 2>/dev/null || true

# =========================================
# 检查配置文件
# =========================================
if [ ! -f "$GTAGATE_CONFIG" ]; then
    echo "❌ ERROR: $GTAGATE_CONFIG not found!"
    echo "Please mount your gtagate config to $GTAGATE_CONFIG"
    exit 1
fi

echo "📝 gtagate config found, validating JSON..."

# 验证 JSON 格式
if jq empty "$GTAGATE_CONFIG" >/tmp/gtagate-validate.log 2>&1; then
    echo "✅ gtagate config validation passed"
else
    echo "❌ ERROR: gtagate config validation failed!"
    cat /tmp/gtagate-validate.log
    exit 1
fi
rm -f /tmp/gtagate-validate.log

# =========================================
# 检查 gtacore 配置
# =========================================
if [ ! -f "$GTACORE_MOUNTED_CONFIG" ]; then
    echo "❌ ERROR: $GTACORE_MOUNTED_CONFIG not found!"
    echo "Please mount your gtacore config to $GTACORE_MOUNTED_CONFIG"
    exit 1
fi

echo "📝 gtacore config found"

# 复制到可写运行时配置。entrypoint 后续会执行兼容性迁移、IPv4 策略修正、证书路径更新，
# 因此不能直接修改只读挂载配置。若挂载配置不可读，必须在启动早期明确失败。
if ! cat "$GTACORE_MOUNTED_CONFIG" > "$GTACORE_RUNTIME_CONFIG"; then
    echo "❌ ERROR: Cannot read $GTACORE_MOUNTED_CONFIG or write $GTACORE_RUNTIME_CONFIG"
    echo "Please check host permissions. Recommended: chown 65532:65532 gtacore/config.json && chmod 640 (未 chown 时用 0644)"
    ls -ld /etc/gtacore "$GTACORE_MOUNTED_CONFIG" /tmp 2>/dev/null || true
    exit 1
fi

if ! chmod 0600 "$GTACORE_RUNTIME_CONFIG"; then
    echo "❌ ERROR: Failed to set permissions on $GTACORE_RUNTIME_CONFIG"
    exit 1
fi

if ! jq empty "$GTACORE_RUNTIME_CONFIG" >/tmp/gtacore-json-validate.log 2>&1; then
    echo "❌ ERROR: $GTACORE_MOUNTED_CONFIG is not valid JSON"
    cat /tmp/gtacore-json-validate.log
    rm -f /tmp/gtacore-json-validate.log
    exit 1
fi
rm -f /tmp/gtacore-json-validate.log

echo "✅ Runtime gtacore config prepared at $GTACORE_RUNTIME_CONFIG"

migrate_legacy_dns_servers() {
    if ! jq -e 'any(.dns.servers[]?; (.address? != null) and (.address | type == "string"))' "$GTACORE_RUNTIME_CONFIG" >/dev/null 2>&1; then
        echo "✅ gtacore DNS server format is current"
        return 0
    fi

    echo "⚠️  Detected legacy gtacore DNS server format, migrating to typed HTTPS servers..."

    if ! jq '
        def migrate_dns_server:
          if (.address? | type == "string") and (.address | startswith("https://")) then
            (.address | capture("^https://(?<host>[^/:]+)(?::(?<port>[0-9]+))?(?<path>/.*)?$")) as $parts
            | del(.address, .detour)
            | .type = "https"
            | .server = $parts.host
            | .server_port = (($parts.port // "443") | tonumber)
            | if ($parts.path // "") != "" and ($parts.path // "") != "/dns-query" then .path = $parts.path else . end
          else
            .
          end;
        .dns.servers |= map(migrate_dns_server)
    ' "$GTACORE_RUNTIME_CONFIG" > "${GTACORE_RUNTIME_CONFIG}.migrated"; then
        echo "❌ Failed to migrate legacy DNS server format"
        rm -f "${GTACORE_RUNTIME_CONFIG}.migrated"
        return 1
    fi

    if jq -e 'any(.dns.servers[]?; .address? != null)' "${GTACORE_RUNTIME_CONFIG}.migrated" >/dev/null 2>&1; then
        echo "❌ Found unsupported legacy DNS server entries after migration"
        rm -f "${GTACORE_RUNTIME_CONFIG}.migrated"
        return 1
    fi

    if ! mv "${GTACORE_RUNTIME_CONFIG}.migrated" "$GTACORE_RUNTIME_CONFIG"; then
        echo "❌ Failed to replace gtacore config after DNS migration"
        rm -f "${GTACORE_RUNTIME_CONFIG}.migrated"
        return 1
    fi

    chmod 0600 "$GTACORE_RUNTIME_CONFIG" 2>/dev/null || true

    echo "✅ Legacy gtacore DNS servers migrated to typed HTTPS format"
    return 0
}

enforce_ipv4_only_without_ipv6() {
    # 无全局 IPv6 的主机（多数云 VM 默认如此，包括未显式启用 IPv6 的 Azure VM）上，
    # 解析 AAAA 会让 gtacore 直连 IPv6 目标并必然失败（Network is unreachable, os error 101），
    # 徒增 IPv4 回退前的延迟。此处自动把 DNS 解析策略降级为 ipv4_only。
    # 检测方式：读 /proc/net/if_inet6（scope 列 == 00 即存在全局 IPv6 地址），无需 iproute2。
    if awk '$4 == "00" { found = 1 } END { exit(found ? 0 : 1) }' /proc/net/if_inet6 2>/dev/null; then
        return 0
    fi

    if ! jq -e 'has("dns")' "$GTACORE_RUNTIME_CONFIG" >/dev/null 2>&1; then
        return 0
    fi

    _dns_strategy=$(jq -r '.dns.strategy // "unset"' "$GTACORE_RUNTIME_CONFIG" 2>/dev/null)
    if [ "$_dns_strategy" = "ipv4_only" ]; then
        echo "ℹ️  未检测到全局 IPv6，DNS strategy 已是 ipv4_only"
        return 0
    fi

    echo "⚠️  未检测到全局 IPv6 地址，将 DNS strategy 由 ${_dns_strategy} 强制为 ipv4_only（避免直连不可达的 IPv6）"
    if jq '.dns.strategy = "ipv4_only"' "$GTACORE_RUNTIME_CONFIG" > "${GTACORE_RUNTIME_CONFIG}.ipv4" \
        && mv "${GTACORE_RUNTIME_CONFIG}.ipv4" "$GTACORE_RUNTIME_CONFIG"; then
        chmod 0600 "$GTACORE_RUNTIME_CONFIG" 2>/dev/null || true
        echo "✅ DNS strategy 已设为 ipv4_only"
    else
        echo "⚠️  设置 ipv4_only 失败，继续使用 ${_dns_strategy}"
        rm -f "${GTACORE_RUNTIME_CONFIG}.ipv4"
    fi
}

if ! migrate_legacy_dns_servers; then
    exit 1
fi

enforce_ipv4_only_without_ipv6

validate_gtagate_sni_routes() {
        local route_errors="/tmp/gtagod-sni-route-errors.$$"

        if ! jq -nr --slurpfile gate "$GTAGATE_CONFIG" --slurpfile core "$GTACORE_RUNTIME_CONFIG" '
                def normalize_sni:
                    ascii_downcase | rtrimstr(".");
                def wildcard_matches($pattern; $sni):
                    ($pattern | normalize_sni) as $normalized_pattern
                    | ($sni | normalize_sni | split(".")) as $sni_labels
                    | if ($normalized_pattern | startswith("*.")) then
                            ($normalized_pattern[2:] | split(".")) as $base_labels
                            | ($sni_labels | length) == (($base_labels | length) + 1)
                                and $sni_labels[1:] == $base_labels
                        else
                            false
                        end;
                def effective_upstream($config; $sni):
                    ([$config.routes[]?
                        | select((.sni | normalize_sni) == ($sni | normalize_sni))
                        | .upstream] | first)
                    // ([$config.routes[]?
                        | select(wildcard_matches(.sni; $sni))
                        | .upstream] | first)
                    // $config.default_upstream;
                def upstream_port($upstream):
                    try ($upstream | capture(":(?<port>[0-9]+)$").port | tonumber) catch null;

                $gate[0] as $gate_config
                | (
                        ($core[0].inbounds[]?
                            | select(.type == "naive" or .type == "anytls" or .type == "vless")
                            | select((.listen_port | type) == "number")
                            | (.tls.server_name? // .tls.reality.handshake.server? // empty) as $sni
                            | select(($sni | type) == "string" and ($sni | length) > 0)
                            | (effective_upstream($gate_config; $sni)) as $actual_upstream
                            | select(upstream_port($actual_upstream) != .listen_port)
                            | "SNI routing mismatch: inbound=\(.tag // .type) sni=\($sni) actual=\($actual_upstream) expected_port=\(.listen_port)"),
                        ($core[0].inbounds[]?
                            | select(.tls.reality.enabled? == true)
                            | (.tls.server_name? // empty) as $server_name
                            | (.tls.reality.handshake.server? // empty) as $handshake_server
                            | select(($server_name | type) == "string" and ($server_name | length) > 0)
                            | select(($handshake_server | type) == "string" and ($handshake_server | length) > 0)
                            | select(($server_name | normalize_sni) != ($handshake_server | normalize_sni))
                            | "REALITY identity mismatch: inbound=\(.tag // .type) server_name=\($server_name) handshake_server=\($handshake_server)")
                    )
        ' > "$route_errors"; then
                echo "❌ Failed to validate gtagate SNI routes against gtacore inbounds" >&2
                rm -f "$route_errors"
                return 1
        fi

        if [ -s "$route_errors" ]; then
                echo "❌ gtagate SNI routing does not match gtacore inbounds:" >&2
                while IFS= read -r route_error; do
                        echo "   $route_error" >&2
                done < "$route_errors"
                rm -f "$route_errors"
                return 1
        fi

        rm -f "$route_errors"
        echo "✅ gtagate SNI routes match gtacore inbounds"
}

if ! validate_gtagate_sni_routes; then
        exit 1
fi

# =========================================
# 检测配置类型 (使用 jq 精确解析 JSON)
# =========================================
HAS_NAIVE=false
HAS_ANYTLS=false
HAS_ANYREALITY=false
HAS_HYSTERIA2=false
HAS_MIERU=false
HAS_VLESSWS=false
HAS_VLESSREALITY=false
HAS_AMNEZIAWG=false
NEEDS_CERT=false

if jq -e '.inbounds[]? | select(.type == "naive")' "$GTACORE_RUNTIME_CONFIG" >/dev/null 2>&1; then
    HAS_NAIVE=true
    echo "✅ Detected NaiveProxy inbound"
fi

if jq -e '.inbounds[]? | select(.type == "anytls" and .tls?.reality?.enabled != true)' "$GTACORE_RUNTIME_CONFIG" >/dev/null 2>&1; then
    HAS_ANYTLS=true
    echo "✅ Detected AnyTLS inbound"
fi

if jq -e '.inbounds[]? | select(.type == "anytls" and .tls?.reality?.enabled == true and .tls?.reality?.private_key != null)' "$GTACORE_RUNTIME_CONFIG" >/dev/null 2>&1; then
    HAS_ANYREALITY=true
    echo "✅ Detected AnyReality inbound"
fi

if jq -e '.inbounds[]? | select(.type == "hysteria2")' "$GTACORE_RUNTIME_CONFIG" >/dev/null 2>&1; then
    HAS_HYSTERIA2=true
    echo "✅ Detected Hysteria2 inbound"
fi

if jq -e '.inbounds[]? | select(.type == "mieru")' "$GTACORE_RUNTIME_CONFIG" >/dev/null 2>&1; then
    HAS_MIERU=true
    echo "✅ Detected Mieru TCP/UDP inbound"
fi

if jq -e '.inbounds[]? | select(.type == "vless" and .transport?.type == "ws")' "$GTACORE_RUNTIME_CONFIG" >/dev/null 2>&1; then
    HAS_VLESSWS=true
    echo "✅ Detected VLESS WebSocket inbound"
fi

if jq -e '.inbounds[]? | select(.type == "vless" and .tls?.reality?.enabled == true and any(.users[]?; .flow == "xtls-rprx-vision"))' "$GTACORE_RUNTIME_CONFIG" >/dev/null 2>&1; then
    HAS_VLESSREALITY=true
    echo "✅ Detected VLESS Vision REALITY inbound"
fi

if jq -e '.endpoints[]? | select(.type == "wireguard" and .amnezia? != null)' "$GTACORE_RUNTIME_CONFIG" >/dev/null 2>&1; then
    HAS_AMNEZIAWG=true
    echo "✅ Detected AmneziaWG userspace endpoint"
fi

# 检测是否需要证书 (naive 和非 reality 的 anytls 都需要证书)
if jq -e '.inbounds[]? | select(.tls?.certificate_path != null)' "$GTACORE_RUNTIME_CONFIG" >/dev/null 2>&1; then
    NEEDS_CERT=true
    echo "📋 Certificate required for TLS inbounds"
fi

if jq -e '
    ((.inbounds? // []) | type == "array" and length > 0)
    or ((.endpoints? // []) | type == "array" and length > 0)
' "$GTACORE_RUNTIME_CONFIG" >/dev/null 2>&1; then
    touch /tmp/gtagod-gtacore-required
else
    rm -f /tmp/gtagod-gtacore-required
fi

# =========================================
# 信号处理 (优雅退出)
# =========================================

# 可中断 sleep：后台 sleep + wait，使 trap 能立即打断长等待
isleep() { sleep "$1" & wait $!; }

cleanup() {
    # 进入清理即忽略后续 TERM/INT/QUIT，保证清理过程不被二次信号打断/重入（幂等加固）。
    trap '' TERM INT QUIT
    echo "🛑 Received stop signal, shutting down gracefully..."
    # Send SIGTERM to all managed processes
    for _pid_var in GTACORE_PID GATE_PID LOG_TAIL_PID; do
        eval "_pid=\$$_pid_var"
        if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
            echo "🛑 Stopping $_pid_var (PID $_pid)..."
            kill -TERM "$_pid" 2>/dev/null
        fi
    done
    # 8s 看门狗：留 Docker 10s grace period 2s 余量，超时强杀
    ( sleep 8; for _v in GTACORE_PID GATE_PID LOG_TAIL_PID; do
        eval "_p=\$$_v"; [ -n "$_p" ] && kill -9 "$_p" 2>/dev/null
    done ) & _wd_pid=$!
    # 用 wait 真正回收子进程（避免 kill -0 轮询僵尸永远成立的 bug）
    for _pid_var in GTACORE_PID GATE_PID LOG_TAIL_PID; do
        eval "_pid=\$$_pid_var"
        [ -n "$_pid" ] && wait "$_pid" 2>/dev/null
    done
    kill "$_wd_pid" 2>/dev/null; wait "$_wd_pid" 2>/dev/null
    echo "✅ Shutdown complete."
    exit 0
}

# 注意：dash（debian /bin/sh）不接受 SIG 前缀（`trap: SIGTERM: bad trap`），
# 必须用 POSIX 裸名 TERM/INT/QUIT，否则 trap 根本不会安装、cleanup 永不触发。
trap cleanup TERM INT QUIT

# =========================================
# 启动 gtagate (用于 L4 分流和证书申请)
# =========================================
echo "🚀 Starting gtagate..."
gtagate "$GTAGATE_CONFIG" &
GATE_PID=$!
isleep 2
if ! kill -0 "$GATE_PID" 2>/dev/null; then
    echo "❌ gtagate failed to start (exited within 2s)"
    echo "   ↑ 若上方日志为「绑定监听地址 0.0.0.0:443 失败: Permission denied」："
    echo "     非 root 进程在你的 runc（老版本 no_new_privs 会忽略文件能力）或 userns-remap/rootless 下"
    echo "     拿不到 NET_BIND_SERVICE。请在【宿主机】以 root 执行（容器内非 root 无权设置此项）："
    echo "       sysctl -w net.ipv4.ip_unprivileged_port_start=0"
    echo "     然后重启容器（部署脚本 run.sh 已自动设置并持久化此项）。"
    exit 1
fi
echo "✅ gtagate started with PID: $GATE_PID"

# =========================================
# 等待证书后启动 gtacore
# =========================================
# 数值 env 守卫：非纯数字（运维误填如 CERT_WAIT_MAX=abc）时回退默认值，
# 避免后续 `[ -lt ]` 算术比较报 "integer expression expected" 致循环行为异常。
_num_or() { case "$1" in '' | *[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
CERT_WAIT_MAX=$(_num_or "${CERT_WAIT_MAX:-180}" 180)
CERT_RETRY_INTERVAL=$(_num_or "${CERT_RETRY_INTERVAL:-30}" 30)
CERT_RETRY_MAX=$(_num_or "${CERT_RETRY_MAX:-10}" 10)
GTACORE_RESTART_ATTEMPTS=0
GTACORE_MAX_RESTART_ATTEMPTS=$(_num_or "${GTACORE_MAX_RESTART_ATTEMPTS:-10}" 10)
GTACORE_STABLE_RESET_SECS=$(_num_or "${GTACORE_STABLE_RESET_SECS:-300}" 300)
GTACORE_STARTED_AT=""
GTACORE_TOKEN_FILE="${GTACORE_TOKEN_FILE:-/tmp/gtacore-token}"
GTACORE_MAX_CONNECTIONS=$(_num_or "${GTACORE_MAX_CONNECTIONS:-8192}" 8192)
# Native REALITY/TLS keeps half-closed requests alive during a bounded response
# drain. The 2048/6144 defaults are the smallest validated pair that keeps the
# 20-worker short-connection gate lossless while retaining three worker units
# per accepted TCP connection.
GTACORE_MAX_TCP_CONNECTIONS=$(_num_or "${GTACORE_MAX_TCP_CONNECTIONS:-2048}" 2048)
GTACORE_MAX_DATA_PLANE_THREADS=$(_num_or "${GTACORE_MAX_DATA_PLANE_THREADS:-6144}" 6144)
GTACORE_DAEMON_PORT=$(_num_or "${GTACORE_DAEMON_PORT:-0}" 0)
GTACORE_LOG_MAX_SIZE=$(_num_or "${GTACORE_LOG_MAX_SIZE:-10485760}" 10485760)
if [ "$GTACORE_LOG_MAX_SIZE" -lt 1024 ]; then
    echo "⚠️  Invalid GTACORE_LOG_MAX_SIZE=${GTACORE_LOG_MAX_SIZE}; falling back to 10485760"
    GTACORE_LOG_MAX_SIZE=10485760
fi
if [ "$GTACORE_DAEMON_PORT" -gt 65535 ]; then
    echo "⚠️  Invalid GTACORE_DAEMON_PORT=${GTACORE_DAEMON_PORT}; falling back to dynamic port 0"
    GTACORE_DAEMON_PORT=0
fi

build_gtacore_optional_limit_args() {
    local run_help="$1"
    GTACORE_OPTIONAL_LIMIT_ARGS=""

    if printf '%s\n' "$run_help" | grep -Fq -- '--max-tcp-connections'; then
        GTACORE_OPTIONAL_LIMIT_ARGS="--max-tcp-connections $GTACORE_MAX_TCP_CONNECTIONS"
    else
        echo "ℹ️  Bundled gtacore does not support --max-tcp-connections; using its built-in data-plane limit"
    fi
    if printf '%s\n' "$run_help" | grep -Fq -- '--max-data-plane-threads'; then
        GTACORE_OPTIONAL_LIMIT_ARGS="${GTACORE_OPTIONAL_LIMIT_ARGS:+$GTACORE_OPTIONAL_LIMIT_ARGS }--max-data-plane-threads $GTACORE_MAX_DATA_PLANE_THREADS"
    else
        echo "ℹ️  Bundled gtacore does not support --max-data-plane-threads; using its built-in thread limit"
    fi
}

if GTACORE_RUN_HELP=$(gtacore run --help 2>&1); then
    build_gtacore_optional_limit_args "$GTACORE_RUN_HELP"
else
    echo "⚠️  Could not inspect gtacore run options; starting without optional data-plane limits"
    GTACORE_OPTIONAL_LIMIT_ARGS=""
fi

# gtacore 控制面始终限制在 loopback；端口 0 由内核动态分配，避免 --net=host
# 下与并行 GTACore 实例争用固定 19810。需要固定端口时显式设置 GTACORE_DAEMON_PORT。
ensure_gtacore_token() {
    if [ -s "$GTACORE_TOKEN_FILE" ]; then
        return 0
    fi
    if ! head -c 32 /dev/urandom | base64 | tr -d '\n' > "$GTACORE_TOKEN_FILE"; then
        echo "❌ Failed to create gtacore control token"
        rm -f "$GTACORE_TOKEN_FILE"
        return 1
    fi
    chmod 600 "$GTACORE_TOKEN_FILE" || return 1
}

ensure_gtacore_log_forwarder() {
    mkdir -p /var/log/gtacore || return 1
    touch "$GTACORE_LOG_FILE" || return 1

    if [ -n "$LOG_TAIL_PID" ] && kill -0 "$LOG_TAIL_PID" 2>/dev/null; then
        return 0
    fi

    # GTACore 会 rename + reopen 轮转日志；-F 按文件名重试，跨轮转继续转发。
    tail -n 0 -F "$GTACORE_LOG_FILE" &
    LOG_TAIL_PID=$!
    isleep 1
    if ! kill -0 "$LOG_TAIL_PID" 2>/dev/null; then
        wait "$LOG_TAIL_PID" 2>/dev/null || true
        LOG_TAIL_PID=""
        echo "❌ Failed to start gtacore log forwarder"
        return 1
    fi
}

stop_gtacore() {
    if [ -n "$GTACORE_PID" ]; then
        if kill -0 "$GTACORE_PID" 2>/dev/null; then
            kill -TERM "$GTACORE_PID" 2>/dev/null
            _stop_timeout=10
            while [ $_stop_timeout -gt 0 ] && kill -0 "$GTACORE_PID" 2>/dev/null; do
                isleep 1
                _stop_timeout=$((_stop_timeout - 1))
            done
            if kill -0 "$GTACORE_PID" 2>/dev/null; then
                echo "⚠️  gtacore did not stop within 10s, force killing PID $GTACORE_PID..."
                kill -9 "$GTACORE_PID" 2>/dev/null
            fi
        fi
        wait "$GTACORE_PID" 2>/dev/null || true
    fi
    GTACORE_PID=""
}

reload_gtacore() {
    # gtacore 无 SIGHUP 热重载，证书更新需重启进程
    if ! validate_gtacore_config; then
        echo "❌ Skipping gtacore reload because config validation failed"
        return 1
    fi

    stop_gtacore
    isleep 1
    if start_gtacore; then
        echo "✅ gtacore reloaded (restarted) successfully"
        return 0
    fi

    echo "❌ gtacore failed to start after reload"
    return 1
}

validate_gtacore_config() {
    VALIDATE_LOG="/tmp/gtacore-check.log"

    if gtacore sing-box check -c "$GTACORE_RUNTIME_CONFIG" >"$VALIDATE_LOG" 2>&1; then
        echo "✅ gtacore config validation passed"
        rm -f "$VALIDATE_LOG"
        return 0
    fi

    echo "❌ gtacore config validation failed!"
    cat "$VALIDATE_LOG"
    rm -f "$VALIDATE_LOG"
    return 1
}

get_gtacore_restart_delay() {
    case "$1" in
        1) echo 2 ;;
        2) echo 5 ;;
        3) echo 10 ;;
        4) echo 30 ;;
        *) echo 60 ;;
    esac
}

start_gtacore() {
    if [ -n "$GTACORE_PID" ] && kill -0 "$GTACORE_PID" 2>/dev/null; then
        return 0
    fi

    echo ""
    echo "🚀 Starting gtacore..."

    if ! validate_gtacore_config; then
        echo "❌ gtacore config is invalid or unreadable"
        return 1
    fi

    ensure_gtacore_token || return 1
    ensure_gtacore_log_forwarder || return 1
    # gtacore inbound 与 gtagate 监听均已设 SO_REUSEADDR：--net=host 重建/重启时
    # 即使端口残留 TIME_WAIT 也能立即重绑，无需等待端口释放（消除 ~55s 重启黑屏）。
    gtacore run --config "$GTACORE_RUNTIME_CONFIG" --host 127.0.0.1 \
        --port "$GTACORE_DAEMON_PORT" --token-file "$GTACORE_TOKEN_FILE" \
        --max-connections "$GTACORE_MAX_CONNECTIONS" \
        $GTACORE_OPTIONAL_LIMIT_ARGS \
        --log-file "$GTACORE_LOG_FILE" --log-max-size "$GTACORE_LOG_MAX_SIZE" &
    GTACORE_PID=$!
    echo "✅ gtacore started with PID: $GTACORE_PID"

    isleep 3
    if kill -0 "$GTACORE_PID" 2>/dev/null; then
        GTACORE_STARTED_AT=$(date +%s)
        touch /tmp/gtagod-gtacore-started
        echo "✅ gtacore is running successfully!"
        
        # 显示启用的功能
        if [ "$HAS_NAIVE" = "true" ]; then
            echo "   📦 NaiveProxy: enabled"
        fi
        if [ "$HAS_ANYTLS" = "true" ]; then
            echo "   📦 AnyTLS: enabled"
        fi
        if [ "$HAS_ANYREALITY" = "true" ]; then
            echo "   📦 AnyReality: enabled"
        fi
        if [ "$HAS_HYSTERIA2" = "true" ]; then
            echo "   📦 Hysteria2: enabled"
        fi
        if [ "$HAS_MIERU" = "true" ]; then
            echo "   📦 Mieru TCP/UDP: enabled"
        fi
        if [ "$HAS_VLESSWS" = "true" ]; then
            echo "   📦 VLESS WebSocket TLS: enabled"
        fi
        if [ "$HAS_VLESSREALITY" = "true" ]; then
            echo "   📦 VLESS Vision REALITY: enabled"
        fi
        if [ "$HAS_AMNEZIAWG" = "true" ]; then
            echo "   📦 AmneziaWG userspace endpoint: enabled"
        fi
        return 0
    else
        echo "❌ gtacore failed to start! Logs:"
        tail -30 "$GTACORE_LOG_FILE" 2>/dev/null || echo "No log file"
        stop_gtacore
        return 1
    fi
}

start_gtacore_initial() {
    if start_gtacore; then
        return 0
    fi
    echo ""
    if [ -f /tmp/gtagod-gtacore-required ]; then
        echo "❌ Fatal: gtacore is required for configured inbounds/endpoints"
        exit 1
    fi
    echo "⚠️  Continuing with gtagate only..."
    return 0
}

if [ "$NEEDS_CERT" = "true" ]; then
    echo ""
    echo "🔍 Waiting for SSL certificates..."

    ACME_CERT_DIR=$(jq -r '.acme.cert_dir // "/data/caddy/certificates"' "$GTAGATE_CONFIG" 2>/dev/null)
    ACME_DOMAINS=$(jq -r '.acme.domains[]?' "$GTAGATE_CONFIG" 2>/dev/null)
    ACME_CA=$(jq -r '.acme.ca // "letsencrypt"' "$GTAGATE_CONFIG" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    case "$ACME_CA" in
        letsencrypt-staging|staging) ACME_CA_LABEL="letsencrypt-staging" ;;
        letsencrypt|le) ACME_CA_LABEL="letsencrypt" ;;
        *)
            echo "❌ Unsupported ACME CA in runtime config: $ACME_CA"
            exit 1
            ;;
    esac
    if [ -z "$ACME_DOMAINS" ]; then
        echo "❌ ACME domains is empty while TLS certificates are required"
        exit 1
    fi

    certificate_label() {
        case "$1" in
            \*.*) printf 'wildcard_.%s\n' "${1#*.}" ;;
            *) printf '%s\n' "$1" ;;
        esac
    }

    find_active_certificate() {
        local domain="$1"
        local cert_label
        cert_label=$(certificate_label "$domain") || return 1
        [ -n "$cert_label" ] || return 1

        local cert_dir="$ACME_CERT_DIR/$ACME_CA_LABEL/$cert_label"
        local current_file="$cert_dir/.gtagate-current"
        [ -f "$current_file" ] || return 1

        local generation
        generation=$(cat "$current_file" 2>/dev/null) || return 1
        [ "${#generation}" -eq 43 ] || return 1
        printf '%s\n' "$generation" | grep -Eq '^generation-[0-9a-f]{32}$' || return 1

        local generation_dir="$cert_dir/.gtagate-generations/$generation"
        local resolved_dir
        local resolved_cert
        local resolved_key
        resolved_dir=$(readlink -f "$generation_dir" 2>/dev/null) || return 1
        resolved_cert=$(readlink -f "$generation_dir/$cert_label.crt" 2>/dev/null) || return 1
        resolved_key=$(readlink -f "$generation_dir/$cert_label.key" 2>/dev/null) || return 1
        case "$resolved_cert" in "$resolved_dir"/*) ;; *) return 1 ;; esac
        case "$resolved_key" in "$resolved_dir"/*) ;; *) return 1 ;; esac
        [ -f "$resolved_cert" ] && [ -f "$resolved_key" ] || return 1

        printf '%s\n' "$resolved_cert"
    }

    # 优先使用 gtagate 已提交的 current generation；再兼容旧 Caddy 布局。
    find_certificate() {
        local domain="$1"
        local cert_label
        local cert=""
        cert_label=$(certificate_label "$domain") || return 1
        cert=$(find_active_certificate "$domain")
        if [ -n "$cert" ] && [ -f "$cert" ]; then
            printf '%s\n' "$cert"
            return 0
        fi

        cert=$(find "$ACME_CERT_DIR" -path "*/$cert_label/$cert_label.crt" \
            -type f ! -path "*/.gtagate-generations/*" 2>/dev/null | head -1)
        [ -n "$cert" ] && [ -f "$cert" ] && [ -f "${cert%.crt}.key" ] || return 1
        printf '%s\n' "$cert"
    }

    acme_domain_for_server_name() {
        local server_name
        local candidate
        local candidate_lower
        local base
        local suffix
        local prefix
        server_name=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/\.$//')

        for candidate in $ACME_DOMAINS; do
            candidate_lower=$(printf '%s' "$candidate" | tr '[:upper:]' '[:lower:]' | sed 's/\.$//')
            case "$candidate_lower" in
                \*.*)
                    base=${candidate_lower#*.}
                    suffix=".$base"
                    case "$server_name" in
                        *"$suffix")
                            prefix=${server_name%"$suffix"}
                            case "$prefix" in
                                ""|*.*) ;;
                                *) printf '%s\n' "$candidate"; return 0 ;;
                            esac
                            ;;
                    esac
                    ;;
                *)
                    if [ "$server_name" = "$candidate_lower" ]; then
                        printf '%s\n' "$candidate"
                        return 0
                    fi
                    ;;
            esac
        done

        # 兼容只有一个 ACME 域名、旧配置未写 tls.server_name 的情形。
        if [ -z "$server_name" ] && [ "$(printf '%s\n' "$ACME_DOMAINS" | wc -l)" -eq 1 ]; then
            printf '%s\n' "$ACME_DOMAINS"
            return 0
        fi
        return 1
    }

    validate_tls_domain_coverage() {
        local entries="/tmp/gtagod-tls-domain-coverage.$$"
        if ! jq -r '
            .inbounds | to_entries[]
            | select(.value.tls?.certificate_path != null)
            | [.key, (.value.tag // ("inbound[" + (.key | tostring) + "]")), (.value.tls.server_name // "")]
            | @tsv
        ' "$GTACORE_RUNTIME_CONFIG" > "$entries"; then
            rm -f "$entries"
            return 1
        fi
        while IFS="$(printf '\t')" read -r _index inbound_tag server_name; do
            if ! acme_domain_for_server_name "$server_name" >/dev/null; then
                echo "❌ TLS inbound $inbound_tag server_name=${server_name:-<empty>} is not covered by ACME domains" >&2
                rm -f "$entries"
                return 1
            fi
        done < "$entries"
        rm -f "$entries"
    }

    build_certificate_map() {
        local tls_entries="/tmp/gtagod-tls-entries.$$"
        local map_entries="/tmp/gtagod-cert-map.$$"
        if ! jq -r '
            .inbounds | to_entries[]
            | select(.value.tls?.certificate_path != null)
            | [.key, (.value.tag // ("inbound[" + (.key | tostring) + "]")), (.value.tls.server_name // "")]
            | @tsv
        ' "$GTACORE_RUNTIME_CONFIG" > "$tls_entries"; then
            rm -f "$tls_entries" "$map_entries"
            return 1
        fi
        : > "$map_entries" || return 1
        while IFS="$(printf '\t')" read -r index inbound_tag server_name; do
            local domain
            local cert
            local key
            domain=$(acme_domain_for_server_name "$server_name") || {
                echo "TLS inbound $inbound_tag has no matching ACME domain" >&2
                rm -f "$tls_entries" "$map_entries"
                return 1
            }
            cert=$(find_certificate "$domain") || {
                echo "certificate for ACME domain $domain is not ready" >&2
                rm -f "$tls_entries" "$map_entries"
                return 1
            }
            key="${cert%.crt}.key"
            [ -f "$cert" ] && [ -f "$key" ] || {
                rm -f "$tls_entries" "$map_entries"
                return 1
            }
            jq -cn --arg index "$index" --arg cert "$cert" --arg key "$key" \
                '{key: $index, value: {cert: $cert, key: $key}}' >> "$map_entries" || {
                rm -f "$tls_entries" "$map_entries"
                return 1
            }
        done < "$tls_entries"
        jq -cs 'from_entries' "$map_entries"
        local result=$?
        rm -f "$tls_entries" "$map_entries"
        return "$result"
    }

    update_cert_paths() {
        local cert_map="$1"
        echo "🔧 Updating gtacore config with per-inbound certificate paths..."
        if ! jq --argjson certs "$cert_map" '
            .inbounds |= (
                to_entries
                | map(
                    if .value.tls?.certificate_path != null then
                        .key as $index
                        | ($certs[($index | tostring)] // error("missing certificate mapping for inbound index \($index)")) as $pair
                        | .value.tls.certificate_path = $pair.cert
                        | .value.tls.key_path = $pair.key
                    else . end
                )
                | map(.value)
            )
        ' \
            "$GTACORE_RUNTIME_CONFIG" > "${GTACORE_RUNTIME_CONFIG}.tmp"; then
            echo "❌ Failed to update certificate paths with jq"
            rm -f "${GTACORE_RUNTIME_CONFIG}.tmp"
            return 1
        fi
        if ! mv "${GTACORE_RUNTIME_CONFIG}.tmp" "$GTACORE_RUNTIME_CONFIG"; then
            echo "❌ Failed to replace gtacore config after cert path update"
            return 1
        fi
        chmod 0600 "$GTACORE_RUNTIME_CONFIG" 2>/dev/null || true
        echo "✅ Certificate paths updated for all TLS inbounds"
    }

    certificate_map_state() {
        local cert_map="$1"
        printf '%s\n' "$cert_map" | jq -r 'to_entries[].value | .cert, .key' \
            | sort -u \
            | while IFS= read -r path; do
                [ -f "$path" ] || return 1
                stat -c '%n|%Y|%s' "$path" 2>/dev/null || return 1
            done
    }

    if ! validate_tls_domain_coverage; then
        exit 1
    fi

    # 等待证书
    WAIT_COUNT=0
    MAX_WAIT=${CERT_WAIT_MAX}
    CERT_FOUND=false

    # 首先检查是否已有证书
    echo "🔍 Checking for all required certificates..."
    CURRENT_CERT_MAP=$(build_certificate_map 2>/dev/null) || CURRENT_CERT_MAP=""
    if [ -n "$CURRENT_CERT_MAP" ]; then
        CERT_FOUND=true
    fi

    if [ "$CERT_FOUND" = "false" ]; then
        echo "⏳ At least one certificate is missing; waiting for gtagate..."
        isleep 10
        WAIT_COUNT=10
    fi

    while [ "$CERT_FOUND" = "false" ] && [ $WAIT_COUNT -lt $MAX_WAIT ]; do
        CURRENT_CERT_MAP=$(build_certificate_map 2>/dev/null) || CURRENT_CERT_MAP=""
        if [ -n "$CURRENT_CERT_MAP" ]; then
            CERT_FOUND=true
        fi

        if [ "$CERT_FOUND" = "false" ]; then
            # 检查 gtagate 是否仍然存活（若已崩溃则证书永远不会到达）
            if ! kill -0 "$GATE_PID" 2>/dev/null; then
                echo "❌ gtagate died during certificate wait; exiting"
                exit 1
            fi
            isleep 3
            WAIT_COUNT=$((WAIT_COUNT + 3))
            if [ $(( (WAIT_COUNT - 10) % 15 )) -eq 0 ]; then
                echo "⏳ Waiting for certificate... (${WAIT_COUNT}s/${MAX_WAIT}s)"
                ls -la /data/caddy/certificates/ 2>/dev/null || echo "   Directory not ready"
            fi
        fi
    done

    if [ "$CERT_FOUND" = "true" ]; then
        if ! update_cert_paths "$CURRENT_CERT_MAP"; then
            echo "❌ Fatal: failed to update certificate paths"
            exit 1
        fi
        CERT_STATE=$(certificate_map_state "$CURRENT_CERT_MAP") || exit 1
        start_gtacore_initial
    else
        echo "⚠️  Timeout waiting for certificate after ${MAX_WAIT}s"
        echo "🔁 Auto-retry is enabled (interval: ${CERT_RETRY_INTERVAL}s, max: ${CERT_RETRY_MAX})"

        RETRY_COUNT=0
        while [ "$CERT_FOUND" = "false" ]; do
            if [ "$CERT_RETRY_MAX" != "0" ] && [ $RETRY_COUNT -ge $CERT_RETRY_MAX ]; then
                echo "❌ Reached max retry count (${CERT_RETRY_MAX}); exiting container to trigger restart"
                exit 1
            fi

            # 检查 gtagate 是否仍然存活
            if ! kill -0 "$GATE_PID" 2>/dev/null; then
                echo "❌ gtagate died during certificate retry; exiting"
                exit 1
            fi
            isleep "$CERT_RETRY_INTERVAL"
            RETRY_COUNT=$((RETRY_COUNT + 1))

            CURRENT_CERT_MAP=$(build_certificate_map 2>/dev/null) || CURRENT_CERT_MAP=""
            if [ -n "$CURRENT_CERT_MAP" ]; then
                echo "✅ Found all certificates on retry #${RETRY_COUNT}"
                CERT_FOUND=true
                if ! update_cert_paths "$CURRENT_CERT_MAP"; then
                    echo "❌ Fatal: failed to update certificate paths"
                    exit 1
                fi
                CERT_STATE=$(certificate_map_state "$CURRENT_CERT_MAP") || exit 1
                start_gtacore_initial
                break
            fi

            if [ $((RETRY_COUNT % 5)) -eq 0 ]; then
                echo "⏳ Still waiting for certificate... (retry #${RETRY_COUNT})"
            fi
        done
    fi
else
    start_gtacore_initial
fi

echo ""
echo "========================================="
echo "✅ GTAGod Container v${VERSION} initialized"
echo "📊 gtagate PID: $GATE_PID"
if [ -n "$GTACORE_PID" ] && kill -0 "$GTACORE_PID" 2>/dev/null; then
    echo "📊 gtacore PID: $GTACORE_PID"
fi
echo "========================================="

# 保持容器运行，同时监控 gtagate 和 gtacore
# =========================================
# 进程监控 + 证书自动重载
# =========================================
# 每 10 秒检查一次:
#   1. gtagate 是否存活
#   2. gtacore 是否存活（如果应该运行的话）
#   3. 证书文件是否更新（自动重载 gtacore）
# =========================================

# 证书热重载失败计数（有界重试）：reload 成功清零；连续失败达上限则放弃本次更新以防风暴。
CERT_RELOAD_FAILS=0
CERT_RELOAD_MAX_FAILS=3
REJECTED_CERT_STATE=""

while true; do
    # 检查 gtagate 是否存活
    if ! kill -0 "$GATE_PID" 2>/dev/null; then
        echo "❌ gtagate (PID $GATE_PID) has exited unexpectedly!"
        echo "🔄 Exiting container to trigger restart..."
        exit 1
    fi

    # 检查 gtacore 是否存活（只要曾成功启动，就持续按有界退避恢复）。
    if [ -f /tmp/gtagod-gtacore-started ] \
        && { [ -z "$GTACORE_PID" ] || ! kill -0 "$GTACORE_PID" 2>/dev/null; }; then
        if [ -n "$GTACORE_PID" ]; then
            wait "$GTACORE_PID" 2>/dev/null || true
            GTACORE_PID=""
        fi
        GTACORE_RESTART_ATTEMPTS=$((GTACORE_RESTART_ATTEMPTS + 1))
        if [ "$GTACORE_RESTART_ATTEMPTS" -gt "$GTACORE_MAX_RESTART_ATTEMPTS" ]; then
            echo "❌ gtacore exceeded max restart attempts ($GTACORE_MAX_RESTART_ATTEMPTS), exiting container..."
            exit 1
        fi
        RESTART_DELAY=$(get_gtacore_restart_delay "$GTACORE_RESTART_ATTEMPTS")
        echo "⚠️  gtacore has exited, attempting restart #${GTACORE_RESTART_ATTEMPTS}/${GTACORE_MAX_RESTART_ATTEMPTS} after ${RESTART_DELAY}s..."
        isleep "$RESTART_DELAY"
        if start_gtacore; then
            echo "✅ gtacore restarted successfully (PID $GTACORE_PID)"
        else
            echo "❌ gtacore restart failed, will continue with backoff"
        fi
    fi

    # 只有跨过稳定窗口才清零失败预算；避免“启动 3 秒后崩溃”永久停留在最短退避。
    if [ "$GTACORE_RESTART_ATTEMPTS" -gt 0 ] \
        && [ -n "$GTACORE_STARTED_AT" ] \
        && [ -n "$GTACORE_PID" ] \
        && kill -0 "$GTACORE_PID" 2>/dev/null; then
        NOW=$(date +%s)
        if [ $((NOW - GTACORE_STARTED_AT)) -ge "$GTACORE_STABLE_RESET_SECS" ]; then
            echo "✅ gtacore remained stable for ${GTACORE_STABLE_RESET_SECS}s; resetting restart budget"
            GTACORE_RESTART_ATTEMPTS=0
        fi
    fi

    # 检查 current generation 路径或证书 mtime 是否更新。reload 成功才推进状态（失败则下轮重试，
    # 用有界失败计数防止持续失败时每 10s 重载风暴）；任何失败都不强停健康进程。
    if [ "$NEEDS_CERT" = "true" ]; then
        CANDIDATE_CERT_MAP=$(build_certificate_map 2>/dev/null) || CANDIDATE_CERT_MAP=""
        NEW_CERT_STATE=""
        if [ -n "$CANDIDATE_CERT_MAP" ]; then
            NEW_CERT_STATE=$(certificate_map_state "$CANDIDATE_CERT_MAP") || NEW_CERT_STATE=""
        fi

        if [ -n "$NEW_CERT_STATE" ] \
            && [ "$NEW_CERT_STATE" != "$CERT_STATE" ] \
            && [ "$NEW_CERT_STATE" != "$REJECTED_CERT_STATE" ]; then
            PREVIOUS_CONFIG="/tmp/gtacore-config.previous.$$"
            if ! cp "$GTACORE_RUNTIME_CONFIG" "$PREVIOUS_CONFIG"; then
                echo "❌ Fatal: failed to snapshot gtacore config before certificate reload"
                exit 1
            fi
            echo "🔄 Certificate updated, reloading gtacore..."
            if update_cert_paths "$CANDIDATE_CERT_MAP" && reload_gtacore; then
                CURRENT_CERT_MAP="$CANDIDATE_CERT_MAP"
                CERT_STATE="$NEW_CERT_STATE"
                CERT_RELOAD_FAILS=0
                REJECTED_CERT_STATE=""
                rm -f "$PREVIOUS_CONFIG"
                echo "✅ gtacore reloaded with new certificate"
            else
                CERT_RELOAD_FAILS=$((CERT_RELOAD_FAILS + 1))
                if ! mv "$PREVIOUS_CONFIG" "$GTACORE_RUNTIME_CONFIG"; then
                    echo "❌ Fatal: failed to restore previous gtacore config"
                    exit 1
                fi
                chmod 0600 "$GTACORE_RUNTIME_CONFIG" 2>/dev/null || true
                if [ -z "$GTACORE_PID" ] || ! kill -0 "$GTACORE_PID" 2>/dev/null; then
                    echo "🔄 Restoring gtacore with the previous certificate..."
                    if ! start_gtacore; then
                        echo "❌ Fatal: failed to restore gtacore after certificate reload failure"
                        exit 1
                    fi
                fi
                if [ "$CERT_RELOAD_FAILS" -ge "$CERT_RELOAD_MAX_FAILS" ]; then
                    REJECTED_CERT_STATE="$NEW_CERT_STATE"
                    CERT_RELOAD_FAILS=0
                    echo "⚠️  证书重载连续失败 ${CERT_RELOAD_MAX_FAILS} 次，隔离该证书集合至下一次变化；gtacore 已恢复旧配置"
                else
                    echo "⚠️  证书重载未成功 (${CERT_RELOAD_FAILS}/${CERT_RELOAD_MAX_FAILS})，已恢复旧配置，下一轮重试"
                fi
            fi
        fi
    fi

    sleep 10 &
    wait $!
done
