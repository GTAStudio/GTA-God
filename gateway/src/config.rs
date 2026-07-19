//! 运行时配置：替代 Caddyfile 的占位符注入。
//!
//! 配置以 JSON 提供（默认 `/etc/gtagate/config.json`），敏感的 Cloudflare
//! API Token 优先从环境变量 `CLOUDFLARE_API_TOKEN` 或 `cloudflare_api_token_file`
//! 指向的文件读取，避免像旧版 `run.sh` 那样把 Token 明文 `sed` 进配置文件。

use std::borrow::Cow;
use std::collections::{HashMap, HashSet};
use std::net::SocketAddr;
use std::path::Path;

use serde::Deserialize;

/// 顶层配置。
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
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
    /// 尚未完成 ClientHello 的最大并发连接数（0 表示不限制）。
    #[serde(default = "default_max_handshake_connections")]
    pub max_handshake_connections: usize,
    /// 已建立转发连接的双向字节空闲超时（秒，0 表示禁用）。
    #[serde(default = "default_relay_idle_timeout")]
    pub relay_idle_timeout_secs: u64,
    /// SNI 路由表（来自 JSON）。`sni` 支持精确主机名，或 `*.example.com`
    /// 形式的通配（恰好匹配一层子域名，与泛域名证书语义一致）。
    #[serde(default)]
    pub routes: Vec<Route>,
    /// 未命中任何路由时的默认上游。
    pub default_upstream: String,
    /// ACME 自动签发/续期配置。
    #[serde(default)]
    pub acme: Option<AcmeConfig>,
    /// 预计算的精确 SNI → 上游 O(1) 查找表（key = lowercased + trimmed trailing dot）。
    /// 由 `load()` 在加载后构建，不参与反序列化。
    #[serde(skip)]
    routes_map: HashMap<String, String>,
    /// 预计算的通配路由：`(base, 上游)`，base 为去掉 `*.` 前缀后的根域
    /// （如 `example.com`）。仅匹配恰好一层子域名。由 `load()` 构建。
    #[serde(skip)]
    wildcard_routes: Vec<(String, String)>,
}

/// 单条 SNI → 上游映射。
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Route {
    /// 匹配的 SNI 主机名：精确（`api.example.com`）或通配（`*.example.com`，
    /// 恰好匹配一层子域名）。精确匹配优先于通配。
    pub sni: String,
    /// 命中后转发到的上游地址，例如 `127.0.0.1:8445`。
    pub upstream: String,
}

