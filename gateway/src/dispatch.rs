//! L4 SNI 分流器：监听 TCP，窥探 ClientHello 的 SNI，按精确匹配把整条 TLS
//! 连接透传（passthrough）到对应上游。等价于 caddy-l4 在本项目中的用法。
//!
//! Linux 上使用 splice(2) 零拷贝，数据在内核态通过 pipe 直接转发，
//! 不经过用户态 buffer；非 Linux 平台回退到有界用户态缓冲。
//! 非 Linux 平台 fallback 到 tokio copy_bidirectional。

use std::future::Future;
use std::io;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use socket2::SockRef;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpSocket, TcpStream};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tokio::time::{Instant, sleep_until, timeout};
use tokio_util::sync::CancellationToken;
use tokio_util::task::TaskTracker;
use tracing::{debug, info, warn};

use crate::config::Config;
use crate::sni::{ClientHelloSniParser, MAX_CLIENT_HELLO_BYTES, SniResult};

/// accept 出现瞬时错误（如 fd 耗尽 EMFILE）时的退避时长，避免 CPU 空转。
const ACCEPT_BACKOFF: Duration = Duration::from_millis(100);

/// 吸收连接突发和 TCP_DEFER_ACCEPT 队列；Linux 会按 net.core.somaxconn 自动封顶。
const LISTEN_BACKLOG: u32 = 4096;

/// 优雅关闭时等待活跃连接完成的最大时长。
/// entrypoint provides a 30s child budget within the required 40s Docker grace,
/// so gtagate can spend up to 5s draining relays without racing forced cleanup.
const SHUTDOWN_DRAIN_TIMEOUT: Duration = Duration::from_secs(5);

/// Tokio、ACME HTTP 客户端、日志与监听 socket 的保守常驻 FD 余量。
#[cfg(target_os = "linux")]
const PROCESS_FD_RESERVE: u64 = 64;

/// Linux relay 每连接使用 client/upstream 两个 socket 与两条 pipe 的四个端点。
#[cfg(target_os = "linux")]
const RELAY_FDS_PER_CONNECTION: u64 = 6;

/// 设置 TCP Keepalive，并在 Linux 上限制未确认数据的黑洞存活时间。
fn set_tcp_liveness(stream: &TcpStream, tcp_user_timeout_secs: u64) {
    let sock = SockRef::from(stream);
    let keepalive = socket2::TcpKeepalive::new()
        .with_time(Duration::from_secs(60))
        .with_interval(Duration::from_secs(15));
    let _ = sock.set_tcp_keepalive(&keepalive);
    #[cfg(target_os = "linux")]
    if tcp_user_timeout_secs > 0 {
        let _ = sock.set_tcp_user_timeout(Some(Duration::from_secs(tcp_user_timeout_secs)));
    }
    #[cfg(not(target_os = "linux"))]
    let _ = tcp_user_timeout_secs;
}

