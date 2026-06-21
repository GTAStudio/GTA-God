//! Cloudflare DNS-01 provider：自动定位 zone、写入与清理 `_acme-challenge` TXT 记录。

use reqwest::Client;
use serde_json::json;
use tracing::debug;

const API_BASE: &str = "https://api.cloudflare.com/client/v4";

/// Cloudflare API 客户端（Bearer Token 认证）。
pub struct Cloudflare {
    token: String,
    http: Client,
}

impl Cloudflare {
    pub fn new(token: String) -> anyhow::Result<Self> {
        let http = Client::builder()
            .user_agent("gtagate/0.1")
            .build()
            .map_err(|e| anyhow::anyhow!("构建 HTTP 客户端失败: {e}"))?;
        Ok(Self { token, http })
    }

    /// 从待签发的基础域名向上查找其所属 zone，返回 zone_id。
    ///
    /// 例如 `a.b.example.com` 会依次尝试 `a.b.example.com`、`b.example.com`、
    /// `example.com`，直到 Cloudflare 返回匹配的 zone。
    pub async fn find_zone_id(&self, base: &str) -> anyhow::Result<String> {
        let mut candidate = base;
        loop {
            if let Some(zone_id) = self.query_zone(candidate).await? {
                debug!(zone = candidate, zone_id, "已定位 Cloudflare zone");
                return Ok(zone_id);
            }
            match candidate.split_once('.') {
                Some((_, rest)) if rest.contains('.') => candidate = rest,
                _ => anyhow::bail!("未能在 Cloudflare 找到 {base} 对应的 zone"),
            }
        }
    }

    async fn query_zone(&self, name: &str) -> anyhow::Result<Option<String>> {
        let resp = self
            .http
            .get(format!("{API_BASE}/zones"))
            .bearer_auth(&self.token)
            .query(&[("name", name), ("status", "active")])
            .send()
            .await
            .map_err(|e| anyhow::anyhow!("查询 zone {name} 失败: {e}"))?;
        let body: serde_json::Value = resp
            .json()
            .await
            .map_err(|e| anyhow::anyhow!("解析 zone 响应失败: {e}"))?;
        ensure_success(&body, "查询 zone")?;
        Ok(body["result"]
            .get(0)
            .and_then(|z| z["id"].as_str())
            .map(str::to_string))
    }

    /// 创建一条 TXT 记录，返回 record_id（用于后续清理）。
    pub async fn create_txt(
        &self,
        zone_id: &str,
        name: &str,
        content: &str,
    ) -> anyhow::Result<String> {
        let resp = self
            .http
            .post(format!("{API_BASE}/zones/{zone_id}/dns_records"))
            .bearer_auth(&self.token)
            .json(&json!({
                "type": "TXT",
                "name": name,
                "content": content,
                "ttl": 60,
            }))
            .send()
            .await
            .map_err(|e| anyhow::anyhow!("创建 TXT 记录失败: {e}"))?;
        let body: serde_json::Value = resp
            .json()
            .await
            .map_err(|e| anyhow::anyhow!("解析 TXT 创建响应失败: {e}"))?;
        ensure_success(&body, "创建 TXT 记录")?;
        body["result"]["id"]
            .as_str()
            .map(str::to_string)
            .ok_or_else(|| anyhow::anyhow!("TXT 创建响应缺少 record id"))
    }

    /// 删除一条 TXT 记录（best-effort，失败仅记录）。
    pub async fn delete_txt(&self, zone_id: &str, record_id: &str) -> anyhow::Result<()> {
        let resp = self
            .http
            .delete(format!(
                "{API_BASE}/zones/{zone_id}/dns_records/{record_id}"
            ))
            .bearer_auth(&self.token)
            .send()
            .await
            .map_err(|e| anyhow::anyhow!("删除 TXT 记录失败: {e}"))?;
        let body: serde_json::Value = resp
            .json()
            .await
            .map_err(|e| anyhow::anyhow!("解析 TXT 删除响应失败: {e}"))?;
        ensure_success(&body, "删除 TXT 记录")?;
        Ok(())
    }
}

/// 校验 Cloudflare API 返回的 `success` 字段。
fn ensure_success(body: &serde_json::Value, action: &str) -> anyhow::Result<()> {
    if body["success"].as_bool() == Some(true) {
        return Ok(());
    }
    let errors = body["errors"].to_string();
    anyhow::bail!("{action} 失败: {errors}")
}