/// ACME 配置。
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AcmeConfig {
    #[serde(default = "default_true")]
    pub enabled: bool,
    /// 申请证书的域名列表（支持泛域名 `*.example.com`）。
    pub domains: Vec<String>,
    /// 账户联系邮箱。
    pub email: String,
    /// CA：`letsencrypt` | `letsencrypt-staging`。
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
        let mut cfg: Config = serde_json::from_str(&raw)
            .map_err(|e| anyhow::anyhow!("解析配置文件 {} 失败: {e}", path.display()))?;

        cfg.validate()?;

        // 预计算路由查找表（精确 + 通配）。
        cfg.build_route_indices();

        Ok(cfg)
    }

    /// 配置校验：防止误配导致 OOM、panic 或全面瘫痪。
    fn validate(&self) -> anyhow::Result<()> {
        validate_socket_addr("listen", &self.listen)?;
        validate_socket_addr("default_upstream", &self.default_upstream)?;
        if self.copy_buffer_size == 0 {
            anyhow::bail!("copy_buffer_size 不能为 0");
        }
        if self.copy_buffer_size > 4 * 1024 * 1024 {
            anyhow::bail!("copy_buffer_size ({}) 超过上限 4MB", self.copy_buffer_size);
        }
        if self.dispatch_timeout_secs == 0 {
            anyhow::bail!("dispatch_timeout_secs 不能为 0");
        }
        if self.upstream_connect_timeout_secs == 0 {
            anyhow::bail!("upstream_connect_timeout_secs 不能为 0");
        }
        if self.max_connections > tokio::sync::Semaphore::MAX_PERMITS {
            anyhow::bail!(
                "max_connections ({}) 超过 Tokio Semaphore 上限 {}",
                self.max_connections,
                tokio::sync::Semaphore::MAX_PERMITS
            );
        }
        if self.max_handshake_connections > tokio::sync::Semaphore::MAX_PERMITS {
            anyhow::bail!(
                "max_handshake_connections ({}) 超过 Tokio Semaphore 上限 {}",
                self.max_handshake_connections,
                tokio::sync::Semaphore::MAX_PERMITS
            );
        }
        let mut exact_routes = HashMap::new();
        let mut wildcard_routes = HashMap::new();
        for route in &self.routes {
            let key = route.sni.trim_end_matches('.').to_ascii_lowercase();
            if key.is_empty() {
                anyhow::bail!("SNI 路由不能为空");
            }
            if route.upstream.trim().is_empty() {
                anyhow::bail!("SNI 路由 {:?} 的 upstream 不能为空", route.sni);
            }
            validate_socket_addr(
                &format!("SNI 路由 {:?} 的 upstream", route.sni),
                &route.upstream,
            )?;
            if let Some(base) = key.strip_prefix("*.") {
                if base.is_empty() || base.contains('*') {
                    anyhow::bail!("无效的 SNI 通配路由 {:?}；仅支持 *.example.com", route.sni);
                }
                if let Some(previous) = wildcard_routes.insert(base.to_owned(), &route.sni) {
                    anyhow::bail!(
                        "SNI 通配路由归一化后重复: {:?} 与 {:?}",
                        previous,
                        route.sni
                    );
                }
            } else {
                if key.contains('*') {
                    anyhow::bail!(
                        "无效的 SNI 路由 {:?}；通配符只能使用 *.example.com",
                        route.sni
                    );
                }
                if let Some(previous) = exact_routes.insert(key, &route.sni) {
                    anyhow::bail!(
                        "SNI 精确路由归一化后重复: {:?} 与 {:?}",
                        previous,
                        route.sni
                    );
                }
            }
        }
        if let Some(acme) = &self.acme
            && acme.enabled
        {
            acme.validate()?;
        }
        Ok(())
    }

    /// 构建精确/通配路由索引。精确路由进 O(1) HashMap；`*.domain` 通配路由
    /// 单列，匹配时按"恰好一层子域名"语义（与泛域名证书一致）。
    fn build_route_indices(&mut self) {
        let mut routes_map: HashMap<String, String> = HashMap::new();
        let mut wildcard_routes: Vec<(String, String)> = Vec::new();
        for r in &self.routes {
            let key = r.sni.trim_end_matches('.').to_ascii_lowercase();
            match key.strip_prefix("*.") {
                // 通配路由 `*.example.com` → base = `example.com`。
                Some(base) if !base.is_empty() => {
                    wildcard_routes.push((base.to_string(), r.upstream.clone()));
                }
                _ => {
                    routes_map.insert(key, r.upstream.clone());
                }
            }
        }
        self.routes_map = routes_map;
        self.wildcard_routes = wildcard_routes;
    }

    /// SNI 查找：精确路由（O(1)）优先，其次通配路由（恰好一层子域名），
    /// 最后回退默认上游。自动 normalize trailing dot 以兼容 FQDN 形式配置。
    pub fn upstream_for(&self, sni: Option<&str>) -> &str {
        if let Some(name) = sni {
            // 常见情况（客户端发小写 SNI）零分配：仅当含大写字母时才 to_ascii_lowercase
            // 落到一次堆分配；否则 `Cow::Borrowed` 直接复用入参切片。
            let trimmed = name.trim_end_matches('.');
            let key: Cow<'_, str> = if trimmed.bytes().any(|b| b.is_ascii_uppercase()) {
                Cow::Owned(trimmed.to_ascii_lowercase())
            } else {
                Cow::Borrowed(trimmed)
            };
            let key: &str = key.as_ref();
            // 1) 精确匹配优先。
            if let Some(upstream) = self.routes_map.get(key) {
                return upstream;
            }
            // 2) 通配匹配：`*.example.com` 仅匹配恰好一层子域名，与泛域名证书
            //    语义一致；可正确拒绝 `evilexample.com`、`a.b.example.com`、
            //    apex `example.com` 等越界/多层情形 → 落到默认上游。
            for (base, upstream) in &self.wildcard_routes {
                if wildcard_label_matches(base, key) {
                    return upstream;
                }
            }
        }
        &self.default_upstream
    }
}

