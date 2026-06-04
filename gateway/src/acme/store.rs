//! 证书落盘与到期检查。
//!
//! 存储布局与 GTA-God 的 `docker-entrypoint.sh::find_certificate` 兼容：
//! `<cert_dir>/<ca_label>/wildcard_.<domain>/wildcard_.<domain>.crt` + `.key`。

use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use x509_parser::prelude::*;

/// 证书存储管理器。
pub struct CertStore {
    root: PathBuf,
}

impl CertStore {
    /// `cert_dir` 与 `ca_label` 组合成存储根目录。
    pub fn new(cert_dir: &str, ca_label: &str) -> Self {
        Self {
            root: Path::new(cert_dir).join(ca_label),
        }
    }

    /// 把域名转换为与 Caddy 一致的目录/文件名标签。
    fn label(domain: &str) -> String {
        if let Some(base) = domain.strip_prefix("*.") {
            format!("wildcard_.{base}")
        } else {
            domain.to_string()
        }
    }

    fn dir_for(&self, domain: &str) -> PathBuf {
        self.root.join(Self::label(domain))
    }

    /// 证书文件路径（`.crt`）。
    pub fn cert_path(&self, domain: &str) -> PathBuf {
        let label = Self::label(domain);
        self.dir_for(domain).join(format!("{label}.crt"))
    }

    /// 私钥文件路径（`.key`）。
    pub fn key_path(&self, domain: &str) -> PathBuf {
        let label = Self::label(domain);
        self.dir_for(domain).join(format!("{label}.key"))
    }

    /// 原子写入证书链与私钥，私钥权限收紧为 0600。
    pub fn save(&self, domain: &str, cert_pem: &str, key_pem: &str) -> anyhow::Result<()> {
        let dir = self.dir_for(domain);
        std::fs::create_dir_all(&dir)
            .map_err(|e| anyhow::anyhow!("创建证书目录 {} 失败: {e}", dir.display()))?;

        let cert_path = self.cert_path(domain);
        let key_path = self.key_path(domain);

        write_atomic(&cert_path, cert_pem.as_bytes(), 0o644)?;
        write_atomic(&key_path, key_pem.as_bytes(), 0o600)?;
        Ok(())
    }

    /// 读取磁盘上证书的到期时间；不存在或解析失败返回 None。
    pub fn not_after(&self, domain: &str) -> Option<SystemTime> {
        let cert_path = self.cert_path(domain);
        let data = std::fs::read(&cert_path).ok()?;
        for pem in Pem::iter_from_buffer(&data).flatten() {
            if let Ok(cert) = pem.parse_x509() {
                let secs = cert.validity().not_after.timestamp();
                if secs < 0 {
                    return None;
                }
                return Some(UNIX_EPOCH + Duration::from_secs(secs as u64));
            }
        }
        None
    }

    /// 判断是否需要签发/续期：证书缺失，或剩余有效期不足阈值。
    pub fn needs_renewal(&self, domain: &str, renew_before_days: i64) -> bool {
        match self.not_after(domain) {
            None => true,
            Some(not_after) => {
                let threshold = Duration::from_secs((renew_before_days.max(0) as u64) * 86_400);
                match not_after.duration_since(SystemTime::now()) {
                    Ok(remaining) => remaining <= threshold,
                    Err(_) => true, // 已过期。
                }
            }
        }
    }
}

/// 写临时文件后 rename，避免读取到半截内容；并设置 Unix 权限。
fn write_atomic(path: &Path, data: &[u8], mode: u32) -> anyhow::Result<()> {
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, data)
        .map_err(|e| anyhow::anyhow!("写入临时文件 {} 失败: {e}", tmp.display()))?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(mode))
            .map_err(|e| anyhow::anyhow!("设置 {} 权限失败: {e}", tmp.display()))?;
    }
    #[cfg(not(unix))]
    let _ = mode;

    std::fs::rename(&tmp, path)
        .map_err(|e| anyhow::anyhow!("重命名 {} 失败: {e}", path.display()))?;
    Ok(())
}
