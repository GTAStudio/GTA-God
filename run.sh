#!/bin/bash
set -e

# =========================================
# V2God 统一部署脚本
# 版本: 2.1.0
# 更新: 2025-12-05
# =========================================
# 
# 使用方式:
#   ./run.sh              # 自动检测配置文件
#   ./run.sh [mode]       # 指定部署模式 (naive/anytls/anyreality/l4)
#   ./run.sh -c file.conf # 使用指定配置文件
#   ./run.sh -i           # 强制交互模式
#
# 配置文件优先级:
#   1. -c 指定的配置文件
#   2. ./v2god.conf
#   3. 进入交互模式
#
# =========================================
VERSION="2.1.0"

# =========================================
# 日志函数
# =========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# =========================================
# 用法说明
# =========================================
show_usage() {
    echo "V2God 部署脚本 v${VERSION}"
    echo ""
    echo "用法:"
    echo "  ./run.sh                    # 自动检测配置文件，无则交互"
    echo "  ./run.sh [mode]             # 指定部署模式"
    echo "  ./run.sh -c config.conf     # 使用指定配置文件"
    echo "  ./run.sh -i                 # 强制交互模式"
    echo "  ./run.sh --version          # 显示版本号"
    echo "  ./run.sh --help             # 显示帮助"
    echo ""
    echo "部署模式:"
    echo "  naive      - 仅 NaiveProxy (最简单)"
    echo "  anytls     - NaiveProxy + AnyTLS"
    echo "  anyreality - NaiveProxy + AnyReality"
    echo "  l4         - 全部启用，443 端口共享"
    echo ""
    echo "配置文件:"
    echo "  默认检测 ./v2god.conf"
    echo "  模板文件 ./v2god.conf.example"
}

# =========================================
# 解析命令行参数
# =========================================
CONFIG_FILE=""
FORCE_INTERACTIVE=false
DEPLOY_MODE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version|-v)
            echo "V2God Deploy Script v${VERSION}"
            exit 0
            ;;
        --help|-h)
            show_usage
            exit 0
            ;;
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        -i|--interactive)
            FORCE_INTERACTIVE=true
            shift
            ;;
        naive|anytls|anyreality|l4)
            DEPLOY_MODE="$1"
            shift
            ;;
        *)
            log_error "未知参数: $1"
            show_usage
            exit 1
            ;;
    esac
done

# =========================================
# 多 ACME CA 配置
# =========================================
# 注意: Buypass 已于 2024 年停止接受新账户，已从列表移除
declare -a ACME_CA_LIST=(
    "letsencrypt|Let's Encrypt|acme_ca https://acme-v02.api.letsencrypt.org/directory|acme-v02.api.letsencrypt.org-directory"
    "zerossl|ZeroSSL|acme_ca https://acme.zerossl.com/v2/DV90|acme.zerossl.com-v2-DV90"
)

