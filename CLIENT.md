# GTAGod 客户端连接指南

本文档介绍如何在各种客户端上配置 GTAGod 部署的代理服务。

## 目录

- [NaiveProxy 客户端](#naiveproxy-客户端)
- [AnyTLS 客户端](#anytls-客户端)
- [AnyReality 客户端](#anyreality-客户端)
- [通用配置说明](#通用配置说明)

---

## NaiveProxy 客户端

NaiveProxy 使用 Chromium 的网络栈，伪装成正常的 HTTPS 流量。

### 连接信息

| 参数 | 值 |
|------|---|
| 协议 | naive+https |
| 地址 | `任意 *.domain.com 子域名` (如 `proxy.example.com`, `www.example.com`) |
| 端口 | **443** |
| 用户名 | 你的用户名 |
| 密码 | 你的密码 |

> **说明**: L4 模式下 NaiveProxy 是默认路由，可以使用任意 `*.domain.com` 子域名连接。强制 TLS 1.3，性能最优。

### Windows / macOS / Linux

使用 [NaiveProxy](https://github.com/klzgrad/naiveproxy) 官方客户端：

```json
{
  "listen": "socks://127.0.0.1:1080",
  "proxy": "https://用户名:密码@任意子域名.example.com"
}
```

> **注意**: 可以使用 `proxy.example.com`、`www.example.com`、`abc.example.com` 等任意子域名，端口 443 可省略。

运行：
```bash
./naive config.json
```

### Android - NekoBox

1. 打开 NekoBox
2. 点击 **+** → **手动配置** → **NaiveProxy**
3. 填写：
   - 服务器: `任意子域名.example.com`
   - 端口: `443`
   - 用户名: `你的用户名`
   - 密码: `你的密码`
   - SNI: (与服务器地址相同)

### iOS - Shadowrocket

1. 打开 Shadowrocket
2. 点击 **+** → 类型选择 **Naive**
3. 填写：
   - 地址: `任意子域名.example.com`
   - 端口: `443`
   - 用户名: `你的用户名`
   - 密码: `你的密码`
   - TLS: 开启
   - SNI: (与地址相同)

---

## AnyTLS 客户端
AnyTLS 是 sing-box 的 TLS 隧道协议，需要服务器证书。

### 连接信息

| 参数 | 值 |
|------|---|
| 协议 | anytls |
| 地址 | `服务器IP` 或 `你的域名` |
| 端口 | **443** (L4分流模式) |
| SNI | `你配置的 ANYTLS_SNI` (如 `api.example.com`) |
| 密码 | 你的密码 |
| TLS 版本 | TLS 1.3 (服务端已强制) |

> **重要**: SNI 必须是你自己域名的子域名，因为 AnyTLS 使用真实证书验证。

### sing-box 客户端配置

```json
{
  "outbounds": [
    {
      "type": "anytls",
      "tag": "anytls-out",
      "server": "服务器IP",
      "server_port": 443,
      "password": "你的密码",
      "tls": {
        "enabled": true,
        "server_name": "你配置的 ANYTLS_SNI",
        "insecure": false
      },
      "idle_session_check_interval": "30s",
      "idle_session_timeout": "300s"
    }
  ]
}
```

### Windows - NekoRay / sing-box GUI

1. 添加新节点 → 类型选择 **AnyTLS**
2. 填写：
   - 服务器: `服务器IP`
   - 端口: `443`
   - 密码: `你的密码`
   - TLS SNI: `你配置的 ANYTLS_SNI`

### Android - NekoBox / sing-box for Android

1. 添加新节点 → **sing-box** → **AnyTLS**
2. 按照上面的参数填写（端口使用 443）

---

## AnyReality 客户端

AnyReality = AnyTLS + Reality TLS。使用 Reality 协议伪装 TLS 握手，无需真实证书。

### 连接信息

| 参数 | 值 |
|------|---|
| 协议 | anytls + reality |
| 地址 | `服务器IP` 或 `你的域名` |
| 端口 | **443** (L4分流模式) |
| SNI | `你配置的 ANYREALITY_SNI` (如 `www.catalog.update.microsoft.com`) |
| 密码 | 你的密码 |
| Reality 公钥 | `从服务器获取` |
| Reality ShortID | `从服务器获取` |

> **重要**: SNI 必须与服务器 Caddyfile 和 sing-box 配置中的 SNI 完全一致！

### sing-box 客户端配置

```json
{
  "outbounds": [
    {
      "type": "anytls",
      "tag": "anyreality-out",
      "server": "服务器IP",
      "server_port": 443,
      "password": "你的密码",
      "tls": {
        "enabled": true,
        "server_name": "你配置的 ANYREALITY_SNI",
        "reality": {
          "enabled": true,
          "public_key": "从服务器获取的公钥",
          "short_id": "从服务器获取的ShortID"
        }
      },
      "idle_session_check_interval": "30s",
      "idle_session_timeout": "300s"
    }
  ]
}
```

> **注意**: `server_name` 必须与服务器配置中的 `ANYREALITY_SNI` 完全一致！

### Windows - NekoRay / sing-box GUI

1. 添加新节点 → 类型选择 **AnyTLS**
2. 填写：
   - 服务器: `服务器IP`
   - 端口: `443`
   - 密码: `你的密码`
   - TLS SNI: `你配置的 ANYREALITY_SNI`
3. 开启 **Reality**：
   - 公钥: `从服务器获取的公钥`
   - ShortID: `从服务器获取的ShortID`

### Android - NekoBox / sing-box for Android

1. 添加新节点 → **sing-box** → **AnyTLS**
2. 开启 Reality 选项
3. 填写公钥和 ShortID

---

## 通用配置说明

### 端口说明 (v4.0 架构)

| 协议 | 对外端口 | 内部端口 | SNI | 后端 |
|------|---------|---------|-----|-----|
| NaiveProxy | **443** | 8443 | `*.your-domain.com` | sing-box native naive |
| AnyTLS | **443** | 8445 | `你配置的 ANYTLS_SNI` | sing-box anytls |
| AnyReality | **443** | 8444 | `你配置的 ANYREALITY_SNI` | sing-box anytls+reality |

> **v4.0 说明**: 
> - 所有协议统一使用 **443 端口**，通过 Caddy L4 SNI 分流
> - 所有代理协议都由 **sing-box 1.13+** 处理（包括 NaiveProxy）
> - Caddy 仅负责 L4 分流和 TLS 证书申请

### L4 分流模式 (全 443 共享)

当服务器使用 L4 分流模式时：

- **NaiveProxy**: 使用 **443 端口**，SNI 为任意 `*.domain.com` 子域名，作为默认路由
- **AnyTLS**: 使用 **443 端口**，SNI 为你配置的 `ANYTLS_SNI` (如 `api.example.com`)
- **AnyReality**: 使用 **443 端口**，SNI 为你配置的 `ANYREALITY_SNI` (如 `www.amazon.com`)

服务器通过 SNI 识别并路由到正确的后端服务（都是 sing-box 的不同 inbound）。

> **重要**: AnyReality 的 SNI 必须三处一致：
> 1. Caddyfile 中的 `@anyreality tls sni`
> 2. sing-box 配置中的 `server_name`
> 3. 客户端配置中的 SNI

### 推荐客户端

| 平台 | 推荐客户端 | 支持协议 |
|------|-----------|---------|
| Windows | NekoRay, sing-box GUI | NaiveProxy, AnyTLS, AnyReality |
| macOS | sing-box, Surge | NaiveProxy, AnyTLS, AnyReality |
| Linux | sing-box | NaiveProxy, AnyTLS, AnyReality |
| Android | NekoBox | NaiveProxy, AnyTLS, AnyReality |
| iOS | Shadowrocket, Stash | NaiveProxy, AnyTLS |

### 性能建议

1. **隐蔽优先**: 使用 AnyReality (伪装知名网站，无需证书)
2. **稳定优先**: 使用 AnyTLS (真实证书验证)
3. **兼容性优先**: 使用 NaiveProxy (任意子域名，默认路由)

> **v4.0 说明**: 所有协议现在都由 sing-box 1.13+ 统一处理，性能差异主要来自于 TLS 握手方式。

### TLS 版本说明

服务端已强制使用 **TLS 1.3**，客户端需要支持 TLS 1.3：
- NaiveProxy 官方客户端：默认支持
- NekoBox / NekoRay：默认支持
- Shadowrocket：默认支持
- sing-box：默认支持

---

## 常见问题

### Q: 连接超时怎么办？
A: 检查服务器防火墙/安全组是否开放对应端口。

### Q: Reality 公钥在哪里获取？
A: 部署脚本执行完成后会显示公钥，也可以查看 `./caddy/deploy-info.txt`。

### Q: 可以同时使用多个协议吗？
A: 可以，在客户端添加多个节点即可。

### Q: 如何测试连接？
A: 
```bash
# 测试 NaiveProxy
curl -x socks5://127.0.0.1:1080 https://httpbin.org/ip

# 测试 AnyTLS/AnyReality (通过 sing-box)
sing-box run -c config.json
```
