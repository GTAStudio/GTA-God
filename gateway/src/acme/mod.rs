//! ACME 管理器：基于 instant-acme（RFC 8555）+ Cloudflare DNS-01，自动签发与续期
//! 泛域名证书，并按 GTA-God 期望的布局落盘。

mod cloudflare;
mod store;

use std::fs::{File, OpenOptions, TryLockError};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use instant_acme::{
    Account, AccountCredentials, AuthorizationStatus, ChallengeType, Identifier, NewAccount,
    NewOrder, Order, OrderStatus, RetryPolicy,
};
use reqwest::Client as HttpClient;
use serde::Deserialize;
use time::{
    OffsetDateTime, PrimitiveDateTime,
    format_description::well_known::{Rfc2822, Rfc3339},
    macros::format_description,
};
use tracing::{debug, error, info, warn};

use crate::config::AcmeConfig;
use cloudflare::Cloudflare;
use store::{CertStore, RenewalReason, RenewalStatus};

/// 每轮续期检查的间隔。
const RENEW_CHECK_INTERVAL: Duration = Duration::from_secs(12 * 3600);

/// 初次签发或续期失败后的指数退避起点。
const ISSUE_INITIAL_RETRY_INTERVAL: Duration = Duration::from_secs(60);

/// 普通失败指数退避上限。CA 明确返回 Retry-After 时优先尊重 CA 时间。
const ISSUE_MAX_RETRY_INTERVAL: Duration = Duration::from_secs(24 * 3600);

/// 另一 gtagate 实例持有 ACME 文件锁时的检查间隔。
const LOCK_BUSY_RETRY_INTERVAL: Duration = Duration::from_secs(60);

const ACME_LOCK_FILE: &str = ".gtagate-acme.lock";

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
    let mut backoff = IssueBackoff::new();
    loop {
        let next_interval = match reconcile(&acme).await {
            Ok(ReconcileOutcome::Done) => {
                backoff.reset();
                RENEW_CHECK_INTERVAL
            }
            Ok(ReconcileOutcome::LockBusy) => LOCK_BUSY_RETRY_INTERVAL,
            Err(e) => {
                let retry_after = retry_after_delay_from_error(&e, OffsetDateTime::now_utc());
                let retry_source = if retry_after.is_some() {
                    "ca_retry_after"
                } else {
                    "exponential_backoff"
                };
                let retry_interval = backoff.next_delay(retry_after);
                error!(
                    error = %e,
                    retry_after_secs = retry_interval.as_secs(),
                    retry_source,
                    "ACME 本轮签发/续期失败，将退避后重试"
                );
                retry_interval
            }
        };
        tokio::time::sleep(next_interval).await;
    }
}

enum ReconcileOutcome {
    Done,
    LockBusy,
}

struct IssueBackoff {
    next: Duration,
}

impl IssueBackoff {
    fn new() -> Self {
        Self {
            next: ISSUE_INITIAL_RETRY_INTERVAL,
        }
    }

    fn reset(&mut self) {
        self.next = ISSUE_INITIAL_RETRY_INTERVAL;
    }

    fn next_delay(&mut self, ca_retry_after: Option<Duration>) -> Duration {
        let delay = ca_retry_after.unwrap_or(self.next);
        self.next = self.next.saturating_mul(2).min(ISSUE_MAX_RETRY_INTERVAL);
        delay
    }
}

struct AcmeLock {
    _file: File,
}

impl AcmeLock {
    fn try_acquire(cert_dir: &str) -> anyhow::Result<Option<Self>> {
        let cert_dir = Path::new(cert_dir);
        std::fs::create_dir_all(cert_dir)
            .map_err(|e| anyhow::anyhow!("创建 ACME 证书目录 {} 失败: {e}", cert_dir.display()))?;

        let lock_path = cert_dir.join(ACME_LOCK_FILE);
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(&lock_path)
            .map_err(|e| anyhow::anyhow!("打开 ACME 锁文件 {} 失败: {e}", lock_path.display()))?;

        match file.try_lock() {
            Ok(()) => {
                debug!(path = %lock_path.display(), "已获取 ACME 文件锁");
                Ok(Some(Self { _file: file }))
            }
            Err(TryLockError::WouldBlock) => Ok(None),
            Err(TryLockError::Error(e)) => Err(anyhow::anyhow!(
                "获取 ACME 锁文件 {} 失败: {e}",
                lock_path.display()
            )),
        }
    }
}

