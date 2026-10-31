#!/bin/sh
# 容器入口：只做一次权限自检，然后把控制权交给定时器
set -e

if [ -z "${WORKBUDDY_STATE_DIR:-}" ]; then
    WORKBUDDY_STATE_DIR=/data
    export WORKBUDDY_STATE_DIR
fi
mkdir -p "$WORKBUDDY_STATE_DIR" 2>/dev/null || true

echo "[entry] $(date '+%F %T') 启动，时区=$(cat /etc/timezone 2>/dev/null || echo '?')，状态目录=$WORKBUDDY_STATE_DIR"

# 有参数就执行参数，没有才进定时器。
# 少这个判断的后果：docker run <镜像> python xxx.py 会被无声忽略、直接进定时器死循环，
# 命令永远不返回（CI 冒烟会挂到 job 超时，人工进容器排查也会卡死）
if [ "$#" -gt 0 ]; then
    exec "$@"
fi

exec python -u /app/scheduler.py
