//! ACME 管理器：基于 instant-acme（RFC 8555）+ Cloudflare DNS-01，自动签发与续期
//! 泛域名证书，并按 GTA-God 期望的布局落盘。

mod cloudflare;
mod store;

use std::fs::{File, OpenOptions, TryLockError};
use std::future::Future;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use instant_acme::{
    Account, AccountCredentials, AuthorizationStatus, ChallengeType, Identifier, NewAccount,
    NewOrder, Order, OrderStatus, RetryPolicy,
};
use reqwest::Client as HttpClient;
use serde::{Deserialize, Serialize};
use time::{
    OffsetDateTime, PrimitiveDateTime,
    format_description::well_known::{Rfc2822, Rfc3339},
    macros::format_description,
};
use tokio_util::sync::CancellationToken;
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
const ACME_CLEANUP_JOURNAL_FILE: &str = ".gtagate-acme-cleanups.json";

/// DNS-01 TXT 传播轮询间隔。
const DNS_PROPAGATION_POLL_INTERVAL: Duration = Duration::from_secs(5);

/// 单次 DoH 查询总超时。
const DNS_QUERY_TIMEOUT: Duration = Duration::from_secs(10);

/// 单次 DoH 连接（含 TLS 握手）建立超时。与查询总超时分离：让"接受 TCP 但 TLS 卡死"
/// 的死 resolver 在 5s 内快速失败、转向下一个解析器，而非烧满 10s 总超时。与
/// cloudflare.rs 的 HTTP 客户端 connect_timeout 对齐。
const DNS_CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

const DNS_CLEANUP_ATTEMPTS: usize = 3;
const DNS_CLEANUP_ATTEMPT_TIMEOUT: Duration = Duration::from_secs(5);
const DNS_CLEANUP_RETRY_INTERVAL: Duration = Duration::from_millis(250);

const DNS_JSON_RESOLVERS: [&str; 2] = [
    "https://cloudflare-dns.com/dns-query",
    "https://dns.google/resolve",
];

