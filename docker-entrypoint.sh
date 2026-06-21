#!/bin/sh
# 不使用 set -e，手动处理错误
# set -e 会导致任何非零返回值立即退出，不适合长时间运行的服务

# =========================================
# GTAGod Docker Entrypoint
# 版本: 0.0.1
# 更新: 2026-06-04
# =========================================
# 
# GTACore (Rust) 统一架构:
#   - gtagate (Rust): L4 SNI 分流 + ACME 证书申请
#   - gtacore (Rust): naive + anytls + anyreality (替代 sing-box)
#
# 支持的部署模式:
#   - NaiveProxy Only (gtacore naive inbound)
#   - NaiveProxy + AnyTLS (gtacore naive + anytls)
#   - NaiveProxy + AnyReality (gtacore naive + anyreality)
#   - L4 多协议 (Layer4 SNI 分流, 全部 gtacore 处理)
#
# =========================================

VERSION="0.0.1"
SINGBOX_MOUNTED_CONFIG="/etc/sing-box/config.json"
SINGBOX_RUNTIME_CONFIG="/tmp/sing-box-config.json"
SINGBOX_LOG_FILE="/var/log/sing-box/sing-box.log"
GTAGATE_CONFIG="/etc/gtagate/config.json"

echo "========================================="
echo "GTAGod Container v${VERSION}"
echo "GTACore (Rust) unified architecture"
echo "Starting gtagate + gtacore services..."
echo "========================================="

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
# 检查 sing-box 配置
# =========================================
if [ ! -f "$SINGBOX_MOUNTED_CONFIG" ]; then
    echo "❌ ERROR: $SINGBOX_MOUNTED_CONFIG not found!"
    echo "Please mount your sing-box config to $SINGBOX_MOUNTED_CONFIG"
    exit 1
fi

echo "📝 sing-box config found"

# 复制到可写运行时配置。entrypoint 后续会执行兼容性迁移、IPv4 策略修正、证书路径更新，
# 因此不能直接修改只读挂载配置。若挂载配置不可读，必须在启动早期明确失败。
if ! cat "$SINGBOX_MOUNTED_CONFIG" > "$SINGBOX_RUNTIME_CONFIG"; then
    echo "❌ ERROR: Cannot read $SINGBOX_MOUNTED_CONFIG or write $SINGBOX_RUNTIME_CONFIG"
    echo "Please check host permissions. Recommended: chmod 644 singbox/config.json"
    ls -ld /etc/sing-box "$SINGBOX_MOUNTED_CONFIG" /tmp 2>/dev/null || true
    exit 1
fi

if ! chmod 0644 "$SINGBOX_RUNTIME_CONFIG"; then
    echo "❌ ERROR: Failed to set readable permissions on $SINGBOX_RUNTIME_CONFIG"
    exit 1
fi

if ! jq empty "$SINGBOX_RUNTIME_CONFIG" >/tmp/sing-box-json-validate.log 2>&1; then
    echo "❌ ERROR: $SINGBOX_MOUNTED_CONFIG is not valid JSON"
    cat /tmp/sing-box-json-validate.log
    rm -f /tmp/sing-box-json-validate.log
    exit 1
fi
rm -f /tmp/sing-box-json-validate.log

echo "✅ Runtime sing-box config prepared at $SINGBOX_RUNTIME_CONFIG"