impl AcmeConfig {
    fn validate(&self) -> anyhow::Result<()> {
        if self.domains.is_empty() {
            anyhow::bail!("启用 ACME 时 domains 不能为空");
        }
        let mut normalized_domains = HashSet::with_capacity(self.domains.len());
        for domain in &self.domains {
            let normalized = normalize_acme_domain(domain)?;
            if !normalized_domains.insert(normalized) {
                anyhow::bail!("ACME domains 归一化后重复: {domain:?}");
            }
        }
        let email = self.email.trim();
        if email.is_empty()
            || email.contains(char::is_whitespace)
            || !email
                .split_once('@')
                .is_some_and(|(local, domain)| !local.is_empty() && is_valid_dns_name(domain))
        {
            anyhow::bail!("ACME email 不是有效联系邮箱: {:?}", self.email);
        }
        if !matches!(
            self.ca.trim().to_ascii_lowercase().as_str(),
            "letsencrypt" | "le" | "letsencrypt-staging" | "staging"
        ) {
            anyhow::bail!(
                "不支持的 ACME CA {:?}；仅支持 letsencrypt 或 letsencrypt-staging",
                self.ca
            );
        }
        if self.cert_dir.trim().is_empty() || !Path::new(&self.cert_dir).is_absolute() {
            anyhow::bail!("ACME cert_dir 必须是非空绝对路径: {:?}", self.cert_dir);
        }
        if !(1..=365).contains(&self.renew_before_days) {
            anyhow::bail!("ACME renew_before_days 必须在 1..=365 之间");
        }
        if !(5..=3600).contains(&self.dns_propagation_secs) {
            anyhow::bail!("ACME dns_propagation_secs 必须在 5..=3600 之间");
        }
        Ok(())
    }

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

    /// 将已经过 `Config::validate` 的 CA 关键字解析为 ACME directory URL。
    pub fn directory_url(&self) -> &'static str {
        match self.ca.to_ascii_lowercase().as_str() {
            "letsencrypt" | "le" => "https://acme-v02.api.letsencrypt.org/directory",
            "letsencrypt-staging" | "staging" => {
                "https://acme-staging-v02.api.letsencrypt.org/directory"
            }
            _ => unreachable!("ACME CA must be validated before use"),
        }
    }

    /// 证书存储目录中使用的 CA 标签子目录名。
    pub fn ca_label(&self) -> &str {
        match self.ca.to_ascii_lowercase().as_str() {
            "letsencrypt-staging" | "staging" => "letsencrypt-staging",
            _ => "letsencrypt",
        }
    }
}

fn validate_socket_addr(field: &str, value: &str) -> anyhow::Result<SocketAddr> {
    let trimmed = value.trim();
    if trimmed != value || trimmed.is_empty() {
        anyhow::bail!("{field} 必须是无首尾空白的 IP:端口地址: {value:?}");
    }
    trimmed
        .parse::<SocketAddr>()
        .map_err(|error| anyhow::anyhow!("{field} 不是有效 IP:端口地址 {value:?}: {error}"))
}

fn normalize_acme_domain(domain: &str) -> anyhow::Result<String> {
    let normalized = domain.trim().trim_end_matches('.').to_ascii_lowercase();
    let dns_name = normalized.strip_prefix("*.").unwrap_or(&normalized);
    if normalized.is_empty()
        || normalized.contains('*') && !normalized.starts_with("*.")
        || !is_valid_dns_name(dns_name)
    {
        anyhow::bail!("无效的 ACME 域名: {domain:?}");
    }
    Ok(normalized)
}

fn is_valid_dns_name(name: &str) -> bool {
    name.len() <= 253
        && name.contains('.')
        && name.split('.').all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && label
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
                && !label.starts_with('-')
                && !label.ends_with('-')
        })
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

fn default_max_handshake_connections() -> usize {
    512
}

