#!/bin/bash
# 首次部署：前置检查 → 建目录 → 写 .env → 拉镜像 → 起容器
# 用法：./install.sh ghcr.io/<你的GitHub用户名>/wb-checkin:latest
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${1:-}"

if [ -z "$IMAGE" ]; then
    echo "用法: ./install.sh ghcr.io/<用户名>/wb-checkin:latest"
    echo "镜像地址就是构建完成后 GitHub 仓库页右侧 Packages 里那个，注意末尾要带 :latest"
    exit 1
fi
case "$IMAGE" in
    *:*) : ;;
    *) echo "⚠️ 镜像地址缺少标签，自动补 :latest"; IMAGE="$IMAGE:latest" ;;
esac

# ---------- 前置检查：一次说清楚，比跑到一半报错强 ----------
if ! command -v docker >/dev/null 2>&1; then
    echo "❌ 没装 docker。先执行官方脚本：curl -fsSL https://get.docker.com | sh"
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    echo "❌ docker 装好了但守护进程没跑（或当前用户无权限）"
    echo "   试：systemctl enable --now docker"
    echo "   非 root 用户还需要：usermod -aG docker \$USER 后重新登录"
    exit 1
fi

if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
else
    echo "❌ 找不到 compose 插件。Debian/Ubuntu：apt install docker-compose-plugin"
    exit 1
fi

cd "$APP_DIR"
mkdir -p data logs data/backup

# 容器内以 uid 10001 运行，bind mount 目录必须是它的
# 非 root 装 docker 的机器上 chown 需要 sudo，否则容器「看起来在跑但什么都不写」
CHOWN=""
if [ "$(id -u)" -eq 0 ]; then
    CHOWN=""
elif command -v sudo >/dev/null 2>&1; then
    CHOWN="sudo"
fi
if ! $CHOWN chown -R 10001:10001 data logs 2>/dev/null; then
    echo "⚠️ 无法 chown data/ logs/（当前用户不是 root 且没有 sudo）"
    echo "   容器会启动但写不进状态文件。请手动执行一次："
    echo "   sudo chown -R 10001:10001 $APP_DIR/data $APP_DIR/logs"
fi

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
    echo "📝 已从模板生成 secrets.env（凭据为空，下一步登录后写入）"
fi
chmod 600 secrets.env

echo "📦 拉取镜像 $IMAGE"
if ! $DC pull; then
    echo "❌ 拉取失败。常见原因："
    echo "   1) 镜像还是 private —— 去 GitHub 仓库 Packages → 目标包 → Package settings → Change visibility → Public"
    echo "   2) 地址写错（用户名大小写、仓库名）—— 以 Packages 页显示为准"
    echo "   3) 真的想用私有镜像，就先 docker login ghcr.io"
    exit 1
fi

echo "🚀 启动容器"
$DC up -d

sleep 3
$DC ps
echo
echo "日志（应能看到「定时时刻」「凭据状态: 未配置」）："
$DC logs --tail 15 wb-checkin || true
echo
echo "------------------------- 下一步 -------------------------"
echo "1) 短信登录拿凭据："
echo "   $DC run --rm --entrypoint /app/login-entry.sh wb-checkin"
echo "2) 写入并自检："
echo "   ./set-token.sh"
echo "3) 看到「✅ 凭据可用」就完事了，后面全自动跑。"