# 随机选择 CA
select_random_ca() {
    local random_index=$((RANDOM % ${#ACME_CA_LIST[@]}))
    SELECTED_CA_INFO="${ACME_CA_LIST[$random_index]}"
    SELECTED_CA_ID=$(echo "$SELECTED_CA_INFO" | cut -d'|' -f1)
    SELECTED_CA_NAME=$(echo "$SELECTED_CA_INFO" | cut -d'|' -f2)
    SELECTED_CA_CONFIG=$(echo "$SELECTED_CA_INFO" | cut -d'|' -f3)
    SELECTED_CA_DIR=$(echo "$SELECTED_CA_INFO" | cut -d'|' -f4)
}

# 通过 ID 选择 CA
select_ca_by_id() {
    local ca_id="$1"
    for ca_info in "${ACME_CA_LIST[@]}"; do
        local id=$(echo "$ca_info" | cut -d'|' -f1)
        if [ "$id" = "$ca_id" ]; then
            SELECTED_CA_INFO="$ca_info"
            SELECTED_CA_ID=$(echo "$ca_info" | cut -d'|' -f1)
            SELECTED_CA_NAME=$(echo "$ca_info" | cut -d'|' -f2)
            SELECTED_CA_CONFIG=$(echo "$ca_info" | cut -d'|' -f3)
            SELECTED_CA_DIR=$(echo "$ca_info" | cut -d'|' -f4)
            return 0
        fi
    done
    return 1
}

# =========================================
# 加载配置文件
# =========================================
load_config_file() {
    local config_path="$1"
    
    if [ ! -f "$config_path" ]; then
        return 1
    fi
    
    log_info "加载配置文件: $config_path"
    
    # 保存命令行指定的 DEPLOY_MODE (优先级最高)
    local cli_mode="${DEPLOY_MODE:-}"
    
    source "$config_path"
    
    # 转换变量名 (大写 -> 小写，保持向后兼容)
    domain="${DOMAIN:-}"
    cloudflareApiToken="${CLOUDFLARE_API_TOKEN:-}"
    naive_user="${NAIVE_USER:-}"
    naive_passwd="${NAIVE_PASSWD:-}"
    
    # AnyTLS 配置 (默认使用 NaiveProxy 密码)
    anytls_port="${ANYTLS_PORT:-8445}"
    anytls_user="${ANYTLS_USER:-$naive_passwd}"
    anytls_password="${ANYTLS_PASSWORD:-$naive_passwd}"
    anytls_sni="${ANYTLS_SNI:-api.${domain}}"
    
    # AnyReality 配置 (默认使用 NaiveProxy 密码)
    anyreality_port="${ANYREALITY_PORT:-8444}"
    anyreality_user="${ANYREALITY_USER:-$naive_passwd}"
    anyreality_password="${ANYREALITY_PASSWORD:-$naive_passwd}"
    anyreality_sni="${ANYREALITY_SNI:-www.amazon.com}"
    anyreality_target="${ANYREALITY_TARGET:-www.amazon.com}"
    anyreality_private_key="${ANYREALITY_PRIVATE_KEY:-}"
    anyreality_public_key="${ANYREALITY_PUBLIC_KEY:-}"
    anyreality_short_id="${ANYREALITY_SHORT_ID:-a1b2c3d4e5f67890}"
    
    # 部署模式优先级: 命令行 > 配置文件 > 默认 naive
    if [ -n "$cli_mode" ]; then
        # 命令行指定了模式，使用命令行的
        DEPLOY_MODE="$cli_mode"
    elif [ -z "$DEPLOY_MODE" ]; then
        # 配置文件也没指定，使用默认值
        DEPLOY_MODE="naive"
    fi
    # 否则使用配置文件中的 DEPLOY_MODE (source 已设置)
    
    # ACME CA 配置
    if [ -n "${FORCE_ACME_CA:-}" ]; then
        if select_ca_by_id "$FORCE_ACME_CA"; then
            log_info "使用指定 CA: ${SELECTED_CA_NAME}"
        else
            log_warning "未知 CA: $FORCE_ACME_CA，使用默认 ZeroSSL"
            select_ca_by_id "zerossl"
        fi
    else
        # 默认使用 ZeroSSL
        select_ca_by_id "zerossl"
        log_info "使用默认 CA: ${SELECTED_CA_NAME}"
    fi
    
    return 0
}

# =========================================
# 验证必要配置
# =========================================
validate_config() {
    local missing=()
    
    [ -z "$domain" ] && missing+=("DOMAIN")
    [ -z "$cloudflareApiToken" ] && missing+=("CLOUDFLARE_API_TOKEN")
    [ -z "$naive_user" ] && missing+=("NAIVE_USER")
    [ -z "$naive_passwd" ] && missing+=("NAIVE_PASSWD")
    
    # AnyReality 需要密钥
    if [ "$DEPLOY_MODE" = "anyreality" ] || [ "$DEPLOY_MODE" = "l4" ]; then
        [ -z "$anyreality_private_key" ] && missing+=("ANYREALITY_PRIVATE_KEY")
        [ -z "$anyreality_public_key" ] && missing+=("ANYREALITY_PUBLIC_KEY")
    fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        log_error "缺少必要配置项: ${missing[*]}"
        return 1
    fi
    
    return 0
}

# =========================================
# 交互式配置
# =========================================
interactive_config() {
    echo "========================================="
    echo "  V2God 交互式部署向导 v${VERSION}"
    echo "========================================="
    echo ""
    
    # 部署模式选择
    echo "请选择部署模式:"
    echo ""
    echo "  ${CYAN}1)${NC} NaiveProxy Only - 最简单"
    echo "  ${CYAN}2)${NC} NaiveProxy + AnyTLS - 需要证书"
    echo "  ${CYAN}3)${NC} NaiveProxy + AnyReality - 无需证书"
    echo "  ${CYAN}4)${NC} 全部启用 (L4 分流) - 443 共享"
    echo ""
    read -p "请输入选项 [1-4] (默认 1): " mode_choice
    mode_choice=${mode_choice:-1}
    
    case "$mode_choice" in
        1) DEPLOY_MODE="naive" ;;
        2) DEPLOY_MODE="anytls" ;;
        3) DEPLOY_MODE="anyreality" ;;
        4) DEPLOY_MODE="l4" ;;
        *) DEPLOY_MODE="naive" ;;
    esac
    
    log_info "部署模式: ${DEPLOY_MODE}"
    echo ""
    
    # 基础配置
    read -p "请输入域名 (例如 example.com): " domain
    while [ -z "$domain" ]; do
        log_error "域名不能为空!"
        read -p "请输入域名: " domain
    done
    
    read -p "请输入 Cloudflare API Token: " cloudflareApiToken
    while [ -z "$cloudflareApiToken" ]; do
        log_error "Token 不能为空!"
        read -p "请输入 Cloudflare API Token: " cloudflareApiToken
    done
    
    read -p "请输入 NaiveProxy 用户名: " naive_user
    while [ -z "$naive_user" ]; do
        log_error "用户名不能为空!"
        read -p "请输入用户名: " naive_user
    done
    
    printf "请输入 NaiveProxy 密码: "
    stty -echo
    read naive_passwd
    stty echo
    echo ""
    while [ -z "$naive_passwd" ]; do
        log_error "密码不能为空!"
        printf "请输入密码: "
        stty -echo
        read naive_passwd
        stty echo
        echo ""
    done
    
    # AnyTLS 配置
    if [ "$DEPLOY_MODE" = "anytls" ] || [ "$DEPLOY_MODE" = "l4" ]; then
        echo ""
        log_info "=== AnyTLS 配置 ==="
        read -p "AnyTLS 端口 (默认 8445): " anytls_port
        anytls_port=${anytls_port:-8445}
        read -p "AnyTLS SNI (默认 api.${domain}): " anytls_sni
        anytls_sni=${anytls_sni:-api.${domain}}
        anytls_user="$naive_passwd"
        anytls_password="$naive_passwd"
    fi
    
    # AnyReality 配置
    if [ "$DEPLOY_MODE" = "anyreality" ] || [ "$DEPLOY_MODE" = "l4" ]; then
        echo ""
        log_info "=== AnyReality 配置 ==="
        read -p "AnyReality 端口 (默认 8444): " anyreality_port
        anyreality_port=${anyreality_port:-8444}
        read -p "AnyReality SNI (默认 www.amazon.com): " anyreality_sni
        anyreality_sni=${anyreality_sni:-www.amazon.com}
        read -p "Reality 伪装目标 (默认 www.amazon.com): " anyreality_target
        anyreality_target=${anyreality_target:-www.amazon.com}
        
        anyreality_user="$naive_passwd"
        anyreality_password="$naive_passwd"
        
        # 生成 Reality 密钥对
        echo ""
        log_info "生成 Reality 密钥对..."
        if docker run --rm ghcr.io/sagernet/sing-box generate reality-keypair > /tmp/reality_keys.txt 2>/dev/null; then
            anyreality_private_key=$(grep "PrivateKey" /tmp/reality_keys.txt | cut -d: -f2 | tr -d ' ')
            anyreality_public_key=$(grep "PublicKey" /tmp/reality_keys.txt | cut -d: -f2 | tr -d ' ')
            rm -f /tmp/reality_keys.txt
            log_success "密钥对生成成功"
        else
            log_warning "无法自动生成密钥对，使用预设密钥"
            anyreality_private_key="sGkPoqJlHt9tMfMV1fzKFLUTLtFfnCdL1kaVzMBnQWU"
            anyreality_public_key="bMpnKHPh92Yh1oD88zlbP7V-rDqLf3DLXE8msXyGxSo"
        fi
        
        anyreality_short_id=$(openssl rand -hex 8 2>/dev/null || echo "a1b2c3d4e5f67890")
        
        log_info "Reality 公钥: ${anyreality_public_key}"
        log_info "Reality ShortID: ${anyreality_short_id}"
    fi
    
    # 随机选择 CA
    select_random_ca
}

