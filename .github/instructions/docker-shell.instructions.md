---
description: 'Docker / Bash 部署脚本与容器构建最佳实践（GTA-God 代理部署层核心栈）'
applyTo: '**/Dockerfile,**/*.sh,**/docker-entrypoint.sh,**/healthcheck.sh,**/.dockerignore,**/docker-build.yml'
---

# Docker / Bash 部署与容器约定（GTA-God）

> **Pre-flight 强制门（继承自 [copilot-instructions.md](../copilot-instructions.md)）**：改 Dockerfile / CI / 部署脚本前，经本地代理 `http://127.0.0.1:2080` 联网核实 **Docker / BuildKit、Debian slim 基镜像、rust:alpine builder、GitHub Actions、buildx、ShellCheck、ACME(DNS-01)** 的官方最新文档与推荐做法。具体版本以联网核实结果为准。

参考来源：[Dockerfile best practices](https://docs.docker.com/build/building/best-practices/)、[CIS Docker Benchmark]、[Google Shell Style Guide]、[ShellCheck](https://www.shellcheck.net/)。

## 项目红线（功能性，错则部署直接坏）

- **进程名是 `gtacore` / `gtagate`**：存活检测一律 `pgrep -x gtacore` / `pgrep -x gtagate`，**严禁** `pgrep -f sing-box`（进程已不叫 sing-box）。
- **gtacore 无 SIGHUP**：证书续期 = stop + start 重启进程，**不能** `kill -HUP`。
- **gtacore CLI**：`gtacore run --config <p> --token-file <p>`；`gtacore sing-box check/version/generate reality-keypair`；控制面 `127.0.0.1:19810` 需 token 文件（`chmod 600`）。
- **仅 linux/amd64**：bin/gtacore 是 x86_64 glibc 预构建产物 → 运行时基镜像必须 glibc（`debian:12-slim`，非 alpine/musl）。
- **真实运行标识保留**：容器名 `caddy`、目录 `caddy/`、`/data/caddy`、`singbox/config.json`、`/etc/sing-box`、`/var/log/sing-box` 是历史遗留但仍在用的真实路径/名称，**不要为"清理命名"而改**。
- **配置 KEY 名保留**：`gtagod.conf` 的变量名（`SINGBOX_LOG_LEVEL`、`DNS_*` 等）被 run.sh 白名单解析，改名即破坏——只改注释别动 KEY。
- **Windows/WSL 无 docker**：实际 `docker build`/端到端只能在 Linux 主机或 CI 验证；本机改动后明确标注"待 Linux 验证"。

## Bash 脚本约定

- 顶部 `set -euo pipefail`（或分段 `set -u` + 关键命令 `|| exit`）；变量一律加引号 `"$var"`，数组用 `"${arr[@]}"`。
- 临时文件用 `mktemp`；写配置用"写临时文件 + 原子 `mv`"，避免读到半截文件。
- 改后必须 `bash -n` 语法校验；逻辑改动过 ShellCheck（修 SC2086 未引号、SC2046 拆词等）。run.sh 是 bash；entrypoint/healthcheck 保持 sh 兼容。
- **机密安全**：不用 `sed` 把 token/key 明文插值落盘——用 `jq`/`envsubst` 安全注入；交互录入口令用 `read -s`（不回显、不落 history）；证书私钥与 deploy-info `chmod 600`。
- 禁止 `eval`/`Invoke-Expression` 拼接外部输入；外部输入先校验（白名单/正则）再用。

## Dockerfile 约定

- **多阶段**：builder（`rust:1.96-alpine`，构建 gtagate musl 静态）→ 运行时（`debian:12-slim`）；只 COPY 必要产物，最小化层。
- **可复现**：基镜像与工具链版本用 ARG pin（RUST_VERSION/ALPINE_VERSION/DEBIAN_VERSION）；apt 包固定并 `--no-install-recommends` + 清理 `/var/lib/apt/lists`。
- **加固**：尽量非 root 运行 + 仅授 `NET_BIND_SERVICE` 能力；可选只读根文件系统 + tmpfs；`HEALTHCHECK` 与 `STOPSIGNAL SIGTERM` 保留；不在镜像层残留构建期机密。
- **不硬编码机密**：构建/CI 用 Actions secrets/OIDC，不写进 Dockerfile/workflow。
- 构建后自检：`--entrypoint gtagate <image> --version`、`--entrypoint gtacore <image> sing-box version`。

## CI（GitHub Actions）约定

- action 不用浮动 `@master`/已弃用版本，pin 到稳定 tag/sha；联网步骤走代理。
- 流水线串联：构建 → 安全扫描（cargo-audit/deny）→ 镜像验证 → 按 tag 触发 release；失败即阻断合入。

## 技术债

- 遇到过时写法（`pgrep -f sing-box`、`sed` 明文插值、未引号变量、`kill -HUP` gtacore、多架构残留）优先重构为上述安全惯用法，并在 `docs/` 记录依据。
