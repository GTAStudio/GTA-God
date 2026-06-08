//! ACME 管理器：基于 instant-acme（RFC 8555）+ Cloudflare DNS-01，自动签发与续期
//! 泛域名证书，并按 GTA-God 期望的布局落盘。

mod cloudflare;
mod store;

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use instant_acme::{
    Account, AccountCredentials, AuthorizationStatus, ChallengeType, Identifier, NewAccount,
    NewOrder, Order, OrderStatus, RetryPolicy,
};
use reqwest::Client as HttpClient;
use serde::Deserialize;
use tracing::{debug, error, info, warn};

use crate::config::AcmeConfig;
use cloudflare::Cloudflare;
use store::CertStore;

/// 每轮续期检查的间隔。
const RENEW_CHECK_INTERVAL: Duration = Duration::from_secs(12 * 3600);

/// 初次签发或续期失败后的短退避重试间隔。
const ISSUE_RETRY_INTERVAL: Duration = Duration::from_secs(60);

/// DNS-01 TXT 传播轮询间隔。
const DNS_PROPAGATION_POLL_INTERVAL: Duration = Duration::from_secs(5);

/// 单次 DoH 查询超时。
const DNS_QUERY_TIMEOUT: Duration = Duration::from_secs(10);

const DNS_JSON_RESOLVERS: [&str; 2] = [
    "https://cloudflare-dns.com/dns-query",
    "https://dns.google/resolve",
];

/// 启动 ACME 后台任务：先做一轮签发，然后周期性检查续期。
pub async fn run(acme: AcmeConfig) {
    if !acme.enabled {
        info!("ACME 未启用，跳过证书管理");
        return;
    }

    let acme = Arc::new(acme);
    loop {
        let next_interval = match reconcile(&acme).await {
            Ok(()) => RENEW_CHECK_INTERVAL,
            Err(e) => {
                error!(error = %e, retry_after_secs = ISSUE_RETRY_INTERVAL.as_secs(), "ACME 本轮签发/续期失败，将短退避后重试");
                ISSUE_RETRY_INTERVAL
            }
        };
        tokio::time::sleep(next_interval).await;
    }
}

/// 遍历所有域名，对缺失或临近到期的证书执行签发。
async fn reconcile(acme: &AcmeConfig) -> anyhow::Result<()> {
    let store = CertStore::new(&acme.cert_dir, acme.ca_label());

    let pending: Vec<&String> = acme
        .domains
        .iter()
        .filter(|d| store.needs_renewal(d, acme.renew_before_days))
        .collect();

    if pending.is_empty() {
        info!("所有证书均在有效期内，无需续期");
        return Ok(());
    }

    let token = acme.resolve_token()?;
    let cf = Cloudflare::new(token)?;
    let account = load_or_create_account(acme).await?;

    let mut failed_domains = Vec::new();
    for domain in pending {
        info!(domain = %domain, "开始签发/续期证书");
        match issue(acme, &cf, &account, &store, domain).await {
            Ok(()) => info!(domain = %domain, "证书已签发并落盘"),
            Err(e) => {
                error!(domain = %domain, error = %e, "证书签发失败");
                failed_domains.push(domain.to_string());
            }
        }
    }

    if !failed_domains.is_empty() {
        anyhow::bail!("证书签发失败: {}", failed_domains.join(", "));
    }
    Ok(())
}

/// 恢复或创建 ACME 账户，避免失败重试时反复注册新账户触发 CA 限流。
async fn load_or_create_account(acme: &AcmeConfig) -> anyhow::Result<Account> {
    let credentials_path = account_credentials_path(acme);

    if credentials_path.is_file() {
        match load_account_credentials(&credentials_path).await {
            Ok(account) => {
                info!(path = %credentials_path.display(), "已恢复 ACME 账户凭据");
                return Ok(account);
            }
            Err(e) => {
                warn!(path = %credentials_path.display(), error = %e, "恢复 ACME 账户凭据失败，将重新创建账户");
            }
        }
    }

    let contact = format!("mailto:{}", acme.email);

    let (account, credentials) = Account::builder()
        .map_err(|e| anyhow::anyhow!("初始化 ACME 客户端失败: {e}"))?
        .create(
            &NewAccount {
                contact: &[&contact],
                terms_of_service_agreed: true,
                only_return_existing: false,
            },
            acme.directory_url(),
            None,
        )
        .await
        .map_err(|e| anyhow::anyhow!("创建 ACME 账户失败: {e}"))?;

    save_account_credentials(&credentials_path, &credentials)?;
    info!(path = %credentials_path.display(), "ACME 账户凭据已保存");
    Ok(account)
}

