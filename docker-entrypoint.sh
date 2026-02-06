#!/bin/sh
# 不使用 set -e，手动处理错误
# set -e 会导致任何非零返回值立即退出，不适合长时间运行的服务

# =========================================
# GTAGod Docker Entrypoint
# 版本: 4.1.0
# 更新: 2026-01-01
# =========================================
# 
# sing-box 1.13+ 统一架构:
#   - Caddy: L4 SNI 分流 + ACME 证书申请
#   - sing-box: naive + anytls + anyreality
#
# 支持的部署模式:
#   - NaiveProxy Only (sing-box naive inbound)
#   - NaiveProxy + AnyTLS (sing-box naive + anytls)
#   - NaiveProxy + AnyReality (sing-box naive + anyreality)
#   - L4 多协议 (Layer4 SNI 分流, 全部 sing-box 处理)
#
# =========================================

VERSION="4.1.0"

echo "========================================="
echo "GTAGod Container v${VERSION}"
echo "sing-box 1.13+ unified architecture"
echo "Starting Caddy + sing-box services..."
echo "========================================="

# =========================================
# 检查配置文件
# =========================================
if [ ! -f "/etc/caddy/Caddyfile" ]; then
    echo "❌ ERROR: /etc/caddy/Caddyfile not found!"
    echo "Please mount your Caddyfile to /etc/caddy/Caddyfile"
    exit 1
fi

echo "📝 Caddyfile found, validating..."

# 验证 Caddyfile 格式
if caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1 | grep -q "Valid configuration"; then
    echo "✅ Caddyfile validation passed"
else
    echo "❌ ERROR: Caddyfile validation failed!"
    exit 1
fi

# =========================================
# 检查 sing-box 配置
# =========================================
if [ ! -f "/etc/sing-box/config.json" ]; then
    echo "❌ ERROR: /etc/sing-box/config.json not found!"
    echo "Please mount your sing-box config to /etc/sing-box/config.json"
    exit 1
fi

echo "📝 sing-box config found"

# 复制配置到可写位置
cp /etc/sing-box/config.json /tmp/sing-box-config.json

# =========================================
# 检测配置类型
# =========================================
HAS_NAIVE=false
HAS_ANYTLS=false
HAS_ANYREALITY=false
NEEDS_CERT=false

if grep -q '"type": "naive"' /tmp/sing-box-config.json; then
    HAS_NAIVE=true
    echo "✅ Detected NaiveProxy inbound"
fi

if grep -q '"type": "anytls"' /tmp/sing-box-config.json; then
    HAS_ANYTLS=true
    echo "✅ Detected AnyTLS inbound"
fi

if grep -q '"reality"' /tmp/sing-box-config.json && grep -q '"private_key"' /tmp/sing-box-config.json; then
    HAS_ANYREALITY=true
    echo "✅ Detected AnyReality inbound"
fi

# 检测是否需要证书 (naive 和非 reality 的 anytls 都需要证书)
if grep -q '"certificate_path"' /tmp/sing-box-config.json; then
    NEEDS_CERT=true
    echo "📋 Certificate required for TLS inbounds"
fi

# =========================================
# 启动 Caddy (用于 L4 分流和证书申请)
# =========================================
echo "🚀 Starting Caddy..."
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
CADDY_PID=$!
echo "✅ Caddy started with PID: $CADDY_PID"

# =========================================
# 等待证书后启动 sing-box
# =========================================
CERT_WAIT_MAX="${CERT_WAIT_MAX:-180}"
CERT_RETRY_INTERVAL="${CERT_RETRY_INTERVAL:-30}"
CERT_RETRY_MAX="${CERT_RETRY_MAX:-0}"

start_singbox() {
    if pgrep -x sing-box >/dev/null 2>&1; then
        return 0
    fi

    echo ""
    echo "🚀 Starting sing-box..."

    # 直接输出到 stdout/stderr，这样 docker logs 可以看到
    # 同时使用 tee 保存到文件以便查看历史
    mkdir -p /var/log/sing-box
    sing-box run -c /tmp/sing-box-config.json 2>&1 | tee /var/log/sing-box/sing-box.log &
    SINGBOX_PID=$!
    echo "✅ sing-box started with PID: $SINGBOX_PID"

    sleep 3
    if kill -0 $SINGBOX_PID 2>/dev/null; then
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
        cat /var/log/sing-box/sing-box.log 2>/dev/null | tail -30 || echo "No log file"
        echo ""
        echo "⚠️  Continuing with Caddy only..."
    fi
}