fn pending_domains<'a>(
    acme: &'a AcmeConfig,
    store: &CertStore,
    log_decisions: bool,
) -> Vec<&'a String> {
    acme.domains
        .iter()
        .filter(|domain| {
            let status = store.renewal_status(domain, acme.renew_before_days);
            if log_decisions {
                log_renewal_status(domain, &status);
            }
            status.needs_renewal
        })
        .collect()
}

fn log_renewal_status(domain: &str, status: &RenewalStatus) {
    let cert_path = status
        .certificate
        .as_ref()
        .map(|cert| cert.cert_path.display().to_string())
        .unwrap_or_else(|| "<none>".to_string());
    let key_path = status
        .certificate
        .as_ref()
        .map(|cert| cert.key_path.display().to_string())
        .unwrap_or_else(|| "<none>".to_string());
    let not_before = status
        .certificate
        .as_ref()
        .map(|cert| format_system_time(cert.not_before))
        .unwrap_or_else(|| "<unknown>".to_string());
    let not_after = status
        .certificate
        .as_ref()
        .map(|cert| format_system_time(cert.not_after))
        .unwrap_or_else(|| "<unknown>".to_string());
    let remaining_days = status
        .remaining
        .map(|remaining| remaining.as_secs() / 86_400);

    match status.reason {
        RenewalReason::Valid => info!(
            domain = %domain,
            cert_path = %cert_path,
            key_path = %key_path,
            not_before = %not_before,
            not_after = %not_after,
            remaining_days = ?remaining_days,
            "证书有效期充足，跳过续签"
        ),
        RenewalReason::RecentlyIssued => info!(
            domain = %domain,
            cert_path = %cert_path,
            key_path = %key_path,
            not_before = %not_before,
            not_after = %not_after,
            remaining_days = ?remaining_days,
            "证书刚刚签发，跳过续签"
        ),
        RenewalReason::WithinRenewalWindow => info!(
            domain = %domain,
            cert_path = %cert_path,
            key_path = %key_path,
            not_before = %not_before,
            not_after = %not_after,
            remaining_days = ?remaining_days,
            "证书进入续签窗口"
        ),
        RenewalReason::Expired => warn!(
            domain = %domain,
            cert_path = %cert_path,
            key_path = %key_path,
            not_before = %not_before,
            not_after = %not_after,
            "证书已过期或系统时间异常，将重新签发"
        ),
        RenewalReason::MissingKey => warn!(domain = %domain, "找到匹配证书但缺少私钥，将重新签发"),
        RenewalReason::Missing => info!(domain = %domain, "未找到可用证书，将签发"),
    }
}

fn format_system_time(value: SystemTime) -> String {
    let Ok(duration) = value.duration_since(UNIX_EPOCH) else {
        return "<before-unix-epoch>".to_string();
    };
    let Ok(seconds) = i64::try_from(duration.as_secs()) else {
        return format!("{}s", duration.as_secs());
    };
    match OffsetDateTime::from_unix_timestamp(seconds) {
        Ok(time) => time
            .format(&Rfc3339)
            .unwrap_or_else(|_| format!("{}s", duration.as_secs())),
        Err(_) => format!("{}s", duration.as_secs()),
    }
}

fn retry_after_delay_from_error(error: &anyhow::Error, now: OffsetDateTime) -> Option<Duration> {
    parse_retry_after_delay(&format!("{error:#}"), now)
}

fn parse_retry_after_delay(text: &str, now: OffsetDateTime) -> Option<Duration> {
    parse_retry_after_seconds(text)
        .or_else(|| parse_retry_after_datetime(text, now))
        .filter(|delay| !delay.is_zero())
}