migrate_legacy_dns_servers() {
    if ! jq -e 'any(.dns.servers[]?; (.address? != null) and (.address | type == "string"))' "$SINGBOX_RUNTIME_CONFIG" >/dev/null 2>&1; then
        echo "✅ sing-box DNS server format is current"
        return 0
    fi

    echo "⚠️  Detected legacy sing-box DNS server format, migrating to typed HTTPS servers..."

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
    ' "$SINGBOX_RUNTIME_CONFIG" > "${SINGBOX_RUNTIME_CONFIG}.migrated"; then
        echo "❌ Failed to migrate legacy DNS server format"
        rm -f "${SINGBOX_RUNTIME_CONFIG}.migrated"
        return 1
    fi

    if jq -e 'any(.dns.servers[]?; .address? != null)' "${SINGBOX_RUNTIME_CONFIG}.migrated" >/dev/null 2>&1; then
        echo "❌ Found unsupported legacy DNS server entries after migration"
        rm -f "${SINGBOX_RUNTIME_CONFIG}.migrated"
        return 1
    fi

    if ! mv "${SINGBOX_RUNTIME_CONFIG}.migrated" "$SINGBOX_RUNTIME_CONFIG"; then
        echo "❌ Failed to replace sing-box config after DNS migration"
        rm -f "${SINGBOX_RUNTIME_CONFIG}.migrated"
        return 1
    fi

    chmod 0644 "$SINGBOX_RUNTIME_CONFIG" 2>/dev/null || true

    echo "✅ Legacy sing-box DNS servers migrated to typed HTTPS format"
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

    if ! jq -e 'has("dns")' "$SINGBOX_RUNTIME_CONFIG" >/dev/null 2>&1; then
        return 0
    fi

    _dns_strategy=$(jq -r '.dns.strategy // "unset"' "$SINGBOX_RUNTIME_CONFIG" 2>/dev/null)
    if [ "$_dns_strategy" = "ipv4_only" ]; then
        echo "ℹ️  未检测到全局 IPv6，DNS strategy 已是 ipv4_only"
        return 0
    fi

    echo "⚠️  未检测到全局 IPv6 地址，将 DNS strategy 由 ${_dns_strategy} 强制为 ipv4_only（避免直连不可达的 IPv6）"
    if jq '.dns.strategy = "ipv4_only"' "$SINGBOX_RUNTIME_CONFIG" > "${SINGBOX_RUNTIME_CONFIG}.ipv4" \
        && mv "${SINGBOX_RUNTIME_CONFIG}.ipv4" "$SINGBOX_RUNTIME_CONFIG"; then
        chmod 0644 "$SINGBOX_RUNTIME_CONFIG" 2>/dev/null || true
        echo "✅ DNS strategy 已设为 ipv4_only"
    else
        echo "⚠️  设置 ipv4_only 失败，继续使用 ${_dns_strategy}"
        rm -f "${SINGBOX_RUNTIME_CONFIG}.ipv4"
    fi
}

if ! migrate_legacy_dns_servers; then
    exit 1
fi

enforce_ipv4_only_without_ipv6

# =========================================
# 检测配置类型 (使用 jq 精确解析 JSON)
# =========================================
HAS_NAIVE=false
HAS_ANYTLS=false
HAS_ANYREALITY=false
NEEDS_CERT=false

if jq -e '.inbounds[]? | select(.type == "naive")' "$SINGBOX_RUNTIME_CONFIG" >/dev/null 2>&1; then
    HAS_NAIVE=true
    echo "✅ Detected NaiveProxy inbound"
fi

if jq -e '.inbounds[]? | select(.type == "anytls")' "$SINGBOX_RUNTIME_CONFIG" >/dev/null 2>&1; then
    HAS_ANYTLS=true
    echo "✅ Detected AnyTLS inbound"
fi

if jq -e '.inbounds[]? | select(.tls?.reality?.enabled == true and .tls?.reality?.private_key != null)' "$SINGBOX_RUNTIME_CONFIG" >/dev/null 2>&1; then
    HAS_ANYREALITY=true
    echo "✅ Detected AnyReality inbound"
fi

# 检测是否需要证书 (naive 和非 reality 的 anytls 都需要证书)
if jq -e '.inbounds[]? | select(.tls?.certificate_path != null)' "$SINGBOX_RUNTIME_CONFIG" >/dev/null 2>&1; then
    NEEDS_CERT=true
    echo "📋 Certificate required for TLS inbounds"
fi

if [ "$HAS_NAIVE" = "true" ] || [ "$HAS_ANYTLS" = "true" ] || [ "$HAS_ANYREALITY" = "true" ]; then
    touch /tmp/gtagod-singbox-required
else
    rm -f /tmp/gtagod-singbox-required
fi

# =========================================
# 信号处理 (优雅退出)
# =========================================

# 可中断 sleep：后台 sleep + wait，使 trap 能立即打断长等待
isleep() { sleep "$1" & wait $!; }

