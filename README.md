# GTAGod - Caddy NaiveProxy + AnyTLS + AnyReality

一键部署 Caddy + NaiveProxy + AnyTLS + AnyReality 的 Docker 解决方案。

支持多协议共享 443 端口，通过 Caddy Layer4 SNI 分流。

## 🎉 v4.1 更新

- **依赖全面升级** - Go 1.26, Alpine 3.23, xcaddy v0.4.5, Caddy v2.11.2, sing-box 1.13.9
- **sing-box 1.13+ 原生 naive inbound** - 移除 Caddy forwardproxy 依赖
- **kernel_tx (kTLS)** - 启用内核级 TLS 发送加速，降低 CPU 开销
- **配置模板修复** - 兼容 sing-box 1.13.9，并迁移到 1.14 兼容 DNS 写法
- **容器稳定性提升** - 修复多个启动问题

## 特性

- ✅ **NaiveProxy** - sing-box 1.13+ 原生 naive inbound，伪装成正常 HTTPS 流量
- ✅ **AnyTLS** - sing-box 的 TLS 隧道协议，需要证书
- ✅ **AnyReality** - AnyTLS + Reality TLS，无需证书，伪装知名网站
- ✅ **自动证书** - 基于 Cloudflare DNS 的通配符证书，支持多 CA 自动切换
- ✅ **443 共享** - 所有协议通过 Caddy L4 共享 443 端口
- ✅ **一键部署** - 交互式脚本，3 分钟完成部署

## 架构图 (v4.0)

```
┌────────────────────────────────────────────────────────────────────────────┐
│                            Cloud Server                                    │
│                                                                            │
│    Internet ──▶ 外部端口 443 (0.0.0.0:443)                                 │
│                         │                                                  │
│              ┌──────────┴──────────┐                                       │
│              │   Caddy Layer4      │                                       │
│              │   SNI 分流           │                                       │
│              └──────────┬──────────┘                                       │
│         ┌───────────────┼───────────────┐                                  │
│         │               │               │                                  │
│         ▼               ▼               ▼                                  │
│  ┌────────────┐  ┌────────────┐  ┌────────────────┐                        │
│  │ ANYTLS_SNI │  │ANYREAL_SNI │  │   其他所有 SNI  │                        │
│  │api.domain  │  │amazon.com  │  │ *.domain.com   │                        │
│  │     │      │  │     │      │  │       │        │                        │
│  │     ▼      │  │     ▼      │  │       ▼        │                        │
│  │ :8445      │  │ :8444      │  │ :8443          │                        │
│  │ (sing-box) │  │ (sing-box) │  │ (sing-box)     │                        │
│  │  AnyTLS    │  │ AnyReality │  │  Naive         │                        │
│  └────────────┘  └────────────┘  └────────────────┘                        │
│         │               │               │                                  │
│         └───────────────┴───────────────┘                                  │
│                         │                                                  │
│                         ▼                                                  │
│                ┌─────────────────┐                                         │
│                │    sing-box     │                                         │
│                │  Direct Outbound│──────────────▶ Internet                 │
│                └─────────────────┘                                         │
└────────────────────────────────────────────────────────────────────────────┘
```

## 快速开始

### 前置要求

1. 一台 Linux 服务器 (Ubuntu 22.04 / Debian 12 推荐)
2. 一个域名，DNS 托管在 Cloudflare
3. Cloudflare API Token (Zone DNS 编辑权限)

## 部署前必读

- `run.sh` 默认仍会按这个项目的既有部署假设工作：自动安装 Docker、关闭宿主机防火墙、关闭宿主机 IPv6、调整 DNS 到 IPv4 优先，并启动 `watchtower`。
- `run.sh` 默认也会应用宿主机网络优化，包括 BBR 和一组 TCP/sysctl 调优，以性能和稳定性优先。
- Docker 容器共享宿主机 Linux 内核；镜像基础层只能更新容器内 Alpine 用户态包。若你要修复 Linux 内核漏洞，必须升级宿主机系统内核并重启 VPS。
- Dockerfile 已固定到当前最新稳定 Alpine 3.23，并在 builder/runtime 阶段执行 `apk upgrade --no-cache`，让镜像构建时拉取该发行版最新安全修复。
- 显式开关还保留着；如果你确实有特殊环境，可以再通过 `HOST_IPV6_TUNING`、`HOST_DNS_TUNING`、`HOST_NETWORK_OPTIMIZATION`、`HOST_FIREWALL_MANAGEMENT`、`PREPARE_HOST_SYSTEM`、`AUTO_INSTALL_DOCKER`、`ENABLE_WATCHTOWER` 手动改回去。
- `gtagod.conf` 应按纯 `KEY=value` 配置文件维护，不要写 shell 语句、命令替换或函数，也不要直接复用来路不明的配置。
- 部署过程中会把域名、Token、认证信息和 Reality 密钥写入生成配置；`gtagod.conf`、`caddy/`、`singbox/` 目录都应视为敏感数据。

