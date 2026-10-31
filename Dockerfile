# syntax=docker/dockerfile:1

# ---- 构建阶段：只在这里装 git 拉上游代码，运行时镜像里不留痕 ----
ARG PYTHON_IMAGE=python:3.11-slim
FROM ${PYTHON_IMAGE} AS fetch

ARG UPSTREAM_REPO=https://github.com/L0NE-6/WorkBuddy-Daily.git

RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# 提交号固定在 upstream.ref，构建可复现；不与上游 main 联动，避免上游改动把线上跑挂
COPY upstream.ref /tmp/upstream.ref
RUN set -eux; \
    REF="$(cat /tmp/upstream.ref)"; \
    git init -q /src; \
    cd /src; \
    git remote add origin "${UPSTREAM_REPO}"; \
    git fetch -q --depth 1 origin "${REF}" || git fetch -q origin "${REF}" || git fetch -q origin; \
    git checkout -q "${REF}"; \
    rm -rf /src/.git

# ---- 运行阶段 ----
FROM ${PYTHON_IMAGE}

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    LANG=C.UTF-8 \
    TZ=Asia/Shanghai

RUN apt-get update \
 && apt-get install -y --no-install-recommends tzdata \
 && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime \
 && echo $TZ > /etc/timezone \
 && rm -rf /var/lib/apt/lists/*

RUN python -m pip install --no-cache-dir "requests==2.32.3"

WORKDIR /app
COPY --from=fetch /src/workbuddy_daily.py /src/workbuddy_login.py /app/src/
COPY scheduler.py /app/scheduler.py
COPY entrypoint.sh /app/entrypoint.sh
COPY login-entry.sh /app/login-entry.sh
RUN chmod +x /app/entrypoint.sh /app/login-entry.sh \
 && useradd -u 10001 -M -s /usr/sbin/nologin wb \
 && mkdir -p /data /logs \
 && chown -R wb:wb /app /data /logs

USER wb
VOLUME ["/data"]

# 无 token 时脚本会以 exit 1 退出并打印「未找到可用账号」，这是预期状态，不是崩溃
ENTRYPOINT ["/app/entrypoint.sh"]
