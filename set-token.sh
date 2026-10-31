#!/bin/bash
# 把登录拿到的 token 写进 secrets.env，并做一次凭据自检
# 用法：
#   ./set-token.sh                      # 自动读取 data/wb_login_result.json 里最新一条
#   ./set-token.sh '手机号:AT:RT'        # 直接给一行
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$APP_DIR/data"
SECRETS="$APP_DIR/secrets.env"
RESULT="$DATA_DIR/wb_login_result.json"

if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
else
    echo "❌ 找不到 docker compose，先完成 Docker 安装"; exit 1
fi

TOKEN_LINE="${1:-}"

if [ -z "$TOKEN_LINE" ] && [ -f "$RESULT" ]; then
    TOKEN_LINE="$(python3 -c "
import json,sys
try:
    data=json.load(open('$RESULT',encoding='utf-8'))
except Exception:
    sys.exit(0)
print(data[-1].get('env_line','') if isinstance(data,list) and data else '')
" 2>/dev/null || true)"
fi

if [ -z "$TOKEN_LINE" ]; then
    echo "❌ 没找到可用的 token"
    echo "   先登录：$DC run --rm --entrypoint /app/login-entry.sh wb-checkin"
    echo "   或直接传参：./set-token.sh '138xxxxxxxx:eyJ...:eyJ...'"
    exit 1
fi

# 只做结构校验，不打印内容
COLONS="$(printf '%s' "$TOKEN_LINE" | tr -cd ':' | wc -c)"
case "$TOKEN_LINE" in
    *"'"*) echo "❌ token 里出现单引号，拒绝写入（复制时混入了多余字符）"; exit 1 ;;
esac
if [ "$COLONS" -lt 2 ] || ! printf '%s' "$TOKEN_LINE" | grep -q 'eyJ'; then
    echo "❌ 格式不对：应为 手机号:AT:RT（三段，英文冒号，AT/RT 都以 eyJ 开头）"
    echo "   当前行长度 ${#TOKEN_LINE}，冒号数 $COLONS"
    exit 1
fi

# 关键一步：清掉旧的本地令牌库。
# 上游脚本优先读 data/wb_refresh_tokens.json，且「同手机号」的新 token 不会被合并进去，
# 不删这个文件的话，重新登录拿到的新凭据会被旧记录静默挡住，表现为一直 401。
if [ -f "$DATA_DIR/wb_refresh_tokens.json" ]; then
    mkdir -p "$DATA_DIR/backup"
    BAK="$DATA_DIR/backup/wb_refresh_tokens.$(date +%Y%m%d-%H%M%S).json"
    cp -f "$DATA_DIR/wb_refresh_tokens.json" "$BAK"
    rm -f "$DATA_DIR/wb_refresh_tokens.json"
    echo "🧹 旧令牌库已备份到 $(basename "$BAK") 并清除"
fi

TMP="$(mktemp)"
if [ -f "$SECRETS" ]; then
    grep -v '^WORKBUDDY_REFRESH_TOKEN=' "$SECRETS" > "$TMP" || true
else
    : > "$TMP"
fi
printf "WORKBUDDY_REFRESH_TOKEN='%s'\n" "$TOKEN_LINE" >> "$TMP"
mv -f "$TMP" "$SECRETS"
chmod 600 "$SECRETS"
echo "✅ 凭据已写入 $SECRETS（权限 600）"

cd "$APP_DIR"
echo "🔄 重建容器以加载新凭据 ..."
$DC up -d --force-recreate wb-checkin >/dev/null
sleep 2
$DC ps wb-checkin || true

echo
echo "🔍 凭据自检（--query 只读，不消耗任务）："
set +e
OUT="$($DC run --rm --no-deps --entrypoint python wb-checkin /app/src/workbuddy_daily.py --query 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT" | tail -22
echo
if printf '%s' "$OUT" | grep -q '凭据失效\|token format error\|未找到可用账号'; then
    echo "⚠️ 自检未通过：上面的输出说明了原因。最常见是 token 被别的设备轮换过，重新登录一次即可。"
    exit 2
fi
if [ "$RC" -ne 0 ]; then
    echo "⚠️ 自检退出码 $RC，请对照上面的输出判断"
    exit 2
fi
echo "✅ 凭据可用。定时任务已生效，下一轮时间见：$DC logs --tail 5 wb-checkin"
