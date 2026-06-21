//! 运行时配置：替代 Caddyfile 的占位符注入。
//!
//! 配置以 JSON 提供（默认 `/etc/gtagate/config.json`），敏感的 Cloudflare
//! API Token 优先从环境变量 `CLOUDFLARE_API_TOKEN` 或 `cloudflare_api_token_file`
//! 指向的文件读取，避免像旧版 `run.sh` 那样把 Token 明文 `sed` 进配置文件。

use std::collections::HashMap;
use std::path::Path;

use serde::Deserialize;

/// 顶层配置。
#[derive(Debug, Clone, Deserialize)]
#[serde(from = "RawConfig")]
pub struct Config {
    /// L4 监听地址，例如 `0.0.0.0:443`。
    pub listen: String,
    /// SNI 读取阶段的超时（秒）。
    #[serde(default = "default_dispatch_timeout")]
    pub dispatch_timeout_secs: u64,
    /// 连接上游的超时（秒）。
    #[serde(default = "default_upstream_connect_timeout")]
    pub upstream_connect_timeout_secs: u64,
    /// 双向透传缓冲区大小（字节）。
    #[serde(default = "default_copy_buffer_size")]
    pub copy_buffer_size: usize,
    /// 最大并发连接数（0 表示不限制）。
    #[serde(default = "default_max_connections")]
    pub max_connections: usize,
    /// 预计算的 SNI → 上游 O(1) 查找表（key = lowercased + trimmed trailing dot）。
    pub routes_map: HashMap<String, String>,
    /// 未命中任何路由时的默认上游。
    pub default_upstream: String,
    /// ACME 自动签发/续期配置。
    #[serde(default)]
    pub acme: Option<AcmeConfig>,
}

/// 单条 SNI → 上游映射。
#[derive(Debug, Clone, Deserialize)]
pub struct Route {
    /// 精确匹配的 SNI 主机名。
    pub sni: String,
    /// 命中后转发到的上游地址，例如 `127.0.0.1:8445`。
    pub upstream: String,
}

/// ACME 配置。
#[derive(Debug, Clone, Deserialize)]
pub struct AcmeConfig {
    #[serde(default = "default_true")]
    pub enabled: bool,
    /// 申请证书的域名列表（支持泛域名 `*.example.com`）。
    pub domains: Vec<String>,
    /// 账户联系邮箱。
    pub email: String,
    /// CA：`letsencrypt` | `letsencrypt-staging` | `zerossl` | `buypass` | 完整 directory URL。
    #[serde(default = "default_ca")]
    pub ca: String,
    /// Cloudflare API Token（明文，仅用于测试；生产用 env 或 token_file）。
    #[serde(default)]
    pub cloudflare_api_token: Option<String>,
    /// 从文件读取 Cloudflare API Token（推荐，配合 Docker secret）。
    #[serde(default)]
    pub cloudflare_api_token_file: Option<String>,
    /// 证书输出根目录，需与 entrypoint 的 find_certificate 兼容。
    #[serde(default = "default_cert_dir")]
    pub cert_dir: String,
    /// 距到期多少天内触发续期。
    #[serde(default = "default_renew_days")]
    pub renew_before_days: i64,
    /// 写入 TXT 记录后、通知 CA 校验前等待 TXT 可查询的最长时间（秒）。
    #[serde(default = "default_propagation")]
    pub dns_propagation_secs: u64,
}