# =========================================
# 主流程开始
# =========================================
echo "========================================="
echo "  V2God 部署脚本 v${VERSION}"
echo "========================================="

# 确定配置来源
CONFIG_LOADED=false

if [ "$FORCE_INTERACTIVE" = true ]; then
    log_info "强制交互模式"
    interactive_config
    CONFIG_LOADED=true
elif [ -n "$CONFIG_FILE" ]; then
    if load_config_file "$CONFIG_FILE"; then
        CONFIG_LOADED=true
    else
        log_error "配置文件不存在: $CONFIG_FILE"
        exit 1
    fi
elif [ -f "./v2god.conf" ]; then
    if load_config_file "./v2god.conf"; then
        CONFIG_LOADED=true
    fi
fi

if [ "$CONFIG_LOADED" = false ]; then
    log_info "未找到配置文件，进入交互模式"
    echo ""
    interactive_config
fi

# 验证配置
if ! validate_config; then
    log_error "配置验证失败，请检查配置文件"
    exit 1
fi

# 设置部署模式标志
enable_anytls="false"
enable_anyreality="false"
enable_l4="false"

case "$DEPLOY_MODE" in
    naive)
        log_info "部署模式: NaiveProxy Only"
        ;;
    anytls)
        enable_anytls="true"
        log_info "部署模式: NaiveProxy + AnyTLS"
        ;;
    anyreality)
        enable_anyreality="true"
        log_info "部署模式: NaiveProxy + AnyReality"
        ;;
    l4)
        enable_anytls="true"
        enable_anyreality="true"
        enable_l4="true"
        log_info "部署模式: L4 多协议 (443 共享)"
        ;;
    *)
        DEPLOY_MODE="naive"
        log_info "部署模式: NaiveProxy Only (默认)"
        ;;
