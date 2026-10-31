#!/bin/sh
# 容器入口：只做一次权限自检，然后把控制权交给定时器
set -e

if [ -z "${WORKBUDDY_STATE_DIR:-}" ]; then
    WORKBUDDY_STATE_DIR=/data
    export WORKBUDDY_STATE_DIR
fi
mkdir -p "$WORKBUDDY_STATE_DIR" 2>/dev/null || true

echo "[entry] $(date '+%F %T') 启动，时区=$(cat /etc/timezone 2>/dev/null || echo '?')，状态目录=$WORKBUDDY_STATE_DIR"
exec python -u /app/scheduler.py
