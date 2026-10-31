# wb-checkin

把 [L0NE-6/WorkBuddy-Daily](https://github.com/L0NE-6/WorkBuddy-Daily) 打包成容器长期运行：
镜像在 GitHub Actions 构建推送到 ghcr.io，服务器只负责 `docker pull` 和定时跑，不装 Python、不装编译工具。

> 只想照做、不想读原理：直接看 **[DEPLOY.md](DEPLOY.md)** 的勾选清单。
> 这份 README 是参考手册，讲结构、运维和踩过的坑。

## 目录结构

```
wb-checkin/
├── Dockerfile                  # 两阶段：拉上游代码 → 精简运行时
├── upstream.ref                # 上游提交号（钉死版本，不跟 main 漂）
├── scheduler.py                # 容器内定时器（到点跑一轮，其余时间休眠）
├── entrypoint.sh               # 入口：交给定时器
├── login-entry.sh              # 登录入口：结果落到持久卷
├── docker-compose.yml          # 主服务 + 一次性登录服务
├── install.sh                  # 首次部署（含前置检查）
├── set-token.sh                # 写入凭据 + 自检
├── update.sh                   # 升级镜像（数据保留 + 可回滚）
├── backup.sh                   # 备份 data/ 与 secrets.env
├── .env.example                # 编排参数模板
├── secrets.env.example         # 凭据 + 推送通道模板（真实文件不进 git）
└── .github/workflows/build.yml # 构建 + 冒烟断言
```

## 你要填的三样东西

| 变量 | 填哪 | 在哪拿到 |
|---|---|---|
| GitHub 用户名 | 不用填，install.sh 的参数里带 | — |
| 镜像地址 | `./install.sh ghcr.io/<用户名>/wb-checkin:latest` | 仓库页右侧 **Packages** |
| refreshToken | 不手填，`./set-token.sh` 自动写入 | 短信登录 |

## 本地 / GitHub 侧（一次性）

1. 在 GitHub 新建仓库（建议 **public**，ghcr 镜像才能免登录拉取），把本目录推上去。
   分支用 `main` 或 `master` 都行，workflow 两个都监听。
2. 仓库 Settings → Actions → General → Workflow permissions 选 **Read and write permissions**（否则推不了镜像）。
3. push 后自动构建；构建完 `smoke` job 会跑三项断言（无凭据提示、定时器启动、容器时区），全绿才算镜像可用。
4. **首次推送后必须做一次**：GitHub 个人 → Packages → `wb-checkin` → 右下角 Package settings → Change visibility → **Public**。
   > 仓库是 public **不代表**包也是 public，这一步漏了服务器会 `pull` 失败（denied）。

镜像标签：`latest`、`sha-xxxxxxx`、`up-<上游提交号>`。

## 服务器部署

```bash
mkdir -p /opt/wb-checkin && cd /opt/wb-checkin
# 传这几个文件上来即可：docker-compose.yml install.sh set-token.sh update.sh backup.sh .env.example secrets.env.example
# 镜像里已经打包了上游代码，服务器不需要源码
chmod +x install.sh set-token.sh update.sh backup.sh
./install.sh ghcr.io/<你的GitHub用户名>/wb-checkin:latest
```

`install.sh` 会检查 docker / compose / 权限，建 `data/`、`logs/` 并 `chown 10001:10001`（容器内以非 root 运行）。

## 登录拿凭据（唯一需要人工的一步）

```bash
docker compose run --rm --entrypoint /app/login-entry.sh wb-checkin
# 输入手机号 → 收短信 → 输入验证码
./set-token.sh
```

`set-token.sh` 会做四件事：清掉旧令牌库（原因见下方坑表）、写入 `secrets.env`（600）、重建容器、跑一次 `--query` 自检。

多账号：`./set-token.sh '手机号1:AT:RT@手机号2:AT:RT'`，用 `@` 分隔写一行。

## 日常运维

```bash
docker compose ps                        # 状态（healthy 表示心跳新鲜）
docker compose logs -f --tail 100        # 实时日志
tail -40 data/.heartbeat                 # 最近一轮结果
docker compose run --rm --no-deps --entrypoint python wb-checkin /app/src/workbuddy_daily.py   # 立刻手动跑一轮
docker compose restart wb-checkin        # 重启
./update.sh                              # 升级镜像（自动先备份，失败可回滚）
./backup.sh                              # 手动备份
docker compose down                      # 停止（数据保留在 ./data）
```

改时间：编辑 `.env` 里的 `RUN_TIMES`，然后 `docker compose up -d --force-recreate`。

定时备份（可选）：

```bash
( crontab -l 2>/dev/null; echo "0 4 * * 1 cd /opt/wb-checkin && ./backup.sh" ) | crontab -
```

## 实现上的几个坑（都已在脚本里处理）

| 坑 | 后果 | 处理 |
|---|---|---|
| 上游优先读 `data/wb_refresh_tokens.json`，同手机号的新 token 不会被合并 | 重新登录后仍然 401，日志看不出原因 | `set-token.sh` 备份并删除该文件，强制从环境变量重建（已实测复现） |
| GitHub 仓库默认分支可能是 `master`，workflow 只写了 `main` | 推上去 CI 静默不触发，以为在构建其实啥也没有 | workflow 同时监听 `main` 和 `master` |
| 仓库 public ≠ 包 public | 服务器 `docker pull` 报 denied | README 与 install.sh 都做了提示 |
| env_file 不支持多行值 | 多账号直接换行写，只有第一个账号生效 | 统一压成 `@` 分隔的一行（上游原生支持 `@`） |
| 容器默认 UTC | 定时时刻和补签日期整体偏 8 小时 | 镜像内装 tzdata 并锁 `Asia/Shanghai`，CI 断言 `date +%Z` 为 `CST` |
| bind mount 目录属 root | 容器内 uid 10001 写不进状态文件，表现只是「没反应」 | `install.sh` 预置 chown；定时器启动时做写权限自检并明确报错 |
| 无凭据时上游 `exit 1` | 误判为崩溃反复重启 | 定时器把 1 识别为「未配置凭据」，只记一行并跳过本轮 |
| 网络卡住导致单轮不结束 | 后续时间点全被堵住 | 单轮 `RUN_TIMEOUT`（默认 3600s）到点 kill |
| 服务器没装 python3 | `set-token.sh` 读不了登录结果 | 优先用宿主机 python3，没有就借镜像内的 python |
| Windows 换行 | 容器内 `sh` 报 `\r` 错误 | `.gitattributes` 强制 LF |
| unhealthy 不会触发重启 | 以为 healthcheck 能自愈 | Docker 本身不会；保命的是 `restart: unless-stopped`，心跳只用于观察 |

## 排障速查

| 现象 | 先看什么 |
|---|---|
| 容器重启循环 | `docker compose logs --tail 50`；多半是 `RUN_TIMES` 写错或 `/data` 不可写 |
| 日志一直「跳过本轮：token 为空」 | `secrets.env` 没写进去，重跑 `./set-token.sh` |
| 一直 401 / 凭据失效 | 令牌被别处轮换过，重新登录；确认 `data/wb_refresh_tokens.json` 已清 |
| 到点没动静 | `docker compose exec wb-checkin date` 看时区；`data/.heartbeat` 看最后活动时间 |
| 签到成功但积分没涨 | 上游日志里会自动核对前后差值；若显示「未确认」，等下一轮补 |
| 升级后行为异常 | `./backup.sh` 的包 + `update.sh` 末尾给的回滚命令 |

## 注意

- `secrets.env` 里的 refreshToken 等于账号密码，能无限续期。不要提交、不要贴聊天窗口、不要放进公开仓库。
- `backup.sh` 产出的 tar.gz 同样含 token，别传网盘。
- 上游是逆向非官方客户端接口，平台随时可能改。镜像钉在固定提交号上，升级时改 `upstream.ref` 再 push，构建失败或冒烟失败都不会影响线上正在跑的旧镜像。