esac

# 显示配置摘要
echo ""
echo "========================================="
echo "配置摘要"
echo "========================================="
echo "部署模式: ${DEPLOY_MODE}"
echo "域名: ${domain}"
echo "NaiveProxy 用户: ${naive_user}"
echo "ACME CA: ${SELECTED_CA_NAME}"
if [ "$enable_anytls" = "true" ]; then
    if [ "$enable_l4" = "true" ]; then
        echo "AnyTLS: 端口 443 (L4分流), SNI ${anytls_sni}"
    else
        echo "AnyTLS: 端口 ${anytls_port}, SNI ${anytls_sni}"
    fi
fi
if [ "$enable_anyreality" = "true" ]; then
    if [ "$enable_l4" = "true" ]; then
        echo "AnyReality: 端口 443 (L4分流), SNI ${anyreality_sni}"
    else
        echo "AnyReality: 端口 ${anyreality_port}, SNI ${anyreality_sni}"
    fi
    echo "Reality 公钥: ${anyreality_public_key}"
fi
echo "========================================="
echo ""

# 确认部署
read -p "确认开始部署? (y/n): " confirm
if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    log_warning "部署已取消"
    exit 0
fi

echo ""
echo "========================================="
log_info "开始部署 V2God 服务"
echo "========================================="