async fn load_account_credentials(path: &Path) -> anyhow::Result<Account> {
    let raw = std::fs::read(path)
        .map_err(|e| anyhow::anyhow!("读取 ACME 账户凭据 {} 失败: {e}", path.display()))?;
    let credentials: AccountCredentials = serde_json::from_slice(&raw)
        .map_err(|e| anyhow::anyhow!("解析 ACME 账户凭据 {} 失败: {e}", path.display()))?;
    Account::builder()
        .map_err(|e| anyhow::anyhow!("初始化 ACME 客户端失败: {e}"))?
        .from_credentials(credentials)
        .await
        .map_err(|e| anyhow::anyhow!("恢复 ACME 账户失败: {e}"))
}

fn save_account_credentials(path: &Path, credentials: &AccountCredentials) -> anyhow::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| anyhow::anyhow!("创建 ACME 账户目录 {} 失败: {e}", parent.display()))?;
    }

    let data = serde_json::to_vec_pretty(credentials)
        .map_err(|e| anyhow::anyhow!("序列化 ACME 账户凭据失败: {e}"))?;
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, data)
        .map_err(|e| anyhow::anyhow!("写入 ACME 账户临时文件 {} 失败: {e}", tmp.display()))?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600))
            .map_err(|e| anyhow::anyhow!("设置 {} 权限失败: {e}", tmp.display()))?;
    }

    std::fs::rename(&tmp, path)
        .map_err(|e| anyhow::anyhow!("保存 ACME 账户凭据 {} 失败: {e}", path.display()))?;
    Ok(())
}

fn account_credentials_path(acme: &AcmeConfig) -> PathBuf {
    Path::new(&acme.cert_dir)
        .join(acme.ca_label())
        .join("account.json")
}

/// 对单个域名完成完整的 DNS-01 签发流程。
async fn issue(
    acme: &AcmeConfig,
    cf: &Cloudflare,
    account: &Account,
    store: &CertStore,
    domain: &str,
) -> anyhow::Result<()> {
    let identifiers = [Identifier::Dns(domain.to_string())];
    let mut order = account
        .new_order(&NewOrder::new(&identifiers))
        .await
        .map_err(|e| anyhow::anyhow!("创建 ACME order 失败: {e}"))?;

    // 待清理的 TXT 记录 (zone_id, record_id)。
    let mut cleanups: Vec<(String, String)> = Vec::new();

    let result = complete_dns01_order(acme, cf, store, domain, &mut order, &mut cleanups).await;

    // 无论成功与否，清理 TXT 记录。
    for (zone_id, record_id) in &cleanups {
        if let Err(e) = cf.delete_txt(zone_id, record_id).await {
            warn!(error = %e, "清理 TXT 记录失败（可忽略）");
        }
    }

    result
}

async fn complete_dns01_order(
    acme: &AcmeConfig,
    cf: &Cloudflare,
    store: &CertStore,
    domain: &str,
    order: &mut Order,
    cleanups: &mut Vec<(String, String)>,
) -> anyhow::Result<()> {
    // 用块作用域限定 authorizations 对 order 的借用，结束后才能 &mut order 续签。
    {
        let mut authorizations = order.authorizations();
        while let Some(result) = authorizations.next().await {
            let mut authz = result.map_err(|e| anyhow::anyhow!("读取 authorization 失败: {e}"))?;
            match authz.status {
                AuthorizationStatus::Pending => {}
                AuthorizationStatus::Valid => continue,
                other => anyhow::bail!("authorization 状态异常: {other:?}"),
            }

            let mut challenge = authz
                .challenge(ChallengeType::Dns01)
                .ok_or_else(|| anyhow::anyhow!("未找到 DNS-01 挑战"))?;

            let ident = challenge.identifier().to_string();
            let base = ident.trim_start_matches("*.").to_string();
            let record_name = format!("_acme-challenge.{base}");
            let dns_value = challenge.key_authorization().dns_value();

            let zone_id = cf.find_zone_id(&base).await?;
            let record_id = cf.create_txt(&zone_id, &record_name, &dns_value).await?;
            cleanups.push((zone_id, record_id));

            wait_for_dns_txt(
                &record_name,
                &dns_value,
                Duration::from_secs(acme.dns_propagation_secs),
            )
            .await?;
            challenge
                .set_ready()
                .await
                .map_err(|e| anyhow::anyhow!("通知 CA 校验失败: {e}"))?;
        }
    }

    finalize_and_store(order, store, domain).await
}

