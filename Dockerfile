# =========================================
# GTAGod Dockerfile - sing-box 1.13+ 统一架构
# 版本: 4.1.0
# 更新: 2026-01-01
# =========================================
#
# 此版本使用 sing-box 1.13+ 原生 naive inbound
# 不再需要 Caddy forwardproxy 插件
# 所有代理协议由 sing-box 统一处理
#
# 架构:
#   - Caddy: L4 SNI 分流 + ACME 证书申请
#   - sing-box 1.13+: naive + anytls + anyreality
#
# 依赖版本 (2026-01-01 更新):
#   - Go: 1.25 (sing-box 1.13+ 需要 Go 1.24+)
#   - Alpine: 3.23 (包含 Go 1.25, GCC 15, apk-tools v3)
#   - xcaddy: v0.4.5
#   - Caddy: latest (2.10.2+)
#   - sing-box: 1.13.x (自动获取最新 1.13.x 版本)
#
# =========================================

# 构建阶段 - 使用 Alpine 基础镜像
# Go 1.25 是 2025 年 8 月发布的稳定版，需要 macOS 12+ / Windows 10+
# 新特性：容器感知 GOMAXPROCS、DWARF5 调试信息、实验性 GC
FROM golang:1.25-alpine AS builder

# 构建参数 - sing-box 1.13+ 支持 naive inbound
# Caddy 2.10.1+ 需要 Go 1.25+ 编译
ARG CADDY_VERSION=latest
ARG XCADDY_VERSION=v0.4.5
ARG SINGBOX_VERSION=1.13.0-rc.2

# 设置 GOTOOLCHAIN 允许自动下载更新的 Go 版本
ENV GOTOOLCHAIN=auto

# 安装构建依赖
RUN apk add --no-cache git ca-certificates curl

# 安装 xcaddy
RUN go install github.com/caddyserver/xcaddy/cmd/xcaddy@${XCADDY_VERSION}

# 构建 Caddy - 仅需要 cloudflare DNS 和 layer4 插件
# sing-box 1.13+ 处理所有代理协议，不再需要 forwardproxy
RUN xcaddy build ${CADDY_VERSION} \
    --with github.com/caddy-dns/cloudflare \
    --with github.com/mholt/caddy-l4 \
    --output /usr/bin/caddy

# 下载 sing-box 1.13+ (支持 naive inbound)
# 使用 TARGETARCH 支持 buildx 多架构构建
# Alpine 使用 musl libc，必须下载 musl 版本
ARG TARGETARCH
RUN set -ex && \
    TARGETARCH=${TARGETARCH:-amd64} && \
    echo "==> TARGETARCH=${TARGETARCH}" && \
    if [ "$TARGETARCH" = "amd64" ]; then ARCH="amd64"; \
    elif [ "$TARGETARCH" = "arm64" ]; then ARCH="arm64"; \
    else echo "Unsupported arch: $TARGETARCH"; exit 1; fi && \
    echo "==> Downloading sing-box v${SINGBOX_VERSION} for ${ARCH} (musl)..." && \
    wget -O /tmp/sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-${ARCH}-musl.tar.gz" && \
    tar -xzf /tmp/sing-box.tar.gz -C /tmp && \
    cp /tmp/sing-box-*/sing-box /usr/bin/sing-box && \
    chmod +x /usr/bin/sing-box && \
    /usr/bin/sing-box version && \
    rm -rf /tmp/sing-box*

# 运行阶段 - 使用 Alpine 3.23 (2025-12 发布)
# 新特性：apk-tools v3, curl HTTP/3 支持, GCC 15
FROM alpine:3.23

# 元数据
LABEL maintainer="gtagod" \
      description="GTAGod - sing-box 1.13+ (naive + anytls + anyreality) with Caddy L4" \
      version="4.1"

# 一次性安装所有依赖并创建目录，减少镜像层
RUN apk add --no-cache \
        ca-certificates \
        libcap \
        tzdata \
        wget \
        jq && \
    # 设置时区
    cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
    echo "Asia/Shanghai" > /etc/timezone && \
    # 创建目录结构
    mkdir -p \
        /config/caddy \
        /data/caddy \
        /var/log/caddy \
        /etc/caddy \
        /etc/sing-box \
        /var/log/sing-box

# 复制编译好的 caddy 和 sing-box
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
COPY --from=builder /usr/bin/sing-box /usr/bin/sing-box

# 设置权限并验证版本
RUN chmod +x /usr/bin/caddy /usr/bin/sing-box && \
    caddy version && \
    caddy list-modules | grep -E "(layer4|cloudflare)" && \
    sing-box version

# 环境变量
ENV XDG_CONFIG_HOME=/config \
    XDG_DATA_HOME=/data \
    TZ=Asia/Shanghai

# 暴露端口
EXPOSE 80 443 2019 8443

# 数据卷
VOLUME ["/config", "/data", "/var/log/caddy", "/etc/sing-box", "/var/log/sing-box"]

# 工作目录
WORKDIR /config/caddy

# 复制启动脚本
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# 健康检查 - Caddy + sing-box + 证书就绪状态
HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD sh -c 'pgrep caddy >/dev/null 2>&1 || exit 1; CERT_PATH=$(jq -r "..|.certificate_path? // empty" /etc/sing-box/config.json | head -n1); if [ -n "$CERT_PATH" ]; then [ -f "$CERT_PATH" ] && [ -f "${CERT_PATH%.crt}.key" ] || exit 1; fi; pgrep sing-box >/dev/null 2>&1 || exit 1'

# 启动命令
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
