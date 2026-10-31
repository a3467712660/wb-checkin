# wb-checkin

把 [L0NE-6/WorkBuddy-Daily](https://github.com/L0NE-6/WorkBuddy-Daily) 打包成容器长期运行：
镜像在 GitHub Actions 构建推送到 ghcr.io，服务器只负责 `docker pull` 和定时跑，不装 Python、不装编译工具。

## 目录结构

```
wb-checkin/
├── Dockerfile                 # 两阶段：拉上游代码 → 精简运行时
├── upstream.ref               # 上游提交号（钉死版本，不跟 main 漂）
├── scheduler.py               # 容器内定时器（到点跑一轮，其余时间休眠）
├── entrypoint.sh              # 入口：权限自检 → 交给定时器
├── login-entry.sh             # 登录入口：结果落到持久卷
├── docker-compose.yml         # 主服务 + 一次性登录服务
├── install.sh                 # 首次部署
├── set-token.sh               # 写入凭据 + 自检
├── secrets.env.example        # 凭据模板（真实文件不进 git）
└── .github/workflows/build.yml # 构建 + 冒烟断言
```

## 一次性准备（本地/GitHub 侧）

1. 在 GitHub 新建仓库（建议 **public**，这样 ghcr 镜像可以免登录拉取），把本目录推上去。
2. 仓库 Settings → Actions → General → Workflow permissions 选 **Read and write permissions**（否则推不了镜像）。
3. push 到 `main` 即自动构建；构建完 `smoke` job 会跑三项断言（无凭据提示、定时器启动、容器时区）。
4. 首次推送后去 GitHub 个人 → Packages → `wb-checkin` → 右下角 Package settings → Change visibility → **Public**（只需做一次，之后服务器免认证拉取）。

镜像标签：`latest`、`sha-xxxxxxx`、`up-<上游提交号>`。

## 服务器部署

```bash
mkdir -p /opt/wb-checkin && cd /opt/wb-checkin
# 把这几个文件传上来：docker-compose.yml install.sh set-token.sh
# （镜像里已经打包了代码，服务器不需要源码）
cp ../wb-checkin/.env.example .env 2>/dev/null || true

chmod +x install.sh set-token.sh
./install.sh ghcr.io/<你的GitHub用户名>/wb-checkin:latest
```

`install.sh` 会建 `data/`、`logs/` 并 `chown 10001:10001`（容器内以非 root 运行）。

## 登录拿凭据（唯一需要人工的一步）

```bash
docker compose run --rm --entrypoint /app/login-entry.sh wb-checkin
# 输入手机号 → 收短信 → 输入验证码
./set-token.sh
```

`set-token.sh` 会做三件事：写入 `secrets.env`（600）、清掉旧令牌库、重建容器并跑一次 `--query` 自检。

## 日常运维

```bash
docker compose ps                      # 状态
docker compose logs -f --tail 100      # 实时日志
docker compose run --rm --no-deps --entrypoint python wb-checkin /app/src/workbuddy_daily.py   # 立刻手动跑一轮
docker compose restart wb-checkin      # 重启
docker compose down                    # 停止（数据保留在 ./data）
```

改时间：编辑 `.env` 里的 `RUN_TIMES`，然后 `docker compose up -d --force-recreate`。

## 实现上的几个坑（都已在脚本里处理）

| 坑 | 后果 | 处理 |
|---|---|---|
| 上游优先读 `data/wb_refresh_tokens.json`，同手机号的新 token 不会被合并 | 重新登录后仍然 401，且日志看不出原因 | `set-token.sh` 备份并删除该文件，强制从环境变量重建（已在服务器上实测复现） |
| 容器默认 UTC | 定时时刻和补签日期整体偏 8 小时 | 镜像内装 tzdata 并锁 `Asia/Shanghai`，CI 断言 `date +%Z` 为 `CST` |
| bind mount 目录属 root | 容器内 uid 10001 写不进状态文件，表现只是“没反应” | `install.sh` 预置 `chown 10001:10001`；定时器启动时做写权限自检并明确报错 |
| 无凭据时上游 `exit 1` | 误判为崩溃反复重启 | 定时器把 1 识别为“未配置凭据”，只记一行并跳过本轮 |
| 网络卡住导致单轮不结束 | 后续时间点全被堵住 | 单轮 `RUN_TIMEOUT`（默认 3600s）到点 kill |
| Windows 换行 | 容器内 `sh` 报 `\r` 错误 | `.gitattributes` 强制 LF |

## 注意

- `secrets.env` 里的 refreshToken 等于账号密码，能无限续期。不要提交、不要贴聊天窗口、不要放进公开仓库。
- 上游是逆向非官方客户端接口，平台随时可能改。镜像钉在固定提交号上，升级时改 `upstream.ref` 再 push，构建失败或冒烟失败都不会影响线上正在跑的旧镜像。
