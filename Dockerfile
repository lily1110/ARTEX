# syntax=docker/dockerfile:1
#
# 从源码构建 ARTEX 运行镜像：前端静态导出 → Go 编译（内嵌前端）→ 运行时镜像。
#
#   docker build -t artex:local .
#   docker compose up -d --build        # 推荐，见 docker-compose.yml
#
# 刻意不使用任何预编译的 ARTEX 二进制或镜像：2026-11 被发现的 tomicdd/artex 镜像
# 后门只存在于发布物中，源码里没有。镜像里跑的必须是这份源码编出来的二进制。
#
# 所有基础镜像按 digest 固定，npm 全局包按精确版本固定；升级时请同时更新 tag 与 digest：
#   docker buildx imagetools inspect <image:tag>
#
# 基础镜像选择（2026-11 复核）：均为 Docker 官方镜像（docker-library 构建，附 SLSA provenance 与 SBOM）。
# 使用 Debian 13 trixie 而不是 bookworm：bookworm 常规安全支持已于 2026-06 结束、只剩 LTS，
# trivy 扫描漏洞数明显更多。运行时额外 `apt-get upgrade`，并把镜像自带的 npm / pip 升到修复版本。

ARG GO_IMAGE=golang:1.26.11-trixie@sha256:f9e99477a80ccd7adfb69780510b22c7249ce9169885f18aa762cd886e75e018
ARG NODE_IMAGE=node:22-trixie-slim@sha256:f0960f8dc047f358e3fb428f36ccba21732194fa5f0cac849f401e63e62fb9e6
ARG RUNTIME_IMAGE=python:3.12-slim-trixie@sha256:191083cdf6c7bda8c76158983163ead5d5cf7b77cf3033e805bb0f5296f51b4b

# ── ① 前端静态导出 ─────────────────────────────────────────────
FROM ${NODE_IMAGE} AS web
WORKDIR /src/web
COPY web/package.json web/package-lock.json ./
# --ignore-scripts：不执行任何依赖的安装脚本（husky / sharp 等静态导出都用不到）。
RUN npm ci --ignore-scripts --no-audit --no-fund
COPY web/ ./
RUN npm run build:static

# ── ② Go 编译（内嵌前端）─────────────────────────────────────────
FROM ${GO_IMAGE} AS build
WORKDIR /src
ENV CGO_ENABLED=0 GOTOOLCHAIN=local GOFLAGS=-buildvcs=false
COPY go.mod go.sum ./
RUN go mod download && go mod verify
COPY . .
COPY --from=web /src/web/out ./server/webui/dist
ARG ARTEX_VERSION=dev
RUN go build -tags embedui -trimpath \
      -ldflags "-s -w -buildid= -X main.version=${ARTEX_VERSION}" \
      -o /out/artex ./cmd/artex \
    && /out/artex -h >/dev/null 2>&1

# ── ③ 运行时 ────────────────────────────────────────────────────
FROM ${NODE_IMAGE} AS node

FROM ${RUNTIME_IMAGE}
# 先装上基础镜像发布后 Debian 已推出的安全更新，再装常用工具 + recon 常备件（按需增删）。
# libcap2-bin 只用来给 nmap 授 cap_net_raw。
RUN apt-get update && apt-get -y upgrade && apt-get install -y --no-install-recommends \
      ca-certificates ripgrep curl wget vim git jq unzip \
      bind9-dnsutils iputils-ping netcat-openbsd inetutils-telnet whois nmap libcap2-bin \
    && rm -rf /var/lib/apt/lists/* \
    && python -m pip install --no-cache-dir --upgrade pip==26.3

# Node 22 直接从固定 digest 的官方镜像拷贝，替代原来的 `curl … nodesource | bash`。
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
# 镜像自带的 npm 10.9.x 打包了有已知漏洞的依赖（brace-expansion / pacote / sigstore 等），升到 npm 11。
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
    && npm install -g --ignore-scripts --no-audit --no-fund --registry=https://registry.npmjs.org/ npm@11.21.3 \
    && node --version && npm --version

# Playwright MCP / CLI 与 playwright 固定到同一个 playwright 版本（MCP 与 CLI 都精确依赖它），
# 这样只装一份匹配的 Chromium。浏览器放在共享目录，非 root 用户也能用。
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
RUN npm install -g --ignore-scripts --no-audit --no-fund --registry=https://registry.npmjs.org/ \
      @playwright/mcp@0.0.86 @playwright/cli@0.1.25 playwright@1.66.0-alpha-2026-11-18 \
    && playwright install --with-deps chromium \
    && playwright-cli --help >/dev/null \
    && chmod -R a+rX /opt/ms-playwright \
    && rm -rf /var/lib/apt/lists/* /root/.npm

# 以非 root 用户运行。nmap 单独授予 cap_net_raw，SYN 扫描等原始套接字功能仍可用；
# 其它进程（包括 agent 执行的命令）没有任何特权。
# /app 归属 artex:0 且组可写：compose 里用 `user: <宿主 UID>:0` 时同样能写 jwt.key 与 data/。
ENV NMAP_PRIVILEGED=1 HOME=/home/artex
RUN useradd --uid 10001 --gid 0 --create-home --home-dir /home/artex --shell /bin/sh artex \
    && setcap cap_net_raw+eip "$(readlink -f /usr/bin/nmap)" \
    && mkdir -p /app/data \
    && chown -R 10001:0 /app /home/artex \
    && chmod -R g+rwX /app /home/artex

WORKDIR /app
COPY --from=build --chown=10001:0 /out/artex /app/artex
# 守护启动脚本：进程退出后按退出码决定是否重新拉起，并把 SIGTERM 转发给 artex。
COPY --chown=10001:0 start.sh /app/start.sh
COPY --chown=10001:0 skills/ /app/skills/
RUN chmod 0775 /app/artex /app/start.sh

USER 10001:0
VOLUME ["/app/data"]
EXPOSE 8787 8788
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8787/api/health >/dev/null || exit 1
ENTRYPOINT ["/app/start.sh"]
# 容器内监听所有网卡，由 docker-compose.yml 只发布到宿主机 127.0.0.1。
CMD ["-addr", ":8787", "-proxy", ":8788"]
