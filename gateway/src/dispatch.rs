//! L4 SNI 分流器：监听 TCP，窥探 ClientHello 的 SNI，按精确匹配把整条 TLS
//! 连接透传（passthrough）到对应上游。等价于 caddy-l4 在本项目中的用法。
//!
//! Linux 上使用 splice(2) 零拷贝，数据在内核态通过 pipe 直接转发，
//! 不经过用户态 buffer；非 Linux 平台回退到有界用户态缓冲。
//! 非 Linux 平台 fallback 到 tokio copy_bidirectional。

use std::future::Future;
use std::io;
use std::sync::Arc;
use std::time::Duration;

use socket2::SockRef;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpSocket, TcpStream};
use tokio::sync::{OwnedSemaphorePermit, Semaphore, watch};
use tokio::time::{Instant, sleep_until, timeout};
use tokio_util::sync::CancellationToken;
use tokio_util::task::TaskTracker;
use tracing::{debug, info, warn};

use crate::config::Config;
use crate::sni::{SniResult, extract_sni};

/// 单连接读取 ClientHello 的缓冲上限，超过则放弃解析走默认路由。
const MAX_CLIENT_HELLO: usize = 16 * 1024;

/// accept 出现瞬时错误（如 fd 耗尽 EMFILE）时的退避时长，避免 CPU 空转。
const ACCEPT_BACKOFF: Duration = Duration::from_millis(100);

/// 优雅关闭时等待活跃连接完成的最大时长。
/// 容器内停机预算受限（entrypoint 8s 看门狗 + Docker 10s grace），故取 5s 让 gtagate 在被 SIGKILL 前干净退出。
const SHUTDOWN_DRAIN_TIMEOUT: Duration = Duration::from_secs(5);

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
    // SO_REUSEADDR：容器以 --net=host 重启/重建时，旧进程在该端口的连接可能仍处于
    // TIME_WAIT 并残留于宿主网络命名空间；不设置则新进程 bind 会因 EADDRINUSE
    // ("Address already in use") 失败。设置后可立即重新绑定。这是服务端标准实践，
    // 不影响安全（仅放宽 TIME_WAIT 同地址重绑，未启用 SO_REUSEPORT 多进程共享）。
    let addr: std::net::SocketAddr = cfg
        .listen
        .parse()
        .map_err(|e| anyhow::anyhow!("解析监听地址 {} 失败（需 IP:端口）: {e}", cfg.listen))?;
    let socket = if addr.is_ipv4() {
        TcpSocket::new_v4()
    } else {
        TcpSocket::new_v6()
    }
    .map_err(|e| anyhow::anyhow!("创建监听 socket 失败: {e}"))?;
    socket
        .set_reuseaddr(true)
        .map_err(|e| anyhow::anyhow!("设置 SO_REUSEADDR 失败: {e}"))?;
    socket
        .bind(addr)
        .map_err(|e| anyhow::anyhow!("绑定监听地址 {} 失败: {e}", cfg.listen))?;
    let listener = socket
        .listen(1024)
        .map_err(|e| anyhow::anyhow!("监听 {} 失败: {e}", cfg.listen))?;
    info!(
        listen = %cfg.listen,
        max_connections = cfg.max_connections,
        max_handshake_connections = cfg.max_handshake_connections,
        relay_idle_timeout_secs = cfg.relay_idle_timeout_secs,
        "L4 SNI 分流器已启动"
    );

    // ClientHello 与已建立连接使用独立预算，慢握手无法耗尽全部转发连接许可。
    let connection_limiter = if cfg.max_connections > 0 {
        Some(Arc::new(Semaphore::new(cfg.max_connections)))
    } else {
        None
    };
    let handshake_limiter = if cfg.max_handshake_connections > 0 {
        Some(Arc::new(Semaphore::new(cfg.max_handshake_connections)))
    } else {
        None
    };

    // TaskTracker 追踪活跃连接，配合 CancellationToken 实现优雅 drain（2026 tokio 规范原语）。
    let tracker = TaskTracker::new();

    loop {
        // 在 accept 前取得慢握手许可，达到上限时由内核 listen backlog 有界背压。
        let handshake_permit = match &handshake_limiter {
            Some(sem) => {
                tokio::select! {
                    biased;
                    _ = cancel.cancelled() => break,
                    p = Arc::clone(sem).acquire_owned() => match p {
                        Ok(p) => Some(p),
                        Err(_) => break, // 信号量已关闭，正常退出。
                    },
                }
            }
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
                let connection_limiter = connection_limiter.clone();
                tracker.spawn(async move {
                    if let Err(e) = handle_connection(
                        client,
                        cfg,
                        handshake_permit,
                        connection_limiter,
                    )
                    .await
                    {
                        debug!(peer = %peer, error = %e, "连接处理结束");
                    }
                });
            }
        }
    }

    // 停止接受新连接，等待活跃连接 drain（带超时）。
    tracker.close();
    if !tracker.is_empty() {
        info!(
            active = tracker.len(),
            timeout_secs = SHUTDOWN_DRAIN_TIMEOUT.as_secs(),
            "停止接受新连接，等待活跃连接完成..."
        );
        match timeout(SHUTDOWN_DRAIN_TIMEOUT, tracker.wait()).await {
            Ok(()) => info!("所有活跃连接已完成"),
            Err(_) => warn!(remaining = tracker.len(), "drain 超时，强制退出"),
        }
    }
    Ok(())
}

