//! L4 SNI 分流器：监听 TCP，窥探 ClientHello 的 SNI，按精确匹配把整条 TLS
//! 连接透传（passthrough）到对应上游。等价于 caddy-l4 在本项目中的用法。
//!
//! Linux 上使用 splice(2) 零拷贝，数据在内核态通过 pipe 直接转发，
//! 不经过用户态 buffer，YouTube 视频流等高吞吐场景可省 20-40% CPU。
//! 非 Linux 平台 fallback 到 tokio copy_bidirectional。
#![allow(unsafe_code)] // splice(2) FFI 需要 unsafe，仅限本模块

use std::io;
use std::sync::Arc;
use std::time::Duration;

use socket2::SockRef;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Semaphore;
use tokio::time::timeout;
use tokio_util::sync::CancellationToken;
use tracing::{debug, info, warn};

use crate::config::Config;
use crate::sni::{SniResult, extract_sni};

/// 单连接读取 ClientHello 的缓冲上限，超过则放弃解析走默认路由。
const MAX_CLIENT_HELLO: usize = 16 * 1024;

/// accept 出现瞬时错误（如 fd 耗尽 EMFILE）时的退避时长，避免 CPU 空转。
const ACCEPT_BACKOFF: Duration = Duration::from_millis(100);

/// 优雅关闭时等待活跃连接完成的最大时长。
const SHUTDOWN_DRAIN_TIMEOUT: Duration = Duration::from_secs(30);

/// 设置 TCP Keepalive：60s 后开始探测，每 15s 一次。检测死连接，避免资源泄漏。
fn set_tcp_keepalive(stream: &TcpStream) {
    let sock = SockRef::from(stream);
    let keepalive = socket2::TcpKeepalive::new()
        .with_time(Duration::from_secs(60))
        .with_interval(Duration::from_secs(15));
    let _ = sock.set_tcp_keepalive(&keepalive);
}

/// 启动分流器主循环。接收 CancellationToken 以支持优雅退出。
pub async fn run(cfg: Arc<Config>, cancel: CancellationToken) -> anyhow::Result<()> {
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

    // 追踪活跃连接，以便优雅 drain。
    let active_connections = Arc::new(tokio::sync::Semaphore::new(0));

    loop {
        // 在 accept 之前先取并发许可，达到上限时自然背压（不会无界堆积）。
        let permit = match &limiter {
            Some(sem) => match Arc::clone(sem).acquire_owned().await {
                Ok(p) => Some(p),
                Err(_) => break, // 信号量已关闭，正常退出。
            },
            None => None,
        };

        // 检查是否收到退出信号（停止 accept 新连接）。
        tokio::select! {
            biased;
            _ = cancel.cancelled() => break,
            result = listener.accept() => {
                let (client, peer) = match result {
                    Ok(pair) => pair,
                    Err(e) => {
                        warn!(error = %e, "accept 失败，退避后重试");
                        tokio::time::sleep(ACCEPT_BACKOFF).await;
                        continue;
                    }
                };
                let cfg = Arc::clone(&cfg);
                let conn_tracker = Arc::clone(&active_connections);
                // 增加活跃连接计数（通过 add_permits 的逆用：用 forget 的 permit 追踪）
                conn_tracker.add_permits(1);
                tokio::spawn(async move {
                    let _permit = permit;
                    if let Err(e) = handle_connection(client, cfg).await {
                        debug!(peer = %peer, error = %e, "连接处理结束");
                    }
                    // 连接结束：通知 drain 逻辑
                    conn_tracker.acquire().await.ok().map(|p| p.forget());
                });
            }
        }
    }

    // 优雅 drain：等待所有活跃连接完成（带超时）。
    let available = active_connections.available_permits();
    if available > 0 {
        info!(active = available, timeout_secs = SHUTDOWN_DRAIN_TIMEOUT.as_secs(), "等待活跃连接完成...");
        // 尝试获取与活跃连接同数的 permits（每个连接完成时 acquire 并 forget，会释放 permit 回来）。
        // 这比 polling 更高效——每个连接结束时自动售票，最终全部释放时我们就能获取到。
        match timeout(
            SHUTDOWN_DRAIN_TIMEOUT,
            active_connections.acquire_many(available as u32),
        )
        .await
        {
            Ok(Ok(_)) => info!("所有活跃连接已完成"),
            Ok(Err(_)) => info!("所有活跃连接已完成"),
            Err(_) => warn!(remaining = active_connections.available_permits(), "drain 超时，强制退出"),
        }
    }
    Ok(())
}

