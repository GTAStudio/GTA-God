//! 证书落盘与到期检查。
//!
//! 存储布局与 GTA-God 的 `docker-entrypoint.sh::find_certificate` 兼容：
//! `<cert_dir>/<ca_label>/wildcard_.<domain>/wildcard_.<domain>.crt` + `.key`。

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use x509_parser::prelude::*;

const SECONDS_PER_DAY: u64 = 86_400;

#[derive(Debug, Clone)]
pub struct StoredCertificate {
    pub cert_path: PathBuf,
    pub key_path: PathBuf,
    pub not_before: SystemTime,
    pub not_after: SystemTime,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RenewalReason {
    Missing,
    MissingKey,
    Expired,
    WithinRenewalWindow,
    RecentlyIssued,
    Valid,
}

#[derive(Debug, Clone)]
pub struct RenewalStatus {
    pub certificate: Option<StoredCertificate>,
    pub remaining: Option<Duration>,
    pub needs_renewal: bool,
    pub reason: RenewalReason,
}

/// 证书存储管理器。
pub struct CertStore {
    cert_dir: PathBuf,
    root: PathBuf,
}

impl CertStore {
    /// `cert_dir` 与 `ca_label` 组合成存储根目录。
    pub fn new(cert_dir: &str, ca_label: &str) -> Self {
        let cert_dir = Path::new(cert_dir).to_path_buf();
        Self {
            root: cert_dir.join(ca_label),
            cert_dir,
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

        // entrypoint 监控证书文件 mtime；先写 key，最后写 cert，避免重启时读到新证书+旧私钥。
        write_atomic(&key_path, key_pem.as_bytes(), 0o600)?;
        write_atomic(&cert_path, cert_pem.as_bytes(), 0o644)?;
        Ok(())
    }

    /// 查找磁盘上可用于该域名的证书。优先检查 gtagate 自己的规范路径，
    /// 再递归兼容旧 Caddy CA 目录布局（例如 acme-v02.api.letsencrypt.org-directory）。
    pub fn find_existing(&self, domain: &str) -> Option<StoredCertificate> {
        let mut seen = HashSet::new();
        let mut matches = Vec::new();

        let canonical = self.cert_path(domain);
        if seen.insert(canonical.clone()) {
            self.push_candidate(&canonical, domain, &mut matches);
        }
        self.scan_cert_dir(&self.cert_dir, domain, &mut seen, &mut matches);

        matches.into_iter().max_by_key(|cert| cert.not_after)
    }

    /// 判断是否需要签发/续期：证书缺失，或剩余有效期不足阈值。
    pub fn renewal_status(&self, domain: &str, renew_before_days: i64) -> RenewalStatus {
        let Some(certificate) = self.find_existing(domain) else {
            return RenewalStatus {
                certificate: None,
                remaining: None,
                needs_renewal: true,
                reason: if self.has_matching_cert_without_key(domain) {
                    RenewalReason::MissingKey
                } else {
                    RenewalReason::Missing
                },
            };
        };

        let threshold =
            Duration::from_secs((renew_before_days.max(0) as u64).saturating_mul(SECONDS_PER_DAY));
        let now = SystemTime::now();
        let recently_issued = now
            .duration_since(certificate.not_before)
            .is_ok_and(|age| age <= Duration::from_secs(3600));

        match certificate.not_after.duration_since(now) {
            Ok(remaining) if recently_issued => RenewalStatus {
                certificate: Some(certificate),
                remaining: Some(remaining),
                needs_renewal: false,
                reason: RenewalReason::RecentlyIssued,
            },
            Ok(remaining) if remaining > threshold => RenewalStatus {
                certificate: Some(certificate),
                remaining: Some(remaining),
                needs_renewal: false,
                reason: RenewalReason::Valid,
            },
            Ok(remaining) => RenewalStatus {
                certificate: Some(certificate),
                remaining: Some(remaining),
                needs_renewal: true,
                reason: RenewalReason::WithinRenewalWindow,
            },
            Err(_) => RenewalStatus {
                certificate: Some(certificate),
                remaining: None,
                needs_renewal: true,
                reason: RenewalReason::Expired,
            },
        }
    }

    fn has_matching_cert_without_key(&self, domain: &str) -> bool {
        let mut seen = HashSet::new();
        let mut candidates = Vec::new();

        if seen.insert(self.cert_path(domain)) {
            candidates.push(self.cert_path(domain));
        }
        self.collect_cert_paths(&self.cert_dir, &mut seen, &mut candidates);

        candidates.into_iter().any(|cert_path| {
            cert_path.is_file()
                && !cert_path.with_extension("key").is_file()
                && read_matching_cert_times(&cert_path, domain).is_some()
        })
    }

    fn push_candidate(&self, cert_path: &Path, domain: &str, matches: &mut Vec<StoredCertificate>) {
        if !cert_path.is_file() {
            return;
        }

        let key_path = cert_path.with_extension("key");
        if !key_path.is_file() {
            return;
        }

        let Some((not_before, not_after)) = read_matching_cert_times(cert_path, domain) else {
            return;
        };

        matches.push(StoredCertificate {
            cert_path: cert_path.to_path_buf(),
            key_path,
            not_before,
            not_after,
        });
    }

    fn collect_cert_paths(
        &self,
        dir: &Path,
        seen: &mut HashSet<PathBuf>,
        candidates: &mut Vec<PathBuf>,
    ) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };

        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                self.collect_cert_paths(&path, seen, candidates);
            } else if path
                .extension()
                .and_then(|ext| ext.to_str())
                .is_some_and(|ext| ext.eq_ignore_ascii_case("crt"))
                && seen.insert(path.clone())
            {
                candidates.push(path);
            }
        }
    }

    fn scan_cert_dir(
        &self,
        dir: &Path,
        domain: &str,
        seen: &mut HashSet<PathBuf>,
        matches: &mut Vec<StoredCertificate>,
    ) {
        let mut candidates = Vec::new();
        self.collect_cert_paths(dir, seen, &mut candidates);
        for path in candidates {
            self.push_candidate(&path, domain, matches);
        }
    }
}

