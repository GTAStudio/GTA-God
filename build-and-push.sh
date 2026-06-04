#!/bin/bash
set -e

# =========================================
# GTAGod 镜像构建 / 推送脚本 (v0.0.1)
# =========================================
# 架构: gtagate (Rust 网关) + gtacore (Rust 代理核心, 预构建二进制 bin/gtacore)
# 运行基仓: debian:12-slim (glibc)
# 仅 linux/amd64: bin/gtacore 为 x86_64 glibc 预构建产物
# =========================================

RUST_VERSION="1.96"
ALPINE_VERSION="3.23"    # rust-builder 阶段 (gtagate musl 静态构建)
DEBIAN_VERSION="12-slim" # 运行阶段
VERSION_TAG="v0.0.1"

# 配置 - 修改为你的 Docker Hub 用户名
DOCKERHUB_USERNAME="aizhihuxiao"
IMAGE_NAME="${DOCKERHUB_USERNAME}/gtagod"
DATE_TAG=$(date +%Y%m%d)

# 校验预构建二进制存在
if [ ! -f "bin/gtacore" ]; then
    echo "ERROR: 缺少预构建二进制 bin/gtacore，请先在 Linux/WSL 构建并放置该文件" >&2
    exit 1
fi

echo "========================================="
echo "  构建并推送到 Docker Hub"
echo "========================================="
echo "镜像名称: ${IMAGE_NAME}"
echo "标签: latest, ${VERSION_TAG}, ${DATE_TAG}"
echo "平台: linux/amd64"
echo ""

# 登录 Docker Hub
echo "🔐 登录 Docker Hub..."
docker login

# 拉取最新基础镜像
echo ""
echo "📥 拉取最新基础镜像..."
docker pull rust:${RUST_VERSION}-alpine${ALPINE_VERSION}
docker pull debian:${DEBIAN_VERSION}

# 构建镜像（仅 amd64）
echo ""
echo "🔨 构建镜像 (linux/amd64)..."
echo "   - rust-builder 阶段编译 gtagate (musl 静态)"
echo "   - 运行阶段 COPY 预构建 gtacore (glibc, 内嵌 libutls)"
echo "   - 这可能需要几分钟时间..."
echo ""

BUILD_ARGS=""
if [ "${FORCE_REBUILD:-false}" = "true" ]; then
    BUILD_ARGS="--no-cache"
    echo "⚠️  FORCE_REBUILD=true，禁用构建缓存"
fi

# 创建并使用 buildx builder
docker buildx create --name gtagod-builder --use 2>/dev/null || docker buildx use gtagod-builder

# 构建并推送
docker buildx build ${BUILD_ARGS} \
    --pull \
    --platform linux/amd64 \
    --build-arg RUST_VERSION=${RUST_VERSION} \
    --build-arg ALPINE_VERSION=${ALPINE_VERSION} \
    --build-arg DEBIAN_VERSION=${DEBIAN_VERSION} \
    -t ${IMAGE_NAME}:latest \
    -t ${IMAGE_NAME}:${VERSION_TAG} \
    -t ${IMAGE_NAME}:${DATE_TAG} \
    --push \
    .

echo ""
# 验证镜像（拉取并测试）
echo "🔍 验证镜像..."
docker pull ${IMAGE_NAME}:${VERSION_TAG}
echo ""
echo "📋 检查 gtagate 版本..."
docker run --rm --entrypoint gtagate ${IMAGE_NAME}:${VERSION_TAG} --version
echo ""
echo "📋 检查 gtacore 版本 (sing-box 兼容)..."
docker run --rm --entrypoint gtacore ${IMAGE_NAME}:${VERSION_TAG} sing-box version

echo ""
echo "========================================="
echo "✅ 成功推送到 Docker Hub!"
echo "========================================="
echo "镜像地址:"
echo "  - ${IMAGE_NAME}:latest"
echo "  - ${IMAGE_NAME}:${VERSION_TAG}"
echo "  - ${IMAGE_NAME}:${DATE_TAG}"
echo ""
echo "使用方式:"
echo "  docker pull ${IMAGE_NAME}:${VERSION_TAG}"
echo ""
echo "查看镜像:"
echo "  https://hub.docker.com/r/${DOCKERHUB_USERNAME}/gtagod"
echo "========================================="