cleanup() {
    echo "🛑 Received stop signal, shutting down gracefully..."
    # Send SIGTERM to all managed processes
    for _pid_var in SINGBOX_PID GATE_PID LOG_TAIL_PID; do
        eval "_pid=\$$_pid_var"
        if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
            echo "🛑 Stopping $_pid_var (PID $_pid)..."
            kill -TERM "$_pid" 2>/dev/null
        fi
    done
    # 8s 看门狗：留 Docker 10s grace period 2s 余量，超时强杀
    ( sleep 8; for _v in SINGBOX_PID GATE_PID LOG_TAIL_PID; do
        eval "_p=\$$_v"; [ -n "$_p" ] && kill -9 "$_p" 2>/dev/null
    done ) & _wd_pid=$!
    # 用 wait 真正回收子进程（避免 kill -0 轮询僵尸永远成立的 bug）
    for _pid_var in SINGBOX_PID GATE_PID LOG_TAIL_PID; do
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
sleep 2
if ! kill -0 "$GATE_PID" 2>/dev/null; then
    echo "❌ gtagate failed to start (exited within 2s)"
    exit 1
fi
echo "✅ gtagate started with PID: $GATE_PID"

# =========================================
# 等待证书后启动 sing-box
# =========================================
CERT_WAIT_MAX="${CERT_WAIT_MAX:-180}"
CERT_RETRY_INTERVAL="${CERT_RETRY_INTERVAL:-30}"
CERT_RETRY_MAX="${CERT_RETRY_MAX:-10}"
SINGBOX_RESTART_ATTEMPTS=0
SINGBOX_MAX_RESTART_ATTEMPTS=10
GTACORE_TOKEN_FILE="${GTACORE_TOKEN_FILE:-/tmp/gtacore-token}"

# gtacore 控制面 (127.0.0.1:19810) 需要 token；仅 loopback，容器不暴露该端口
ensure_gtacore_token() {
    if [ -s "$GTACORE_TOKEN_FILE" ]; then
        return 0
    fi
    head -c 32 /dev/urandom | base64 | tr -d '\n' > "$GTACORE_TOKEN_FILE"
    chmod 600 "$GTACORE_TOKEN_FILE"
}

ensure_singbox_log_forwarder() {
    mkdir -p /var/log/sing-box
    touch "$SINGBOX_LOG_FILE"

    if [ -n "$LOG_TAIL_PID" ] && kill -0 "$LOG_TAIL_PID" 2>/dev/null; then
        return 0
    fi

    tail -n 0 -f "$SINGBOX_LOG_FILE" &
    LOG_TAIL_PID=$!
}

stop_singbox() {
    if [ -n "$SINGBOX_PID" ] && kill -0 "$SINGBOX_PID" 2>/dev/null; then
        kill -TERM "$SINGBOX_PID" 2>/dev/null
        _stop_timeout=10
        while [ $_stop_timeout -gt 0 ] && kill -0 "$SINGBOX_PID" 2>/dev/null; do
            sleep 1
            _stop_timeout=$((_stop_timeout - 1))
        done
        if kill -0 "$SINGBOX_PID" 2>/dev/null; then
            echo "⚠️  gtacore did not stop within 10s, force killing PID $SINGBOX_PID..."
            kill -9 "$SINGBOX_PID" 2>/dev/null
        fi
        wait "$SINGBOX_PID" 2>/dev/null || true
    fi
    SINGBOX_PID=""
}

reload_singbox() {
    # gtacore 无 SIGHUP 热重载，证书更新需重启进程
    if ! validate_singbox_config; then
        echo "❌ Skipping gtacore reload because config validation failed"
        return 1
    fi

    stop_singbox
    sleep 1
    start_singbox

    if [ -n "$SINGBOX_PID" ] && kill -0 "$SINGBOX_PID" 2>/dev/null; then
        echo "✅ gtacore reloaded (restarted) successfully"
        return 0
    fi

    echo "❌ gtacore failed to start after reload"
    return 1
}

validate_singbox_config() {
    VALIDATE_LOG="/tmp/sing-box-check.log"

    if gtacore sing-box check -c "$SINGBOX_RUNTIME_CONFIG" >"$VALIDATE_LOG" 2>&1; then
        echo "✅ gtacore config validation passed"
        rm -f "$VALIDATE_LOG"
        return 0
    fi

    echo "❌ gtacore config validation failed!"
    cat "$VALIDATE_LOG"
    rm -f "$VALIDATE_LOG"
    return 1
}

get_singbox_restart_delay() {
    case "$1" in
        1) echo 2 ;;
        2) echo 5 ;;
        3) echo 10 ;;
        4) echo 30 ;;
        *) echo 60 ;;
    esac
}

