//! 从 TLS ClientHello 明文中提取 SNI，不做任何解密（TLS passthrough）。

use tls_parser::{
    TlsExtension, TlsMessage, TlsMessageHandshake, parse_tls_extensions, parse_tls_plaintext,
};

/// SNI 解析结果。
pub enum SniResult {
    /// 成功提取到 SNI 主机名。
    Found(String),
    /// 解析到 ClientHello 但其中没有 SNI 扩展。
    NoSni,
    /// 数据还不完整，需要继续读取更多字节。
    Incomplete,
    /// 不是合法的 TLS ClientHello。
    Invalid,
}

/// 尝试从缓冲区中解析出 SNI。
///
/// `buf` 应包含从客户端读取的原始 TLS 字节（首个握手记录）。
pub fn extract_sni(buf: &[u8]) -> SniResult {
    match parse_tls_plaintext(buf) {
        Ok((_, record)) => {
            for msg in &record.msg {
                if let TlsMessage::Handshake(TlsMessageHandshake::ClientHello(ch)) = msg {
                    if let Some(ext) = ch.ext {
                        if let Ok((_, extensions)) = parse_tls_extensions(ext) {
                            for extension in extensions {
                                if let TlsExtension::SNI(list) = extension {
                                    for (_, name) in list {
                                        if let Ok(host) = std::str::from_utf8(name) {
                                            if !host.is_empty() {
                                                return SniResult::Found(host.to_string());
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    // 解析到 ClientHello 但没有可用的 SNI。
                    return SniResult::NoSni;
                }
            }
            SniResult::NoSni
        }
        Err(tls_parser::nom::Err::Incomplete(_)) => SniResult::Incomplete,
        Err(_) => SniResult::Invalid,
    }
}