# =========================================
# 系统配置
# =========================================
log_info "设置时区..."
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone

log_info "安装系统依赖..."
apt update && apt upgrade -y
apt install -y curl ca-certificates gnupg ntpdate

log_info "同步系统时间..."
ntpdate -u pool.ntp.org || ntpdate -u time.google.com || ntpdate -u time.cloudflare.com || log_warning "时间同步失败，继续部署..."

# =========================================
# Docker 安装和配置
# =========================================
if ! command -v docker &> /dev/null; then
    log_info "安装 Docker..."
    curl -fsSL https://get.docker.com | sh
fi

log_info "检查 Docker 服务..."
systemctl daemon-reload 2>/dev/null || true
systemctl enable docker 2>/dev/null || true
systemctl start docker 2>/dev/null || true
sleep 2

if docker ps >/dev/null 2>&1; then
    log_success "Docker 服务正常运行"
else
    log_error "Docker 服务启动失败"
    exit 1
fi

# =========================================
# 清理旧容器
# =========================================
log_info "清理旧容器..."
docker stop caddy 2>/dev/null || true
docker rm caddy 2>/dev/null || true
docker stop watchtower 2>/dev/null || true
docker rm watchtower 2>/dev/null || true
docker rmi lingex/caddy-cf-naive:latest 2>/dev/null || true
docker rmi lingex/caddy-cf-naive 2>/dev/null || true
log_success "容器清理完成"

# =========================================
# 创建目录结构
# =========================================
log_info "创建目录..."
mkdir -p "$PWD/caddy/data" "$PWD/caddy/config" "$PWD/caddy/logs"
mkdir -p "$PWD/singbox/logs"
chmod -R 777 "$PWD/caddy/data" "$PWD/caddy/config" "$PWD/caddy/logs"
chmod -R 777 "$PWD/singbox"

# =========================================
# 生成 Caddyfile
# =========================================
log_info "生成 Caddyfile..."

if [ -f "./caddy/Caddyfile" ]; then
    log_warning "发现已存在的 Caddyfile..."
    mv ./caddy/Caddyfile ./caddy/Caddyfile.bak.$(date +%s)
fi

# 选择模板
if [ "$enable_l4" = "true" ] && [ -f "Caddyfile.l4.example" ]; then
    log_info "使用 Layer4 SNI 分流模板..."
    cp Caddyfile.l4.example ./caddy/Caddyfile
elif [ -f "Caddyfile.reality.example" ]; then
    log_info "使用标准模板..."
    cp Caddyfile.reality.example ./caddy/Caddyfile
else
    log_error "未找到 Caddyfile 模板"
    exit 1
fi

# 替换占位符
sed -i "s/{{DOMAIN}}/${domain}/g" ./caddy/Caddyfile
sed -i "s/{{CLOUDFLARE_API_TOKEN}}/${cloudflareApiToken}/g" ./caddy/Caddyfile
sed -i "s/{{NAIVE_USER}}/${naive_user}/g" ./caddy/Caddyfile
sed -i "s/{{NAIVE_PASSWD}}/${naive_passwd}/g" ./caddy/Caddyfile
sed -i "s|{{ACME_CA_CONFIG}}|${SELECTED_CA_CONFIG}|g" ./caddy/Caddyfile

if [ "$enable_anytls" = "true" ]; then
    sed -i "s/{{ANYTLS_PORT}}/${anytls_port}/g" ./caddy/Caddyfile
    sed -i "s/{{ANYTLS_SNI}}/${anytls_sni}/g" ./caddy/Caddyfile
fi
if [ "$enable_anyreality" = "true" ]; then
    sed -i "s/{{ANYREALITY_PORT}}/${anyreality_port}/g" ./caddy/Caddyfile
    sed -i "s/{{ANYREALITY_SNI}}/${anyreality_sni}/g" ./caddy/Caddyfile
fi

log_success "Caddyfile 生成完成"

