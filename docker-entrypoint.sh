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
#   - gtacore (Rust): 七协议稳定组合 + VLESS Vision REALITY / AmneziaWG 扩展轴
#
# 支持的部署模式:
#   - NaiveProxy Only (gtacore naive inbound)
#   - NaiveProxy + AnyTLS (gtacore naive + anytls)
#   - NaiveProxy + AnyReality (gtacore naive + anyreality)
#   - L4/Portfolio/Full 多协议 (TLS 类共享 443，UDP/免 TLS 协议独立监听)
#
# =========================================

VERSION="0.0.1"
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
GTACORE_MAX_RESTART_ATTEMPTS=10
GTACORE_TOKEN_FILE="${GTACORE_TOKEN_FILE:-/tmp/gtacore-token}"
GTACORE_MAX_CONNECTIONS=$(_num_or "${GTACORE_MAX_CONNECTIONS:-8192}" 8192)

# gtacore 控制面 (127.0.0.1:19810) 需要 token；仅 loopback，容器不暴露该端口
ensure_gtacore_token() {
    if [ -s "$GTACORE_TOKEN_FILE" ]; then
        return 0
    fi
    head -c 32 /dev/urandom | base64 | tr -d '\n' > "$GTACORE_TOKEN_FILE"
    chmod 600 "$GTACORE_TOKEN_FILE"
}

ensure_gtacore_log_forwarder() {
    mkdir -p /var/log/gtacore
    touch "$GTACORE_LOG_FILE"

    if [ -n "$LOG_TAIL_PID" ] && kill -0 "$LOG_TAIL_PID" 2>/dev/null; then
        return 0
    fi

    tail -n 0 -f "$GTACORE_LOG_FILE" &
    LOG_TAIL_PID=$!
}

stop_gtacore() {
    if [ -n "$GTACORE_PID" ] && kill -0 "$GTACORE_PID" 2>/dev/null; then
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
    start_gtacore

    if [ -n "$GTACORE_PID" ] && kill -0 "$GTACORE_PID" 2>/dev/null; then
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
        echo "❌ Fatal: gtacore config is invalid or unreadable; exiting instead of running a degraded container"
        exit 1
    fi

    ensure_gtacore_token
    ensure_gtacore_log_forwarder
    # gtacore inbound 与 gtagate 监听均已设 SO_REUSEADDR：--net=host 重建/重启时
    # 即使端口残留 TIME_WAIT 也能立即重绑，无需等待端口释放（消除 ~55s 重启黑屏）。
    gtacore run --config "$GTACORE_RUNTIME_CONFIG" --token-file "$GTACORE_TOKEN_FILE" \
        --max-connections "$GTACORE_MAX_CONNECTIONS" >> "$GTACORE_LOG_FILE" 2>&1 &
    GTACORE_PID=$!
    echo "✅ gtacore started with PID: $GTACORE_PID"

    isleep 3
    if kill -0 "$GTACORE_PID" 2>/dev/null; then
        GTACORE_RESTART_ATTEMPTS=0
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
    else
        echo "❌ gtacore failed to start! Logs:"
        tail -30 "$GTACORE_LOG_FILE" 2>/dev/null || echo "No log file"
        stop_gtacore
        echo ""
        if [ -f /tmp/gtagod-gtacore-required ]; then
            echo "❌ Fatal: gtacore is required for configured inbounds/endpoints; exiting instead of running a degraded container"
            exit 1
        fi
        echo "⚠️  Continuing with gtagate only..."
    fi
}