### 方式一: 配置文件部署 (推荐)

```bash
# 1. 复制配置模板
cp gtagod.conf.example gtagod.conf

# 2. 编辑配置文件
nano gtagod.conf

# 3. 运行部署
chmod +x run.sh
./run.sh
```

### 方式二: 交互式部署

```bash
chmod +x run.sh
./run.sh
```

按提示输入配置信息即可。

### 命令行选项

```bash
./run.sh                    # 自动检测配置文件，无则交互
./run.sh [mode]             # 指定部署模式 (naive/anytls/anyreality/l4)
./run.sh -c config.conf     # 使用指定配置文件
./run.sh -i                 # 强制交互模式
./run.sh --preflight        # 仅执行部署前自检
./run.sh --help             # 显示帮助
```

## 部署模式

| 模式 | 对外端口 | 说明 |
|------|---------|-----|
| `naive` | 443 | 仅 NaiveProxy |
| `anytls` | 443 | NaiveProxy + AnyTLS (L4 SNI 分流) |
| `anyreality` | 443 | NaiveProxy + AnyReality (L4 SNI 分流) |
| `l4` | **443** | **全部启用，443 共享** (推荐) |

> **架构说明 (v4.0)**: 
> - **全部协议共享 443 端口**，通过 Caddy Layer4 SNI 分流
> - **全部代理由 sing-box 1.13+ 处理** (包括 NaiveProxy)
> - NaiveProxy: 任意 `*.domain.com` 子域名 (默认路由)
> - AnyTLS: 特定 SNI (如 `api.domain.com`)
> - AnyReality: 特定 SNI (如 `www.amazon.com`)
> - 内部端口：Naive :8443，AnyTLS :8445，AnyReality :8444

## 文件说明

| 文件 | 说明 |
|------|-----|
| `run.sh` | 统一部署脚本 |
| `gtagod.conf.example` | 配置文件模板 |
| `gtagod.conf` | 个人配置文件 (敏感，已在 .gitignore) |
| `Dockerfile` | Docker 构建文件 |
| `docker-entrypoint.sh` | 容器入口脚本 |
| `Caddyfile.singbox.example` | Caddy L4 配置模板 (sing-box 统一架构) |
| `Caddyfile.reality.example` | Caddy 配置模板 (旧版，兼容) |
| `singbox-config.l4.example` | sing-box L4 三合一配置模板 |
| `singbox-config.naive.example` | sing-box Naive-only 配置模板 |
| `singbox-config.anytls.example` | sing-box AnyTLS 配置模板 |
| `singbox-config.anyreality.example` | sing-box AnyReality 配置模板 (旧版，兼容) |

## 高级配置

可在 [gtagod.conf.example](gtagod.conf.example) 中配置：

- `PREPARE_HOST_SYSTEM`：是否初始化宿主机时区、依赖和时间同步，默认开启。
- 若系统升级包含 Linux 内核更新，必须重启宿主机后才会生效；`run.sh` 会提示 reboot-required 标记。
- `AUTO_INSTALL_DOCKER`：未安装 Docker 时是否自动安装，默认开启。
- `HOST_IPV6_TUNING`：是否真正修改宿主机 IPv6 配置，默认开启。
- `HOST_DNS_TUNING`：是否修改宿主机 `/etc/gai.conf` 和 `/etc/resolv.conf`，默认开启。
- `HOST_NETWORK_OPTIMIZATION`：是否写入 BBR / TCP sysctl 优化，默认开启。
- `HOST_FIREWALL_MANAGEMENT`：是否禁用宿主机防火墙并清空 iptables，默认开启。
- `ENABLE_WATCHTOWER`：是否启动 Watchtower 自动更新容器，默认开启。
- `CONTAINER_GOMEMLIMIT`：容器内 Go 运行时内存上限，默认 `384MiB`。
- `CONTAINER_PIDS_LIMIT`：容器进程数限制，默认 `512`。
- `CONTAINER_TMPFS_SIZE`：容器 `/tmp` 的 tmpfs 大小，默认 `64m`。
- `CONTAINER_LOG_MAX_SIZE`：Docker 日志轮转单文件大小，默认 `10m`。
- `CONTAINER_LOG_MAX_FILE`：Docker 日志轮转保留文件数，默认 `3`。
- `ENABLE_MPTCP`：控制 `tcp_multi_path`，默认关闭，仅在内核支持 MPTCP 时开启。
- `ENABLE_KTLS`：控制 `kernel_tx`，默认关闭。开启可降低 TLS 发送 CPU 开销，要求宿主机内核 >= 4.13 且支持 kTLS。
- `CERT_WAIT_MAX`：首次等待证书时长（秒），默认 180。
- `CERT_RETRY_INTERVAL`：证书重试间隔（秒），默认 30。
- `CERT_RETRY_MAX`：证书重试次数上限（0 表示无限重试）。

