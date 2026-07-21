//! 证书落盘与到期检查。
//!
//! 存储布局与 GTA-God 的 `docker-entrypoint.sh::find_certificate` 兼容：
//! `<cert_dir>/<ca_label>/wildcard_.<domain>/wildcard_.<domain>.crt` + `.key`。

use std::collections::HashSet;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context, bail};
use rcgen::{KeyPair, PublicKeyData};
use x509_parser::prelude::*;

const CURRENT_FILE: &str = ".gtagate-current";
const GENERATIONS_DIR: &str = ".gtagate-generations";
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
    root: PathBuf,
    legacy_root: PathBuf,
}

impl CertStore {
    /// `cert_dir` 与 `ca_label` 组合成存储根目录。
    pub fn new(cert_dir: &str, ca_label: &str) -> Self {
        let cert_dir = Path::new(cert_dir).to_path_buf();
        let legacy_ca_label = match ca_label {
            "letsencrypt-staging" => "acme-staging-v02.api.letsencrypt.org-directory",
            _ => "acme-v02.api.letsencrypt.org-directory",
        };
        Self {
            root: cert_dir.join(ca_label),
            legacy_root: cert_dir.join(legacy_ca_label),
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

    pub(super) fn has_valid_active_generation(&self, domain: &str) -> bool {
        let Some((cert_path, key_path)) = self.active_paths(domain) else {
            return false;
        };
        read_valid_certificate_pair_times(&cert_path, &key_path, domain).is_some()
    }

    pub(super) fn adopt_existing(&self, domain: &str) -> anyhow::Result<bool> {
        if self.has_valid_active_generation(domain) {
            return Ok(false);
        }
        let Some(existing) = self.find_existing(domain) else {
            return Ok(false);
        };
        let cert_pem = std::fs::read_to_string(&existing.cert_path).map_err(|error| {
            anyhow::anyhow!(
                "读取待采纳证书 {} 失败: {error}",
                existing.cert_path.display()
            )
        })?;
        let key_pem = std::fs::read_to_string(&existing.key_path).map_err(|error| {
            anyhow::anyhow!(
                "读取待采纳私钥 {} 失败: {error}",
                existing.key_path.display()
            )
        })?;
        self.save(domain, &cert_pem, &key_pem)?;
        Ok(true)
    }

    fn legacy_paths(&self, domain: &str) -> (PathBuf, PathBuf) {
        (self.cert_path(domain), self.key_path(domain))
    }

    fn active_paths(&self, domain: &str) -> Option<(PathBuf, PathBuf)> {
        let dir = self.dir_for(domain);
        let generation = std::fs::read_to_string(dir.join(CURRENT_FILE)).ok()?;
        let generation = generation.trim();
        if !valid_generation_name(generation) {
            return None;
        }

        let label = Self::label(domain);
        let generation_dir = dir.join(GENERATIONS_DIR).join(generation);
        Some((
            generation_dir.join(format!("{label}.crt")),
            generation_dir.join(format!("{label}.key")),
        ))
    }

    /// 将完整证书/私钥对写入不可变 generation，再原子切换 current 提交点。
    pub fn save(&self, domain: &str, cert_pem: &str, key_pem: &str) -> anyhow::Result<()> {
        let (not_before, not_after) =
            validate_certificate_pair(domain, cert_pem.as_bytes(), key_pem.as_bytes())?;
        let now = SystemTime::now();
        if now < not_before || now >= not_after {
            bail!("签发证书当前不在有效期内，拒绝发布");
        }

        let dir = self.dir_for(domain);
        std::fs::create_dir_all(&dir)
            .map_err(|e| anyhow::anyhow!("创建证书目录 {} 失败: {e}", dir.display()))?;

        let generations_dir = dir.join(GENERATIONS_DIR);
        std::fs::create_dir_all(&generations_dir).map_err(|e| {
            anyhow::anyhow!(
                "创建证书 generation 根目录 {} 失败: {e}",
                generations_dir.display()
            )
        })?;

        let generation = unique_name("generation")?;
        let generation_dir = generations_dir.join(&generation);
        std::fs::create_dir(&generation_dir).map_err(|e| {
            anyhow::anyhow!(
                "创建证书 generation 目录 {} 失败: {e}",
                generation_dir.display()
            )
        })?;

        let label = Self::label(domain);
        let cert_path = generation_dir.join(format!("{label}.crt"));
        let key_path = generation_dir.join(format!("{label}.key"));

        let prepare_result = write_new_file(&key_path, key_pem.as_bytes(), 0o600)
            .and_then(|_| write_new_file(&cert_path, cert_pem.as_bytes(), 0o644))
            .and_then(|_| sync_directory(&generation_dir))
            .and_then(|_| sync_directory(&generations_dir))
            .and_then(|_| sync_directory(&dir));
        if let Err(error) = prepare_result {
            let _ = std::fs::remove_dir_all(&generation_dir);
            return Err(error);
        }

        // publish_generation 返回后才允许读者看到新 generation。发布后即使父目录
        // fsync 报错，也不能删除 generation，否则 current 会指向不存在的证书对。
        publish_generation(&dir, &generation)?;
        Ok(())
    }

    /// 查找磁盘上可用于该域名的证书。优先检查 gtagate 自己的规范路径，
    /// 再兼容所选 CA 对应的旧 Caddy 目录；绝不跨 production/staging 信任边界。
    pub fn find_existing(&self, domain: &str) -> Option<StoredCertificate> {
        let mut seen = HashSet::new();
        let mut matches = Vec::new();

        if let Some((cert_path, key_path)) = self.active_paths(domain)
            && cert_path.is_file()
            && key_path.is_file()
        {
            self.push_candidate(&cert_path, domain, &mut matches);
            return matches.pop();
        }

        let (canonical, _) = self.legacy_paths(domain);
        if seen.insert(canonical.clone()) {
            self.push_candidate(&canonical, domain, &mut matches);
        }
        self.scan_cert_dir(&self.legacy_root, domain, &mut seen, &mut matches);

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

        if let Some((cert_path, _)) = self.active_paths(domain)
            && seen.insert(cert_path.clone())
        {
            candidates.push(cert_path);
        }

        let (canonical, _) = self.legacy_paths(domain);
        if seen.insert(canonical.clone()) {
            candidates.push(canonical);
        }
        self.collect_cert_paths(&self.legacy_root, &mut seen, &mut candidates);

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

        let Some((not_before, not_after)) =
            read_valid_certificate_pair_times(cert_path, &key_path, domain)
        else {
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
            // 用 DirEntry::file_type()（不跟随符号链接）而非 Path::is_dir()（会跟随符号链接）。
            // 后者遇到指回祖先目录的符号链接会无限递归 → 栈溢出 → panic=abort →
            // --restart 持续崩溃循环（环在持久卷里，每次启动首轮 reconcile 即崩）。
            // 证书目录是纯目录布局，跳过符号链接子目录无功能损失；指向证书文件的符号
            // 链接仍会在下方按扩展名进入 candidates（read_matching_cert_times 的 fs::read
            // 跟随读取目标），故"符号链接指向证书文件"的用法不受影响。
            if entry.file_name() == GENERATIONS_DIR {
                continue;
            }
            if entry.file_type().is_ok_and(|t| t.is_dir()) {
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

fn valid_generation_name(name: &str) -> bool {
    name.strip_prefix("generation-").is_some_and(|suffix| {
        suffix.len() == 32 && suffix.bytes().all(|byte| byte.is_ascii_hexdigit())
    })
}

fn unique_name(prefix: &str) -> anyhow::Result<String> {
    let mut random = [0_u8; 16];
    getrandom::fill(&mut random)
        .map_err(|error| anyhow::anyhow!("生成安全临时文件名失败: {error}"))?;
    Ok(format!("{prefix}-{:032x}", u128::from_be_bytes(random)))
}

fn validate_certificate_pair(
    domain: &str,
    cert_pem: &[u8],
    key_pem: &[u8],
) -> anyhow::Result<(SystemTime, SystemTime)> {
    let leaf_pem = Pem::iter_from_buffer(cert_pem)
        .next()
        .context("证书链为空")?
        .map_err(|error| anyhow::anyhow!("解析 leaf 证书 PEM 失败: {error}"))?;
    if leaf_pem.label != "CERTIFICATE" {
        bail!("证书链首个 PEM 块不是 CERTIFICATE");
    }

    let leaf = leaf_pem
        .parse_x509()
        .map_err(|error| anyhow::anyhow!("解析 leaf X.509 证书失败: {error}"))?;
    if leaf.is_ca() {
        bail!("leaf 证书不能是 CA 证书");
    }

    let san = leaf
        .subject_alternative_name()
        .map_err(|error| anyhow::anyhow!("解析 leaf 证书 subjectAltName 失败: {error}"))?
        .context("leaf 证书缺少 subjectAltName")?;
    if !san.value.general_names.iter().any(
        |name| matches!(name, GeneralName::DNSName(dns_name) if dns_name_matches(dns_name, domain)),
    ) {
        bail!("leaf 证书不覆盖请求域名 {domain}");
    }

    let key_pem = std::str::from_utf8(key_pem).context("私钥 PEM 不是有效 UTF-8")?;
    let key_pair = KeyPair::from_pem(key_pem).context("解析私钥 PEM 失败")?;
    if key_pair.subject_public_key_info().as_slice() != leaf.public_key().raw {
        bail!("leaf 证书与私钥不匹配");
    }

    let not_before = system_time_from_timestamp(leaf.validity().not_before.timestamp())
        .context("leaf 证书 notBefore 超出可表示范围")?;
    let not_after = system_time_from_timestamp(leaf.validity().not_after.timestamp())
        .context("leaf 证书 notAfter 超出可表示范围")?;
    if not_after <= not_before {
        bail!("leaf 证书有效期范围无效");
    }
    Ok((not_before, not_after))
}

fn read_valid_certificate_pair_times(
    cert_path: &Path,
    key_path: &Path,
    domain: &str,
) -> Option<(SystemTime, SystemTime)> {
    let cert_pem = std::fs::read(cert_path).ok()?;
    let key_pem = std::fs::read(key_path).ok()?;
    validate_certificate_pair(domain, &cert_pem, &key_pem).ok()
}

fn publish_generation(dir: &Path, generation: &str) -> anyhow::Result<()> {
    let current_path = dir.join(CURRENT_FILE);
    let temporary_path = dir.join(format!(".{CURRENT_FILE}.{}", unique_name("tmp")?));
    write_new_file(&temporary_path, format!("{generation}\n").as_bytes(), 0o644)?;

    if let Err(error) = std::fs::rename(&temporary_path, &current_path)
        .map_err(|error| anyhow::anyhow!("发布证书 generation 失败: {error}"))
    {
        let _ = std::fs::remove_file(&temporary_path);
        return Err(error);
    }
    sync_directory(dir)
}

fn write_new_file(path: &Path, data: &[u8], mode: u32) -> anyhow::Result<()> {
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(mode);
    }
    #[cfg(not(unix))]
    let _ = mode;

    let mut file = options
        .open(path)
        .map_err(|error| anyhow::anyhow!("独占创建文件 {} 失败: {error}", path.display()))?;
    let write_result = file
        .write_all(data)
        .map_err(|error| anyhow::anyhow!("写入文件 {} 失败: {error}", path.display()))
        .and_then(|_| {
            file.sync_all()
                .map_err(|error| anyhow::anyhow!("fsync 文件 {} 失败: {error}", path.display()))
        });
    if let Err(error) = write_result {
        drop(file);
        let _ = std::fs::remove_file(path);
        return Err(error);
    }
    Ok(())
}

#[cfg(unix)]
fn sync_directory(path: &Path) -> anyhow::Result<()> {
    std::fs::File::open(path)
        .map_err(|error| anyhow::anyhow!("打开目录 {} 以执行 fsync 失败: {error}", path.display()))?
        .sync_all()
        .map_err(|error| anyhow::anyhow!("fsync 目录 {} 失败: {error}", path.display()))
}

#[cfg(not(unix))]
fn sync_directory(_path: &Path) -> anyhow::Result<()> {
    Ok(())
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
    let parent = path.parent().context("原子写入目标路径缺少父目录")?;
    let temporary_path = parent.join(format!(".atomic-{}", unique_name("tmp")?));
    write_new_file(&temporary_path, data, mode)?;
    if let Err(error) = std::fs::rename(&temporary_path, path)
        .map_err(|error| anyhow::anyhow!("重命名 {} 失败: {error}", path.display()))
    {
        let _ = std::fs::remove_file(&temporary_path);
        return Err(error);
    }
    sync_directory(parent)
}

#[cfg(test)]
mod tests {
    use super::*;
    use rcgen::{CertifiedKey, generate_simple_self_signed};
    use tempfile::tempdir;

    fn must<T, E: std::fmt::Display>(result: Result<T, E>) -> T {
        match result {
            Ok(value) => value,
            Err(error) => panic!("test operation failed: {error}"),
        }
    }

    fn must_some<T>(value: Option<T>) -> T {
        match value {
            Some(value) => value,
            None => panic!("expected test value to be present"),
        }
    }

    fn certificate(domain: &str) -> (String, String) {
        let CertifiedKey { cert, signing_key } =
            must(generate_simple_self_signed(vec![domain.to_owned()]));
        (cert.pem(), signing_key.serialize_pem())
    }

    fn test_store(root: &Path) -> CertStore {
        CertStore::new(&root.to_string_lossy(), "test-ca")
    }

    #[test]
    fn publishes_complete_generation_and_finds_it() {
        let temp = must(tempdir());
        let store = test_store(temp.path());
        let (cert_pem, key_pem) = certificate("example.com");

        must(store.save("example.com", &cert_pem, &key_pem));

        let (cert_path, key_path) = must_some(store.active_paths("example.com"));
        assert!(cert_path.is_file());
        assert!(key_path.is_file());
        let found = must_some(store.find_existing("example.com"));
        assert_eq!(found.cert_path, cert_path);
        assert_eq!(found.key_path, key_path);
    }

    #[test]
    fn rejects_mismatched_private_key_without_publishing() {
        let temp = must(tempdir());
        let store = test_store(temp.path());
        let (cert_pem, _) = certificate("example.com");
        let (_, wrong_key_pem) = certificate("example.com");

        let error = match store.save("example.com", &cert_pem, &wrong_key_pem) {
            Ok(()) => panic!("mismatched certificate pair was accepted"),
            Err(error) => error,
        };

        assert!(error.to_string().contains("不匹配"));
        assert!(store.active_paths("example.com").is_none());
        assert!(store.find_existing("example.com").is_none());
    }

    #[test]
    fn invalid_active_generation_is_not_masked_by_legacy_certificate() {
        let temp = must(tempdir());
        let store = test_store(temp.path());
        let (legacy_cert, legacy_key) = certificate("example.com");
        must(std::fs::create_dir_all(store.dir_for("example.com")));
        must(std::fs::write(store.cert_path("example.com"), legacy_cert));
        must(std::fs::write(store.key_path("example.com"), legacy_key));

        let generation = "generation-00000000000000000000000000000000";
        let generation_dir = store
            .dir_for("example.com")
            .join(GENERATIONS_DIR)
            .join(generation);
        must(std::fs::create_dir_all(&generation_dir));
        let (active_cert, _) = certificate("example.com");
        let (_, wrong_key) = certificate("example.com");
        must(std::fs::write(
            generation_dir.join("example.com.crt"),
            active_cert,
        ));
        must(std::fs::write(
            generation_dir.join("example.com.key"),
            wrong_key,
        ));
        must(std::fs::write(
            store.dir_for("example.com").join(CURRENT_FILE),
            format!("{generation}\n"),
        ));

        assert!(store.find_existing("example.com").is_none());
        let status = store.renewal_status("example.com", 30);
        assert!(status.needs_renewal);
    }

    #[test]
    fn ignores_generation_without_current_commit() {
        let temp = must(tempdir());
        let store = test_store(temp.path());
        let generation_dir = store
            .dir_for("example.com")
            .join(GENERATIONS_DIR)
            .join("generation-00000000000000000000000000000000");
        must(std::fs::create_dir_all(&generation_dir));
        let (cert_pem, key_pem) = certificate("example.com");
        must(std::fs::write(
            generation_dir.join("example.com.crt"),
            cert_pem,
        ));
        must(std::fs::write(
            generation_dir.join("example.com.key"),
            key_pem,
        ));

        assert!(store.find_existing("example.com").is_none());
    }

    #[test]
    fn ignores_certificate_from_another_ca_tree() {
        let temp = must(tempdir());
        let store = CertStore::new(&temp.path().to_string_lossy(), "letsencrypt");
        let staging_dir = temp
            .path()
            .join("acme-staging-v02.api.letsencrypt.org-directory")
            .join("example.com");
        must(std::fs::create_dir_all(&staging_dir));
        let (cert_pem, key_pem) = certificate("example.com");
        must(std::fs::write(
            staging_dir.join("example.com.crt"),
            cert_pem,
        ));
        must(std::fs::write(staging_dir.join("example.com.key"), key_pem));

        assert!(store.find_existing("example.com").is_none());
    }

    #[test]
    fn rejects_certificate_for_another_domain() {
        let temp = must(tempdir());
        let store = test_store(temp.path());
        let (cert_pem, key_pem) = certificate("other.example");

        let error = match store.save("example.com", &cert_pem, &key_pem) {
            Ok(()) => panic!("certificate for another domain was accepted"),
            Err(error) => error,
        };

        assert!(error.to_string().contains("不覆盖"));
        assert!(store.active_paths("example.com").is_none());
    }

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
