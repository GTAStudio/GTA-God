# syntax=docker/dockerfile:1
# =========================================
# GTAGod Dockerfile - GTACore (Rust) 统一架构
# 版本: 0.0.1
# 更新: 2026-06-04
# =========================================
#
# 此版本用 GTACore (Rust, sing-box 兼容) 完全替代 sing-box，
# 原生处理 naive + anytls + anyreality（anyreality 所需 uTLS sidecar 已内嵌）。
#
# 架构 (v0.0.1):
#   - gtagate (Rust): L4 SNI 分流 + ACME 证书申请 (替代 Caddy)
#   - gtacore (Rust): naive + anytls + anyreality (替代 sing-box)
#
# 依赖版本 (2026-06-04 更新):
#   - Rust: 1.96 (edition 2024，需要 rustc >= 1.85)
#   - gtagate: 本仓库 gateway/ (musl 静态, tokio + rustls + instant-acme)
#   - gtacore: 预构建 glibc 二进制 bin/gtacore (含内嵌 libutls.so)
#   - 运行镜像: debian 13-slim (glibc 2.41，满足 gtacore 需求 GLIBC_2.39；代理高吞吞性能优于 musl)
#
# =========================================

ARG RUST_VERSION=1.96
ARG ALPINE_VERSION=3.23
ARG DEBIAN_VERSION=13-slim

# =========================================
# 构建阶段 1 - gtagate (Rust L4 网关 + ACME)
# =========================================
FROM rust:${RUST_VERSION}-alpine AS rust-builder

# aws-lc-rs (rustls/instant-acme 默认后端) 需要 C 工具链 + cmake + perl
RUN apk add --no-cache musl-dev cmake make gcc g++ perl pkgconfig

WORKDIR /build
# 先拷依赖清单以利用层缓存
COPY gateway/Cargo.toml gateway/Cargo.lock ./
COPY gateway/src ./src

# --locked 确保与提交的 Cargo.lock 可重复构建
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/build/target \
    cargo build --release --locked && \
    strip target/release/gtagate && \
    cp target/release/gtagate /usr/local/bin/gtagate

# 运行阶段 - debian 13-slim (glibc 2.41)
# gtacore 为 glibc 二进制；debian glibc 在代理高并发/加解密负载下吞吞优于 musl。
# gtagate 为 musl 静态二进制，可在 glibc 系统直接运行。
FROM debian:${DEBIAN_VERSION}

# 元数据
LABEL maintainer="gtagod" \
    description="GTAGod - GTACore (Rust, naive + anytls + anyreality) with gtagate L4" \
    version="0.0.1"

# 一次性安装所有依赖并创建目录，减少镜像层
# procps 提供 pgrep/ps：healthcheck.sh 与 run.sh 的存活检测统一用 `pgrep -x gtagate/gtacore`，
# 缺失时 pgrep 返回 127 会被误判为“进程未运行”，导致容器永远 unhealthy。
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        libcap2-bin \
        netcat-openbsd \
        procps \
        tini \
        tzdata \
        jq && \
    rm -rf /var/lib/apt/lists/* && \
    # 设置时区
    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
    echo "Asia/Shanghai" > /etc/timezone && \
    # 创建目录结构 (cert 目录沿用 /data/caddy 以兼容历史卷与 find_certificate)
    mkdir -p \
        /config/caddy \
        /data/caddy \
        /var/log/caddy \
        /etc/gtagate \
        /etc/sing-box \
        /var/log/sing-box

# 创建非 root 用户（固定 UID/GID 65532，便于宿主机 bind-mount 目录精确 chown，
# 避免用 chmod 777 放开世界可写）。配合 setcap 和 --cap-add=NET_BIND_SERVICE 实现最小权限。
RUN groupadd -g 65532 gtagate && \
    useradd -u 65532 -g 65532 -M -s /usr/sbin/nologin -d /nonexistent gtagate && \
    chown gtagate:gtagate /config /data /var/log/caddy /var/log/sing-box

# 复制 gtagate (musl 静态, 来自构建阶段) 与 gtacore (本地预构建 glibc 二进制)
COPY --from=rust-builder --chmod=755 /usr/local/bin/gtagate /usr/bin/gtagate
COPY --chmod=755 bin/gtacore /usr/bin/gtacore
COPY bin/gtacore.sha256 /tmp/gtacore.sha256
RUN set -e; \
    EXPECTED=$(awk '{print $1}' /tmp/gtacore.sha256); \
    ACTUAL=$(sha256sum /usr/bin/gtacore | awk '{print $1}'); \
    if [ "$EXPECTED" != "$ACTUAL" ]; then \
        echo "FATAL: gtacore integrity check failed!"; \
        echo "  expected: $EXPECTED"; \
        echo "  actual:   $ACTUAL"; \
        exit 1; \
    fi; \
    rm -f /tmp/gtacore.sha256

# 加固：赋予 gtagate 绑定特权端口(443)的 file capability，
# 使其在 docker run --cap-drop=ALL --cap-add=NET_BIND_SERVICE 下仍可监听 443，
# 无需容器以 root 全权运行。
RUN setcap 'cap_net_bind_service=+ep' /usr/bin/gtagate

# 验证版本 (同时验证 musl gtagate 在 glibc 运行、gtacore 内嵌 sidecar)
RUN gtagate --version && \
    gtacore sing-box version

# 环境变量
ENV XDG_CONFIG_HOME=/config \
    XDG_DATA_HOME=/data \
    TZ=Asia/Shanghai

# 暴露端口 (gtagate 仅需 443；ACME 采用 DNS-01，无需 80)
EXPOSE 443

# 数据卷
VOLUME ["/config", "/data", "/var/log/caddy", "/etc/sing-box", "/var/log/sing-box"]

# 工作目录
WORKDIR /data/caddy

STOPSIGNAL SIGTERM

# 默认非 root 运行（setcap + --cap-add=NET_BIND_SERVICE 确保可绑 443）
USER gtagate

# 复制启动脚本
COPY --chmod=755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY --chmod=755 healthcheck.sh /usr/local/bin/healthcheck.sh

# 健康检查 - gtagate + sing-box + 证书就绪状态
HEALTHCHECK --interval=30s --timeout=10s --start-period=300s --start-interval=5s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh

# 启动命令
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
