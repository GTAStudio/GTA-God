#!/bin/bash
set -e

# =========================================
# GTAGod WARP (Cloudflare 出口) 一键安装脚本
# 版本: 1.0.0
# 更新: 2026-02-22
# =========================================
#
# 此脚本用于在宿主机上安装并配置 Cloudflare WARP (WGCF)
# 并生成一个本地 SOCKS5 代理 (默认端口 40000)
# 供 sing-box 容器作为出站 (outbound) 使用，以解锁流媒体或隐藏真实 IP。
#
# =========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# 检查 root 权限
if [ "$(id -u)" != "0" ]; then
    log_error "此脚本需要 root 权限运行，请使用 sudo ./setup-warp.sh"
    exit 1
fi

# 检查系统架构
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    WGCF_ARCH="amd64"
elif [ "$ARCH" = "aarch64" ]; then
    WGCF_ARCH="arm64"
else
    log_error "不支持的架构: $ARCH"
    exit 1
fi

log_info "开始安装 Cloudflare WARP (WGCF)..."

# 1. 安装依赖
log_info "安装必要依赖 (curl, wireguard-tools)..."
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y curl wireguard-tools
elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release
    yum install -y curl wireguard-tools
else
    log_error "未知的包管理器，请手动安装 curl 和 wireguard-tools"
    exit 1
fi

# 2. 下载 WGCF
log_info "下载 WGCF 客户端..."
WGCF_URL="https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_linux_${WGCF_ARCH}"
curl -fsSL -o /usr/local/bin/wgcf "$WGCF_URL"
chmod +x /usr/local/bin/wgcf

# 3. 注册 WARP 账户并生成配置
mkdir -p /etc/wireguard
cd /etc/wireguard

log_info "注册 WARP 账户..."
yes | wgcf register

log_info "生成 WireGuard 配置文件..."
wgcf generate

if [ ! -f "wgcf-profile.conf" ]; then
    log_error "配置文件生成失败！"
    exit 1
fi

# 4. 修改配置以避免路由冲突 (仅作为出口，不接管全局流量)
log_info "修改 WireGuard 配置以避免全局路由冲突..."
sed -i 's/AllowedIPs = 0.0.0.0\/0/AllowedIPs = 162.159.192.1\/32, 2606:4700:d0::a29f:c001\/128/g' wgcf-profile.conf
sed -i 's/AllowedIPs = ::\/0/#AllowedIPs = ::\/0/g' wgcf-profile.conf
# 移除 DNS 设置，防止覆盖系统 DNS
sed -i '/DNS =/d' wgcf-profile.conf

mv wgcf-profile.conf wg0.conf

# 5. 启动 WireGuard 接口
log_info "启动 WARP (wg0) 接口..."
wg-quick down wg0 2>/dev/null || true
wg-quick up wg0
systemctl enable wg-quick@wg0

# 6. 安装并配置 Xray-core (仅用于将 WARP 转换为 SOCKS5)
log_info "安装 Xray-core 用于提供 SOCKS5 接口..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

cat > /usr/local/etc/xray/config.json << 'EOF'
{
  "inbounds": [
    {
      "port": 40000,
      "listen": "127.0.0.1",
      "protocol": "socks",
      "settings": {
        "auth": "noauth",
        "udp": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      },
      "sendThrough": "172.16.0.2"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "direct"
      }
    ]
  }
}
EOF

# 自动获取 WARP 的本地 IP 并替换到 Xray 配置中
WARP_IP=$(ip -4 addr show wg0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
if [ -n "$WARP_IP" ]; then
    sed -i "s/172.16.0.2/$WARP_IP/g" /usr/local/etc/xray/config.json
    log_info "检测到 WARP IP: $WARP_IP"
else
    log_warning "未能自动检测到 WARP IP，请手动检查 /usr/local/etc/xray/config.json 中的 sendThrough 字段"
fi

systemctl restart xray
systemctl enable xray

log_success "WARP 安装并配置完成！"
echo "========================================="
echo "本地 SOCKS5 代理已启动: 127.0.0.1:40000"
echo "所有通过此端口的流量都将从 Cloudflare WARP 出口。"
echo ""
echo "要在 GTAGod 中使用 WARP 出口，请在 sing-box 配置的 outbounds 中添加："
echo "{"
echo "  \"type\": \"socks\","
echo "  \"tag\": \"warp-out\","
echo "  \"server\": \"172.17.0.1\", // Docker 宿主机默认 IP"
echo "  \"server_port\": 40000"
echo "}"
echo "并将需要解锁的域名路由到 'warp-out' tag。"
echo "========================================="
