#!/bin/bash
# =========================================
# GTAGod WARP 安装脚本
# 用途: 安装 Cloudflare WARP 并修改 sing-box 配置
#       让所有代理出站流量走 WARP，解决 VPS IP 被屏蔽问题
# =========================================

set -euo pipefail

WARP_PORT=40000
SINGBOX_CONFIG="./singbox/config.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

# =========================================
# 1. 安装 Cloudflare WARP
# =========================================
install_warp() {
    if command -v warp-cli &>/dev/null; then
        log_info "WARP 已安装，跳过安装步骤"
        return 0
    fi

    log_info "安装 Cloudflare WARP..."

    # 检测系统
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO=$ID
        VERSION=$VERSION_CODENAME
    else
        log_error "无法检测系统版本"
        exit 1
    fi

    case "$DISTRO" in
        debian|ubuntu)
            curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
            echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${VERSION} main" > /etc/apt/sources.list.d/cloudflare-client.list
            apt-get update && apt-get install -y cloudflare-warp
            ;;
        centos|rhel|fedora)
            rpm -ivh https://pkg.cloudflareclient.com/cloudflare-release-el8.rpm 2>/dev/null || true
            yum install -y cloudflare-warp
            ;;
        *)
            log_error "不支持的系统: $DISTRO"
            exit 1
            ;;
    esac

    log_success "WARP 安装完成"
}