fn parse_retry_after_seconds(text: &str) -> Option<Duration> {
    for tail in retry_after_tails(text) {
        let tail = trim_retry_after_prefix(tail);
        let digits_len = tail
            .chars()
            .take_while(|ch| ch.is_ascii_digit())
            .map(char::len_utf8)
            .sum();
        if digits_len == 0 {
            continue;
        }

        if tail[digits_len..]
            .chars()
            .next()
            .is_some_and(|ch| !ch.is_ascii_whitespace() && !matches!(ch, ',' | ';' | ')' | ']'))
        {
            continue;
        }

        if let Ok(seconds) = tail[..digits_len].parse::<u64>() {
            return Some(Duration::from_secs(seconds));
        }
    }
    None
}

fn parse_retry_after_datetime(text: &str, now: OffsetDateTime) -> Option<Duration> {
    for tail in retry_after_tails(text) {
        let tail = trim_retry_after_prefix(tail);
        for candidate in datetime_candidates(tail) {
            if let Some(delay) = parse_datetime_candidate(&candidate, now) {
                return Some(delay);
            }
        }
    }

    for candidate in lets_encrypt_utc_candidates(text) {
        if let Some(delay) = parse_datetime_candidate(&candidate, now) {
            return Some(delay);
        }
    }
    None
}

fn retry_after_tails(text: &str) -> Vec<&str> {
    let lower = text.to_ascii_lowercase();
    let mut tails = Vec::new();
    for marker in ["retry-after", "retry_after", "retry after"] {
        let mut start = 0;
        while let Some(offset) = lower[start..].find(marker) {
            let marker_end = start + offset + marker.len();
            tails.push(&text[marker_end..]);
            start = marker_end;
        }
    }
    tails
}

fn trim_retry_after_prefix(value: &str) -> &str {
    value.trim_start_matches(|ch: char| {
        ch.is_ascii_whitespace() || matches!(ch, ':' | '=' | '"' | '\'')
    })
}

fn datetime_candidates(text: &str) -> Vec<String> {
    let mut candidates = Vec::new();

    if let Some(line) = text.lines().next() {
        let line = line
            .trim()
            .trim_matches(|ch: char| matches!(ch, '"' | '\'' | ',' | ';' | ')' | ']'));
        if !line.is_empty() {
            candidates.push(line.to_string());
        }
    }

    for token in text.split_ascii_whitespace() {
        let token = token.trim_matches(|ch: char| matches!(ch, '"' | '\'' | ',' | ';' | ')' | ']'));
        if token.contains('T') && token.contains(':') {
            candidates.push(token.to_string());
        }
    }

    candidates.extend(lets_encrypt_utc_candidates(text));
    candidates
}

fn lets_encrypt_utc_candidates(text: &str) -> Vec<String> {
    const LEN: usize = "2026-06-08 20:00:00 UTC".len();
    let bytes = text.as_bytes();
    if bytes.len() < LEN {
        return Vec::new();
    }

    let mut candidates = Vec::new();
    for start in 0..=bytes.len() - LEN {
        let candidate = &text[start..start + LEN];
        if looks_like_lets_encrypt_utc(candidate) {
            candidates.push(candidate.to_string());
        }
    }
    candidates
}

fn looks_like_lets_encrypt_utc(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == "2026-06-08 20:00:00 UTC".len()
        && bytes[0..4].iter().all(u8::is_ascii_digit)
        && bytes[4] == b'-'
        && bytes[5..7].iter().all(u8::is_ascii_digit)
        && bytes[7] == b'-'
        && bytes[8..10].iter().all(u8::is_ascii_digit)
        && bytes[10] == b' '
        && bytes[11..13].iter().all(u8::is_ascii_digit)
        && bytes[13] == b':'
        && bytes[14..16].iter().all(u8::is_ascii_digit)
        && bytes[16] == b':'
        && bytes[17..19].iter().all(u8::is_ascii_digit)
        && &bytes[19..] == b" UTC"
}

