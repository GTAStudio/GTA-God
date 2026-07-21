# syntax=docker/dockerfile:1@sha256:87999aa3d42bdc6bea60565083ee17e86d1f3339802f543c0d03998580f9cb89
# =========================================
# GTAGod Dockerfile - GTACore (Rust) 统一架构
# 版本: 0.2.5
# 更新: 2026-07-20
# =========================================
#
# 此版本用 GTACore (Rust, gtacore 兼容) 完全替代 gtacore，
# 原生处理九组合协议（正式七轴 + VLESS Vision REALITY + AmneziaWG）；
# uTLS、WireGuard、AmneziaWG 与 userspace netstack 均为原生 Rust；
# 单文件 gtacore 只内嵌当前服务器需要的 Cloudflared sidecar。
#
# 架构 (v0.2.5):
#   - gtagate (Rust): L4 SNI 分流 + ACME 证书申请 (替代 Caddy)
#   - gtacore (Rust): 九组合协议，AmneziaWG 使用 userspace packet endpoint
#
# 依赖版本 (2026-07-19 更新):
#   - Rust: 1.97 (edition 2024)
#   - gtagate: 本仓库 gateway/ (musl 静态, tokio + rustls + instant-acme)
#   - gtacore: 预构建 glibc 二进制 bin/gtacore（native uTLS/WireGuard/netstack + 内嵌 Cloudflared）
#   - 运行镜像: debian 13-slim (glibc 2.41，满足 gtacore 需求 GLIBC_2.39；代理高吞吞性能优于 musl)
#
# =========================================

# 基镜像 tag@digest 内联（不再用 ARG 间接）：使 dependabot 的 docker updater 能解析并自动
# 跟踪 base image 的 digest 安全更新（ARG 间接它无法解析，旧写法下 dependabot docker 形同虚设）。
# rust 已在 dependabot.yml 忽略 minor/major（保持 1.97，仅跟同 tag 的 digest）；debian 跟安全补丁
# （major 升级由人审 PR）。更新 tag 时须同步 digest（docker buildx imagetools inspect rust:1.97-alpine / debian:13-slim）。

# =========================================
# 构建阶段 1 - gtagate (Rust L4 网关 + ACME)
# =========================================
FROM rust:1.97-alpine@sha256:3c38f3f82c2f3d73da3b38e18d279393a04cb43ddded0e35088a8c3324d40900 AS rust-builder

# aws-lc-rs (rustls/instant-acme 默认后端) 需要 C 工具链 + cmake + perl
RUN apk add --no-cache musl-dev cmake make gcc g++ perl pkgconfig

WORKDIR /build
# 直接 COPY 全部源码后一次性编译（--locked 与提交的 Cargo.lock 可重复构建）。改 gateway/src
# 任意文件会使本层失效、全量重编(含依赖)；但这种 push 少见——多数是 gtacore 升级不碰 gateway/src，
# 此时 COPY+RUN 两层经 gha layer-cache 整体命中、跳过编译，与依赖预构建同样快。
# ⚠️ 不用 dummy-main 依赖预构建层：COPY 真实源码保留的旧 mtime < dummy 产物 mtime → cargo 误判
# main.rs 未变而跳过重编 → cp 出 dummy 空壳(417KB) → 容器 gtagate 起不来（2026-06-30 实测踩坑）。
COPY gateway/Cargo.toml gateway/Cargo.lock ./
COPY gateway/.cargo ./.cargo
COPY gateway/src ./src
RUN cargo build --release --locked && \
    cp target/release/gtagate /usr/local/bin/gtagate

# 运行阶段 - debian 13-slim (glibc 2.41)
# gtacore 为 glibc 二进制；debian glibc 在代理高并发/加解密负载下吞吐优于 musl。
# gtagate 为 musl 静态二进制，可在 glibc 系统直接运行。
FROM debian:13-slim@sha256:020c0d20b9880058cbe785a9db107156c3c75c2ac944a6aa7ab59f2add76a7bd

# 元数据：镜像语义版本=所打包的 gtacore 版本（单一 source of truth）。
# CI 从 bin/gtacore 读出真版本并经 --build-arg GTAGOD_VERSION 注入；本地构建用默认值。
# 更新 bin/gtacore 时须同步此默认值（与 bin/gtacore.sha256、ARG GTACORE_SHA256 一起）。
ARG GTAGOD_VERSION=0.2.5
ARG GTACORE_REVISION=91cb526439af613420a94c7df2870a9009e6bec9
LABEL maintainer="gtagod" \
    org.opencontainers.image.title="gtagod" \
    org.opencontainers.image.description="GTAGod - GTACore nine-combination portfolio with AmneziaWG + gtagate L4" \
    org.opencontainers.image.version="${GTAGOD_VERSION}" \
    io.gtagod.gtacore.revision="${GTACORE_REVISION}" \
    io.gtagod.stop-timeout-seconds="40" \
    org.opencontainers.image.licenses="MIT"