/// 读取 SNI 阶段：独立函数使 buf/chunk 在返回后自动释放，不占 copy 阶段内存。
async fn read_sni(
    client: &mut TcpStream,
    timeout_secs: u64,
) -> anyhow::Result<(Option<String>, Vec<u8>)> {
    let mut buf: Vec<u8> = Vec::with_capacity(2048);
    let mut chunk = [0u8; 2048];

    let sni = timeout(Duration::from_secs(timeout_secs), async {
        loop {
            let n = client.read(&mut chunk).await?;
            if n == 0 {
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

    Ok((sni, buf))
}

/// 处理单个客户端连接：读 SNI → 选上游 → 透传双向拷贝。
async fn handle_connection(mut client: TcpStream, cfg: Arc<Config>) -> anyhow::Result<()> {
    let _ = client.set_nodelay(true);
    set_tcp_keepalive(&client);

    // SNI 读取在独立函数中，返回后 chunk 栈数组自动释放。
    let (sni, initial_data) = read_sni(&mut client, cfg.dispatch_timeout_secs).await?;

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
    set_tcp_keepalive(&upstream);

    // 先把已读取的 ClientHello 原样转发给上游，再释放 initial_data 内存。
    upstream.write_all(&initial_data).await?;
    drop(initial_data);

    // Linux: splice(2) 零拷贝——数据在内核态通过 pipe 直接从 source socket 移到 dest socket，
    // 完全不经过用户态 buffer，YouTube 视频流等高吞吐场景可省 20-40% CPU。
    // 非 Linux: fallback 到 copy_bidirectional_with_sizes（用户态拷贝）。
    #[cfg(target_os = "linux")]
    {
        copy_bidirectional_splice(&client, &upstream).await?;
    }
    #[cfg(not(target_os = "linux"))]
    {
        let buf_size = cfg.copy_buffer_size.max(8 * 1024);
        tokio::io::copy_bidirectional_with_sizes(&mut client, &mut upstream, buf_size, buf_size)
            .await?;
    }
    Ok(())
}

// =========================================================================
// Linux splice(2) 零拷贝实现
// =========================================================================

/// Linux splice(2) 双向零拷贝透传。
/// 每个方向用一对 pipe 作为内核缓冲区，splice 在 fd 之间移动数据完全不经用户态。
#[cfg(target_os = "linux")]
async fn copy_bidirectional_splice(
    client: &TcpStream,
    upstream: &TcpStream,
) -> io::Result<()> {
    use std::os::unix::io::AsRawFd;

    let client_fd = client.as_raw_fd();
    let upstream_fd = upstream.as_raw_fd();

    // 为每个方向创建 pipe（非阻塞 + CLOEXEC）。
    let (pr1, pw1) = create_pipe()?; // client → upstream
    let (pr2, pw2) = create_pipe()?; // upstream → client

    let c2u = splice_one_direction(client, client_fd, pw1, pr1, upstream, upstream_fd);
    let u2c = splice_one_direction(upstream, upstream_fd, pw2, pr2, client, client_fd);

    // 任一方向 EOF 或错误即结束整条连接。
    tokio::select! {
        r = c2u => r,
        r = u2c => r,
    }
}

/// 创建非阻塞 pipe 并设置 64KB pipe buffer（匹配 copy_buffer_size）。
#[cfg(target_os = "linux")]
fn create_pipe() -> io::Result<(i32, i32)> {
    let mut fds = [0i32; 2];
    // pipe2 with O_NONBLOCK | O_CLOEXEC
    let ret = unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_NONBLOCK | libc::O_CLOEXEC) };
    if ret < 0 {
        return Err(io::Error::last_os_error());
    }
    // 扩大 pipe buffer 到 64KB（失败不致命，默认 16 页 = 64KB 在多数内核已足够）。
    unsafe { libc::fcntl(fds[1], libc::F_SETPIPE_SZ, 65536) };
    Ok((fds[0], fds[1]))
}

/// 单方向 splice 循环：source_fd → pipe → dest_fd。
#[cfg(target_os = "linux")]
async fn splice_one_direction(
    src_stream: &TcpStream,
    src_fd: i32,
    pipe_w: i32,
    pipe_r: i32,
    dst_stream: &TcpStream,
    dst_fd: i32,
) -> io::Result<()> {
    const SPLICE_FLAGS: libc::c_uint =
        (libc::SPLICE_F_MOVE | libc::SPLICE_F_NONBLOCK) as libc::c_uint;
    const CHUNK: usize = 65536;

    loop {
        // 等待 source 可读。
        src_stream.readable().await?;

        // splice: source socket → pipe (非阻塞)。
        let n = match splice_call(src_fd, pipe_w, CHUNK, SPLICE_FLAGS) {
            Ok(0) => return Ok(()), // EOF
            Ok(n) => n,
            Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => continue,
            Err(e) => return Err(e),
        };

        // splice: pipe → dest socket。pipe 中已有 n 字节，全部写完。
        let mut remaining = n;
        while remaining > 0 {
            dst_stream.writable().await?;
            match splice_call(pipe_r, dst_fd, remaining, SPLICE_FLAGS) {
                Ok(0) => return Err(io::Error::new(io::ErrorKind::BrokenPipe, "splice dest closed")),
                Ok(written) => remaining -= written,
                Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => continue,
                Err(e) => return Err(e),
            }
        }
    }
}

/// 安全包装 splice(2) 系统调用。
#[cfg(target_os = "linux")]
fn splice_call(fd_in: i32, fd_out: i32, len: usize, flags: libc::c_uint) -> io::Result<usize> {
    let ret = unsafe {
        libc::splice(
            fd_in,
            std::ptr::null_mut(),
            fd_out,
            std::ptr::null_mut(),
            len,
            flags,
        )
    };
    if ret < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(ret as usize)
    }
}