fn parse_datetime_candidate(candidate: &str, now: OffsetDateTime) -> Option<Duration> {
    let candidate = candidate.trim();
    let parsed = OffsetDateTime::parse(candidate, &Rfc3339)
        .or_else(|_| OffsetDateTime::parse(candidate, &Rfc2822))
        .or_else(|_| {
            let format = format_description!("[year]-[month]-[day] [hour]:[minute]:[second] UTC");
            PrimitiveDateTime::parse(candidate, format).map(PrimitiveDateTime::assume_utc)
        })
        .ok()?;

    duration_until(parsed, now)
}

fn duration_until(target: OffsetDateTime, now: OffsetDateTime) -> Option<Duration> {
    let seconds = (target - now).whole_seconds();
    if seconds <= 0 {
        return None;
    }
    Some(Duration::from_secs(seconds as u64))
}

/// 遍历所有域名，对缺失或临近到期的证书执行签发。
async fn reconcile(acme: &AcmeConfig) -> anyhow::Result<ReconcileOutcome> {
    let store = CertStore::new(&acme.cert_dir, acme.ca_label());

    let mut pending = pending_domains(acme, &store, true);

    if pending.is_empty() {
        info!("所有证书均在有效期内，无需续期");
        return Ok(ReconcileOutcome::Done);
    }

    let Some(_lock) = AcmeLock::try_acquire(&acme.cert_dir)? else {
        warn!(
            retry_after_secs = LOCK_BUSY_RETRY_INTERVAL.as_secs(),
            "另一个 gtagate 实例正在执行 ACME，本轮跳过以避免并发签发"
        );
        return Ok(ReconcileOutcome::LockBusy);
    };

    // 拿到锁后再检查一次，避免并发实例刚刚写入证书后继续创建新 order。
    pending = pending_domains(acme, &store, false);
    if pending.is_empty() {
        info!("获取 ACME 锁后复查发现所有证书均在有效期内，无需续期");
        return Ok(ReconcileOutcome::Done);
    }

    let token = acme.resolve_token()?;
    let cf = Cloudflare::new(token)?;
    let account = load_or_create_account(acme).await?;

    let mut failures = Vec::new();
    for domain in pending {
        info!(domain = %domain, "开始签发/续期证书");
        match issue(acme, &cf, &account, &store, domain).await {
            Ok(()) => info!(domain = %domain, "证书已签发并落盘"),
            Err(e) => {
                error!(domain = %domain, error = %e, "证书签发失败");
                failures.push(format!("{domain}: {e:#}"));
            }
        }
    }

    if !failures.is_empty() {
        anyhow::bail!("证书签发失败: {}", failures.join("; "));
    }
    Ok(ReconcileOutcome::Done)
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

#[cfg(test)]
mod tests {
    use super::*;
    use time::macros::datetime;

    #[test]
    fn parses_retry_after_seconds() {
        let now = datetime!(2026-06-08 10:00 UTC);
        assert_eq!(
            parse_retry_after_delay("rateLimited: retry-after: 120", now),
            Some(Duration::from_secs(120))
        );
    }

    #[test]
    fn parses_lets_encrypt_retry_after_timestamp() {
        let now = datetime!(2026-06-08 10:00 UTC);
        assert_eq!(
            parse_retry_after_delay(
                "urn:ietf:params:acme:error:rateLimited :: retry after 2026-06-08 20:00:00 UTC",
                now,
            ),
            Some(Duration::from_secs(10 * 3600))
        );
    }

    #[test]
    fn parses_http_date_retry_after() {
        let now = datetime!(2026-06-08 10:00 UTC);
        assert_eq!(
            parse_retry_after_delay("Retry-After: Mon, 08 Jun 2026 20:00:00 GMT", now),
            Some(Duration::from_secs(10 * 3600))
        );
    }

    #[test]
    fn ordinary_failures_use_exponential_backoff() {
        let mut backoff = IssueBackoff::new();
        assert_eq!(backoff.next_delay(None), Duration::from_secs(60));
        assert_eq!(backoff.next_delay(None), Duration::from_secs(120));
        assert_eq!(
            backoff.next_delay(Some(Duration::from_secs(10 * 3600))),
            Duration::from_secs(10 * 3600)
        );
        assert_eq!(backoff.next_delay(None), Duration::from_secs(480));
    }
}
