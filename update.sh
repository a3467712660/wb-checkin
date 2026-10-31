#!/bin/bash
# 升级到最新镜像（数据、凭据、定时设置全部保留）
# 用法：./update.sh
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$APP_DIR"

if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
else
    echo "❌ 找不到 docker compose"; exit 1
fi

[ -f .env ] || { echo "❌ 没有 .env，这机器还没部署过。先跑 ./install.sh <镜像地址>"; exit 1; }
IMAGE="$(grep '^WB_IMAGE=' .env | cut -d= -f2-)"
[ -n "$IMAGE" ] || { echo "❌ .env 里没有 WB_IMAGE"; exit 1; }

# 注意：这里不能用 `docker compose images -q "$IMAGE"` —— compose 的子命令会把
# 参数当服务名解析，镜像地址会被当成不存在的服务，永远返回空。
img_id() { docker image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null || true; }

OLD_ID="$(img_id)"

echo "🔄 拉取 $IMAGE"
$DC pull

NEW_ID="$(img_id)"
if [ -n "$OLD_ID" ] && [ "$OLD_ID" = "$NEW_ID" ]; then
    echo "✅ 已经是最新镜像，无需重启"
    exit 0
fi

# 升级前留一份数据快照：万一新镜像行为有变，能退回旧镜像 + 旧数据
if [ -x ./backup.sh ]; then
    echo "💾 升级前备份数据 ..."
    ./backup.sh || echo "⚠️ 备份失败，继续升级（自行决定是否要停）"
fi

echo "🚀 重建容器"
$DC up -d --force-recreate wb-checkin

sleep 3
$DC ps wb-checkin || true
echo
echo "最近日志："
$DC logs --tail 20 wb-checkin || true

if [ -n "$OLD_ID" ]; then
    echo
    echo "↩️ 想回滚到升级前的镜像（数据不动）："
    echo "   docker tag $OLD_ID ${IMAGE%%:*}:rollback"
    echo "   然后把 .env 里的 WB_IMAGE 改成 ${IMAGE%%:*}:rollback 再 $DC up -d --force-recreate"
fi