/// 读取 SNI 阶段：独立函数使读取缓冲在返回后自动释放，不占 copy 阶段内存。
async fn read_sni(
    client: &mut TcpStream,
    timeout_secs: u64,
) -> anyhow::Result<(Option<String>, Vec<u8>)> {
    // 直接读入 buf 的 spare capacity（read_buf，无 chunk 中转、无额外 memcpy）。
    // Take 将每次底层读取限制在剩余预算内，使 16 KiB 成为真实硬上限。
    let mut buf: Vec<u8> = Vec::with_capacity(2048);

    let sni = timeout(Duration::from_secs(timeout_secs), async {
        loop {
            let remaining = MAX_CLIENT_HELLO.saturating_sub(buf.len());
            if remaining == 0 {
                return Ok::<Option<String>, io::Error>(None);
            }
            buf.reserve(remaining.min(2048));
            let mut limited = (&mut *client).take(remaining as u64);
            let n = limited.read_buf(&mut buf).await?;
            if n == 0 {
                return Ok::<Option<String>, io::Error>(None);
            }
            match extract_sni(&buf) {
                SniResult::Found(host) => return Ok(Some(host)),
                SniResult::NoSni | SniResult::Invalid => return Ok(None),
                SniResult::Incomplete => {
                    if buf.len() == MAX_CLIENT_HELLO {
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
async fn handle_connection(
    mut client: TcpStream,
    cfg: Arc<Config>,
    handshake_permit: Option<OwnedSemaphorePermit>,
    connection_limiter: Option<Arc<Semaphore>>,
) -> anyhow::Result<()> {
    let _ = client.set_nodelay(true);
    set_tcp_keepalive(&client);

    // SNI 读取在独立函数中，返回后读取缓冲自动释放。
    let (sni, initial_data) = read_sni(&mut client, cfg.dispatch_timeout_secs).await?;
    drop(handshake_permit);

    // 不等待已建立连接许可：满载时立即拒绝新连接，避免完成握手的 socket
    // 在用户态形成无界等待队列，同时不影响已建立连接。
    let _connection_permit = try_acquire_connection(connection_limiter)?;

    // upstream_for 返回借用自 cfg 的 &str，cfg 生命周期覆盖整个函数，省去 to_string 分配。
    let upstream_addr = cfg.upstream_for(sni.as_deref());
    debug!(sni = ?sni, upstream = %upstream_addr, "分流决策");

    // 带超时的上游连接，避免挂起的上游长期占用任务与套接字。
    let mut upstream = timeout(
        Duration::from_secs(cfg.upstream_connect_timeout_secs),
        TcpStream::connect(upstream_addr),
    )
    .await
    .map_err(|_| anyhow::anyhow!("连接上游 {upstream_addr} 超时"))?
    .map_err(|e| anyhow::anyhow!("连接上游 {upstream_addr} 失败: {e}"))?;
    let _ = upstream.set_nodelay(true);
    set_tcp_keepalive(&upstream);

    // 先把已读取的 ClientHello 原样转发给上游，再释放 initial_data 内存。
    upstream.write_all(&initial_data).await?;
    drop(initial_data);

    // Linux 使用 splice(2) 零拷贝；非 Linux 使用有界用户态缓冲。
    let activity = ActivityTracker::new();
    let idle_timeout =
        (cfg.relay_idle_timeout_secs > 0).then(|| Duration::from_secs(cfg.relay_idle_timeout_secs));
    #[cfg(target_os = "linux")]
    relay_with_idle_timeout(
        copy_bidirectional_splice(&client, &upstream, &activity),
        idle_timeout,
        &activity,
    )
    .await?;
    #[cfg(not(target_os = "linux"))]
    relay_with_idle_timeout(
        copy_bidirectional_buffered(
            &mut client,
            &mut upstream,
            cfg.copy_buffer_size.max(8 * 1024),
            &activity,
        ),
        idle_timeout,
        &activity,
    )
    .await?;
    Ok(())
}

fn try_acquire_connection(
    limiter: Option<Arc<Semaphore>>,
) -> anyhow::Result<Option<OwnedSemaphorePermit>> {
    limiter
        .map(|limiter| {
            limiter
                .try_acquire_owned()
                .map_err(|_| anyhow::anyhow!("已建立连接达到上限"))
        })
        .transpose()
}

struct ActivityTracker {
    sender: watch::Sender<Instant>,
}

impl ActivityTracker {
    fn new() -> Self {
        let (sender, _) = watch::channel(Instant::now());
        Self { sender }
    }

    fn mark(&self) {
        self.sender.send_replace(Instant::now());
    }
}

async fn relay_with_idle_timeout<F>(
    relay: F,
    idle_timeout: Option<Duration>,
    activity: &ActivityTracker,
) -> io::Result<()>
where
    F: Future<Output = io::Result<()>>,
{
    let Some(idle_timeout) = idle_timeout else {
        return relay.await;
    };
    let mut receiver = activity.sender.subscribe();
    tokio::pin!(relay);

    loop {
        let deadline = *receiver.borrow_and_update() + idle_timeout;
        tokio::select! {
            result = &mut relay => return result,
            _ = sleep_until(deadline) => {
                let idle_for = Instant::now().saturating_duration_since(*receiver.borrow());
                if idle_for >= idle_timeout {
                    return Err(io::Error::new(
                        io::ErrorKind::TimedOut,
                        "转发连接超过空闲超时",
                    ));
                }
            }
            changed = receiver.changed() => {
                if changed.is_err() {
                    return Err(io::Error::new(
                        io::ErrorKind::BrokenPipe,
                        "转发活动监控意外关闭",
                    ));
                }
            }
        }
    }
}

// =========================================================================
// Linux splice(2) 零拷贝实现
// =========================================================================

/// RAII pipe：用标准库 `io::pipe()` 创建，两端均为自动 close 的 owned 句柄
/// （`PipeReader`/`PipeWriter`，Drop 即关闭）—— 根除"每连接泄漏 4 个 fd"的旧缺陷，
/// 且创建过程不再需要任何 unsafe（替代旧的 `libc::pipe2` + `OwnedFd::from_raw_fd`）。
#[cfg(target_os = "linux")]
struct Pipe {
    read: io::PipeReader,
    write: io::PipeWriter,
}

#[cfg(target_os = "linux")]
impl Pipe {
    /// 创建匿名管道。标准库保证两端 fd 均为 CLOEXEC，离开作用域自动关闭。
    ///
    /// 关于两项被移除的旧设置（行为与旧实现等价）：
    /// - 不再手动设 `O_NONBLOCK`：本路径从不直接 read/write pipe，只经 splice 搬运，而
    ///   splice 始终带 `SPLICE_F_NONBLOCK`，pipe 端非阻塞性由该标志保证（与 pipe fd 自身
    ///   的 O_NONBLOCK 无关）；两个 socket 端由 tokio 设为非阻塞。
    /// - 不再手动 `F_SETPIPE_SZ`：Linux 默认管道容量即 64KB（16 页），与旧值一致。
    fn new() -> io::Result<Self> {
        let (read, write) = io::pipe()?;
        Ok(Self { read, write })
    }
}

/// Linux splice(2) 双向零拷贝透传。
///
/// 正确性要点（修复历史三个缺陷）：
///   1. pipe 由标准库 `PipeReader`/`PipeWriter` 托管，连接结束自动 close —— 根除每连接 4 个 fd 的泄漏（→ EMFILE）。
///   2. 用 `TcpStream::async_io`（而非裸 `readable()` + 裸 splice）驱动系统调用 ——
///      WouldBlock 时 tokio 会清除 readiness 并真正挂起任务，根除 100% CPU 空转。
///   3. 用 `join!`（而非 `select!`）跑完两个方向，一方 EOF 时仅关闭对端写半边 ——
///      正确处理 TCP 半关闭，不截断在途数据。
#[cfg(target_os = "linux")]
async fn copy_bidirectional_splice(
    client: &TcpStream,
    upstream: &TcpStream,
    activity: &ActivityTracker,
) -> io::Result<()> {
    use std::net::Shutdown;
    use std::os::fd::AsRawFd;

    let client_fd = client.as_raw_fd();
    let upstream_fd = upstream.as_raw_fd();

    let pipe_c2u = Pipe::new()?; // client → upstream
    let pipe_u2c = Pipe::new()?; // upstream → client

    let c2u = async {
        let r = splice_one_direction(
            client,
            client_fd,
            &pipe_c2u,
            upstream,
            upstream_fd,
            activity,
        )
        .await;
        // client 该方向 EOF：关闭 upstream 写半边，让其得以正常收尾（半关闭）。
        let _ = SockRef::from(upstream).shutdown(Shutdown::Write);
        r
    };
    let u2c = async {
        let r = splice_one_direction(
            upstream,
            upstream_fd,
            &pipe_u2c,
            client,
            client_fd,
            activity,
        )
        .await;
        let _ = SockRef::from(client).shutdown(Shutdown::Write);
        r
    };

    // try_join!：任一方向出错立即返回并丢弃另一方向（释放 permit/fd，避免对端 idle 时 join 永挂）；
    // 两个方向都正常 EOF 时仍等待双方完成，保持 TCP 半关闭语义。
    tokio::try_join!(c2u, u2c).map(|_| ())
}

/// 单方向 splice 循环：src socket → pipe → dst socket。
/// 用 `async_io` 让 tokio 正确管理 readiness（WouldBlock 自动挂起，绝不空转）。
#[cfg(target_os = "linux")]
async fn splice_one_direction(
    src: &TcpStream,
    src_fd: std::os::fd::RawFd,
    pipe: &Pipe,
    dst: &TcpStream,
    dst_fd: std::os::fd::RawFd,
    activity: &ActivityTracker,
) -> io::Result<()> {
    use std::os::fd::AsRawFd;
    use tokio::io::Interest;

    const CHUNK: usize = 65536;
    let pipe_w = pipe.write.as_raw_fd();
    let pipe_r = pipe.read.as_raw_fd();

    loop {
        // src socket → pipe：等待源可读；splice 返回 EAGAIN 时 async_io 自动清 readiness 并挂起。
        let n = src
            .async_io(Interest::READABLE, || splice_raw(src_fd, pipe_w, CHUNK))
            .await?;
        if n == 0 {
            return Ok(()); // 源 EOF
        }
        activity.mark();

        // pipe → dst socket：把 pipe 中的 n 字节全部写出。
        let mut remaining = n;
        while remaining > 0 {
            let written = dst
                .async_io(Interest::WRITABLE, || splice_raw(pipe_r, dst_fd, remaining))
                .await?;
            if written == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::WriteZero,
                    "splice 写入 0 字节",
                ));
            }
            remaining -= written;
            activity.mark();
        }
    }
}

#[cfg(not(target_os = "linux"))]
async fn copy_bidirectional_buffered(
    client: &mut TcpStream,
    upstream: &mut TcpStream,
    buffer_size: usize,
    activity: &ActivityTracker,
) -> io::Result<()> {
    let (mut client_read, mut client_write) = client.split();
    let (mut upstream_read, mut upstream_write) = upstream.split();
    let client_to_upstream =
        copy_one_direction_buffered(&mut client_read, &mut upstream_write, buffer_size, activity);
    let upstream_to_client =
        copy_one_direction_buffered(&mut upstream_read, &mut client_write, buffer_size, activity);
    tokio::try_join!(client_to_upstream, upstream_to_client).map(|_| ())
}

#[cfg(not(target_os = "linux"))]
async fn copy_one_direction_buffered<R, W>(
    reader: &mut R,
    writer: &mut W,
    buffer_size: usize,
    activity: &ActivityTracker,
) -> io::Result<()>
where
    R: tokio::io::AsyncRead + Unpin,
    W: tokio::io::AsyncWrite + Unpin,
{
    let mut buffer = vec![0_u8; buffer_size];
    loop {
        let read = reader.read(&mut buffer).await?;
        if read == 0 {
            writer.shutdown().await?;
            return Ok(());
        }
        activity.mark();
        writer.write_all(&buffer[..read]).await?;
        activity.mark();
    }
}

/// 裸 splice(2) 包装：EAGAIN → `ErrorKind::WouldBlock`（供 `async_io` 识别并挂起，而非空转）。
#[cfg(target_os = "linux")]
#[allow(
    unsafe_code,
    reason = "splice(2) has no stable standard-library equivalent"
)]
fn splice_raw(
    fd_in: std::os::fd::RawFd,
    fd_out: std::os::fd::RawFd,
    len: usize,
) -> io::Result<usize> {
    let flags = (libc::SPLICE_F_MOVE | libc::SPLICE_F_NONBLOCK) as libc::c_uint;
    loop {
        // SAFETY: fd_in/fd_out 由调用方保证有效（来自存活的 TcpStream / Pipe）；
        // 两个 offset 传 null 表示使用各自隐含偏移（socket/pipe 无 seek 偏移）。
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
            let err = io::Error::last_os_error();
            // EINTR：被信号打断，就地重试（标准 syscall 处理）。其它错误（含 EAGAIN）
            // 上抛，由 async_io 识别 WouldBlock 并挂起，绝不空转。
            if err.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(err);
        }
        return Ok(ret as usize);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test(start_paused = true)]
    async fn idle_watchdog_times_out_without_activity() {
        let activity = ActivityTracker::new();
        let relay = std::future::pending::<io::Result<()>>();
        let result = relay_with_idle_timeout(relay, Some(Duration::from_secs(5)), &activity);
        tokio::pin!(result);
        tokio::time::advance(Duration::from_secs(6)).await;

        let error = match result.await {
            Ok(()) => panic!("idle relay unexpectedly completed"),
            Err(error) => error,
        };
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
    }

    #[tokio::test(start_paused = true)]
    async fn idle_watchdog_resets_after_activity() {
        let activity = ActivityTracker::new();
        let relay = std::future::pending::<io::Result<()>>();
        let result = relay_with_idle_timeout(relay, Some(Duration::from_secs(5)), &activity);
        tokio::pin!(result);

        tokio::select! {
            result = &mut result => panic!("relay completed before idle timeout: {result:?}"),
            _ = tokio::task::yield_now() => {}
        }
        tokio::time::advance(Duration::from_secs(4)).await;
        activity.mark();
        tokio::time::advance(Duration::from_secs(4)).await;
        tokio::select! {
            result = &mut result => panic!("activity did not reset idle timeout: {result:?}"),
            _ = tokio::task::yield_now() => {}
        }
        tokio::time::advance(Duration::from_secs(2)).await;

        let error = match result.await {
            Ok(()) => panic!("idle relay unexpectedly completed"),
            Err(error) => error,
        };
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
    }

    #[tokio::test]
    async fn established_limit_rejects_without_waiting() {
        let limiter = Arc::new(Semaphore::new(1));
        let held = match Arc::clone(&limiter).acquire_owned().await {
            Ok(permit) => permit,
            Err(error) => panic!("failed to acquire test permit: {error}"),
        };

        assert!(try_acquire_connection(Some(Arc::clone(&limiter))).is_err());
        drop(held);
        assert!(try_acquire_connection(Some(limiter)).is_ok());
    }
}