# =========================================
# 生成 sing-box 配置
# =========================================
if [ "$enable_anytls" = "true" ]; then
    log_info "生成 AnyTLS 配置..."
    if [ -f "singbox-config.json.example" ]; then
        mkdir -p ./singbox
        cp singbox-config.json.example ./singbox/config-anytls.json
        sed -i "s|{{ANYTLS_USER}}|${anytls_user}|g" ./singbox/config-anytls.json
        sed -i "s|{{ANYTLS_PASSWORD}}|${anytls_password}|g" ./singbox/config-anytls.json
        sed -i "s|{{ANYTLS_SNI}}|${anytls_sni}|g" ./singbox/config-anytls.json
        sed -i "s|{{ANYTLS_PORT}}|${anytls_port}|g" ./singbox/config-anytls.json
        sed -i "s|{{DOMAIN}}|${domain}|g" ./singbox/config-anytls.json
        log_success "AnyTLS 配置生成完成"
    else
        log_warning "未找到 singbox-config.json.example"
        enable_anytls="false"
    fi
fi

if [ "$enable_anyreality" = "true" ]; then
    log_info "生成 AnyReality 配置..."
    if [ -f "singbox-config.anyreality.example" ]; then
        mkdir -p ./singbox
        cp singbox-config.anyreality.example ./singbox/config-anyreality.json
        sed -i "s|{{ANYREALITY_USER}}|${anyreality_user}|g" ./singbox/config-anyreality.json
        sed -i "s|{{ANYREALITY_PASSWORD}}|${anyreality_password}|g" ./singbox/config-anyreality.json
        sed -i "s|{{ANYREALITY_PORT}}|${anyreality_port}|g" ./singbox/config-anyreality.json
        sed -i "s|{{ANYREALITY_SNI}}|${anyreality_sni}|g" ./singbox/config-anyreality.json
        sed -i "s|{{ANYREALITY_TARGET}}|${anyreality_target}|g" ./singbox/config-anyreality.json
        sed -i "s|{{ANYREALITY_PRIVATE_KEY}}|${anyreality_private_key}|g" ./singbox/config-anyreality.json
        sed -i "s|{{ANYREALITY_SHORT_ID}}|${anyreality_short_id}|g" ./singbox/config-anyreality.json
        log_success "AnyReality 配置生成完成"
    else
        log_warning "未找到 singbox-config.anyreality.example"
        enable_anyreality="false"
    fi
fi

# 合并或复制最终配置
if [ "$enable_anytls" = "true" ] && [ "$enable_anyreality" = "true" ]; then
    log_info "合并 AnyTLS + AnyReality 配置..."
    cat > ./singbox/config.json << EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "anytls",
      "listen": "::",
      "listen_port": ${anytls_port},
      "users": [
        {
          "name": "${anytls_user}",
          "password": "${anytls_password}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${anytls_sni}",
        "min_version": "1.3",
        "certificate_path": "/data/caddy/certificates/${SELECTED_CA_DIR}/wildcard_.${domain}/wildcard_.${domain}.crt",
        "key_path": "/data/caddy/certificates/${SELECTED_CA_DIR}/wildcard_.${domain}/wildcard_.${domain}.key"
      }
    },
    {
      "type": "anytls",
      "listen": "::",
      "listen_port": ${anyreality_port},
      "users": [
        {
          "name": "${anyreality_user}",
          "password": "${anyreality_password}"
        }
      ],
      "padding_scheme": [
        "stop=8",
        "0=30-30",
        "1=100-400",
        "2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000",
        "3=9-9,500-1000",
        "4=500-1000",
        "5=500-1000",
        "6=500-1000",
        "7=500-1000"
      ],
      "tls": {
        "enabled": true,
        "server_name": "${anyreality_sni}",
        "min_version": "1.3",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${anyreality_target}",
            "server_port": 443
          },
          "private_key": "${anyreality_private_key}",
          "short_id": "${anyreality_short_id}"
        }
      }
    }
  ]
}
EOF
    log_success "合并配置生成完成"
