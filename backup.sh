#!/bin/bash
# 备份 data/（令牌库、活跃状态、补偿防重）和 secrets.env
# 用法：./backup.sh          → 存到 backup/wb-data-<时间>.tar.gz
#       ./backup.sh /root   → 存到指定目录
# 建议挂到 crontab 每周一次：0 4 * * 1 cd /opt/wb-checkin && ./backup.sh
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${1:-$APP_DIR/backup}"
KEEP=8

cd "$APP_DIR"
mkdir -p "$DEST"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$DEST/wb-data-$STAMP.tar.gz"

# 只装必要的东西：data 目录整体（含令牌库）+ 凭据文件
TARGETS=()
[ -d data ] && TARGETS+=("data")
[ -f secrets.env ] && TARGETS+=("secrets.env")
[ ${#TARGETS[@]} -gt 0 ] || { echo "❌ data/ 和 secrets.env 都不存在，没什么可备份的"; exit 1; }

tar -czf "$OUT" --exclude='data/backup' "${TARGETS[@]}"
chmod 600 "$OUT"
echo "✅ 已备份到 $OUT（$(du -h "$OUT" | cut -f1)）"
echo "   ⚠️ 这个包里含有 refreshToken，等同于账号密码，别传网盘、别提交 git"

# 只留最近 KEEP 份，防止把磁盘占满
COUNT="$(ls -1 "$DEST"/wb-data-*.tar.gz 2>/dev/null | wc -l)"
if [ "$COUNT" -gt "$KEEP" ]; then
    ls -1t "$DEST"/wb-data-*.tar.gz | tail -n "+$((KEEP + 1))" | xargs -r rm -f
    echo "🧹 已清理较旧的备份，保留最近 $KEEP 份"
fi
