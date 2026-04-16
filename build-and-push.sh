#!/bin/bash
set -e

CADDY_VERSION="v2.11.2"
SINGBOX_VERSION="1.13.8"

# 配置 - 修改为你的 Docker Hub 用户名
DOCKERHUB_USERNAME="aizhihuxiao"
IMAGE_NAME="${DOCKERHUB_USERNAME}/gtagod"
DATE_TAG=$(date +%Y%m%d)

echo "========================================="
echo "  构建并推送到 Docker Hub"
echo "========================================="
echo "镜像名称: ${IMAGE_NAME}"
echo "标签: latest, ${DATE_TAG}"
echo ""

# 登录 Docker Hub
echo "🔐 登录 Docker Hub..."
docker login

# 拉取最新基础镜像
echo ""
echo "📥 拉取最新基础镜像..."
docker pull golang:1.26-alpine
docker pull alpine:3.23

# 构建多架构镜像（需要 buildx）
echo ""
echo "🔨 构建多架构镜像 (amd64, arm64)..."
echo "   - 使用固定版本的 Caddy 和 sing-box 核心"
echo "   - 这可能需要几分钟时间..."
echo ""

BUILD_ARGS=""
if [ "${FORCE_REBUILD:-false}" = "true" ]; then
    BUILD_ARGS="--no-cache"
    echo "⚠️  FORCE_REBUILD=true，禁用构建缓存"
fi

# 创建并使用 buildx builder
docker buildx create --name naiveproxy-builder --use 2>/dev/null || docker buildx use naiveproxy-builder

# 构建并推送
docker buildx build ${BUILD_ARGS} \
    --platform linux/amd64,linux/arm64 \
    --build-arg CADDY_VERSION=${CADDY_VERSION} \
    --build-arg SINGBOX_VERSION=${SINGBOX_VERSION} \
    -t ${IMAGE_NAME}:latest \
    -t ${IMAGE_NAME}:${DATE_TAG} \
    --push \
    .

echo ""
# 验证镜像（拉取并测试）
echo "🔍 验证镜像..."
docker pull ${IMAGE_NAME}:latest
docker run --rm --entrypoint caddy ${IMAGE_NAME}:latest version
echo ""
echo "📋 检查 Caddy L4 和 Cloudflare 模块..."
docker run --rm --entrypoint caddy ${IMAGE_NAME}:latest list-modules | grep -E "(layer4|cloudflare)"
echo ""
echo "📋 检查 sing-box 版本 (native naive inbound)..."
docker run --rm --entrypoint sing-box ${IMAGE_NAME}:latest version

echo ""
echo "========================================="
echo "✅ 成功推送到 Docker Hub!"
echo "========================================="
echo "镜像地址:"
echo "  - ${IMAGE_NAME}:latest"
echo "  - ${IMAGE_NAME}:${DATE_TAG}"
echo ""
echo "使用方式:"
echo "  docker pull ${IMAGE_NAME}:latest"
echo ""
echo "查看镜像:"
echo "  https://hub.docker.com/r/${DOCKERHUB_USERNAME}/gtagod"
echo "========================================="