async fn wait_for_dns_txt(name: &str, expected: &str, max_wait: Duration) -> anyhow::Result<()> {
    let http = HttpClient::builder()
        .user_agent("gtagate/0.1")
        .timeout(DNS_QUERY_TIMEOUT)
        .build()
        .map_err(|e| anyhow::anyhow!("构建 DNS 查询客户端失败: {e}"))?;

    let deadline = tokio::time::Instant::now() + max_wait.max(DNS_PROPAGATION_POLL_INTERVAL);
    loop {
        if dns_txt_is_visible(&http, name, expected).await {
            info!(record = %name, "DNS-01 TXT 记录已传播");
            return Ok(());
        }

        let now = tokio::time::Instant::now();
        if now >= deadline {
            anyhow::bail!("等待 DNS-01 TXT 记录传播超时: {name}");
        }

        tokio::time::sleep(DNS_PROPAGATION_POLL_INTERVAL.min(deadline - now)).await;
    }
}

async fn dns_txt_is_visible(http: &HttpClient, name: &str, expected: &str) -> bool {
    for resolver in DNS_JSON_RESOLVERS {
        match query_dns_txt(http, resolver, name).await {
            Ok(answers) if answers.iter().any(|answer| answer.contains(expected)) => {
                return true;
            }
            Ok(_) => {}
            Err(e) => debug!(resolver, record = %name, error = %e, "DNS TXT 查询失败"),
        }
    }
    false
}

async fn query_dns_txt(
    http: &HttpClient,
    resolver: &str,
    name: &str,
) -> anyhow::Result<Vec<String>> {
    let response = http
        .get(resolver)
        .header("accept", "application/dns-json")
        .query(&[("name", name), ("type", "TXT")])
        .send()
        .await
        .map_err(|e| anyhow::anyhow!("查询 DNS resolver {resolver} 失败: {e}"))?
        .error_for_status()
        .map_err(|e| anyhow::anyhow!("DNS resolver {resolver} 返回错误状态: {e}"))?;

    let body: DnsJsonResponse = response
        .json()
        .await
        .map_err(|e| anyhow::anyhow!("解析 DNS resolver {resolver} 响应失败: {e}"))?;
    Ok(body.answer.into_iter().map(|answer| answer.data).collect())
}

#[derive(Deserialize)]
struct DnsJsonResponse {
    #[serde(rename = "Answer", default)]
    answer: Vec<DnsJsonAnswer>,
}

#[derive(Deserialize)]
struct DnsJsonAnswer {
    data: String,
}

/// 等待 order 就绪、finalize 并把证书写入磁盘。
async fn finalize_and_store(
    order: &mut Order,
    store: &CertStore,
    domain: &str,
) -> anyhow::Result<()> {
    let status = order
        .poll_ready(&RetryPolicy::default())
        .await
        .map_err(|e| anyhow::anyhow!("等待 order 就绪失败: {e}"))?;
    if status != OrderStatus::Ready {
        anyhow::bail!("order 状态非 Ready: {status:?}");
    }

    let key_pem = order
        .finalize()
        .await
        .map_err(|e| anyhow::anyhow!("finalize 失败: {e}"))?;
    let cert_pem = order
        .poll_certificate(&RetryPolicy::default())
        .await
        .map_err(|e| anyhow::anyhow!("获取证书失败: {e}"))?;

    store.save(domain, &cert_pem, &key_pem)?;
    Ok(())
}