start_singbox() {
    if [ -n "$SINGBOX_PID" ] && kill -0 "$SINGBOX_PID" 2>/dev/null; then
        return 0
    fi

    echo ""
    echo "🚀 Starting gtacore..."

    if ! validate_singbox_config; then
        echo "❌ Fatal: gtacore config is invalid or unreadable; exiting instead of running a degraded container"
        exit 1
    fi

    ensure_gtacore_token
    ensure_singbox_log_forwarder
    gtacore run --config "$SINGBOX_RUNTIME_CONFIG" --token-file "$GTACORE_TOKEN_FILE" >> "$SINGBOX_LOG_FILE" 2>&1 &
    SINGBOX_PID=$!
    echo "✅ gtacore started with PID: $SINGBOX_PID"

    sleep 3
    if kill -0 "$SINGBOX_PID" 2>/dev/null; then
        SINGBOX_RESTART_ATTEMPTS=0
        touch /tmp/gtagod-singbox-started
        echo "✅ sing-box is running successfully!"
        
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
    else
        echo "❌ sing-box failed to start! Logs:"
        tail -30 "$SINGBOX_LOG_FILE" 2>/dev/null || echo "No log file"
        stop_singbox
        echo ""
        if [ -f /tmp/gtagod-singbox-required ]; then
            echo "❌ Fatal: gtacore is required for configured inbounds; exiting instead of running a degraded container"
            exit 1
        fi
        echo "⚠️  Continuing with gtagate only..."
    fi
}