# =========================================
# 2. 配置 WARP (proxy 模式，不接管全部流量)
# =========================================
configure_warp() {
    log_info "配置 WARP proxy 模式..."

    # 检查是否已注册
    if ! warp-cli registration show &>/dev/null; then
        log_info "注册 WARP..."
        warp-cli registration new
    else
        log_info "WARP 已注册"
    fi

    # 设置为 proxy 模式 (SOCKS5)
    warp-cli mode proxy
    warp-cli proxy port ${WARP_PORT}

    # 连接
    warp-cli connect

    # 等待连接
    sleep 3

    # 验证
    local status=$(warp-cli status 2>/dev/null | grep -i "status" | head -1)
    log_info "WARP 状态: $status"

    # 测试 WARP 连通性
    log_info "测试 WARP 连通性..."
    local warp_test=$(curl -x socks5://127.0.0.1:${WARP_PORT} -m 10 -s https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep "warp=" || echo "warp=off")
    
    if echo "$warp_test" | grep -q "warp=on\|warp=plus"; then
        log_success "WARP 代理工作正常: $warp_test"
    else
        log_warning "WARP 可能未完全生效: $warp_test"
        log_info "继续配置..."
    fi
}

# =========================================
# 3. 修改 sing-box 配置，添加 WARP 出站
# =========================================
patch_singbox_config() {
    if [ ! -f "$SINGBOX_CONFIG" ]; then
        log_error "sing-box 配置不存在: $SINGBOX_CONFIG"
        log_error "请先运行 ./run.sh 生成配置，再运行此脚本"
        exit 1
    fi

    log_info "修改 sing-box 配置..."

    # 备份原配置
    cp "$SINGBOX_CONFIG" "${SINGBOX_CONFIG}.bak.$(date +%s)"

    # 使用 python3 修改 JSON 配置
    python3 << 'PYEOF'
import json
import sys

config_path = "./singbox/config.json"

with open(config_path, "r") as f:
    config = json.load(f)

# 添加 WARP SOCKS5 出站 (如果不存在)
warp_outbound = {
    "type": "socks",
    "tag": "warp",
    "server": "127.0.0.1",
    "server_port": 40000,
    "tcp_fast_open": True
}

# 检查是否已添加
outbound_tags = [o.get("tag") for o in config.get("outbounds", [])]
if "warp" not in outbound_tags:
    # 插入到 direct 之前
    config.setdefault("outbounds", [])
    config["outbounds"].insert(0, warp_outbound)
    print("[INFO] 添加 WARP 出站")
else:
    # 如果已存在，强制更新 tcp_fast_open 属性
    for o in config.get("outbounds", []):
        if o.get("tag") == "warp":
            o["tcp_fast_open"] = True
            break
    print("[INFO] WARP 出站已存在，已更新 tcp_fast_open 属性")

# 添加路由配置: 默认走 WARP
if "route" not in config:
    config["route"] = {}

config["route"]["final"] = "warp"

# 可选: 添加规则让内网/本地流量走 direct
rules = config["route"].get("rules", [])

# 检查是否已有 private IP 规则
has_private_rule = any(
    r.get("ip_is_private") == True 
    for r in rules
)

if not has_private_rule:
    # 内网 IP 直连
    rules.insert(0, {
        "ip_is_private": True,
        "outbound": "direct"
    })
    print("[INFO] 添加内网直连规则")

# 确保 DNS 流量走 direct (因为我们配置了 DoH)
has_dns_rule = any(
    r.get("protocol") == "dns" or r.get("port") == 53
    for r in rules
)

if not has_dns_rule:
    rules.insert(0, {
        "protocol": "dns",
        "outbound": "direct"
    })
    rules.insert(0, {
        "port": 53,
        "outbound": "direct"
    })
    print("[INFO] 添加 DNS 直连规则")

config["route"]["rules"] = rules

with open(config_path, "w") as f:
    json.dump(config, f, indent=2, ensure_ascii=False)

print("[SUCCESS] sing-box 配置更新完成")
print(f"[INFO] 默认出站: warp (127.0.0.1:40000)")
print(f"[INFO] 内网流量: direct")
PYEOF

    log_success "sing-box 配置已更新"
}

# =========================================
# 4. 重启容器
# =========================================
restart_container() {
    log_info "重启容器以应用新配置..."
    
    if docker ps -a | grep -q caddy; then
        docker restart caddy
        sleep 5
        
        if docker ps | grep -q caddy; then
            log_success "容器重启成功"
            docker logs caddy --tail 15
        else
            log_error "容器启动失败，查看日志："
            docker logs caddy --tail 30
            exit 1
        fi
    else
        log_warning "容器不存在，请先运行 ./run.sh"
    fi
}

# =========================================
# 5. 最终验证
# =========================================
verify() {
    echo ""
    log_info "========== 最终验证 =========="
    
    # 测试 WARP
    local warp_ip=$(curl -x socks5://127.0.0.1:${WARP_PORT} -4 -m 10 -s https://ifconfig.me 2>/dev/null)
    if [ -n "$warp_ip" ]; then
        log_success "WARP 出口 IP: $warp_ip"
    else
        log_warning "无法获取 WARP 出口 IP"
    fi
    
    # 测试 Gemini
    local gemini_code=$(curl -x socks5://127.0.0.1:${WARP_PORT} -4 -m 10 -s -o /dev/null -w "%{http_code}" https://gemini.google.com 2>/dev/null)
    if [ "$gemini_code" = "200" ] || [ "$gemini_code" = "301" ] || [ "$gemini_code" = "302" ]; then
        log_success "Gemini 通过 WARP 可访问 (HTTP $gemini_code)"
    else
        log_warning "Gemini 通过 WARP 返回: HTTP $gemini_code"
    fi
    
    echo ""
    log_success "==========================================="
    log_success "  WARP 配置完成!"
    log_success "  所有代理流量将通过 Cloudflare WARP 出站"
    log_success "  WARP SOCKS5: 127.0.0.1:${WARP_PORT}"
    log_success "==========================================="
    echo ""
    log_warning "注意: 重新运行 ./run.sh 会覆盖 sing-box 配置"
    log_warning "需要重新运行此脚本: ./setup-warp.sh patch"
}

# =========================================
# 主逻辑
# =========================================
case "${1:-all}" in
    install)
        install_warp
        ;;
    configure)
        configure_warp
        ;;
    patch)
        patch_singbox_config
        restart_container
        ;;
    verify)
        verify
        ;;
    all)
        install_warp
        configure_warp
        patch_singbox_config
        restart_container
        verify
        ;;
    *)
        echo "用法: $0 {all|install|configure|patch|verify}"
        echo ""
        echo "  all       - 完整安装 (默认)"
        echo "  install   - 仅安装 WARP"
        echo "  configure - 仅配置 WARP"
        echo "  patch     - 仅修改 sing-box 配置并重启容器"
        echo "  verify    - 仅验证"
        exit 1
        ;;
esac