# 一次性安装所有依赖并创建目录，减少镜像层
# procps 提供 pgrep/ps：healthcheck.sh 与 run.sh 的存活检测统一用 `pgrep -x gtagate/gtacore`，
# 缺失时 pgrep 返回 127 会被误判为“进程未运行”，导致容器永远 unhealthy。
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        findutils \
        libcap2-bin \
        netcat-openbsd \
        openssl \
        procps \
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
        /etc/gtacore \
        /var/log/gtacore

# 创建非 root 用户（固定 UID/GID 65532，便于宿主机 bind-mount 目录精确 chown，
# 避免用 chmod 777 放开世界可写）。配合 setcap 和 --cap-add=NET_BIND_SERVICE 实现最小权限。
RUN groupadd -g 65532 gtagate && \
    useradd -u 65532 -g 65532 -M -s /usr/sbin/nologin -d /nonexistent gtagate && \
    chown -R gtagate:gtagate /config /data /var/log/caddy /var/log/gtacore

# 复制 gtagate (musl 静态, 来自构建阶段) 与 gtacore (本地预构建 glibc 二进制)
COPY --from=rust-builder --chmod=755 /usr/local/bin/gtagate /usr/bin/gtagate
COPY --chmod=755 bin/gtacore /usr/bin/gtacore
COPY --chmod=0444 bin/gtacore.provenance.json /usr/share/gtagod/gtacore.provenance.json
# gtacore 期望哈希钉进 Dockerfile（构建配方=更强信任锚；攻击者须同时改二进制+本 ARG+.sha256 文件）。
# 更新 bin/gtacore 时须同步更新此值与 bin/gtacore.sha256。
ARG GTACORE_SHA256=3fc6b0c5101aca88cb748cbae2cfa8bb15204c94437829f929e2bd63e95c26f2
COPY bin/gtacore.sha256 /tmp/gtacore.sha256
RUN set -e; \
    ACTUAL=$(sha256sum /usr/bin/gtacore | awk '{print $1}'); \
    FILEHASH=$(awk '{print $1}' /tmp/gtacore.sha256); \
    if [ "$GTACORE_SHA256" != "$ACTUAL" ]; then \
        echo "FATAL: gtacore hash != Dockerfile ARG GTACORE_SHA256"; \
        echo "  arg:    $GTACORE_SHA256"; \
        echo "  actual: $ACTUAL"; \
        exit 1; \
    fi; \
    if [ "$FILEHASH" != "$ACTUAL" ]; then \
        echo "FATAL: gtacore hash != bin/gtacore.sha256"; \
        echo "  file:   $FILEHASH"; \
        echo "  actual: $ACTUAL"; \
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
    GTAGOD_VERSION=${GTAGOD_VERSION} \
    TZ=Asia/Shanghai

# 端口元数据（实际部署使用 --net=host）：TLS/SNI 类经 443；Hysteria2、Mieru、
# AmneziaWG 直连独立端口。AmneziaWG 默认 8450/udp。
# ACME 采用 DNS-01，无需开放 80。
EXPOSE 443/tcp 8446/udp 8447/tcp 8447/udp 8450/udp

# 数据卷
VOLUME ["/config", "/data", "/var/log/caddy", "/etc/gtacore", "/var/log/gtacore"]

# 工作目录
WORKDIR /data/caddy

STOPSIGNAL SIGTERM

# 默认非 root 运行（setcap + --cap-add=NET_BIND_SERVICE 确保可绑 443）
USER gtagate

# 复制启动脚本
COPY --chmod=755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY --chmod=755 healthcheck.sh /usr/local/bin/healthcheck.sh
COPY --chmod=755 tests/container-data-path.sh /usr/local/bin/gtagod-data-path-check
COPY --chmod=0444 gtacore-watchdog.sh /usr/local/lib/gtacore-watchdog.sh
COPY --chmod=0444 certificate-health-lib.sh /usr/local/lib/gtagod-certificate-health.sh

# 健康检查 - gtagate + gtacore + 证书就绪状态
# 默认证书等待预算为 180s + 10x30s；600s start period 让 entrypoint 先完成或明确失败，
# 避免编排器在 ACME 仍按设计重试时把容器提前判为 unhealthy。
HEALTHCHECK --interval=30s --timeout=10s --start-period=600s --start-interval=5s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh

# 启动命令
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