## 项目体检结论 (2026-03-11)

这部分基于脚本、Dockerfile、配置模板和 CI 文件的实际检查整理，不以旧文档描述作为依据。

- 当前主链路是成立的：镜像构建、容器入口脚本、L4 分流模板和 GitHub Actions 的验证逻辑基本一致。
- Caddy 当前建议至少跟进到 `v2.11.2`；`v2.11.1` 之后官方补了 bugfix 和安全修复，尤其是若未来恢复 HTTP 反代或 `forward_auth` 场景时更有必要同步。
- 示例配置里原先使用的 `dns.rules -> outbound: any` 已经是 1.12 起废弃、1.14 将移除的写法；现在应统一迁移到 `route.default_domain_resolver`。
- `Caddyfile.singbox.example` 里原先全局 `acme_dns` 和站点内 `tls { dns ... }` 是重复配置；按官方文档保留全局 DNS 提供者即可，后续若要启用 ECH 也能直接复用。
- `build-and-push.sh` 原先的本地镜像校验命令没有覆盖镜像 `ENTRYPOINT`，实际上不能正确执行 `caddy version` 和 `sing-box version`；这一点已修正。
- `docker-entrypoint.sh` 仅校验 Caddyfile 还不够，启动前还应执行 `sing-box check`；这样能在证书就绪后先拦住配置错误，而不是等进程直接拉起失败。
- `run.sh` 现在把宿主机动作拆成了显式开关，但默认值仍保持项目原有部署前提：自动装 Docker、关闭防火墙、关闭 IPv6、应用网络优化、启动 Watchtower；只有在配置中主动关闭时，才会跳过这些步骤。
- `run.sh` 当前已不再对 `caddy/` 和 `singbox/` 目录执行 `chmod -R 777`，改为较收敛的目录和文件权限。
- 容器运行参数还有一轮收敛：现在会用 `--init` 处理僵尸进程、把 `/tmp` 挂成 tmpfs、开启 `no-new-privileges`，并把 `GOMEMLIMIT`、日志轮转和 PIDs 限制做成可配置项。
- `run.sh` 现在会在真正部署前自动执行一轮 preflight，自检 root 权限、Cloudflare Token、域名解析、模板占位符、JSON 格式、关键端口占用、目录写权限，以及 `GOMEMLIMIT`、PIDs、tmpfs、日志轮转这些容器参数的取值；如果本地镜像已存在，还会调用镜像内的 `caddy` 和 `sing-box` 做语法级校验，并检查 Docker Hub 上的镜像可达性。也可以单独运行 `./run.sh --preflight` 只做检查不部署。
- `run.sh` 现在不再 `source` 配置文件，而是只按白名单解析 `KEY=value` 项，避免把 `gtagod.conf` 当成 shell 直接执行。
- `run.sh` 仍通过 `curl https://get.docker.com | sh` 安装 Docker。对于追求可审计和可重复部署的环境，后续建议切换到发行版包源或明确版本安装。
- `gtagod.conf` 虽然默认被 `.gitignore` 忽略，但里面通常包含 Cloudflare Token、Naive 凭据和 Reality 私钥，仍建议长期放在仓库目录之外，或改用环境变量、单独密钥文件管理。

如果后续继续演进，建议优先处理这三件事：

1. 把模板替换从 `sed` 逐步收敛到更可控的方式，例如结构化模板渲染。
2. 继续减少明文凭据落盘范围，例如把 Token 和私钥改成运行时注入，而不是长期保存在工作目录。
3. 如果未来要跟进 1.14 正式版，优先关注 DNS 解析链路和 deprecated 项清理，不建议提前切到 1.14 alpha 做生产默认版本。

## 文档

