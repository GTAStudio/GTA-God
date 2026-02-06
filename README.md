# GTAGod - Caddy NaiveProxy + AnyTLS + AnyReality

一键部署 Caddy + NaiveProxy + AnyTLS + AnyReality 的 Docker 解决方案。

支持多协议共享 443 端口，通过 Caddy Layer4 SNI 分流。

## 🎉 v4.1 更新

- **依赖全面升级** - Go 1.25, Alpine 3.23, xcaddy v0.4.5, sing-box 1.13.0-rc.2
- **sing-box 1.13+ 原生 naive inbound** - 移除 Caddy forwardproxy 依赖
- **kernel_tx (kTLS)** - 启用内核级 TLS 发送加速，降低 CPU 开销
- **配置模板修复** - 兼容 sing-box 1.13.0 最新 API
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

- `ENABLE_MPTCP`：控制 `tcp_multi_path`，默认关闭，仅在内核支持 MPTCP 时开启。
- `CERT_WAIT_MAX`：首次等待证书时长（秒），默认 180。
- `CERT_RETRY_INTERVAL`：证书重试间隔（秒），默认 30。
- `CERT_RETRY_MAX`：证书重试次数上限（0 表示无限重试）。

## 文档

- [CLIENT.md](CLIENT.md) - 客户端连接指南
- [FRIEND-GUIDE.md](FRIEND-GUIDE.md) - 朋友部署指南

## 版本历史

### v4.1.0 (2026-01-01)
- 🔧 **依赖升级到最新稳定版**:
  - Go 1.24 → **Go 1.25** (容器感知 GOMAXPROCS、DWARF5 调试信息)
  - Alpine 3.21 → **Alpine 3.23** (apk-tools v3、curl HTTP/3、GCC 15)
  - xcaddy v0.4.4 → **xcaddy v0.4.5** (bug 修复)
  - sing-box → **1.13.0-rc.2** (musl 版本，原生 naive inbound)
- ⚡ **启用 kernel_tx (kTLS TX)**:
  - 所有非 Reality 的 TLS inbound 添加 `"kernel_tx": true`
  - Linux 5.1+ / TLS 1.3 下内核通过 splice(2) 零拷贝发送加密数据
  - 降低用户态↔内核态切换开销，提升吞吐量
- 🐛 **修复 sing-box 1.13.0 配置兼容性**:
  - 移除废弃的 `sniff` 和 `sniff_override_destination` 字段 (1.11.0 废弃，1.13.0 已移除)
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