if [ "$NEEDS_CERT" = "true" ]; then
    echo ""
    echo "🔍 Waiting for SSL certificates..."
    
    # 提取域名信息
    DOMAIN=$(grep -o '"server_name"[[:space:]]*:[[:space:]]*"[^"]*"' /tmp/sing-box-config.json | head -1 | cut -d'"' -f4)
    ROOT_DOMAIN=$(echo "$DOMAIN" | awk -F. '{if(NF>=2) print $(NF-1)"."$NF; else print $0}')
    if [ -z "$ROOT_DOMAIN" ]; then
        ROOT_DOMAIN="example.com"
    fi
    echo "📋 Domain: $DOMAIN (root: $ROOT_DOMAIN)"

    # 证书查找函数 - 支持多种路径格式
    find_certificate() {
        local cert=""
        
        # 策略1: 通配符证书 wildcard_*.domain.com (最常见)
        cert=$(find /data/caddy/certificates -name "*.crt" -path "*/wildcard_*.${ROOT_DOMAIN}/*" 2>/dev/null | head -1)
        if [ -n "$cert" ] && [ -f "$cert" ]; then echo "$cert"; return 0; fi
        
        # 策略2: 完整域名证书 subdomain.domain.com
        if [ -n "$DOMAIN" ]; then
            cert=$(find /data/caddy/certificates -name "*.crt" -path "*/${DOMAIN}/*" 2>/dev/null | head -1)
            if [ -n "$cert" ] && [ -f "$cert" ]; then echo "$cert"; return 0; fi
        fi
        
        # 策略3: 根域名证书 domain.com
        cert=$(find /data/caddy/certificates -name "*.crt" -path "*/${ROOT_DOMAIN}/*" 2>/dev/null | head -1)
        if [ -n "$cert" ] && [ -f "$cert" ]; then echo "$cert"; return 0; fi
        
        # 策略4: 任意包含根域名的证书
        cert=$(find /data/caddy/certificates -name "*.crt" 2>/dev/null | grep -i "${ROOT_DOMAIN}" | head -1)
        if [ -n "$cert" ] && [ -f "$cert" ]; then echo "$cert"; return 0; fi
        
        # 策略5: 任意有效证书（最后手段）
        cert=$(find /data/caddy/certificates -name "*.crt" -type f 2>/dev/null | head -1)
        if [ -n "$cert" ] && [ -f "$cert" ]; then echo "$cert"; return 0; fi
        
        return 1
    }

    update_cert_paths() {
        echo "🔧 Updating sing-box config with certificate paths..."
        sed -i "s|\"certificate_path\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"certificate_path\": \"${ACTUAL_CERT}\"|g" /tmp/sing-box-config.json
        sed -i "s|\"key_path\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"key_path\": \"${ACTUAL_KEY}\"|g" /tmp/sing-box-config.json
        echo "✅ Certificate paths updated"
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
        echo "⏳ No existing cert found, waiting for Caddy to request certificate..."
        sleep 10
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
            sleep 3
            WAIT_COUNT=$((WAIT_COUNT + 3))
            if [ $((WAIT_COUNT % 15)) -eq 0 ]; then
                echo "⏳ Waiting for certificate... (${WAIT_COUNT}s/${MAX_WAIT}s)"
                ls -la /data/caddy/certificates/ 2>/dev/null || echo "   Directory not ready"
            fi
        fi
    done
    
    if [ "$CERT_FOUND" = "true" ]; then
        update_cert_paths
        start_singbox
    else
        echo "⚠️  Timeout waiting for certificate after ${MAX_WAIT}s"
        echo "🔁 Auto-retry is enabled (interval: ${CERT_RETRY_INTERVAL}s, max: ${CERT_RETRY_MAX})"

        RETRY_COUNT=0
        while [ "$CERT_FOUND" = "false" ]; do
            if [ "$CERT_RETRY_MAX" != "0" ] && [ $RETRY_COUNT -ge $CERT_RETRY_MAX ]; then
                echo "❌ Reached max retry count (${CERT_RETRY_MAX}), sing-box will remain stopped"
                break
            fi

            sleep "$CERT_RETRY_INTERVAL"
            RETRY_COUNT=$((RETRY_COUNT + 1))

            ACTUAL_CERT=$(find_certificate)
            if [ -n "$ACTUAL_CERT" ] && [ -f "$ACTUAL_CERT" ]; then
                ACTUAL_KEY="${ACTUAL_CERT%.crt}.key"
                if [ -f "$ACTUAL_KEY" ]; then
                    echo "✅ Found certificate on retry #${RETRY_COUNT}: $ACTUAL_CERT"
                    echo "✅ Found key: $ACTUAL_KEY"
                    CERT_FOUND=true
                    update_cert_paths
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
echo "📊 Caddy PID: $CADDY_PID"
if [ -n "$SINGBOX_PID" ] && kill -0 $SINGBOX_PID 2>/dev/null; then
    echo "📊 sing-box PID: $SINGBOX_PID"
fi
echo "========================================="

# 保持容器运行，同时监控 Caddy 和 sing-box
# =========================================
# 进程监控 + 证书自动重载
# =========================================
# 每 60 秒检查一次:
#   1. Caddy 是否存活
#   2. sing-box 是否存活（如果应该运行的话）
#   3. 证书文件是否更新（自动重载 sing-box）
# =========================================

CERT_MTIME=""
if [ "$NEEDS_CERT" = "true" ] && [ -n "$ACTUAL_CERT" ] && [ -f "$ACTUAL_CERT" ]; then
    CERT_MTIME=$(stat -c %Y "$ACTUAL_CERT" 2>/dev/null || echo "")
fi

while true; do
    # 检查 Caddy 是否存活
    if ! kill -0 $CADDY_PID 2>/dev/null; then
        echo "❌ Caddy (PID $CADDY_PID) has exited unexpectedly!"
        echo "🔄 Exiting container to trigger restart..."
        exit 1
    fi

    # 检查 sing-box 是否存活（如果之前成功启动过）
    if [ -n "$SINGBOX_PID" ] && ! kill -0 $SINGBOX_PID 2>/dev/null; then
        echo "⚠️  sing-box (PID $SINGBOX_PID) has exited, attempting restart..."
        sing-box run -c /tmp/sing-box-config.json 2>&1 | tee /var/log/sing-box/sing-box.log &
        SINGBOX_PID=$!
        sleep 3
        if kill -0 $SINGBOX_PID 2>/dev/null; then
            echo "✅ sing-box restarted successfully (PID $SINGBOX_PID)"
        else
            echo "❌ sing-box restart failed, will retry in 60s"
        fi
    fi

    # 检查证书是否更新（自动重载 sing-box）
    if [ "$NEEDS_CERT" = "true" ] && [ -n "$ACTUAL_CERT" ] && [ -f "$ACTUAL_CERT" ]; then
        NEW_MTIME=$(stat -c %Y "$ACTUAL_CERT" 2>/dev/null || echo "")
        if [ -n "$NEW_MTIME" ] && [ -n "$CERT_MTIME" ] && [ "$NEW_MTIME" != "$CERT_MTIME" ]; then
            echo "🔄 Certificate updated, reloading sing-box..."
            CERT_MTIME="$NEW_MTIME"
            if [ -n "$SINGBOX_PID" ] && kill -0 $SINGBOX_PID 2>/dev/null; then
                kill $SINGBOX_PID 2>/dev/null
                sleep 2
                sing-box run -c /tmp/sing-box-config.json 2>&1 | tee /var/log/sing-box/sing-box.log &
                SINGBOX_PID=$!
                sleep 3
                if kill -0 $SINGBOX_PID 2>/dev/null; then
                    echo "✅ sing-box reloaded with new certificate"
                else
                    echo "❌ sing-box reload failed"
                fi
            fi
        fi
    fi

    sleep 60
done
