#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""容器内定时器：到点执行上游 workbuddy_daily.py，其余时间休眠。

设计要点（都是为了少出事）：
  · 时区依赖容器 TZ=Asia/Shanghai，容器内直接取本地时间，不需要换算成 UTC
  · 每轮结束重新计算下一个时间点，不预生成长 sleep，避免宿主机时钟漂移把节奏带偏
  · 上游脚本 exit 1 表示「没有可用凭据」，属预期状态（还没登录），不当作崩溃
  · 单轮超时后直接 kill，防止网络卡死把后续时间点全堵住
  · 收到 SIGTERM 会把信号转发给子进程，docker stop 不会留下孤儿进程

可选环境变量：
  RUN_TIMES      逗号分隔的时刻，默认 07:00,12:00,23:30
  RUN_ON_START   1 = 容器启动立刻先跑一轮（默认 0，避免部署即消耗任务）
  RUN_TIMEOUT    单轮最长秒数，默认 3600
  TASK_ARGS      传给上游脚本的额外参数，默认空
"""
import os
import signal
import subprocess
import sys
import time

SCRIPT = "/app/src/workbuddy_daily.py"
STATE_DIR = os.environ.get("WORKBUDDY_STATE_DIR", "/data")
LOG_DIR = os.environ.get("LOG_DIR", "/logs")
HEARTBEAT = os.path.join(STATE_DIR, ".heartbeat")
DEFAULT_TIMES = "07:00,12:00,23:30"

_stop = False
_child = None


def log(msg):
    print("[sched %s] %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg), flush=True)


def _on_signal(signum, _frame):
    global _stop
    _stop = True
    log("收到信号 %s，准备退出" % signum)
    if _child is not None and _child.poll() is None:
        try:
            _child.send_signal(signal.SIGTERM)
            log("已把 SIGTERM 转发给子进程 pid=%s" % _child.pid)
        except Exception as exc:      # 子进程刚好退出时会走到这里
            log("转发信号失败（忽略）: %s" % exc)


def parse_times(raw):
    """把 '07:00,12:00,23:30' 解析成 [(7,0),(12,0),(23,30)]，非法项就地丢弃并告警。"""
    result = set()
    for item in (raw or "").replace(";", ",").replace("，", ",").split(","):
        item = item.strip()
        if not item:
            continue
        try:
            hh, mm = item.split(":")
            hh, mm = int(hh), int(mm)
        except Exception:
            log("⚠️ RUN_TIMES 里的「%s」不是 HH:MM 格式，已忽略" % item)
            continue
        if 0 <= hh < 24 and 0 <= mm < 60:
            result.add((hh, mm))
        else:
            log("⚠️ RUN_TIMES 里的「%s」超出 00:00-23:59，已忽略" % item)
    return sorted(result)


def next_run_epoch(slots, now=None):
    """下一个时间点的 epoch 秒。"""
    now = time.time() if now is None else now
    lt = time.localtime(now)
    best = None
    for hh, mm in slots:
        cand = int(time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, hh, mm, 0,
                                lt.tm_wday, lt.tm_yday, -1)))
        if cand <= now:
            cand += 86400
        if best is None or cand < best:
            best = cand
    return best


def writable(path):
    probe = os.path.join(path, ".write-test")
    try:
        with open(probe, "w") as fh:
            fh.write("ok")
        os.remove(probe)
        return True
    except Exception:
        return False


def write_heartbeat(note):
    try:
        with open(HEARTBEAT, "w") as fh:
            fh.write("%s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), note))
    except Exception as exc:
        log("⚠️ 心跳文件写入失败: %s" % exc)


def run_once(reason):
    """执行一轮上游脚本，返回退出码。"""
    global _child
    args = [sys.executable, "-u", SCRIPT]
    extra = (os.environ.get("TASK_ARGS") or "").strip()
    if extra:
        args.extend(extra.split())

    timeout_s = int((os.environ.get("RUN_TIMEOUT") or "3600").strip() or 3600)
    log("=== 开始执行（%s）超时上限 %ds ===" % (reason, timeout_s))
    started = time.time()
    try:
        _child = subprocess.Popen(args, cwd="/app/src")
    except Exception as exc:
        log("❌ 启动失败: %s" % exc)
        return 127

    rc = None
    try:
        while True:
            rc = _child.poll()
            if rc is not None:
                break
            if _stop:
                break
            if time.time() - started > timeout_s:
                log("❌ 超过 %ds 未结束，强制结束子进程" % timeout_s)
                _child.kill()
                time.sleep(2)
                rc = _child.poll()
                break
            time.sleep(1)
    finally:
        _child = None

    took = int(time.time() - started)
    if rc == 0:
        log("=== 执行完成，退出码 0，耗时 %ds ===" % took)
    elif rc == 1:
        log("=== 退出码 1（通常是未配置凭据，见上方提示），耗时 %ds ===" % took)
    else:
        log("=== 执行结束，退出码 %s，耗时 %ds ===" % (rc, took))
    write_heartbeat("rc=%s took=%ss" % (rc, took))
    return rc if rc is not None else -1


def main():
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, _on_signal)

    # 卷挂载权限检查：bind mount 由宿主机 root 建立时，容器内 uid 10001 可能写不进去，
    # 这个错误如果不提前说清楚，表现出来就只是「签到没反应」。
    for path in (STATE_DIR, LOG_DIR):
        try:
            os.makedirs(path, exist_ok=True)
        except Exception:
            pass
        if not writable(path):
            log("❌ 目录不可写: %s（宿主机上执行 chown -R 10001:10001 后重启容器）" % path)
            return 2

    slots = parse_times(os.environ.get("RUN_TIMES") or DEFAULT_TIMES)
    if not slots:
        log("❌ RUN_TIMES 无有效时刻，退出")
        return 2

    has_token = bool((os.environ.get("WORKBUDDY_REFRESH_TOKEN") or "").strip())
    log("定时时刻: %s（共 %d 个）" % (", ".join("%02d:%02d" % s for s in slots), len(slots)))
    log("凭据状态: %s" % ("已配置" if has_token else "未配置（会持续提示，登录后自动生效）"))
    write_heartbeat("started")

    if (os.environ.get("RUN_ON_START") or "0").strip() == "1":
        run_once("启动即跑")

    while not _stop:
        target = next_run_epoch(slots)
        log("下一轮: %s（还有 %d 分钟）"
            % (time.strftime("%Y-%m-%d %H:%M", time.localtime(target)),
               max(0, int((target - time.time()) // 60))))
        while not _stop and time.time() < target:
            time.sleep(30)
        if _stop:
            break
        if not (os.environ.get("WORKBUDDY_REFRESH_TOKEN") or "").strip():
            # 没有凭据时不空跑：只写心跳，免得日志被同一段提示刷爆
            log("跳过本轮：WORKBUDDY_REFRESH_TOKEN 为空（先执行 ./set-token.sh 写入凭据）")
            write_heartbeat("skipped:no-token")
            continue
        run_once("定时")

    log("已停止")
    return 0


if __name__ == "__main__":
    sys.exit(main())
