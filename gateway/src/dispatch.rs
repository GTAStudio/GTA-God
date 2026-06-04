//! L4 SNI 分流器：监听 TCP，窥探 ClientHello 的 SNI，按精确匹配把整条 TLS
//! 连接透传（passthrough）到对应上游。等价于 caddy-l4 在本项目中的用法。

use std::io;
use std::sync::Arc;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Semaphore;
use tokio::time::timeout;
use tracing::{debug, info, warn};

use crate::config::Config;
use crate::sni::{SniResult, extract_sni};

/// 单连接读取 ClientHello 的缓冲上限，超过则放弃解析走默认路由。
const MAX_CLIENT_HELLO: usize = 16 * 1024;

/// accept 出现瞬时错误（如 fd 耗尽 EMFILE）时的退避时长，避免 CPU 空转。
const ACCEPT_BACKOFF: Duration = Duration::from_millis(100);

/// 启动分流器主循环（永不返回，除非监听失败）。
pub async fn run(cfg: Arc<Config>) -> anyhow::Result<()> {
    let listener = TcpListener::bind(&cfg.listen)
        .await
        .map_err(|e| anyhow::anyhow!("绑定监听地址 {} 失败: {e}", cfg.listen))?;
    info!(listen = %cfg.listen, max_connections = cfg.max_connections, "L4 SNI 分流器已启动");

    // 并发连接上限：0 表示不限制；否则用信号量背压，抵御资源耗尽型攻击。
    let limiter = if cfg.max_connections > 0 {
        Some(Arc::new(Semaphore::new(cfg.max_connections)))
    } else {
        None
    };

    loop {
        // 在 accept 之前先取并发许可，达到上限时自然背压（不会无界堆积）。
        let permit = match &limiter {
            Some(sem) => match Arc::clone(sem).acquire_owned().await {
                Ok(p) => Some(p),
                Err(_) => return Ok(()), // 信号量已关闭，正常退出。
            },
            None => None,
        };

        let (client, peer) = match listener.accept().await {
            Ok(pair) => pair,
            Err(e) => {
                // 瞬时错误（EMFILE/ENFILE 等）退避后重试，避免 100% CPU 空转。
                warn!(error = %e, "accept 失败，退避后重试");
                tokio::time::sleep(ACCEPT_BACKOFF).await;
                continue;
            }
        };
        let cfg = Arc::clone(&cfg);
        tokio::spawn(async move {
            // permit 随任务生命周期持有，任务结束自动释放许可。
            let _permit = permit;
            if let Err(e) = handle_connection(client, cfg).await {
                debug!(peer = %peer, error = %e, "连接处理结束");
            }
        });
    }
}

/// 处理单个客户端连接：读 SNI → 选上游 → 透传双向拷贝。
async fn handle_connection(mut client: TcpStream, cfg: Arc<Config>) -> anyhow::Result<()> {
    let _ = client.set_nodelay(true);

    let mut buf: Vec<u8> = Vec::with_capacity(2048);
    let mut chunk = [0u8; 2048];

    // 在超时窗口内读取并解析 ClientHello。
    let sni = timeout(Duration::from_secs(cfg.dispatch_timeout_secs), async {
        loop {
            let n = client.read(&mut chunk).await?;
            if n == 0 {
                // 对端在发送 ClientHello 前就关闭了连接。
                return Ok::<Option<String>, io::Error>(None);
            }
            buf.extend_from_slice(&chunk[..n]);
            match extract_sni(&buf) {
                SniResult::Found(host) => return Ok(Some(host)),
                SniResult::NoSni | SniResult::Invalid => return Ok(None),
                SniResult::Incomplete => {
                    if buf.len() > MAX_CLIENT_HELLO {
                        return Ok(None);
                    }
                    continue;
                }
            }
        }
    })
    .await
    .map_err(|_| anyhow::anyhow!("读取 ClientHello 超时"))??;

    let upstream_addr = cfg.upstream_for(sni.as_deref()).to_string();
    debug!(sni = ?sni, upstream = %upstream_addr, "分流决策");

    // 带超时的上游连接，避免挂起的上游长期占用任务与套接字。
    let mut upstream = timeout(
        Duration::from_secs(cfg.upstream_connect_timeout_secs),
        TcpStream::connect(&upstream_addr),
    )
    .await
    .map_err(|_| anyhow::anyhow!("连接上游 {upstream_addr} 超时"))?
    .map_err(|e| anyhow::anyhow!("连接上游 {upstream_addr} 失败: {e}"))?;
    let _ = upstream.set_nodelay(true);

    // 先把已读取的 ClientHello 原样转发给上游，再双向透传剩余流量。
    upstream.write_all(&buf).await?;
    // 用更大的对称缓冲提升高吞吐转发性能（默认 32KiB，可配置）。
    let buf_size = cfg.copy_buffer_size.max(8 * 1024);
    tokio::io::copy_bidirectional_with_sizes(&mut client, &mut upstream, buf_size, buf_size)
        .await?;
    Ok(())
}
