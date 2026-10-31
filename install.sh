#!/bin/bash
# 首次部署：建目录、写 .env、拉镜像、起容器
# 用法：./install.sh ghcr.io/<你的GitHub用户名>/wb-checkin:latest
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${1:-}"

if [ -z "$IMAGE" ]; then
    echo "用法: ./install.sh ghcr.io/<用户名>/wb-checkin:latest"
    exit 1
fi

if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
else
    echo "❌ 找不到 docker compose"; exit 1
fi

cd "$APP_DIR"
mkdir -p data logs data/backup
# 容器内以 uid 10001 运行，bind mount 目录必须是它的
chown -R 10001:10001 data logs

if [ ! -f .env ]; then
    cp .env.example .env
fi
if grep -q '^WB_IMAGE=' .env; then
    sed -i "s|^WB_IMAGE=.*|WB_IMAGE=${IMAGE}|" .env
else
    printf 'WB_IMAGE=%s\n' "$IMAGE" >> .env
fi

if [ ! -f secrets.env ]; then
    cp secrets.env.example secrets.env
    chmod 600 secrets.env
fi

echo "📦 拉取镜像 $IMAGE"
$DC pull

echo "🚀 启动容器"
$DC up -d

sleep 3
$DC ps
echo
echo "日志（应能看到定时时刻表与「凭据状态：未配置」）："
$DC logs --tail 15 wb-checkin || true
echo
echo "下一步：$DC run --rm --entrypoint /app/login-entry.sh wb-checkin   # 短信登录"
echo "然后：  ./set-token.sh"