impl Config {
    /// 从 JSON 文件加载配置。
    pub fn load(path: &Path) -> anyhow::Result<Self> {
        let raw = std::fs::read_to_string(path)
            .map_err(|e| anyhow::anyhow!("读取配置文件 {} 失败: {e}", path.display()))?;
        let cfg: Config = serde_json::from_str(&raw)
            .map_err(|e| anyhow::anyhow!("解析配置文件 {} 失败: {e}", path.display()))?;

        // 配置校验：防止误配导致 OOM 或全面瘫痪
        if cfg.copy_buffer_size == 0 {
            anyhow::bail!("copy_buffer_size 不能为 0");
        }
        if cfg.copy_buffer_size > 4 * 1024 * 1024 {
            anyhow::bail!(
                "copy_buffer_size ({}) 超过上限 4MB",
                cfg.copy_buffer_size
            );
        }
        if cfg.dispatch_timeout_secs == 0 {
            anyhow::bail!("dispatch_timeout_secs 不能为 0");
        }
        if cfg.upstream_connect_timeout_secs == 0 {
            anyhow::bail!("upstream_connect_timeout_secs 不能为 0");
        }

        Ok(cfg)
    }

    /// 按 SNI 精确匹配上游，未命中返回默认上游。
    /// 自动 normalize trailing dot 以兑容 FQDN 形式配置。
    pub fn upstream_for(&self, sni: Option<&str>) -> &str {
        if let Some(name) = sni {
            let name = name.trim_end_matches('.');
            for route in &self.routes {
                let route_sni = route.sni.trim_end_matches('.');
                if route_sni.eq_ignore_ascii_case(name) {
                    return &route.upstream;
                }
            }
        }
        &self.default_upstream
    }
}

impl AcmeConfig {
    /// 解析最终生效的 Cloudflare API Token：env > 明文字段 > 文件。
    pub fn resolve_token(&self) -> anyhow::Result<String> {
        if let Ok(token) = std::env::var("CLOUDFLARE_API_TOKEN") {
            let token = token.trim().to_string();
            if !token.is_empty() {
                return Ok(token);
            }
        }
        if let Some(token) = &self.cloudflare_api_token {
            let token = token.trim().to_string();
            if !token.is_empty() {
                return Ok(token);
            }
        }
        if let Some(path) = &self.cloudflare_api_token_file {
            let token = std::fs::read_to_string(path)
                .map_err(|e| anyhow::anyhow!("读取 Cloudflare token 文件 {path} 失败: {e}"))?;
            let token = token.trim().to_string();
            if !token.is_empty() {
                return Ok(token);
            }
        }
        anyhow::bail!(
            "未找到 Cloudflare API Token（设置环境变量 CLOUDFLARE_API_TOKEN，或配置 cloudflare_api_token_file）"
        )
    }

    /// 将 `ca` 关键字解析为 ACME directory URL。
    pub fn directory_url(&self) -> String {
        match self.ca.to_ascii_lowercase().as_str() {
            "letsencrypt" | "le" => "https://acme-v02.api.letsencrypt.org/directory".to_string(),
            "letsencrypt-staging" | "staging" => {
                "https://acme-staging-v02.api.letsencrypt.org/directory".to_string()
            }
            "zerossl" => "https://acme.zerossl.com/v2/DV90".to_string(),
            "buypass" => "https://api.buypass.com/acme/directory".to_string(),
            other if other.starts_with("http://") || other.starts_with("https://") => {
                self.ca.clone()
            }
            _ => "https://acme-v02.api.letsencrypt.org/directory".to_string(),
        }
    }

    /// 证书存储目录中使用的 CA 标签子目录名。
    pub fn ca_label(&self) -> &str {
        match self.ca.to_ascii_lowercase().as_str() {
            "letsencrypt-staging" | "staging" => "letsencrypt-staging",
            "zerossl" => "zerossl",
            "buypass" => "buypass",
            _ => "letsencrypt",
        }
    }
}

fn default_dispatch_timeout() -> u64 {
    10
}

fn default_upstream_connect_timeout() -> u64 {
    10
}

fn default_copy_buffer_size() -> usize {
    64 * 1024
}

fn default_max_connections() -> usize {
    8192
}

fn default_true() -> bool {
    true
}

fn default_ca() -> String {
    "letsencrypt".to_string()
}

fn default_cert_dir() -> String {
    "/data/caddy/certificates".to_string()
}

fn default_renew_days() -> i64 {
    30
}

fn default_propagation() -> u64 {
    60
}