fn default_relay_idle_timeout() -> u64 {
    300
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

/// 判断 `key` 是否为 `base` 的恰好一层子域名（通配路由匹配）。
/// 例如 base=`example.com`：`foo.example.com` ✓；`a.b.example.com`/`example.com`/
/// `evilexample.com`（无点边界）✗。与 `acme::store::dns_name_matches` 的泛域名
/// 证书匹配语义保持一致。入参 `key` 应已 normalize（lowercase + 去尾点）。
fn wildcard_label_matches(base: &str, key: &str) -> bool {
    match key.strip_suffix(base) {
        // label 必须以 '.' 结尾（点边界）且其余部分不含 '.'（恰好一层）。
        // `ends_with('.')` 保证 label 非空，故 `label.len() - 1` 不会下溢。
        Some(label) => label.ends_with('.') && !label[..label.len() - 1].contains('.'),
        None => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 复用 `build_route_indices` 的预计算逻辑（跳过 `load()` 的文件 I/O 与
    /// 阈值校验，仅验证路由匹配）。`#[serde(skip)]` 字段反序列化为默认空值。
    fn load_str(json: &str) -> Config {
        let mut cfg: Config = match serde_json::from_str(json) {
            Ok(c) => c,
            Err(e) => panic!("测试配置 JSON 非法: {e}"),
        };
        cfg.build_route_indices();
        cfg
    }

    const COMBO: &str = r#"{
        "listen": "0.0.0.0:443",
        "default_upstream": "127.0.0.1:8444",
        "routes": [
            { "sni": "api.example.com", "upstream": "127.0.0.1:8445" },
            { "sni": "www.amazon.com", "upstream": "127.0.0.1:8444" },
            { "sni": "*.example.com", "upstream": "127.0.0.1:8443" }
        ]
    }"#;

    #[test]
    fn exact_route_takes_priority_over_wildcard() {
        let cfg = load_str(COMBO);
        // api.example.com 同时匹配精确(anytls)与通配(*.example.com→naive)，精确优先。
        assert_eq!(cfg.upstream_for(Some("api.example.com")), "127.0.0.1:8445");
    }

    #[test]
    fn wildcard_matches_single_label_subdomain() {
        let cfg = load_str(COMBO);
        // naive 客户端的"任意 *.domain 子域名" → 通配 → naive(8443)。
        for s in [
            "proxy.example.com",
            "www.example.com",
            "abc.example.com",
            "PROXY.Example.COM",
        ] {
            assert_eq!(cfg.upstream_for(Some(s)), "127.0.0.1:8443", "{s}");
        }
    }

    #[test]
    fn probes_fall_through_to_default_decoy() {
        let cfg = load_str(COMBO);
        // 无 SNI / apex / 多层 / 越界相似 / 后缀伪装 / 随机 → 默认上游(=decoy 8444)。
        assert_eq!(cfg.upstream_for(None), "127.0.0.1:8444");
        for s in [
            "example.com",              // apex 不匹配 *.example.com
            "a.b.example.com",          // 多层子域名
            "evilexample.com",          // 越界相似（无点边界）
            "example.com.attacker.net", // 后缀伪装
            "scanner-probe.invalid",    // 随机探测
        ] {
            assert_eq!(cfg.upstream_for(Some(s)), "127.0.0.1:8444", "{s}");
        }
    }

    #[test]
    fn wildcard_matching_is_case_and_trailing_dot_insensitive() {
        let cfg = load_str(COMBO);
        assert_eq!(
            cfg.upstream_for(Some("Proxy.Example.Com.")),
            "127.0.0.1:8443"
        );
        assert_eq!(cfg.upstream_for(Some("API.EXAMPLE.COM.")), "127.0.0.1:8445");
    }

    #[test]
    fn exact_only_config_unaffected_by_wildcard_logic() {
        // 无通配路由时行为与旧版一致（回归保护）。
        let cfg = load_str(
            r#"{
            "listen": "0.0.0.0:443",
            "default_upstream": "127.0.0.1:8443",
            "routes": [ { "sni": "api.example.com", "upstream": "127.0.0.1:8445" } ]
        }"#,
        );
        assert_eq!(cfg.upstream_for(Some("api.example.com")), "127.0.0.1:8445");
        assert_eq!(
            cfg.upstream_for(Some("other.example.com")),
            "127.0.0.1:8443"
        );
        assert_eq!(cfg.upstream_for(None), "127.0.0.1:8443");
    }

    #[test]
    fn rejects_normalized_duplicate_exact_routes() {
        let cfg = load_str(
            r#"{
            "listen": "0.0.0.0:443",
            "default_upstream": "127.0.0.1:8443",
            "routes": [
                { "sni": "API.Example.com", "upstream": "127.0.0.1:8445" },
                { "sni": "api.example.com.", "upstream": "127.0.0.1:8448" }
            ]
        }"#,
        );
        assert!(cfg.validate().is_err());
    }

    #[test]
    fn rejects_normalized_duplicate_wildcard_routes() {
        let cfg = load_str(
            r#"{
            "listen": "0.0.0.0:443",
            "default_upstream": "127.0.0.1:8444",
            "routes": [
                { "sni": "*.Example.com", "upstream": "127.0.0.1:8443" },
                { "sni": "*.example.com.", "upstream": "127.0.0.1:8449" }
            ]
        }"#,
        );
        assert!(cfg.validate().is_err());
    }

    #[test]
    fn rejects_malformed_wildcard_routes() {
        for sni in ["*.", "api.*.example.com", "**.example.com"] {
            let json = format!(
                r#"{{
                "listen": "0.0.0.0:443",
                "default_upstream": "127.0.0.1:8444",
                "routes": [{{ "sni": "{sni}", "upstream": "127.0.0.1:8443" }}]
            }}"#
            );
            let cfg = load_str(&json);
            assert!(
                cfg.validate().is_err(),
                "accepted malformed SNI route {sni}"
            );
        }
    }

    #[test]
    fn rejects_max_connections_above_tokio_limit() {
        let mut cfg = load_str(COMBO);
        cfg.max_connections = tokio::sync::Semaphore::MAX_PERMITS + 1;
        assert!(cfg.validate().is_err());
    }

    #[test]
    fn rejects_handshake_limit_above_tokio_limit() {
        let mut cfg = load_str(COMBO);
        cfg.max_handshake_connections = tokio::sync::Semaphore::MAX_PERMITS + 1;
        assert!(cfg.validate().is_err());
    }

    #[test]
    fn rejects_unsupported_acme_ca_instead_of_falling_back() {
        let mut cfg = load_str(COMBO);
        cfg.acme = Some(AcmeConfig {
            enabled: true,
            domains: vec!["*.example.com".to_owned()],
            email: "admin@example.com".to_owned(),
            ca: "zerossl".to_owned(),
            cloudflare_api_token: None,
            cloudflare_api_token_file: Some("/run/secrets/cloudflare".to_owned()),
            cert_dir: "/data/caddy/certificates".to_owned(),
            renew_before_days: 30,
            dns_propagation_secs: 60,
        });

        let error = match cfg.validate() {
            Ok(()) => panic!("unsupported ACME CA was accepted"),
            Err(error) => error,
        };
        assert!(error.to_string().contains("不支持的 ACME CA"));
    }

    #[test]
    fn rejects_invalid_listener_and_upstream_addresses() {
        for (field, value) in [
            ("listen", "localhost:443"),
            ("default_upstream", ""),
            ("default_upstream", "127.0.0.1"),
        ] {
            let mut cfg = load_str(COMBO);
            match field {
                "listen" => cfg.listen = value.to_owned(),
                "default_upstream" => cfg.default_upstream = value.to_owned(),
                _ => unreachable!(),
            }
            assert!(cfg.validate().is_err(), "accepted {field}={value:?}");
        }

        let mut cfg = load_str(COMBO);
        cfg.routes[0].upstream = "localhost:8445".to_owned();
        assert!(cfg.validate().is_err());
    }

    #[test]
    fn rejects_incomplete_acme_contract() {
        let mut cfg = load_str(COMBO);
        let mut acme = AcmeConfig {
            enabled: true,
            domains: Vec::new(),
            email: String::new(),
            ca: "letsencrypt".to_owned(),
            cloudflare_api_token: None,
            cloudflare_api_token_file: Some("/run/secrets/cloudflare".to_owned()),
            cert_dir: "/data/caddy/certificates".to_owned(),
            renew_before_days: 30,
            dns_propagation_secs: 60,
        };
        cfg.acme = Some(acme.clone());
        assert!(cfg.validate().is_err());

        acme.domains = vec!["*.example.com".to_owned(), "*.EXAMPLE.com.".to_owned()];
        acme.email = "admin@example.com".to_owned();
        cfg.acme = Some(acme.clone());
        assert!(cfg.validate().is_err());

        acme.domains = vec!["bad_*_domain".to_owned()];
        cfg.acme = Some(acme.clone());
        assert!(cfg.validate().is_err());

        acme.domains = vec!["example.com".to_owned()];
        acme.email = "not-an-email".to_owned();
        cfg.acme = Some(acme);
        assert!(cfg.validate().is_err());
    }
}