- [CLIENT.md](CLIENT.md) - 客户端连接指南
- [FRIEND-GUIDE.md](FRIEND-GUIDE.md) - 朋友部署指南

## 版本历史

### v4.1.0 (2026-01-01)
- 🔧 **依赖升级到最新稳定版**:
  - Go 1.24 → **Go 1.26** (稳定工具链，默认安全与性能优化)
  - Alpine 3.21 → **Alpine 3.23** (当前 Docker Hub latest 稳定版，构建时执行 apk upgrade)
  - xcaddy v0.4.4 → **xcaddy v0.4.5** (bug 修复)
  - Caddy → **v2.11.2** (补充 bugfix 与安全修复)
  - sing-box → **1.13.9** (musl 版本，原生 naive inbound)
- ⚡ **kTLS (kernel_tx)**:
  - 默认关闭 (`ENABLE_KTLS="false"`)，避免容器内缺少 `/lib/modules` 导致握手失败
  - 开启时自动在宿主机执行 `modprobe tls` 并挂载 `/lib/modules` 到容器
  - 要求宿主机内核 >= 4.13 且编译了 `CONFIG_TLS` 模块
- 🐛 **修复 sing-box 1.13.9 / 1.14 配置兼容性**:
  - 移除废弃的 `sniff` 和 `sniff_override_destination` 字段 (1.11.0 废弃，1.13.x 已移除)
  - 将废弃的 `dns.rules.outbound` 迁移到 `route.default_domain_resolver`，避免 1.14 升级时报错
  - 补全所有模板的 `outbounds` 配置
- 🐛 **修复 Caddyfile 端口冲突**:
  - HTTPS 证书申请站点改为 `:8888` 端口，避免与 Layer4 `:443` 冲突
  - 移除 `proxy_protocol v2` (sing-box 不支持)
- 🐛 **修复容器启动问题**:
  - 移除 `set -e` 避免脚本意外退出
  - 使用 POSIX sh 兼容语法 (Alpine 使用 ash 而非 bash)
- 📝 更新所有 sing-box 配置模板

### v4.0.0 (2025-01-14)
- 🚀 **sing-box 1.13+ 原生 naive inbound** - 移除 Caddy forwardproxy 依赖
- ✨ 统一由 sing-box 处理所有代理协议 (naive/anytls/anyreality)
- 🔧 Caddy 简化为仅 L4 分流 + 证书申请
- 📦 Docker 镜像体积更小，构建更快
- 🔧 Go 1.24 + Alpine 3.21 基础镜像
- 📝 新增 singbox-config.l4.example 和 singbox-config.naive.example
- 📝 新增 Caddyfile.singbox.example 配置模板

### v3.0.0 (2025-12-05)
- 🚀 **全 443 端口架构** - 所有协议共享 443 端口
- ✨ NaiveProxy 改为 L4 默认路由，支持任意子域名
- 🔧 移除独立 8443 端口，简化部署
- 📝 更新所有文档和配置模板

## 常见问题

### 部署后连接失败？

**最常见原因：证书尚未申请完成**

通配符证书需要通过 Cloudflare DNS 验证，首次申请可能需要 1-3 分钟。如果部署后立即连接失败，请：

1. **查看证书状态**：
```bash
ls -la caddy/data/caddy/certificates/
```

2. **等待证书申请完成后重启容器**：
```bash
docker restart caddy
```

3. **确认 sing-box 启动成功**：
```bash
docker exec caddy pgrep -f sing-box
```

> ⚠️ **重要提示**：脚本默认等待证书 180 秒，超时后容器会按配置自动重试（无需手动重启）。如需调整等待/重试策略，请修改 `CERT_WAIT_MAX`、`CERT_RETRY_INTERVAL`、`CERT_RETRY_MAX`。

### 证书申请失败？

Caddy 支持多个 CA:
1. ZeroSSL (默认)
2. Let's Encrypt

如果申请失败，请检查：
- Cloudflare Token 是否有 Zone DNS 编辑权限
- 域名是否正确托管在 Cloudflare

可以通过配置文件强制切换 CA：
```bash
# gtagod.conf
FORCE_ACME_CA=letsencrypt  # 或 zerossl
```

### sing-box 未启动？

AnyTLS 需要证书才能启动。如果 sing-box 报错找不到证书文件：

1. 确认证书已申请成功
2. 重启容器：`docker restart caddy`

AnyReality 使用 Reality TLS，不需要本地证书，应该能立即启动。

### 如何更新？

```bash
docker pull aizhihuxiao/gtagod:latest
docker restart caddy
```

## License

MIT