elif [ "$enable_anytls" = "true" ]; then
    cp ./singbox/config-anytls.json ./singbox/config.json
elif [ "$enable_anyreality" = "true" ]; then
    cp ./singbox/config-anyreality.json ./singbox/config.json
fi

# =========================================
# 拉取镜像并启动容器
# =========================================
log_info "拉取最新 Docker 镜像..."
docker pull aizhihuxiao/v2god:latest

log_info "启动 Caddy 容器..."

NEED_SINGBOX="false"
if [ "$enable_anytls" = "true" ] || [ "$enable_anyreality" = "true" ]; then
    NEED_SINGBOX="true"
fi

if [ "$NEED_SINGBOX" = "true" ] && [ -f "$PWD/singbox/config.json" ]; then
    docker run -d --name caddy \
        --restart=always \
        --net=host \
        --log-opt max-size=10m \
        --log-opt max-file=3 \
        -e CLOUDFLARE_API_TOKEN="${cloudflareApiToken}" \
        -v $PWD/caddy/Caddyfile:/etc/caddy/Caddyfile:ro \
        -v $PWD/caddy/data:/data/caddy \
        -v $PWD/caddy/config:/config \
        -v $PWD/caddy/logs:/var/log/caddy \
        -v $PWD/singbox/config.json:/etc/sing-box/config.json:ro \
        -v $PWD/singbox/logs:/var/log/sing-box \
        aizhihuxiao/v2god:latest
    log_success "Caddy + sing-box 容器启动完成"
else
    docker run -d --name caddy \
        --restart=always \
        --net=host \
        --log-opt max-size=10m \
        --log-opt max-file=3 \
        -e CLOUDFLARE_API_TOKEN="${cloudflareApiToken}" \
        -v $PWD/caddy/Caddyfile:/etc/caddy/Caddyfile:ro \
        -v $PWD/caddy/data:/data/caddy \
        -v $PWD/caddy/config:/config \
        -v $PWD/caddy/logs:/var/log/caddy \
        aizhihuxiao/v2god:latest
    log_success "Caddy 容器启动完成 (仅 NaiveProxy)"
fi

# =========================================
# 等待证书申请
# =========================================
log_info "等待 Caddy 启动..."
sleep 5

if docker ps | grep -q caddy; then
    log_success "容器启动成功"
    docker logs caddy --tail 20
    
    # 检查 sing-box
    if [ "$NEED_SINGBOX" = "true" ]; then
        echo ""
        log_info "检查 sing-box 状态..."
        sleep 3
        if docker exec caddy pgrep -f sing-box >/dev/null 2>&1; then
            log_success "sing-box 启动成功"
        else
            log_warning "sing-box 可能未启动，等待证书或 Reality 模式"
        fi
    fi
    
    # 等待证书
    echo ""
    log_info "等待证书申请，最多 3 分钟..."
    
    CERT_WAIT=0
    MAX_CERT_WAIT=180
    CERT_FOUND=false
    
    while [ $CERT_WAIT -lt $MAX_CERT_WAIT ]; do
        if docker exec caddy find /data/caddy/certificates -name "*.crt" -type f 2>/dev/null | grep -q ".crt"; then
            log_success "证书申请成功!"
            CERT_FOUND=true
            break
        fi
        
        if [ $((CERT_WAIT % 15)) -eq 0 ]; then
            log_info "等待中... (${CERT_WAIT}s/${MAX_CERT_WAIT}s)"
        fi
        
        sleep 3
        CERT_WAIT=$((CERT_WAIT + 3))
    done
    
    if [ "$CERT_FOUND" = "false" ]; then
        log_warning "证书申请超时"
        log_info "查看日志: docker logs caddy"
    fi
else
    log_error "容器启动失败"
    docker logs caddy
    exit 1
fi

# =========================================
# Watchtower 自动更新
# =========================================
log_info "启动 Watchtower..."
docker pull containrrr/watchtower:latest
docker run -d --name watchtower \
    --restart=unless-stopped \
    -e DOCKER_API_VERSION=1.44 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    containrrr/watchtower:latest --cleanup --interval 86400

