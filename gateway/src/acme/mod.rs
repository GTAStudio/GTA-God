//! ACME 管理器：基于 instant-acme（RFC 8555）+ Cloudflare DNS-01，自动签发与续期
//! 泛域名证书，并按 GTA-God 期望的布局落盘。

mod cloudflare;
mod store;

use std::sync::Arc;
use std::time::Duration;

use instant_acme::{
    Account, AuthorizationStatus, ChallengeType, Identifier, NewAccount, NewOrder, Order,
    OrderStatus, RetryPolicy,
};
use tracing::{error, info, warn};

use crate::config::AcmeConfig;
use cloudflare::Cloudflare;
use store::CertStore;

/// 每轮续期检查的间隔。
const RENEW_CHECK_INTERVAL: Duration = Duration::from_secs(12 * 3600);

/// 启动 ACME 后台任务：先做一轮签发，然后周期性检查续期。
pub async fn run(acme: AcmeConfig) {
    if !acme.enabled {
        info!("ACME 未启用，跳过证书管理");
        return;
    }

    let acme = Arc::new(acme);
    loop {
        if let Err(e) = reconcile(&acme).await {
            error!(error = %e, "ACME 本轮签发/续期失败，将在下一轮重试");
        }
        tokio::time::sleep(RENEW_CHECK_INTERVAL).await;
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
    let account = create_account(acme).await?;

    for domain in pending {
        info!(domain = %domain, "开始签发/续期证书");
        match issue(acme, &cf, &account, &store, domain).await {
            Ok(()) => info!(domain = %domain, "证书已签发并落盘"),
            Err(e) => error!(domain = %domain, error = %e, "证书签发失败"),
        }
    }
    Ok(())
}

/// 创建 ACME 账户（每个进程生命周期内复用一个账户）。
async fn create_account(acme: &AcmeConfig) -> anyhow::Result<Account> {
    let contact = format!("mailto:{}", acme.email);

    let (account, _credentials) = Account::builder()
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
    Ok(account)
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

        // 等待 DNS 传播后再通知 CA 校验。
        tokio::time::sleep(Duration::from_secs(acme.dns_propagation_secs)).await;
        challenge
            .set_ready()
            .await
            .map_err(|e| anyhow::anyhow!("通知 CA 校验失败: {e}"))?;
        }
    }

    let result = finalize_and_store(&mut order, store, domain).await;

    // 无论成功与否，清理 TXT 记录。
    for (zone_id, record_id) in &cleanups {
        if let Err(e) = cf.delete_txt(zone_id, record_id).await {
            warn!(error = %e, "清理 TXT 记录失败（可忽略）");
        }
    }

    result
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