/// 启动分流器主循环。接收 CancellationToken 以支持优雅退出。
pub async fn run(cfg: Arc<Config>, cancel: CancellationToken) -> anyhow::Result<()> {
    validate_process_capacity(&cfg)?;

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
        .listen(LISTEN_BACKLOG)
        .map_err(|e| anyhow::anyhow!("监听 {} 失败: {e}", cfg.listen))?;
    #[cfg(target_os = "linux")]
    if let Err(error) = set_tcp_defer_accept(&listener, cfg.dispatch_timeout_secs) {
        warn!(%error, "设置 TCP_DEFER_ACCEPT 失败，继续使用普通 accept");
    }
    info!(
        listen = %cfg.listen,
        max_connections = cfg.max_connections,
        max_handshake_connections = cfg.max_handshake_connections,
        relay_queue_timeout_secs = cfg.relay_queue_timeout_secs,
        relay_idle_timeout_secs = cfg.relay_idle_timeout_secs,
        tcp_user_timeout_secs = cfg.tcp_user_timeout_secs,
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
                // 始终持续 drain 内核 accept 队列；握手预算满时快速卸载新连接，
                // 避免慢 ClientHello 让整个监听器停在 permit 等待上并最终打满 backlog。
                let handshake_permit = match &handshake_limiter {
                    Some(semaphore) => match Arc::clone(semaphore).try_acquire_owned() {
                        Ok(permit) => Some(permit),
                        Err(_) => {
                            debug!(peer = %peer, "握手容量已满，卸载新连接");
                            continue;
                        }
                    },
                    None => None,
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
    // Take 将每次底层读取限制在剩余预算内，使 64 KiB 成为真实硬上限。
    let mut buf: Vec<u8> = Vec::with_capacity(2048);
    let mut parser = ClientHelloSniParser::new();

    let sni = timeout(Duration::from_secs(timeout_secs), async {
        loop {
            let remaining = MAX_CLIENT_HELLO_BYTES.saturating_sub(buf.len());
            if remaining == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "ClientHello 超过 64 KiB 上限",
                ));
            }
            buf.reserve(remaining.min(2048));
            let mut limited = (&mut *client).take(remaining as u64);
            let n = limited.read_buf(&mut buf).await?;
            if n == 0 {
                if buf.is_empty() {
                    return Ok::<Option<String>, io::Error>(None);
                }
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "ClientHello 未完成即 EOF",
                ));
            }
            match parser.extract(&buf) {
                SniResult::Found(host) => return Ok(Some(host)),
                SniResult::NoSni | SniResult::Invalid => return Ok(None),
                SniResult::Incomplete => {
                    if buf.len() == MAX_CLIENT_HELLO_BYTES {
                        return Err(io::Error::new(
                            io::ErrorKind::InvalidData,
                            "ClientHello 超过 64 KiB 上限",
                        ));
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
    set_tcp_liveness(&client, cfg.tcp_user_timeout_secs);

    // SNI 读取在独立函数中，返回后读取缓冲自动释放。
    let (sni, initial_data) = read_sni(&mut client, cfg.dispatch_timeout_secs).await?;

    // relay 满载时保留握手许可并有界等待，吸收短暂突发但不让失联客户端永久
    // 占住握手池；等待者最多为 max_handshake_connections。
    let _connection_permit = acquire_connection(
        connection_limiter,
        Duration::from_secs(cfg.relay_queue_timeout_secs),
    )
    .await?;
    drop(handshake_permit);

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
    set_tcp_liveness(&upstream, cfg.tcp_user_timeout_secs);

    // 先把已读取的 ClientHello 原样转发给上游，再释放 initial_data 内存。
    upstream.write_all(&initial_data).await?;
    drop(initial_data);

    // Linux 使用 splice(2) 零拷贝；非 Linux 使用有界用户态缓冲。
    let idle_timeout =
        (cfg.relay_idle_timeout_secs > 0).then(|| Duration::from_secs(cfg.relay_idle_timeout_secs));
    let activity = ActivityTracker::new(idle_timeout.is_some());
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

async fn acquire_connection(
    limiter: Option<Arc<Semaphore>>,
    queue_timeout: Duration,
) -> anyhow::Result<Option<OwnedSemaphorePermit>> {
    match limiter {
        Some(limiter) if queue_timeout.is_zero() => limiter
            .try_acquire_owned()
            .map(Some)
            .map_err(|_| anyhow::anyhow!("转发容量已满")),
        Some(limiter) => timeout(queue_timeout, limiter.acquire_owned())
            .await
            .map_err(|_| anyhow::anyhow!("等待转发容量超时"))?
            .map(Some)
            .map_err(|_| anyhow::anyhow!("连接许可池已关闭")),
        None => Ok(None),
    }
}

struct ActivityTracker {
    enabled: bool,
    started: Instant,
    last_activity_millis: AtomicU64,
}

impl ActivityTracker {
    fn new(enabled: bool) -> Self {
        Self {
            enabled,
            started: Instant::now(),
            last_activity_millis: AtomicU64::new(0),
        }
    }

    fn mark(&self) {
        if !self.enabled {
            return;
        }
        let millis = self.started.elapsed().as_millis().min(u128::from(u64::MAX)) as u64;
        self.last_activity_millis.store(millis, Ordering::Release);
    }

    fn last_activity(&self) -> Instant {
        self.started + Duration::from_millis(self.last_activity_millis.load(Ordering::Acquire))
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
    tokio::pin!(relay);

    loop {
        let observed_activity = activity.last_activity();
        let deadline = observed_activity + idle_timeout;
        tokio::select! {
            result = &mut relay => return result,
            _ = sleep_until(deadline) => {
                let latest_activity = activity.last_activity();
                let idle_for = Instant::now().saturating_duration_since(latest_activity);
                if idle_for >= idle_timeout {
                    return Err(io::Error::new(
                        io::ErrorKind::TimedOut,
                        "转发连接超过空闲超时",
                    ));
                }
            }
        }
    }
}

#[cfg(target_os = "linux")]
fn validate_process_capacity(cfg: &Config) -> anyhow::Result<()> {
    if cfg.max_connections == 0 || cfg.max_handshake_connections == 0 {
        warn!(
            max_connections = cfg.max_connections,
            max_handshake_connections = cfg.max_handshake_connections,
            "连接预算包含无限制项，无法验证文件描述符容量"
        );
        return Ok(());
    }

    let required = u64::try_from(cfg.max_connections)
        .unwrap_or(u64::MAX)
        .saturating_mul(RELAY_FDS_PER_CONNECTION)
        .saturating_add(u64::try_from(cfg.max_handshake_connections).unwrap_or(u64::MAX))
        .saturating_add(PROCESS_FD_RESERVE);
    let soft_limit = process_nofile_soft_limit()?;
    if required > soft_limit {
        let available_for_relays = soft_limit
            .saturating_sub(PROCESS_FD_RESERVE)
            .saturating_sub(u64::try_from(cfg.max_handshake_connections).unwrap_or(u64::MAX));
        let suggested_connections = available_for_relays / RELAY_FDS_PER_CONNECTION;
        anyhow::bail!(
            "文件描述符软上限 {soft_limit} 不足：当前连接预算至少需要 {required}；请提高 nofile，或把 max_connections 调到不超过 {suggested_connections}"
        );
    }
    info!(soft_limit, required, "文件描述符容量校验通过");
    Ok(())
}

#[cfg(target_os = "linux")]
#[allow(
    unsafe_code,
    reason = "getrlimit has no stable standard-library equivalent"
)]
fn process_nofile_soft_limit() -> anyhow::Result<u64> {
    let mut limit = std::mem::MaybeUninit::<libc::rlimit>::uninit();
    // SAFETY: getrlimit initializes the provided rlimit on success.
    let result = unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, limit.as_mut_ptr()) };
    if result != 0 {
        return Err(anyhow::anyhow!(
            "读取 RLIMIT_NOFILE 失败: {}",
            io::Error::last_os_error()
        ));
    }
    // SAFETY: result == 0 guarantees initialization.
    let limit = unsafe { limit.assume_init() };
    Ok(limit.rlim_cur)
}

#[cfg(target_os = "linux")]
#[allow(
    unsafe_code,
    reason = "TCP_DEFER_ACCEPT has no socket2 or stable standard-library equivalent"
)]
fn set_tcp_defer_accept(listener: &tokio::net::TcpListener, timeout_secs: u64) -> io::Result<()> {
    use std::os::fd::AsRawFd;

    let seconds = libc::c_int::try_from(timeout_secs).unwrap_or(libc::c_int::MAX);
    // SAFETY: listener owns a valid TCP socket; seconds points to an initialized c_int whose
    // size is supplied exactly. The kernel copies the value during this call.
    let result = unsafe {
        libc::setsockopt(
            listener.as_raw_fd(),
            libc::IPPROTO_TCP,
            libc::TCP_DEFER_ACCEPT,
            std::ptr::from_ref(&seconds).cast(),
            std::mem::size_of_val(&seconds) as libc::socklen_t,
        )
    };
    if result == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

#[cfg(not(target_os = "linux"))]
fn validate_process_capacity(_cfg: &Config) -> anyhow::Result<()> {
    Ok(())
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

    const CHUNK: usize = 64 * 1024;
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

    async fn tcp_pair() -> io::Result<(TcpStream, TcpStream)> {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
        let address = listener.local_addr()?;
        let connect = TcpStream::connect(address);
        let accept = async {
            let (stream, _) = listener.accept().await?;
            Ok::<TcpStream, io::Error>(stream)
        };
        tokio::try_join!(connect, accept)
    }

    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn tcp_user_timeout_is_applied_to_socket() -> anyhow::Result<()> {
        let (stream, _peer) = tcp_pair().await?;

        set_tcp_liveness(&stream, 7);

        assert_eq!(
            SockRef::from(&stream).tcp_user_timeout()?,
            Some(Duration::from_secs(7))
        );
        Ok(())
    }

    fn unused_tcp_address() -> io::Result<std::net::SocketAddr> {
        let listener = std::net::TcpListener::bind("127.0.0.1:0")?;
        let address = listener.local_addr()?;
        drop(listener);
        Ok(address)
    }

    async fn connect_when_ready(address: std::net::SocketAddr) -> io::Result<TcpStream> {
        for _ in 0..100 {
            match TcpStream::connect(address).await {
                Ok(stream) => return Ok(stream),
                Err(error) if error.kind() == io::ErrorKind::ConnectionRefused => {
                    tokio::time::sleep(Duration::from_millis(10)).await;
                }
                Err(error) => return Err(error),
            }
        }
        Err(io::Error::new(
            io::ErrorKind::TimedOut,
            "等待 dispatcher 监听超时",
        ))
    }

    #[tokio::test]
    async fn dispatcher_recovers_after_upstream_refusal() -> anyhow::Result<()> {
        timeout(Duration::from_secs(10), async {
            let gateway_address = unused_tcp_address()?;
            let upstream_address = unused_tcp_address()?;
            let temp = tempfile::NamedTempFile::new()?;
            std::fs::write(
                temp.path(),
                format!(
                    r#"{{
                        "listen": "{gateway_address}",
                        "dispatch_timeout_secs": 1,
                        "upstream_connect_timeout_secs": 1,
                        "copy_buffer_size": 65536,
                        "max_connections": 16,
                        "max_handshake_connections": 8,
                        "relay_idle_timeout_secs": 0,
                        "default_upstream": "{upstream_address}",
                        "routes": []
                    }}"#
                ),
            )?;
            let cfg = Arc::new(Config::load(temp.path())?);
            let cancel = CancellationToken::new();
            let dispatcher = tokio::spawn(run(cfg, cancel.clone()));

            let mut failed_client = connect_when_ready(gateway_address).await?;
            failed_client
                .write_all(b"GET /unavailable HTTP/1.1\r\n\r\n")
                .await?;
            let mut byte = [0_u8; 1];
            let _ = timeout(Duration::from_secs(2), failed_client.read(&mut byte)).await;
            assert!(!dispatcher.is_finished());

            let upstream_listener = tokio::net::TcpListener::bind(upstream_address).await?;
            let request = b"GET /recovered HTTP/1.1\r\nConnection: close\r\n\r\n";
            let response = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK";
            let upstream = tokio::spawn(async move {
                let (mut stream, _) = upstream_listener.accept().await?;
                let mut received = Vec::new();
                stream.read_to_end(&mut received).await?;
                if received != request {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "上游收到的恢复请求不完整",
                    ));
                }
                stream.write_all(response).await?;
                stream.shutdown().await
            });

            let mut recovered_client = TcpStream::connect(gateway_address).await?;
            recovered_client.write_all(request).await?;
            recovered_client.shutdown().await?;
            let mut received = Vec::new();
            recovered_client.read_to_end(&mut received).await?;
            assert_eq!(received, response);
            upstream.await??;

            cancel.cancel();
            dispatcher.await??;
            Ok::<(), anyhow::Error>(())
        })
        .await
        .map_err(|_| anyhow::anyhow!("上游恢复测试超时"))??;
        Ok(())
    }

    #[tokio::test]
    async fn dispatcher_drains_active_connection_after_cancellation() -> anyhow::Result<()> {
        timeout(Duration::from_secs(10), async {
            let gateway_address = unused_tcp_address()?;
            let upstream_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
            let upstream_address = upstream_listener.local_addr()?;
            let temp = tempfile::NamedTempFile::new()?;
            std::fs::write(
                temp.path(),
                format!(
                    r#"{{
                        "listen": "{gateway_address}",
                        "dispatch_timeout_secs": 1,
                        "upstream_connect_timeout_secs": 1,
                        "copy_buffer_size": 65536,
                        "max_connections": 16,
                        "max_handshake_connections": 8,
                        "relay_idle_timeout_secs": 0,
                        "default_upstream": "{upstream_address}",
                        "routes": []
                    }}"#
                ),
            )?;
            let cfg = Arc::new(Config::load(temp.path())?);
            let cancel = CancellationToken::new();
            let dispatcher = tokio::spawn(run(cfg, cancel.clone()));

            let mut client = connect_when_ready(gateway_address).await?;
            client.write_all(b"PING!").await?;
            let (mut upstream, _) = upstream_listener.accept().await?;
            let mut request = [0_u8; 5];
            upstream.read_exact(&mut request).await?;
            assert_eq!(&request, b"PING!");

            cancel.cancel();
            upstream.write_all(b"PONG!").await?;
            let mut response = [0_u8; 5];
            client.read_exact(&mut response).await?;
            assert_eq!(&response, b"PONG!");

            client.shutdown().await?;
            let mut trailing_request = Vec::new();
            upstream.read_to_end(&mut trailing_request).await?;
            assert!(trailing_request.is_empty());
            upstream.shutdown().await?;
            let mut trailing_response = Vec::new();
            client.read_to_end(&mut trailing_response).await?;
            assert!(trailing_response.is_empty());

            dispatcher.await??;
            Ok::<(), anyhow::Error>(())
        })
        .await
        .map_err(|_| anyhow::anyhow!("dispatcher 活跃连接 drain 测试超时"))??;
        Ok(())
    }

    #[tokio::test]
    async fn dispatcher_queues_connection_until_limit_is_released() -> anyhow::Result<()> {
        timeout(Duration::from_secs(10), async {
            let gateway_address = unused_tcp_address()?;
            let upstream_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
            let upstream_address = upstream_listener.local_addr()?;
            let temp = tempfile::NamedTempFile::new()?;
            std::fs::write(
                temp.path(),
                format!(
                    r#"{{
                        "listen": "{gateway_address}",
                        "dispatch_timeout_secs": 1,
                        "upstream_connect_timeout_secs": 1,
                        "copy_buffer_size": 65536,
                        "max_connections": 1,
                        "max_handshake_connections": 4,
                        "relay_idle_timeout_secs": 0,
                        "default_upstream": "{upstream_address}",
                        "routes": []
                    }}"#
                ),
            )?;
            let cfg = Arc::new(Config::load(temp.path())?);
            let cancel = CancellationToken::new();
            let dispatcher = tokio::spawn(run(cfg, cancel.clone()));

            let mut first_client = connect_when_ready(gateway_address).await?;
            first_client.write_all(b"FIRST").await?;
            let (mut first_upstream, _) = upstream_listener.accept().await?;
            let mut first_request = [0_u8; 5];
            first_upstream.read_exact(&mut first_request).await?;
            assert_eq!(&first_request, b"FIRST");

            let mut queued_client = TcpStream::connect(gateway_address).await?;
            queued_client.write_all(b"SECOND").await?;
            queued_client.shutdown().await?;
            assert!(
                timeout(Duration::from_millis(100), upstream_listener.accept())
                    .await
                    .is_err()
            );

            first_client.shutdown().await?;
            let mut first_trailing_request = Vec::new();
            first_upstream
                .read_to_end(&mut first_trailing_request)
                .await?;
            first_upstream.shutdown().await?;
            let mut first_trailing_response = Vec::new();
            first_client
                .read_to_end(&mut first_trailing_response)
                .await?;

            let (mut queued_upstream, _) =
                timeout(Duration::from_secs(1), upstream_listener.accept()).await??;
            let mut queued_request = [0_u8; 6];
            queued_upstream.read_exact(&mut queued_request).await?;
            assert_eq!(&queued_request, b"SECOND");
            queued_upstream.write_all(b"QUEUED").await?;
            queued_upstream.shutdown().await?;
            let mut queued_response = Vec::new();
            queued_client.read_to_end(&mut queued_response).await?;
            assert_eq!(&queued_response, b"QUEUED");

            let mut recovered_client = TcpStream::connect(gateway_address).await?;
            recovered_client.write_all(b"THIRD").await?;
            let (mut recovered_upstream, _) = upstream_listener.accept().await?;
            let mut recovered_request = [0_u8; 5];
            recovered_upstream
                .read_exact(&mut recovered_request)
                .await?;
            assert_eq!(&recovered_request, b"THIRD");
            recovered_upstream.write_all(b"READY").await?;
            let mut recovered_response = [0_u8; 5];
            recovered_client.read_exact(&mut recovered_response).await?;
            assert_eq!(&recovered_response, b"READY");

            recovered_client.shutdown().await?;
            let mut recovered_trailing_request = Vec::new();
            recovered_upstream
                .read_to_end(&mut recovered_trailing_request)
                .await?;
            recovered_upstream.shutdown().await?;
            let mut recovered_trailing_response = Vec::new();
            recovered_client
                .read_to_end(&mut recovered_trailing_response)
                .await?;

            cancel.cancel();
            dispatcher.await??;
            Ok::<(), anyhow::Error>(())
        })
        .await
        .map_err(|_| anyhow::anyhow!("连接配额恢复测试超时"))??;
        Ok(())
    }

    #[tokio::test]
    async fn relay_preserves_response_after_client_half_close() -> anyhow::Result<()> {
        timeout(Duration::from_secs(10), async {
            let (mut client, gate_client) = tcp_pair().await?;
            let (mut upstream, gate_upstream) = tcp_pair().await?;
            let relay = tokio::spawn(async move {
                let activity = ActivityTracker::new(false);
                #[cfg(target_os = "linux")]
                copy_bidirectional_splice(&gate_client, &gate_upstream, &activity).await?;
                #[cfg(not(target_os = "linux"))]
                let (mut gate_client, mut gate_upstream) = (gate_client, gate_upstream);
                #[cfg(not(target_os = "linux"))]
                copy_bidirectional_buffered(
                    &mut gate_client,
                    &mut gate_upstream,
                    64 * 1024,
                    &activity,
                )
                .await?;
                Ok::<(), io::Error>(())
            });

            let request = vec![0x5a; 1024 * 1024];
            client.write_all(&request).await?;
            client.shutdown().await?;

            let mut received_request = Vec::new();
            upstream.read_to_end(&mut received_request).await?;
            assert_eq!(received_request, request);

            let response = vec![0xa5; 2 * 1024 * 1024];
            upstream.write_all(&response).await?;
            upstream.shutdown().await?;

            let mut received_response = Vec::new();
            client.read_to_end(&mut received_response).await?;
            assert_eq!(received_response, response);
            relay.await??;
            Ok::<(), anyhow::Error>(())
        })
        .await
        .map_err(|_| anyhow::anyhow!("半关闭转发测试超时"))??;
        Ok(())
    }

    #[tokio::test]
    async fn reads_large_client_hello_fragmented_across_records() -> anyhow::Result<()> {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
        let address = listener.local_addr()?;
        let hello = large_fragmented_client_hello("api.example.com", 20 * 1024);
        let expected = hello.clone();
        let sender = tokio::spawn(async move {
            let mut stream = TcpStream::connect(address).await?;
            stream.write_all(&hello).await?;
            Ok::<(), io::Error>(())
        });
        let (mut server, _) = listener.accept().await?;

        let (sni, initial_data) = read_sni(&mut server, 1).await?;

        sender.await??;
        assert_eq!(sni.as_deref(), Some("api.example.com"));
        assert_eq!(initial_data, expected);
        Ok(())
    }

    fn large_fragmented_client_hello(host: &str, target_size: usize) -> Vec<u8> {
        let host = host.as_bytes();
        let server_name_list_len = 1 + 2 + host.len();
        let sni_extension_len = 2 + server_name_list_len;
        let fixed_body_len = 2 + 32 + 1 + 2 + 2 + 1 + 1 + 2;
        let sni_total_len = 4 + sni_extension_len;
        let padding_len = target_size - 4 - fixed_body_len - sni_total_len - 4;

        let mut extensions = Vec::new();
        extensions.extend_from_slice(&0_u16.to_be_bytes());
        extensions.extend_from_slice(&(sni_extension_len as u16).to_be_bytes());
        extensions.extend_from_slice(&(server_name_list_len as u16).to_be_bytes());
        extensions.push(0);
        extensions.extend_from_slice(&(host.len() as u16).to_be_bytes());
        extensions.extend_from_slice(host);
        extensions.extend_from_slice(&21_u16.to_be_bytes());
        extensions.extend_from_slice(&(padding_len as u16).to_be_bytes());
        extensions.resize(extensions.len() + padding_len, 0);

        let body_len = fixed_body_len + extensions.len();
        let mut handshake = Vec::with_capacity(4 + body_len);
        handshake.push(1);
        handshake.extend_from_slice(&[
            (body_len >> 16) as u8,
            (body_len >> 8) as u8,
            body_len as u8,
        ]);
        handshake.extend_from_slice(&[0x03, 0x03]);
        handshake.extend_from_slice(&[0; 32]);
        handshake.push(0);
        handshake.extend_from_slice(&2_u16.to_be_bytes());
        handshake.extend_from_slice(&[0x13, 0x01]);
        handshake.push(1);
        handshake.push(0);
        handshake.extend_from_slice(&(extensions.len() as u16).to_be_bytes());
        handshake.extend_from_slice(&extensions);

        let mut records = Vec::with_capacity(handshake.len() + 10);
        for fragment in handshake.chunks(16 * 1024) {
            records.extend_from_slice(&[0x16, 0x03, 0x03]);
            records.extend_from_slice(&(fragment.len() as u16).to_be_bytes());
            records.extend_from_slice(fragment);
        }
        records
    }

    #[tokio::test(start_paused = true)]
    async fn idle_watchdog_times_out_without_activity() {
        let activity = ActivityTracker::new(true);
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
        let activity = ActivityTracker::new(true);
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
    async fn established_limit_waits_for_capacity() {
        let limiter = Arc::new(Semaphore::new(1));
        let held = match Arc::clone(&limiter).acquire_owned().await {
            Ok(permit) => permit,
            Err(error) => panic!("failed to acquire test permit: {error}"),
        };

        let waiting = acquire_connection(Some(Arc::clone(&limiter)), Duration::from_secs(1));
        tokio::pin!(waiting);
        assert!(
            timeout(Duration::from_millis(10), &mut waiting)
                .await
                .is_err()
        );
        drop(held);
        assert!(timeout(Duration::from_secs(1), waiting).await.is_ok());
    }

    #[tokio::test(start_paused = true)]
    async fn established_limit_times_out_without_capacity() {
        let limiter = Arc::new(Semaphore::new(1));
        let _held = Arc::clone(&limiter)
            .acquire_owned()
            .await
            .unwrap_or_else(|error| panic!("failed to acquire test permit: {error}"));

        let waiting = acquire_connection(Some(limiter), Duration::from_secs(5));
        tokio::pin!(waiting);
        tokio::time::advance(Duration::from_secs(6)).await;

        let error = match waiting.await {
            Err(error) => error,
            Ok(_) => panic!("relay queue unexpectedly waited without a deadline"),
        };
        assert!(error.to_string().contains("等待转发容量超时"));
    }
}
