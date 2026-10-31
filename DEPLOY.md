# 从零到跑起来（照着勾）

全程约 20 分钟，唯一要动脑的地方是第 3 步的短信验证码。
需要准备：一个 GitHub 账号、一台装了 docker 的服务器（1C1G 够）、一张能收短信的手机卡。

> **当前进度（2026-11-01）**
> - 仓库已建好：https://github.com/a3467712660/wb-checkin （Public，已推 5 个提交）
> - 镜像已构建并公开：`ghcr.io/a3467712660/wb-checkin:latest`，`build` 与 `smoke` 全绿，匿名 pull 已验证返回 200
> - 所以**第 1、2 步可以整段跳过**，从第 3 步开始
> - 现役环境是 CentOS 7 裸机（`/opt/workbuddy` + crontab，无 docker），容器方案留作换机备用

---

## 第 1 步：建仓库、推代码（你本机 / GitHub 网页）

- [ ] GitHub 新建仓库，起名 `wb-checkin`，**选 Public**，不要勾 add README
- [ ] 本机把 `wb-checkin` 目录推上去：

```bash
cd wb-checkin
git remote add origin https://github.com/<你的用户名>/wb-checkin.git
git push -u origin main
```

> 报 `src refspec main does not match` 说明当前分支叫 `master`，
> 那就 `git push -u origin master`，workflow 两个分支都认。

- [ ] 仓库 Settings → Actions → General → Workflow permissions → 选 **Read and write permissions** → Save

**成功标志**：仓库顶部 Actions 页出现一个正在跑的 `build-image`。

---

## 第 2 步：等构建、把包改成公开（GitHub 网页）

- [ ] Actions 里 `build` 和 `smoke` 两个 job 都变绿（约 3~5 分钟）
- [ ] 个人头像 → Your profile → **Packages** → `wb-checkin` → 右侧 Package settings → Danger Zone → Change visibility → **Public**

> 这步最容易漏。仓库 public 不等于包 public，漏了服务器拉镜像会报 `denied`。

- [ ] 记下镜像地址：`ghcr.io/<你的用户名>/wb-checkin:latest`
      （用户名全小写，以 Packages 页面显示的为准）

**成功标志**：`smoke` job 里三项断言都打印 ✅（无凭据提示 / 定时器启动 / 时区 CST）。

---

## 第 3 步：服务器部署（SSH 上去）

- [ ] 装 docker（已装可跳过）：

```bash
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker
```

- [ ] 传 7 个文件到 `/opt/wb-checkin/`：
      `docker-compose.yml` `install.sh` `set-token.sh` `update.sh` `backup.sh` `.env.example` `secrets.env.example`

```bash
mkdir -p /opt/wb-checkin && cd /opt/wb-checkin
# 本机执行（把文件传过去）
# scp docker-compose.yml install.sh set-token.sh update.sh backup.sh .env.example secrets.env.example root@<服务器IP>:/opt/wb-checkin/
chmod +x install.sh set-token.sh update.sh backup.sh
./install.sh ghcr.io/<你的用户名>/wb-checkin:latest
```

**成功标志**：日志里出现

```
[sched ...] 定时时刻: 07:00, 12:00, 23:30（共 3 个）
[sched ...] 凭据状态: 未配置（会持续提示，登录后自动生效）
[sched ...] 下一轮: ...
```

此时容器已经常驻，只是还没凭据。

---

## 第 4 步：短信登录写凭据（最后一步）

- [ ] 登录（交互式，会问手机号和验证码）：

```bash
docker compose run --rm --entrypoint /app/login-entry.sh wb-checkin
```

- [ ] 写入并自检：

```bash
./set-token.sh
```

**成功标志**：最后一行是 `✅ 凭据可用`。

如果看到 `⚠️ 自检未通过`：最常见是该账号在别处登录过，token 被轮换。
重新执行本步的登录命令一次即可。

---

## 第 5 步：验收

- [ ] 看一轮真实结果（不消耗当天次数，`--query` 只读）：

```bash
docker compose run --rm --no-deps --entrypoint python wb-checkin /app/src/workbuddy_daily.py --query
```

- [ ] 确认下一轮时间对得上北京时间：`docker compose logs --tail 3 wb-checkin`
- [ ] 第二天回来看一眼：`tail -20 data/.heartbeat`，应该有 `rc=0`

---

## 可选：让它跑完给你发微信

编辑 `/opt/wb-checkin/secrets.env`，取消注释并填一个通道（PushPlus 最省事，扫码就有 token）：

```bash
PUSHPLUS_TOKEN=你的token
WORKBUDDY_NOTIFY=fail     # 只在出问题时推，不想每天收消息就用这个
```

然后 `docker compose up -d --force-recreate wb-checkin` 生效。

---

## 之后你可能想做的三件事

| 想干什么 | 命令 |
|---|---|
| 改运行时间 | 编辑 `.env` 的 `RUN_TIMES` → `docker compose up -d --force-recreate` |
| 升级镜像 | `./update.sh`（自动先备份，末尾给回滚命令） |
| 备份 / 防丢 | `./backup.sh`，或挂到 crontab 每周一次 |

---

## 出事了看哪里

| 现象 | 原因 | 处理 |
|---|---|---|
| `pull` 报 denied | 包还是 private | 回到第 2 步最后一条 |
| 日志一直「跳过本轮：token 为空」 | 凭据没写进去 | 重跑 `./set-token.sh` |
| 一直 401 | 旧令牌库挡着 | `set-token.sh` 会自动清；不行就删 `data/wb_refresh_tokens.json` 重新登录 |
| 容器起不来 | `/data` 写不进 | `sudo chown -R 10001:10001 data logs` 后重启 |
| 到点没动静 | 时区不对 | `docker compose exec wb-checkin date` 应显示 CST |
| 想全部重来 | — | `docker compose down && rm -rf data logs .env secrets.env` 后从第 3 步开始 |
