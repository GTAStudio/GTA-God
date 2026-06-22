//! gtagate — GTA-God 的 L4 SNI 分流 + ACME(Cloudflare DNS-01) 网关。
//!
//! 纯 Rust 替代 Caddy 在本项目承担的两项职责：
//!   1. 监听 443，按 TLS SNI 透传分流到 sing-box 的各 inbound 本地端口；
//!   2. 通过 Cloudflare DNS-01 自动签发/续期泛域名证书并落盘。

mod acme;
mod config;
mod dispatch;
mod sni;

use std::path::PathBuf;
use std::sync::Arc;

use tokio_util::sync::CancellationToken;
use tracing::{error, info, warn};
use tracing_subscriber::EnvFilter;

const DEFAULT_CONFIG_PATH: &str = "/etc/gtagate/config.json";

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();

    // 安装默认 rustls 加密后端（供下游依赖使用）。
    let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();

    let arg = std::env::args().nth(1);
    match arg.as_deref() {
        Some("--version" | "-V") => {
            println!("gtagate {}", env!("CARGO_PKG_VERSION"));
            return Ok(());
        }
        Some("--help" | "-h") => {
            println!("用法: gtagate [配置文件路径]  (默认 {DEFAULT_CONFIG_PATH})");
            return Ok(());
        }
        _ => {}
    }

    let config_path = arg
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(DEFAULT_CONFIG_PATH));

    let cfg = Arc::new(config::Config::load(&config_path)?);
    info!(config = %config_path.display(), "gtagate 启动");

    // 优雅退出令牌：dispatcher 与 ACME 任务共用，收到信号时一并取消。
    let cancel = CancellationToken::new();

    // 后台启动 ACME 任务（不阻塞分流器；分流器为 TLS passthrough，无需等待证书）。
    // 保留 JoinHandle，退出时给在途 DNS-01 清理一点时间，避免残留 _acme-challenge TXT。
    let acme_task = cfg.acme.clone().map(|acme_cfg| {
        let cancel = cancel.clone();
        tokio::spawn(async move {
            acme::run(acme_cfg, cancel).await;
        })
    });
    if acme_task.is_none() {
        info!("未配置 ACME，仅运行 L4 分流");
    }

    let mut dispatcher = {
        let cfg = Arc::clone(&cfg);
        let cancel = cancel.clone();
        tokio::spawn(async move { dispatch::run(cfg, cancel).await })
    };

    tokio::select! {
        result = &mut dispatcher => {
            match result {
                Ok(Ok(())) => {}
                Ok(Err(e)) => {
                    error!(error = %e, "分流器异常退出");
                    return Err(e);
                }
                Err(e) => {
                    error!(error = %e, "分流器任务 panic");
                    anyhow::bail!("分流器任务失败");
                }
            }
        }
        _ = shutdown_signal() => {
            info!("收到退出信号，gtagate 正在优雅关闭");
            cancel.cancel();
            // 等待分流器 drain（内部 5s drain 超时先触发，此处 6s 兜底）；总停机预算需 < entrypoint 8s 看门狗 < Docker 10s grace。
            match tokio::time::timeout(std::time::Duration::from_secs(6), dispatcher).await {
                Ok(Ok(Ok(()))) => info!("分流器已优雅退出"),
                Ok(Ok(Err(e))) => error!(error = %e, "分流器退出时报错"),
                Ok(Err(e)) => error!(error = %e, "分流器任务 join 失败"),
                Err(_) => warn!("分流器优雅退出超时（6s），强制结束"),
            }
            // 给 ACME 任务一点时间响应取消并完成在途 DNS-01 TXT 清理（停机预算紧，仅 1s 尽力而为）。
            if let Some(handle) = acme_task {
                let _ = tokio::time::timeout(std::time::Duration::from_secs(1), handle).await;
            }
        }
    }
    Ok(())
}

/// 等待 SIGTERM / SIGINT。
async fn shutdown_signal() {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{SignalKind, signal};
        let mut term = match signal(SignalKind::terminate()) {
            Ok(s) => s,
            Err(_) => return,
        };
        let mut int = match signal(SignalKind::interrupt()) {
            Ok(s) => s,
            Err(_) => return,
        };
        tokio::select! {
            _ = term.recv() => {}
            _ = int.recv() => {}
        }
    }
    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}