# =========================================
# 网络优化
# =========================================
log_info "配置网络性能优化..."
modprobe tcp_bbr 2>/dev/null || log_warning "BBR 模块加载失败"

if ! grep -q "# V2God BBR" /etc/sysctl.conf; then
cat >> /etc/sysctl.conf << 'SYSCTL'

# V2God BBR 加速和性能优化
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=8192
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
SYSCTL
fi

sysctl -p > /dev/null
log_success "网络优化已应用"

# =========================================
# 禁用防火墙
# =========================================
log_info "禁用系统防火墙..."
if command -v ufw &> /dev/null; then
    ufw --force disable 2>/dev/null || true
    systemctl disable ufw 2>/dev/null || true
fi
if command -v firewalld &> /dev/null; then
    systemctl stop firewalld 2>/dev/null || true
    systemctl disable firewalld 2>/dev/null || true
fi
iptables -F 2>/dev/null || true
iptables -P INPUT ACCEPT 2>/dev/null || true
iptables -P FORWARD ACCEPT 2>/dev/null || true
iptables -P OUTPUT ACCEPT 2>/dev/null || true

# =========================================
# 保存部署信息
# =========================================
cat > ./caddy/deploy-info.txt << EOF
# V2God 部署信息
# 生成时间: $(date)
# 脚本版本: v${VERSION}
# 部署模式: ${DEPLOY_MODE}

域名: ${domain}
ACME CA: ${SELECTED_CA_NAME}
NaiveProxy 用户: ${naive_user}
EOF

if [ "$enable_anytls" = "true" ]; then
    cat >> ./caddy/deploy-info.txt << EOF

AnyTLS:
  端口: ${anytls_port}
  SNI: ${anytls_sni}
EOF
fi

if [ "$enable_anyreality" = "true" ]; then
    cat >> ./caddy/deploy-info.txt << EOF

AnyReality:
  端口: ${anyreality_port}
  SNI: ${anyreality_sni}
  Reality 公钥: ${anyreality_public_key}
  Reality ShortID: ${anyreality_short_id}
EOF
fi

chmod 600 ./caddy/deploy-info.txt

# =========================================
# 完成输出
# =========================================
echo ""
echo "========================================="
log_success "部署完成!"
echo "========================================="
echo "脚本版本: v${VERSION}"
echo "部署模式: ${DEPLOY_MODE}"
echo ""
echo "NaiveProxy:"
echo "   协议: naive+https"
echo "   域名: ${domain}"
echo "   端口: 8443"
echo "   用户: ${naive_user}"
echo ""
if [ "$enable_anytls" = "true" ]; then
    echo "AnyTLS:"
    if [ "$enable_l4" = "true" ]; then
        echo "   端口: 443 (L4分流)"
    else
        echo "   端口: ${anytls_port}"
    fi
    echo "   SNI: ${anytls_sni}"
    echo ""
fi
if [ "$enable_anyreality" = "true" ]; then
    echo "AnyReality:"
    if [ "$enable_l4" = "true" ]; then
        echo "   端口: 443 (L4分流)"
    else
        echo "   端口: ${anyreality_port}"
    fi
    echo "   SNI: ${anyreality_sni}"
    echo "   Reality 公钥: ${anyreality_public_key}"
    echo "   Reality ShortID: ${anyreality_short_id}"
    echo ""
fi
log_info "部署信息: ./caddy/deploy-info.txt"
echo ""
log_warning "请在云服务商控制台开放端口:"
echo "   - 22/tcp  (SSH)"
echo "   - 80/tcp  (HTTP)"
echo "   - 443/tcp (HTTPS/AnyTLS/AnyReality)"
echo "   - 8443/tcp (NaiveProxy)"
echo ""
log_info "常用命令:"
echo "   docker logs -f caddy    # 查看日志"
echo "   docker restart caddy    # 重启服务"
echo "   docker ps               # 查看状态"
echo "========================================="