if [ "$NEEDS_CERT" = "true" ]; then
    echo ""
    echo "🔍 Waiting for SSL certificates..."
    
    # 提取域名信息 (使用 jq 精确解析)
    DOMAIN=$(jq -r '[.inbounds[]? | .tls?.server_name // empty] | first // empty' "$SINGBOX_RUNTIME_CONFIG" 2>/dev/null)
    ROOT_DOMAIN=$(echo "$DOMAIN" | awk -F. '{if(NF>=2) print $(NF-1)"."$NF; else print $0}')
    if [ -z "$ROOT_DOMAIN" ]; then
        ROOT_DOMAIN="example.com"
    fi
    echo "📋 Domain: $DOMAIN (root: $ROOT_DOMAIN)"

    # 证书查找函数 - 单次 find 遍历，按优先级匹配
    find_certificate() {
        local cert=""
        local cert_list
        cert_list=$(find /data/caddy/certificates -name "*.crt" -type f 2>/dev/null)
        [ -z "$cert_list" ] && return 1

        # 策略1: 通配符证书 wildcard_*.domain.com (最常见)
        cert=$(echo "$cert_list" | grep "/wildcard_.*\.${ROOT_DOMAIN}/" | head -1)
        if [ -n "$cert" ] && [ -f "$cert" ]; then echo "$cert"; return 0; fi

        # 策略2: 完整域名证书 subdomain.domain.com
        if [ -n "$DOMAIN" ]; then
            cert=$(echo "$cert_list" | grep "/${DOMAIN}/" | head -1)
            if [ -n "$cert" ] && [ -f "$cert" ]; then echo "$cert"; return 0; fi
        fi

        # 策略3: 根域名证书 domain.com
        cert=$(echo "$cert_list" | grep "/${ROOT_DOMAIN}/" | head -1)
        if [ -n "$cert" ] && [ -f "$cert" ]; then echo "$cert"; return 0; fi

        # 策略4: 任意包含根域名的证书
        cert=$(echo "$cert_list" | grep -i "${ROOT_DOMAIN}" | head -1)
        if [ -n "$cert" ] && [ -f "$cert" ]; then echo "$cert"; return 0; fi

        return 1
    }

    update_cert_paths() {
        echo "🔧 Updating sing-box config with certificate paths..."
        if ! jq --arg cert "$ACTUAL_CERT" --arg key "$ACTUAL_KEY" \
            '(.inbounds[] | select(.tls?.certificate_path != null) | .tls) |= (.certificate_path = $cert | .key_path = $key)' \
            "$SINGBOX_RUNTIME_CONFIG" > "${SINGBOX_RUNTIME_CONFIG}.tmp"; then
            echo "❌ Failed to update certificate paths with jq"
            rm -f "${SINGBOX_RUNTIME_CONFIG}.tmp"
            return 1
        fi
        if ! mv "${SINGBOX_RUNTIME_CONFIG}.tmp" "$SINGBOX_RUNTIME_CONFIG"; then
            echo "❌ Failed to replace sing-box config after cert path update"
            return 1
        fi
        chmod 0644 "$SINGBOX_RUNTIME_CONFIG" 2>/dev/null || true
        echo "✅ Certificate paths updated: $ACTUAL_CERT"
    }
    
    # 等待证书
    WAIT_COUNT=0
    MAX_WAIT=${CERT_WAIT_MAX}
    CERT_FOUND=false
    
    # 首先检查是否已有证书
    echo "🔍 Checking for existing certificates..."
    ACTUAL_CERT=$(find_certificate)
    if [ -n "$ACTUAL_CERT" ] && [ -f "$ACTUAL_CERT" ]; then
        ACTUAL_KEY="${ACTUAL_CERT%.crt}.key"
        if [ -f "$ACTUAL_KEY" ]; then
            echo "✅ Found existing certificate: $ACTUAL_CERT"
            echo "✅ Found existing key: $ACTUAL_KEY"
            CERT_FOUND=true
        fi
    fi
    
    if [ "$CERT_FOUND" = "false" ]; then
        echo "⏳ No existing cert found, waiting for gtagate to request certificate..."
        isleep 10
        WAIT_COUNT=10
    fi
    
    while [ "$CERT_FOUND" = "false" ] && [ $WAIT_COUNT -lt $MAX_WAIT ]; do
        ACTUAL_CERT=$(find_certificate)
        if [ -n "$ACTUAL_CERT" ] && [ -f "$ACTUAL_CERT" ]; then
            ACTUAL_KEY="${ACTUAL_CERT%.crt}.key"
            
            if [ -f "$ACTUAL_KEY" ]; then
                echo "✅ Found certificate: $ACTUAL_CERT"
                echo "✅ Found key: $ACTUAL_KEY"
                CERT_FOUND=true
            else
                echo "⚠️  Certificate found but key missing: $ACTUAL_KEY"
            fi
        fi
        
        if [ "$CERT_FOUND" = "false" ]; then
            # 检查 gtagate 是否仍然存活（若已崩溃则证书永远不会到达）
            if ! kill -0 "$GATE_PID" 2>/dev/null; then
                echo "❌ gtagate died during certificate wait; exiting"
                exit 1
            fi
            isleep 3
            WAIT_COUNT=$((WAIT_COUNT + 3))
            if [ $((WAIT_COUNT % 3)) -lt 3 ] && [ $((WAIT_COUNT / 15 * 15)) -eq $WAIT_COUNT ]; then
                echo "⏳ Waiting for certificate... (${WAIT_COUNT}s/${MAX_WAIT}s)"
                ls -la /data/caddy/certificates/ 2>/dev/null || echo "   Directory not ready"
            fi
        fi
    done
    
    if [ "$CERT_FOUND" = "true" ]; then
        if ! update_cert_paths; then
            echo "❌ Fatal: failed to update certificate paths"
            exit 1
        fi
        start_singbox
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

            ACTUAL_CERT=$(find_certificate)
            if [ -n "$ACTUAL_CERT" ] && [ -f "$ACTUAL_CERT" ]; then
                ACTUAL_KEY="${ACTUAL_CERT%.crt}.key"
                if [ -f "$ACTUAL_KEY" ]; then
                    echo "✅ Found certificate on retry #${RETRY_COUNT}: $ACTUAL_CERT"
                    echo "✅ Found key: $ACTUAL_KEY"
                    CERT_FOUND=true
                    if ! update_cert_paths; then
                        echo "❌ Fatal: failed to update certificate paths"
                        exit 1
                    fi
                    start_singbox
                    break
                fi
            fi

            if [ $((RETRY_COUNT % 5)) -eq 0 ]; then
                echo "⏳ Still waiting for certificate... (retry #${RETRY_COUNT})"
            fi
        done
    fi
else
    start_singbox
fi