fn read_matching_cert_times(path: &Path, domain: &str) -> Option<(SystemTime, SystemTime)> {
    let data = std::fs::read(path).ok()?;
    for pem in Pem::iter_from_buffer(&data).flatten() {
        if let Ok(cert) = pem.parse_x509() {
            if !certificate_covers_domain(&cert, domain) {
                continue;
            }

            let not_before = system_time_from_timestamp(cert.validity().not_before.timestamp())?;
            let not_after = system_time_from_timestamp(cert.validity().not_after.timestamp())?;
            return Some((not_before, not_after));
        }
    }
    None
}

fn system_time_from_timestamp(secs: i64) -> Option<SystemTime> {
    if secs < 0 {
        return None;
    }
    Some(UNIX_EPOCH + Duration::from_secs(secs as u64))
}

fn certificate_covers_domain(cert: &X509Certificate<'_>, domain: &str) -> bool {
    if let Ok(Some(san)) = cert.subject_alternative_name() {
        return san.value.general_names.iter().any(|name| match name {
            GeneralName::DNSName(dns_name) => dns_name_matches(dns_name, domain),
            _ => false,
        });
    }

    cert.subject()
        .iter_common_name()
        .filter_map(|cn| cn.as_str().ok())
        .any(|cn| dns_name_matches(cn, domain))
}

fn dns_name_matches(cert_name: &str, requested_domain: &str) -> bool {
    let cert_name = normalize_dns_name(cert_name);
    let requested_domain = normalize_dns_name(requested_domain);

    if cert_name == requested_domain {
        return true;
    }

    let Some(wildcard_base) = cert_name.strip_prefix("*.") else {
        return false;
    };

    if requested_domain.starts_with("*.") {
        return false;
    }

    let Some(label) = requested_domain.strip_suffix(wildcard_base) else {
        return false;
    };

    label.ends_with('.') && !label[..label.len() - 1].contains('.')
}

fn normalize_dns_name(name: &str) -> String {
    name.trim().trim_end_matches('.').to_ascii_lowercase()
}

/// 写临时文件后 rename，避免读取到半截内容；并设置 Unix 权限。
/// 使用 OpenOptions + mode 原子创建，消除 write→chmod 之间的 TOCTOU 窗口。
/// fsync 确保断电后数据持久性（不丢证书/私钥）。
/// 供本模块与 acme::mod（账户凭据落盘）复用。
pub(crate) fn write_atomic(path: &Path, data: &[u8], mode: u32) -> anyhow::Result<()> {
    // 使用带 mode 后缀的 tmp 名，避免 .crt 和 .key 共享同一 .tmp 路径
    let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("dat");
    let tmp = path.with_extension(format!("{ext}.tmp"));

    #[cfg(unix)]
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(mode)
            .open(&tmp)
            .map_err(|e| anyhow::anyhow!("创建临时文件 {} 失败: {e}", tmp.display()))?;
        file.write_all(data)
            .map_err(|e| anyhow::anyhow!("写入临时文件 {} 失败: {e}", tmp.display()))?;
        file.sync_all()
            .map_err(|e| anyhow::anyhow!("fsync 临时文件 {} 失败: {e}", tmp.display()))?;
    }

    #[cfg(not(unix))]
    {
        let _ = mode;
        std::fs::write(&tmp, data)
            .map_err(|e| anyhow::anyhow!("写入临时文件 {} 失败: {e}", tmp.display()))?;
    }

    std::fs::rename(&tmp, path)
        .map_err(|e| anyhow::anyhow!("重命名 {} 失败: {e}", path.display()))?;

    // fsync 父目录，确保目录条目持久化（断电后不丢文件）。
    #[cfg(unix)]
    if let Some(parent) = path.parent()
        && let Ok(dir) = std::fs::File::open(parent)
    {
        let _ = dir.sync_all();
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wildcard_request_requires_wildcard_certificate() {
        assert!(dns_name_matches("*.99gtr.com", "*.99gtr.com"));
        assert!(!dns_name_matches("99gtr.com", "*.99gtr.com"));
    }

    #[test]
    fn wildcard_certificate_matches_single_label_only() {
        assert!(dns_name_matches("*.99gtr.com", "sa.99gtr.com"));
        assert!(!dns_name_matches("*.99gtr.com", "deep.sa.99gtr.com"));
        assert!(!dns_name_matches("*.99gtr.com", "99gtr.com"));
    }
}