/// 启动 ACME 后台任务：先做一轮签发，然后周期性检查续期。
/// `cancel` 触发后尽快退出（在退避/续期等待期间可被即时打断），避免残留在途 DNS-01 TXT。
pub async fn run(acme: AcmeConfig, cancel: CancellationToken) {
    if !acme.enabled {
        info!("ACME 未启用，跳过证书管理");
        return;
    }

    let acme = Arc::new(acme);
    let mut backoff = IssueBackoff::new();
    loop {
        if cancel.is_cancelled() {
            info!("ACME 收到取消信号，退出证书管理任务");
            return;
        }
        let next_interval = match reconcile(&acme, &cancel).await {
            Ok(ReconcileOutcome::Done) => {
                backoff.reset();
                RENEW_CHECK_INTERVAL
            }
            Ok(ReconcileOutcome::LockBusy) => LOCK_BUSY_RETRY_INTERVAL,
            Err(e) => {
                if cancel.is_cancelled() {
                    info!("ACME 收到取消信号，退出证书管理任务");
                    return;
                }
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
        tokio::select! {
            _ = cancel.cancelled() => {
                info!("ACME 收到取消信号，退出证书管理任务");
                return;
            }
            _ = tokio::time::sleep(next_interval) => {}
        }
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

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
struct CleanupRecord {
    zone_id: String,
    record_id: String,
}

struct CleanupJournal {
    path: PathBuf,
    records: Vec<CleanupRecord>,
}

struct DnsCleanupState<'a> {
    records: &'a mut Vec<CleanupRecord>,
    journal: &'a mut CleanupJournal,
}

impl CleanupJournal {
    fn load(cert_dir: &str) -> anyhow::Result<Self> {
        let path = Path::new(cert_dir).join(ACME_CLEANUP_JOURNAL_FILE);
        let records = if path.is_file() {
            let raw = std::fs::read(&path).map_err(|error| {
                anyhow::anyhow!("读取 ACME 清理 journal {} 失败: {error}", path.display())
            })?;
            serde_json::from_slice(&raw).map_err(|error| {
                anyhow::anyhow!("解析 ACME 清理 journal {} 失败: {error}", path.display())
            })?
        } else {
            Vec::new()
        };
        Ok(Self { path, records })
    }

    fn is_empty(&self) -> bool {
        self.records.is_empty()
    }

    fn add(&mut self, record: CleanupRecord) -> anyhow::Result<()> {
        if !self.records.contains(&record) {
            self.records.push(record);
            self.persist()?;
        }
        Ok(())
    }

    fn remove_all(&mut self, records: &[CleanupRecord]) -> anyhow::Result<()> {
        self.records.retain(|record| !records.contains(record));
        self.persist()
    }

    fn persist(&self) -> anyhow::Result<()> {
        let data = serde_json::to_vec_pretty(&self.records)
            .map_err(|error| anyhow::anyhow!("序列化 ACME 清理 journal 失败: {error}"))?;
        store::write_atomic(&self.path, &data, 0o600)
    }
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

fn needs_legacy_adoption(acme: &AcmeConfig, store: &CertStore) -> bool {
    acme.domains.iter().any(|domain| {
        let status = store.renewal_status(domain, acme.renew_before_days);
        !status.needs_renewal && !store.has_valid_active_generation(domain)
    })
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
    if text.len() < LEN {
        return Vec::new();
    }

    // 按字符边界滑动定长窗口，并用 `str::get`（越界或非字符边界返回 None，而非 panic）。
    // text 来自 `format!("{e:#}")` 的 anyhow 错误信息——本项目错误信息含中文，
    // 旧实现 `&text[start..start + LEN]` 会在多字节字符中间 panic，叠加 panic=abort 拖垮整进程。
    let mut candidates = Vec::new();
    for (start, _) in text.char_indices() {
        let Some(candidate) = text.get(start..start + LEN) else {
            continue;
        };
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
async fn reconcile(
    acme: &AcmeConfig,
    cancel: &CancellationToken,
) -> anyhow::Result<ReconcileOutcome> {
    let store = CertStore::new(&acme.cert_dir, acme.ca_label());

    let mut pending = pending_domains(acme, &store, true);
    let needs_adoption = needs_legacy_adoption(acme, &store);
    let cleanup_journal = CleanupJournal::load(&acme.cert_dir)?;

    if pending.is_empty() && !needs_adoption && cleanup_journal.is_empty() {
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

    // 拿到锁后先把有效 legacy 证书采纳为 active generation，统一 ACME 与
    // entrypoint 的证书来源；临近到期的证书仍保留在 pending 中直接签新证书。
    for domain in &acme.domains {
        let status = store.renewal_status(domain, acme.renew_before_days);
        if !status.needs_renewal && store.adopt_existing(domain)? {
            info!(domain = %domain, "已将 legacy 证书采纳为 active generation");
        }
    }

    // 拿到锁并完成采纳后再检查一次，避免并发实例刚刚写入证书后继续创建新 order。
    pending = pending_domains(acme, &store, false);
    let mut cleanup_journal = CleanupJournal::load(&acme.cert_dir)?;
    if pending.is_empty() && cleanup_journal.is_empty() {
        info!("获取 ACME 锁后复查发现所有证书均在有效期内，无需续期");
        return Ok(ReconcileOutcome::Done);
    }

    let token = acme.resolve_token()?;
    let cf = Cloudflare::new(token)?;
    if !cleanup_journal.is_empty() {
        let stale_records = cleanup_journal.records.clone();
        info!(
            count = stale_records.len(),
            "重试清理上轮残留的 DNS-01 TXT 记录"
        );
        cleanup_dns_records(&cf, &stale_records, &mut cleanup_journal).await?;
    }
    if pending.is_empty() {
        return Ok(ReconcileOutcome::Done);
    }
    let account = load_or_create_account(acme).await?;

    let mut failures = Vec::new();
    for domain in pending {
        if cancel.is_cancelled() {
            warn!("收到取消信号，停止处理剩余待签发域名");
            break;
        }
        info!(domain = %domain, "开始签发/续期证书");
        match issue(
            acme,
            &cf,
            &account,
            &store,
            domain,
            cancel,
            &mut cleanup_journal,
        )
        .await
        {
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
            acme.directory_url().to_owned(),
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

    // 与 store.rs 一致的原子写：OpenOptions.mode(0o600) 原子创建（消除 write→chmod 的 0644 窗口）
    // + sync_all + 父目录 fsync（断电不丢账户凭据，避免重新注册触发 CA new-account 限流）。
    store::write_atomic(path, &data, 0o600)?;
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
    cancel: &CancellationToken,
    cleanup_journal: &mut CleanupJournal,
) -> anyhow::Result<()> {
    let identifiers = [Identifier::Dns(domain.to_string())];
    let mut order = account
        .new_order(&NewOrder::new(&identifiers))
        .await
        .map_err(|e| anyhow::anyhow!("创建 ACME order 失败: {e}"))?;

    // 待清理的 TXT 记录 (zone_id, record_id)。
    let mut cleanups: Vec<CleanupRecord> = Vec::new();
    let result = {
        let mut cleanup_state = DnsCleanupState {
            records: &mut cleanups,
            journal: cleanup_journal,
        };
        complete_dns01_order(
            acme,
            cf,
            store,
            domain,
            &mut order,
            &mut cleanup_state,
            cancel,
        )
        .await
    };

    // 无论成功、失败还是停机取消，都尽力清理已经创建的 TXT 记录。
    let cleanup_result = cleanup_dns_records(cf, &cleanups, cleanup_journal).await;
    match (result, cleanup_result) {
        (Ok(()), Ok(())) => Ok(()),
        (Err(issue_error), Ok(())) => Err(issue_error),
        (Ok(()), Err(cleanup_error)) => Err(cleanup_error),
        (Err(issue_error), Err(cleanup_error)) => Err(anyhow::anyhow!(
            "{issue_error:#}; DNS-01 TXT 清理同时失败: {cleanup_error:#}"
        )),
    }
}

async fn cleanup_dns_records(
    cf: &Cloudflare,
    cleanups: &[CleanupRecord],
    cleanup_journal: &mut CleanupJournal,
) -> anyhow::Result<()> {
    let mut deleted = Vec::new();
    let mut failures = Vec::new();
    for cleanup in cleanups {
        for attempt in 0..DNS_CLEANUP_ATTEMPTS {
            let result = match tokio::time::timeout(
                DNS_CLEANUP_ATTEMPT_TIMEOUT,
                cf.delete_txt(&cleanup.zone_id, &cleanup.record_id),
            )
            .await
            {
                Ok(result) => result,
                Err(_) => Err(anyhow::anyhow!(
                    "清理 TXT 记录单次请求超过 {} 秒",
                    DNS_CLEANUP_ATTEMPT_TIMEOUT.as_secs()
                )),
            };
            match result {
                Ok(()) => {
                    deleted.push(cleanup.clone());
                    break;
                }
                Err(error) if attempt + 1 < DNS_CLEANUP_ATTEMPTS => {
                    let delay = DNS_CLEANUP_RETRY_INTERVAL.saturating_mul(1_u32 << attempt);
                    warn!(
                        %error,
                        attempt = attempt + 1,
                        retry_after_millis = delay.as_millis(),
                        "清理 TXT 记录失败，将重试"
                    );
                    tokio::time::sleep(delay).await;
                }
                Err(error) => {
                    error!(
                        %error,
                        attempts = DNS_CLEANUP_ATTEMPTS,
                        "清理 TXT 记录最终失败，已保留 journal 供下轮重试"
                    );
                    failures.push(format!(
                        "zone={} record={}: {error}",
                        cleanup.zone_id, cleanup.record_id
                    ));
                }
            }
        }
    }
    if !deleted.is_empty() {
        cleanup_journal.remove_all(&deleted)?;
    }
    if !failures.is_empty() {
        anyhow::bail!("清理 TXT 记录失败: {}", failures.join("; "));
    }
    Ok(())
}

async fn cancellable<T, F>(
    cancel: &CancellationToken,
    stage: &str,
    operation: F,
) -> anyhow::Result<T>
where
    F: Future<Output = anyhow::Result<T>>,
{
    tokio::select! {
        biased;
        _ = cancel.cancelled() => anyhow::bail!("{stage}期间收到取消信号"),
        result = operation => result,
    }
}

async fn complete_dns01_order(
    acme: &AcmeConfig,
    cf: &Cloudflare,
    store: &CertStore,
    domain: &str,
    order: &mut Order,
    cleanup_state: &mut DnsCleanupState<'_>,
    cancel: &CancellationToken,
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
            let cleanup = CleanupRecord { zone_id, record_id };
            cleanup_state.records.push(cleanup.clone());
            cleanup_state.journal.add(cleanup)?;

            wait_for_dns_txt(
                &record_name,
                &dns_value,
                Duration::from_secs(acme.dns_propagation_secs),
                cancel,
            )
            .await?;
            cancellable(cancel, "通知 CA 校验", async {
                challenge
                    .set_ready()
                    .await
                    .map_err(|e| anyhow::anyhow!("通知 CA 校验失败: {e}"))
            })
            .await?;
        }
    }

    cancellable(
        cancel,
        "等待 CA 签发证书",
        finalize_and_store(order, store, domain),
    )
    .await
}

async fn wait_for_dns_txt(
    name: &str,
    expected: &str,
    max_wait: Duration,
    cancel: &CancellationToken,
) -> anyhow::Result<()> {
    let http = HttpClient::builder()
        .user_agent("gtagate/0.1")
        .timeout(DNS_QUERY_TIMEOUT)
        .connect_timeout(DNS_CONNECT_TIMEOUT)
        .build()
        .map_err(|e| anyhow::anyhow!("构建 DNS 查询客户端失败: {e}"))?;

    let deadline = tokio::time::Instant::now() + max_wait.max(DNS_PROPAGATION_POLL_INTERVAL);
    loop {
        let visible = tokio::select! {
            biased;
            _ = cancel.cancelled() => {
                anyhow::bail!("等待 DNS-01 TXT 期间收到取消信号，提前返回以触发 TXT 清理: {name}");
            }
            visible = dns_txt_is_visible(&http, name, expected) => visible,
        };
        if visible {
            info!(record = %name, "DNS-01 TXT 记录已传播");
            return Ok(());
        }

        let now = tokio::time::Instant::now();
        if now >= deadline {
            anyhow::bail!("等待 DNS-01 TXT 记录传播超时: {name}");
        }

        tokio::select! {
            _ = cancel.cancelled() => {
                anyhow::bail!("等待 DNS-01 TXT 期间收到取消信号，提前返回以触发 TXT 清理: {name}");
            }
            _ = tokio::time::sleep(DNS_PROPAGATION_POLL_INTERVAL.min(deadline - now)) => {}
        }
    }
}

async fn dns_txt_is_visible(http: &HttpClient, name: &str, expected: &str) -> bool {
    let (cloudflare, google) = tokio::join!(
        query_dns_txt(http, DNS_JSON_RESOLVERS[0], name),
        query_dns_txt(http, DNS_JSON_RESOLVERS[1], name),
    );
    let mut confirmations = 0;
    let mut successful_queries = 0;
    for (resolver, result) in DNS_JSON_RESOLVERS.into_iter().zip([cloudflare, google]) {
        match result {
            Ok(answers) => {
                successful_queries += 1;
                if txt_answers_contain_exact(&answers, expected) {
                    confirmations += 1;
                }
            }
            Err(e) => debug!(resolver, record = %name, error = %e, "DNS TXT 查询失败"),
        }
    }
    dns_visibility_confirmed(successful_queries, confirmations)
}

fn dns_visibility_confirmed(successful_queries: usize, confirmations: usize) -> bool {
    confirmations > 0 && confirmations == successful_queries
}

fn txt_answers_contain_exact(answers: &[String], expected: &str) -> bool {
    answers
        .iter()
        .filter_map(|answer| decode_dns_json_txt(answer))
        .any(|value| value == expected)
}

fn decode_dns_json_txt(answer: &str) -> Option<String> {
    let mut remaining = answer.trim();
    let mut decoded = String::new();
    while !remaining.is_empty() {
        remaining = remaining.strip_prefix('"')?;
        let mut escaped = false;
        let mut closing_index = None;
        for (index, character) in remaining.char_indices() {
            if escaped {
                decoded.push(character);
                escaped = false;
            } else if character == '\\' {
                escaped = true;
            } else if character == '"' {
                closing_index = Some(index);
                break;
            } else {
                decoded.push(character);
            }
        }
        if escaped {
            return None;
        }
        let closing_index = closing_index?;
        remaining = remaining[closing_index + 1..].trim_start();
    }
    Some(decoded)
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
    use rcgen::{CertifiedKey, generate_simple_self_signed};
    use tempfile::tempdir;
    use time::macros::datetime;

    #[tokio::test]
    async fn reconcile_adopts_valid_legacy_certificate() -> anyhow::Result<()> {
        let temp = tempdir()?;
        let cert_dir = temp.path().to_string_lossy().into_owned();
        let acme = AcmeConfig {
            enabled: true,
            domains: vec!["example.com".to_owned()],
            email: "admin@example.com".to_owned(),
            ca: "letsencrypt-staging".to_owned(),
            cloudflare_api_token: None,
            cloudflare_api_token_file: None,
            cert_dir: cert_dir.clone(),
            renew_before_days: 30,
            dns_propagation_secs: 60,
        };
        let store = CertStore::new(&cert_dir, acme.ca_label());
        let CertifiedKey { cert, signing_key } =
            generate_simple_self_signed(vec!["example.com".to_owned()])?;
        let cert_path = store.cert_path("example.com");
        let key_path = store.key_path("example.com");
        std::fs::create_dir_all(cert_path.parent().ok_or_else(|| {
            anyhow::anyhow!("legacy certificate path unexpectedly has no parent")
        })?)?;
        std::fs::write(cert_path, cert.pem())?;
        std::fs::write(key_path, signing_key.serialize_pem())?;

        reconcile(&acme, &CancellationToken::new()).await?;

        assert!(
            temp.path()
                .join("letsencrypt-staging")
                .join("example.com")
                .join(".gtagate-current")
                .is_file()
        );
        Ok(())
    }

    #[cfg(unix)]
    #[test]
    fn cleanup_journal_persists_and_removes_records() -> anyhow::Result<()> {
        use std::os::unix::fs::PermissionsExt;

        let temp = tempdir()?;
        let cert_dir = temp.path().to_string_lossy();
        let record = CleanupRecord {
            zone_id: "zone-1".to_owned(),
            record_id: "record-1".to_owned(),
        };
        let mut journal = CleanupJournal::load(&cert_dir)?;
        journal.add(record.clone())?;

        let mut reloaded = CleanupJournal::load(&cert_dir)?;
        assert_eq!(reloaded.records, vec![record.clone()]);
        assert_eq!(
            std::fs::metadata(&reloaded.path)?.permissions().mode() & 0o777,
            0o600
        );

        reloaded.remove_all(&[record])?;
        assert!(CleanupJournal::load(&cert_dir)?.is_empty());
        Ok(())
    }

    #[test]
    fn dns_txt_matching_requires_exact_decoded_token() {
        let expected = "challenge-token";
        assert!(txt_answers_contain_exact(
            &["\"challenge-token\"".to_owned()],
            expected
        ));
        assert!(txt_answers_contain_exact(
            &["\"challenge-\" \"token\"".to_owned()],
            expected
        ));
        assert!(!txt_answers_contain_exact(
            &["\"prefix-challenge-token-suffix\"".to_owned()],
            expected
        ));
        assert!(!txt_answers_contain_exact(
            &["challenge-token".to_owned()],
            expected
        ));
    }

    #[test]
    fn dns_visibility_tolerates_resolver_failure_but_not_disagreement() {
        assert!(dns_visibility_confirmed(1, 1));
        assert!(dns_visibility_confirmed(2, 2));
        assert!(!dns_visibility_confirmed(2, 1));
        assert!(!dns_visibility_confirmed(0, 0));
    }

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
    fn retry_after_parsing_is_panic_free_on_multibyte_text() {
        let now = datetime!(2026-06-08 10:00 UTC);
        // anyhow 错误信息常含中文：含合法 LE 时间戳时仍能解析，且绝不 panic。
        assert_eq!(
            parse_retry_after_delay(
                "证书签发失败：rateLimited，请 retry after 2026-06-08 20:00:00 UTC 后重试",
                now,
            ),
            Some(Duration::from_secs(10 * 3600))
        );
        // 纯中文、无时间戳：返回 None 且不 panic（旧实现会在此 panic）。
        assert_eq!(parse_retry_after_delay("证书签发失败：未知错误", now), None);
    }

    #[tokio::test]
    async fn cancellable_operation_returns_immediately_on_shutdown() {
        let cancel = CancellationToken::new();
        cancel.cancel();

        let result = cancellable(
            &cancel,
            "测试阶段",
            std::future::pending::<anyhow::Result<()>>(),
        )
        .await;

        assert!(result.is_err());
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
