# GTA-God Workspace Instructions

> GTA-God 是一个 **Docker 私有代理部署项目（v0.0.1，纯 Rust 架构）**。运行时镜像 `aizhihuxiao/gtagod:latest`（**仅 linux/amd64**）。两个核心组件：**gtagate**（Rust musl 网关，L4 SNI 分流 + ACME DNS-01，取代 Caddy）与 **gtacore**（预构建 Rust 二进制，sing-box 配置兼容，取代 sing-box）。本仓库的"交付物"是镜像构建链 + 部署脚本，**不是**多平台 App。

## 现代化与官方最佳实践优先（所有 agent 强制遵循）
- **所有联网必须走本地代理 `http://127.0.0.1:2080`**：任何联网动作（`@web`/web fetch、`git` fetch/push、`cargo`/`rustup` 下载、`docker pull`、`curl`/`Invoke-WebRequest` 等）**都必须经由本地代理 `http://127.0.0.1:2080`**。运行任何联网命令前，先在当前 shell 导出代理环境变量：`$env:HTTP_PROXY="http://127.0.0.1:2080"; $env:HTTPS_PROXY="http://127.0.0.1:2080"; $env:ALL_PROXY="http://127.0.0.1:2080"`（同时设置小写 `http_proxy`/`https_proxy`/`all_proxy` 与 `CARGO_HTTP_PROXY`）。**不得绕过代理直连。**
- **联网核实是动手前的强制前置门（Pre-flight Gate）**：在开始任何规划/开发/审计/修复前，**必须先联网（web / `@web`）核实**相关技术栈（Rust / Docker / BuildKit / Debian slim / GitHub Actions / ACME / ShellCheck）的官方最新稳定版文档、Release Notes、最佳实践与依赖最新版本。**未完成联网核实前，不得进入规划或编码阶段。**
- **依赖尽量用官方最新稳定版**：新增/升级依赖（Cargo crate、基镜像、Actions）优先选官方最新 **stable**（不用 nightly/pre-release/已废弃 crate），并确认其仍在积极维护。
- **采用最新现代化惯用法**：Rust 2024 edition 惯用法、Tokio async、typed Serde；Dockerfile 多阶段 + BuildKit；CI 用 pin 版 Actions。避免过时模式。
- **主动规避并优先偿还技术债**：不引入临时方案；遇到既有技术债（过时依赖、废弃 API、反模式、迁移残留如 `pgrep -f sing-box`）时**优先处理**，并在 `docs/` 记录依据。
- **变更需有依据**：升级/重构必须给出官方文档或 Release Notes 依据，并通过相应校验（`cargo fmt`/`clippy`/`test`、`bash -n`/ShellCheck、镜像自检）后才算完成。

## 项目红线（功能性，错则部署直接坏）
- **进程名 `gtacore` / `gtagate`**：存活检测一律 `pgrep -x gtacore` / `pgrep -x gtagate`，**严禁** `pgrep -f sing-box`。
- **gtacore 无 SIGHUP**：证书续期 = stop + start 重启进程，不能 `kill -HUP`。
- **gtacore CLI**：`gtacore run --config <p> --token-file <p>`（控制面 `127.0.0.1:19810`，token 文件 `chmod 600`）；`gtacore sing-box check/version/generate reality-keypair`。
- **仅 linux/amd64 + glibc**：bin/gtacore 是 x86_64 glibc 预构建产物 → 运行时基镜像必须 glibc（`debian:12-slim`）；gtagate 在 `rust:1.96-alpine` builder 内构建 musl 静态。
- **真实运行标识保留**：容器名 `caddy`、目录 `caddy/`、`/data/caddy`、`/etc/sing-box`、`/var/log/sing-box`、配置 KEY 名（`SINGBOX_LOG_LEVEL`/`DNS_*` 等被 run.sh 白名单解析）是历史遗留但仍在用的真实标识，**不要为"清理命名"而改**；只改注释别动 KEY。
- **Windows/WSL 无 docker**：实际 `docker build`/端到端只能在 Linux 主机或 CI 验证；本机改动后明确标注"待 Linux 验证"。
- **NEVER 用 PowerShell 编辑/生成项目文件**（`Out-File`/`Set-Content`/`echo >`）——会破坏 UTF-8/中文/BOM。文件改动一律用编辑器工具（`Copy-Item` 逐字节复制不受此限）。

## 工具权限词表（agent frontmatter `tools` 取值约定）
- `read` 读文件 / `search` 检索 / `web` 联网核实（强制门，所有 agent 必备） / `edit` 写文件 / `execute` 跑构建/校验 / `todo` 任务清单 / `agent` 委派子 Agent / `memory` 持久记忆读写。
- **写权限是默认而非例外**：PM 与所有需要落地交付物的角色都授予 `edit`；审查/裁决/研究类角色（Code Reviewer / Gate Reviewer / Planner）同样授予 `edit`，但**仅用于写自己的报告/计划/审计产物（`docs/`、`plans/`、`reviews/`）与记忆，严禁改产品源代码**——中立性靠行为边界约束，不靠工具级锁死。

## 模型分档（避免高峰限流，按风险/难度三档）
- 🔴 **Opus 4.8**（高风险/强判断）：PM、架构、评审、安全审计 —— 5 个。PM Orchestrator 固定 Opus 4.8。
- 🟡 **GPT-5.5**（开发实现）：网关、容器/DevOps、部署脚本、依赖现代化、性能、QA/配置校验 —— 6 个。
- 🟢 **Opus 4.6**（执行/研究）：规划、文档记忆策展、发布复盘 —— 3 个。
- 精确模型串：`Claude Opus 4.8 (copilot)` / `GPT-5.5 (copilot)` / `Claude Opus 4.6 (copilot)`。

## 持久记忆策略（所有 agent，`memory` 工具）
- **动手前先读记忆**：复用既往结论（踩过的坑、验证过的命令、基线版本、技术债清单），避免重复犯错或重复核实。
- **完成后写回记忆**：把"可复用且跨会话有价值"的结论写回——
  - 仓库级事实（v0.0.1 架构、进程名、构建命令、目录约定）→ `/memories/repo/gtagod.md`。
  - 跨工作区通用经验（Windows/WSL/代理坑、个人偏好）→ `/memories/`。
  - 当前任务在途上下文 → `/memories/session/`。
- **发现旧记忆过时即更正或删除**；结构化交付物落 `docs/`，精炼可复用要点落记忆。

## 强制工作流门（所有 Agent 继承）
1. **Pre-flight 联网核实门**：规划/开发/审计/修复前先经代理联网核实官方最新稳定版文档与依赖。
2. **官方最新最佳实践优先**：最新 stable 依赖、现代惯用法、优先偿还技术债。
3. **项目红线**：进程名 `pgrep -x`、gtacore 无 SIGHUP、glibc 运行时、保留真实运行标识、禁 PowerShell 编辑文件、镜像仅 linux/amd64。
4. **持久记忆门**：动手前读 `/memories/` 复用结论，完成后把可复用经验写回（仓库事实落 `/memories/repo/gtagod.md`）。
5. **安全门**：机密不明文落盘（禁 `sed` 插值 token/key）、容器尽量非 root + 最小能力、依赖过 `cargo-audit`/`cargo-deny`、外部输入先校验。