if [ "$NEEDS_CERT" = "true" ]; then
    echo ""
    echo "🔍 Waiting for SSL certificates..."
    
    # 提取域名信息 (使用 jq 精确解析)
    DOMAIN=$(jq -r '[.inbounds[]? | .tls?.server_name // empty] | first // empty' "$GTACORE_RUNTIME_CONFIG" 2>/dev/null)
    # 优先用 gtagate 配置里 ACME 申请的权威域名（去掉通配前缀 *.）作为证书根域名，
    # 避免用 awk -F. 取末两段在多级 TLD（如 foo.co.uk → 误得 co.uk）上猜错。
    ROOT_DOMAIN=$(jq -r '.acme.domains[0]? // empty' "$GTAGATE_CONFIG" 2>/dev/null | sed 's/^\*\.//')
    if [ -z "$ROOT_DOMAIN" ]; then
        ROOT_DOMAIN=$(echo "$DOMAIN" | awk -F. '{if(NF>=2) print $(NF-1)"."$NF; else print $0}')
    fi
    if [ -z "$ROOT_DOMAIN" ]; then
        ROOT_DOMAIN="example.com"
    fi
    ACME_CERT_DIR=$(jq -r '.acme.cert_dir // "/data/caddy/certificates"' "$GTAGATE_CONFIG" 2>/dev/null)
    ACME_DOMAIN=$(jq -r '.acme.domains[0]? // empty' "$GTAGATE_CONFIG" 2>/dev/null)
    ACME_CA=$(jq -r '.acme.ca // "letsencrypt"' "$GTAGATE_CONFIG" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    case "$ACME_CA" in
        letsencrypt-staging|staging) ACME_CA_LABEL="letsencrypt-staging" ;;
        letsencrypt|le) ACME_CA_LABEL="letsencrypt" ;;
        *)
            echo "❌ Unsupported ACME CA in runtime config: $ACME_CA"
            exit 1
            ;;
    esac
    case "$ACME_DOMAIN" in
        \*.*) ACME_CERT_LABEL="wildcard_.${ACME_DOMAIN#*.}" ;;
        *) ACME_CERT_LABEL="$ACME_DOMAIN" ;;
    esac
    echo "📋 Domain: $DOMAIN (root: $ROOT_DOMAIN)"

    find_active_certificate() {
        [ -n "$ACME_CERT_LABEL" ] || return 1

        local cert_dir="$ACME_CERT_DIR/$ACME_CA_LABEL/$ACME_CERT_LABEL"
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
        resolved_cert=$(readlink -f "$generation_dir/$ACME_CERT_LABEL.crt" 2>/dev/null) || return 1
        resolved_key=$(readlink -f "$generation_dir/$ACME_CERT_LABEL.key" 2>/dev/null) || return 1
        case "$resolved_cert" in "$resolved_dir"/*) ;; *) return 1 ;; esac
        case "$resolved_key" in "$resolved_dir"/*) ;; *) return 1 ;; esac
        [ -f "$resolved_cert" ] && [ -f "$resolved_key" ] || return 1

        printf '%s\n' "$resolved_cert"
    }

    # 优先使用 gtagate 已提交的 current generation；再兼容旧 Caddy 布局。
    find_certificate() {
        local cert=""
        local cert_list
        cert=$(find_active_certificate)
        if [ -n "$cert" ] && [ -f "$cert" ]; then
            printf '%s\n' "$cert"
            return 0
        fi

        cert_list=$(find "$ACME_CERT_DIR" -name "*.crt" -type f ! -path "*/.gtagate-generations/*" 2>/dev/null)
        [ -z "$cert_list" ] && return 1

        # 策略1: 通配符证书 wildcard_*.domain.com (最常见)
        cert=$(printf '%s\n' "$cert_list" | grep -F "/wildcard_.${ROOT_DOMAIN}/" | head -1)
        if [ -n "$cert" ] && [ -f "$cert" ]; then echo "$cert"; return 0; fi

        # 策略2: 完整域名证书 subdomain.domain.com
        if [ -n "$DOMAIN" ]; then
            cert=$(printf '%s\n' "$cert_list" | grep -F "/${DOMAIN}/" | head -1)
            if [ -n "$cert" ] && [ -f "$cert" ]; then echo "$cert"; return 0; fi
        fi

        # 策略3: 根域名证书 domain.com
        cert=$(printf '%s\n' "$cert_list" | grep -F "/${ROOT_DOMAIN}/" | head -1)
        if [ -n "$cert" ] && [ -f "$cert" ]; then echo "$cert"; return 0; fi

        # 策略4: 任意包含根域名的证书
        cert=$(printf '%s\n' "$cert_list" | grep -Fi "$ROOT_DOMAIN" | head -1)
        if [ -n "$cert" ] && [ -f "$cert" ]; then echo "$cert"; return 0; fi

        return 1
    }

    update_cert_paths() {
        echo "🔧 Updating gtacore config with certificate paths..."
        if ! jq --arg cert "$ACTUAL_CERT" --arg key "$ACTUAL_KEY" \
            '(.inbounds[] | select(.tls?.certificate_path != null) | .tls) |= (.certificate_path = $cert | .key_path = $key)' \
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
            if [ $(( (WAIT_COUNT - 10) % 15 )) -eq 0 ]; then
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
        start_gtacore
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
                    start_gtacore
                    break
                fi
            fi

            if [ $((RETRY_COUNT % 5)) -eq 0 ]; then
                echo "⏳ Still waiting for certificate... (retry #${RETRY_COUNT})"
            fi
        done
    fi
else
    start_gtacore
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

CERT_MTIME=""
# 证书热重载失败计数（有界重试）：reload 成功清零；连续失败达上限则放弃本次更新以防风暴。
CERT_RELOAD_FAILS=0
CERT_RELOAD_MAX_FAILS=3
REJECTED_CERT=""
REJECTED_MTIME=""
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

    # 检查 gtacore 是否存活（如果之前成功启动过）
    if [ -n "$GTACORE_PID" ] && ! kill -0 "$GTACORE_PID" 2>/dev/null; then
        GTACORE_RESTART_ATTEMPTS=$((GTACORE_RESTART_ATTEMPTS + 1))
        if [ "$GTACORE_RESTART_ATTEMPTS" -gt "$GTACORE_MAX_RESTART_ATTEMPTS" ]; then
            echo "❌ gtacore exceeded max restart attempts ($GTACORE_MAX_RESTART_ATTEMPTS), exiting container..."
            exit 1
        fi
        RESTART_DELAY=$(get_gtacore_restart_delay "$GTACORE_RESTART_ATTEMPTS")
        echo "⚠️  gtacore (PID $GTACORE_PID) has exited, attempting restart #${GTACORE_RESTART_ATTEMPTS}/${GTACORE_MAX_RESTART_ATTEMPTS} after ${RESTART_DELAY}s..."
        isleep "$RESTART_DELAY"
        start_gtacore
        if [ -n "$GTACORE_PID" ] && kill -0 "$GTACORE_PID" 2>/dev/null; then
            echo "✅ gtacore restarted successfully (PID $GTACORE_PID)"
        else
            echo "❌ gtacore restart failed, will continue with backoff"
        fi
    fi

    # 检查 current generation 路径或证书 mtime 是否更新。reload 成功才推进状态（失败则下轮重试，
    # 用有界失败计数防止持续失败时每 10s 重载风暴）；任何失败都不强停健康进程。
    if [ "$NEEDS_CERT" = "true" ]; then
        CANDIDATE_CERT=$(find_certificate)
        CANDIDATE_KEY="${CANDIDATE_CERT%.crt}.key"
        NEW_MTIME=""
        if [ -n "$CANDIDATE_CERT" ] && [ -f "$CANDIDATE_CERT" ] && [ -f "$CANDIDATE_KEY" ]; then
            NEW_MTIME=$(stat -c %Y "$CANDIDATE_CERT" 2>/dev/null || stat -f %m "$CANDIDATE_CERT" 2>/dev/null || echo "")
        fi
        CERT_CHANGED=false
        if [ -n "$NEW_MTIME" ] && { [ "$CANDIDATE_CERT" != "$ACTUAL_CERT" ] || [ "$NEW_MTIME" != "$CERT_MTIME" ]; }; then
            CERT_CHANGED=true
        fi
        if [ "$CANDIDATE_CERT" = "$REJECTED_CERT" ] && [ "$NEW_MTIME" = "$REJECTED_MTIME" ]; then
            CERT_CHANGED=false
        fi

        if [ "$CERT_CHANGED" = "true" ]; then
            PREVIOUS_CERT="$ACTUAL_CERT"
            PREVIOUS_KEY="$ACTUAL_KEY"
            ACTUAL_CERT="$CANDIDATE_CERT"
            ACTUAL_KEY="$CANDIDATE_KEY"
            echo "🔄 Certificate updated, reloading gtacore..."
            if update_cert_paths && reload_gtacore; then
                CERT_MTIME="$NEW_MTIME"
                CERT_RELOAD_FAILS=0
                REJECTED_CERT=""
                REJECTED_MTIME=""
                echo "✅ gtacore reloaded with new certificate"
            else
                CERT_RELOAD_FAILS=$((CERT_RELOAD_FAILS + 1))
                ACTUAL_CERT="$PREVIOUS_CERT"
                ACTUAL_KEY="$PREVIOUS_KEY"
                if [ -z "$ACTUAL_CERT" ] || [ ! -f "$ACTUAL_CERT" ] || [ ! -f "$ACTUAL_KEY" ]; then
                    echo "❌ Fatal: certificate reload failed and no valid previous pair is available"
                    exit 1
                fi
                if ! update_cert_paths; then
                    echo "❌ Fatal: failed to restore previous certificate paths"
                    exit 1
                fi
                if [ -z "$GTACORE_PID" ] || ! kill -0 "$GTACORE_PID" 2>/dev/null; then
                    echo "🔄 Restoring gtacore with the previous certificate..."
                    start_gtacore
                    if [ -z "$GTACORE_PID" ] || ! kill -0 "$GTACORE_PID" 2>/dev/null; then
                        echo "❌ Fatal: failed to restore gtacore after certificate reload failure"
                        exit 1
                    fi
                fi
                if [ "$CERT_RELOAD_FAILS" -ge "$CERT_RELOAD_MAX_FAILS" ]; then
                    REJECTED_CERT="$CANDIDATE_CERT"
                    REJECTED_MTIME="$NEW_MTIME"
                    CERT_RELOAD_FAILS=0
                    echo "⚠️  证书重载连续失败 ${CERT_RELOAD_MAX_FAILS} 次，隔离该 generation 至下一次证书变化；gtacore 已恢复旧证书"
                else
                    echo "⚠️  证书重载未成功 (${CERT_RELOAD_FAILS}/${CERT_RELOAD_MAX_FAILS})，已恢复旧证书，下一轮重试"
                fi
            fi
        fi
    fi

    sleep 10 &
    wait $!
done
