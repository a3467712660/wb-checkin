#!/bin/sh
# 登录用入口：跑完交互式登录后，把结果复制到持久卷，宿主机上的 set-token.sh 才能读到
python /app/src/workbuddy_login.py "$@"
rc=$?
if [ -f /app/src/wb_login_result.json ]; then
    cp -f /app/src/wb_login_result.json "$WORKBUDDY_STATE_DIR/wb_login_result.json"
    chmod 600 "$WORKBUDDY_STATE_DIR/wb_login_result.json" 2>/dev/null || true
    echo "[login] 结果已同步到 $WORKBUDDY_STATE_DIR/wb_login_result.json"
fi
exit $rc