echo ""
echo "========================================="
echo "✅ GTAGod Container v${VERSION} initialized"
echo "📊 gtagate PID: $GATE_PID"
if [ -n "$SINGBOX_PID" ] && kill -0 "$SINGBOX_PID" 2>/dev/null; then
    echo "📊 gtacore PID: $SINGBOX_PID"
fi
echo "========================================="

# 保持容器运行，同时监控 gtagate 和 sing-box
# =========================================
# 进程监控 + 证书自动重载
# =========================================
# 每 10 秒检查一次:
#   1. gtagate 是否存活
#   2. sing-box 是否存活（如果应该运行的话）
#   3. 证书文件是否更新（自动重载 sing-box）
# =========================================

CERT_MTIME=""
if [ "$NEEDS_CERT" = "true" ] && [ -n "$ACTUAL_CERT" ] && [ -f "$ACTUAL_CERT" ]; then
    CERT_MTIME=$(stat -c %Y "$ACTUAL_CERT" 2>/dev/null || stat -f %m "$ACTUAL_CERT" 2>/dev/null || echo "")
fi

while true; do
    # 检查 gtagate 是否存活
    if ! kill -0 "$GATE_PID" 2>/dev/null; then
        echo "❌ gtagate (PID $GATE_PID) has exited unexpectedly!"
        echo "🔄 Exiting container to trigger restart..."
        exit 1
    fi

    # 检查 sing-box 是否存活（如果之前成功启动过）
    if [ -n "$SINGBOX_PID" ] && ! kill -0 "$SINGBOX_PID" 2>/dev/null; then
        SINGBOX_RESTART_ATTEMPTS=$((SINGBOX_RESTART_ATTEMPTS + 1))
        if [ "$SINGBOX_RESTART_ATTEMPTS" -gt "$SINGBOX_MAX_RESTART_ATTEMPTS" ]; then
            echo "❌ sing-box exceeded max restart attempts ($SINGBOX_MAX_RESTART_ATTEMPTS), exiting container..."
            exit 1
        fi
        RESTART_DELAY=$(get_singbox_restart_delay "$SINGBOX_RESTART_ATTEMPTS")
        echo "⚠️  sing-box (PID $SINGBOX_PID) has exited, attempting restart #${SINGBOX_RESTART_ATTEMPTS}/${SINGBOX_MAX_RESTART_ATTEMPTS} after ${RESTART_DELAY}s..."
        isleep "$RESTART_DELAY"
        start_singbox
        if [ -n "$SINGBOX_PID" ] && kill -0 "$SINGBOX_PID" 2>/dev/null; then
            echo "✅ sing-box restarted successfully (PID $SINGBOX_PID)"
        else
            echo "❌ sing-box restart failed, will continue with backoff"
        fi
    fi

    # 检查证书是否更新（自动重载 sing-box）
    if [ "$NEEDS_CERT" = "true" ] && [ -n "$ACTUAL_CERT" ] && [ -f "$ACTUAL_CERT" ]; then
        NEW_MTIME=$(stat -c %Y "$ACTUAL_CERT" 2>/dev/null || stat -f %m "$ACTUAL_CERT" 2>/dev/null || echo "")
        if [ -n "$NEW_MTIME" ] && [ -n "$CERT_MTIME" ] && [ "$NEW_MTIME" != "$CERT_MTIME" ]; then
            echo "🔄 Certificate updated, reloading sing-box..."
            CERT_MTIME="$NEW_MTIME"
            if ! update_cert_paths; then
                echo "❌ Failed to update certificate paths after cert change; skipping reload"
                continue
            fi
            if [ -n "$SINGBOX_PID" ] && kill -0 "$SINGBOX_PID" 2>/dev/null; then
                if reload_singbox; then
                    echo "✅ sing-box reloaded with new certificate"
                else
                    echo "⚠️  Hot reload failed, falling back to restart..."
                    stop_singbox
                    sleep 2
                    start_singbox
                    if [ -n "$SINGBOX_PID" ] && kill -0 "$SINGBOX_PID" 2>/dev/null; then
                        echo "✅ sing-box restarted with new certificate"
                    else
                        echo "❌ sing-box restart failed"
                    fi
                fi
            fi
        fi
    fi

    sleep 10 &
    wait $!
done
