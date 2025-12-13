#!/bin/sh
set -e

# =========================================
# V2God Docker Entrypoint
# 版本: 2.1.0
# 更新: 2025-12-13
# =========================================
# 
# 支持的部署模式:
#   - NaiveProxy Only (仅 Caddy)
#   - NaiveProxy + AnyTLS (Caddy + sing-box 真实证书)
#   - NaiveProxy + AnyReality (Caddy + sing-box Reality)
#   - L4 多协议 (Layer4 SNI 分流)
#
# =========================================

VERSION="2.1.0"

echo "========================================="
echo "V2God Container v${VERSION}"
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
if ! caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile; then
    echo "❌ ERROR: Caddyfile validation failed!"
    exit 1
fi
echo "✅ Caddyfile validation passed"

# =========================================
# 启动 Caddy
# =========================================
echo "🚀 Starting Caddy..."
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
CADDY_PID=$!
echo "✅ Caddy started with PID: $CADDY_PID"

# =========================================
# 检查 sing-box 配置并启动
# =========================================
if [ -f "/etc/sing-box/config.json" ]; then
    echo ""
    echo "🔍 Detecting sing-box configuration..."
    
    # 复制配置到可写位置，解决只读挂载问题
    cp /etc/sing-box/config.json /tmp/sing-box-config.json
    
    # 检测是否为 Reality 模式（无需等待证书）
    IS_REALITY=false
    if grep -q '"reality"' /tmp/sing-box-config.json; then
        if grep -q '"private_key"' /tmp/sing-box-config.json; then
            IS_REALITY=true
            echo "✅ Detected AnyReality mode (Reality TLS)"
        fi
    fi
    
    # 检测是否需要证书 (AnyTLS 模式)
    NEEDS_CERT=false
    if grep -q '"certificate_path"' /tmp/sing-box-config.json; then
        NEEDS_CERT=true
        echo "✅ Detected AnyTLS mode (requires certificate)"
    fi
    
    # =========================================
    # Reality 模式：直接启动 sing-box
    # =========================================
    if [ "$IS_REALITY" = "true" ]; then
        echo "🚀 Starting sing-box (Reality mode, no certificate needed)..."
        
        mkdir -p /var/log/sing-box
        sing-box run -c /tmp/sing-box-config.json > /var/log/sing-box/sing-box.log 2>&1 &
        SINGBOX_PID=$!
        echo "✅ sing-box started with PID: $SINGBOX_PID"
        
        sleep 3
        if kill -0 $SINGBOX_PID 2>/dev/null; then
            echo "✅ sing-box (AnyReality) is running successfully!"
        else
            echo "❌ sing-box failed to start! Logs:"
            cat /var/log/sing-box/sing-box.log 2>/dev/null | tail -20 || echo "No log file"
            echo "⚠️  Continuing with Caddy only..."
        fi
    
    # =========================================
    # AnyTLS 模式：等待证书后启动
    # =========================================
    elif [ "$NEEDS_CERT" = "true" ]; then
        echo "🔍 Waiting for SSL certificates..."
        
        # 提取域名信息
        DOMAIN=$(grep -o '"server_name"[[:space:]]*:[[:space:]]*"[^"]*"' /etc/sing-box/config.json | cut -d'"' -f4 | head -1)
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
        
        # 等待证书
        WAIT_COUNT=0
        MAX_WAIT=180
        CERT_FOUND=false
        
        # 首先检查是否已有证书（避免无谓等待）
        echo "🔍 Checking for existing certificates..."
        ACTUAL_CERT=$(find_certificate)
        if [ -n "$ACTUAL_CERT" ] && [ -f "$ACTUAL_CERT" ]; then
            ACTUAL_KEY="${ACTUAL_CERT%.crt}.key"
            if [ -f "$ACTUAL_KEY" ]; then
                echo "✅ Found existing certificate: $ACTUAL_CERT"
                echo "✅ Found existing key: $ACTUAL_KEY"
                echo "🔧 Updating sing-box config with certificate paths..."
                
                # 替换证书路径
                sed -i "s|\"certificate_path\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"certificate_path\": \"${ACTUAL_CERT}\"|g" /tmp/sing-box-config.json
                sed -i "s|\"key_path\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"key_path\": \"${ACTUAL_KEY}\"|g" /tmp/sing-box-config.json
                
                echo "✅ Certificate paths updated"
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
                    echo "🔧 Updating sing-box config with certificate paths..."
                    
                    # 替换证书路径
                    sed -i "s|\"certificate_path\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"certificate_path\": \"${ACTUAL_CERT}\"|g" /tmp/sing-box-config.json
                    sed -i "s|\"key_path\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"key_path\": \"${ACTUAL_KEY}\"|g" /tmp/sing-box-config.json
                    
                    echo "✅ Certificate paths updated"
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
            echo "🚀 Starting sing-box with auto-detected certificate..."
            
            mkdir -p /var/log/sing-box
            sing-box run -c /tmp/sing-box-config.json > /var/log/sing-box/sing-box.log 2>&1 &
            SINGBOX_PID=$!
            echo "✅ sing-box started with PID: $SINGBOX_PID"
            
            sleep 3
            if kill -0 $SINGBOX_PID 2>/dev/null; then
                echo "✅ sing-box (AnyTLS) is running successfully!"
            else
                echo "❌ sing-box failed to start! Logs:"
                cat /var/log/sing-box/sing-box.log 2>/dev/null | tail -20 || echo "No log file"
                echo "⚠️  Continuing with Caddy only..."
            fi
        else
            echo "⚠️  Timeout waiting for certificate after ${MAX_WAIT}s"
            echo "💡 sing-box will not start. Certificate may still be pending."
            echo "💡 Check: docker exec caddy ls -la /data/caddy/certificates/"
            echo "💡 Restart container later: docker restart caddy"
        fi
    else
        echo "ℹ️  sing-box config found but no TLS configuration detected"
        echo "ℹ️  Skipping sing-box startup..."
    fi
else
    echo "ℹ️  No sing-box config found, running Caddy only (NaiveProxy mode)"
fi

echo ""
echo "========================================="
echo "✅ V2God Container v${VERSION} initialized"
echo "📊 Caddy PID: $CADDY_PID"
if [ -n "$SINGBOX_PID" ]; then
    echo "📊 sing-box PID: $SINGBOX_PID"
fi
echo "========================================="

# 保持容器运行
wait $CADDY_PID
