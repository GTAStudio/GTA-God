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
                    if let Some(ext) = ch.ext
                        && let Ok((_, extensions)) = parse_tls_extensions(ext)
                    {
                        for extension in extensions {
                            if let TlsExtension::SNI(list) = extension {
                                for (_, name) in list {
                                    if let Ok(host) = std::str::from_utf8(name)
                                        && !host.is_empty()
                                    {
                                        return SniResult::Found(host.to_string());
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

#[cfg(test)]
mod tests {
    use super::{SniResult, extract_sni};

    #[test]
    fn extracts_sni_from_client_hello() {
        let hello = client_hello_with_sni("api.example.com");

        match extract_sni(&hello) {
            SniResult::Found(host) => assert_eq!(host, "api.example.com"),
            _ => panic!("expected SNI to be found"),
        }
    }

    #[test]
    fn reports_no_sni_when_extension_is_absent() {
        let hello = client_hello_without_extensions();

        assert!(matches!(extract_sni(&hello), SniResult::NoSni));
    }

    #[test]
    fn reports_incomplete_for_truncated_client_hello() {
        let hello = client_hello_with_sni("api.example.com");

        assert!(matches!(extract_sni(&hello[..8]), SniResult::Incomplete));
    }

    fn client_hello_with_sni(host: &str) -> Vec<u8> {
        let host = host.as_bytes();
        let server_name_len = host.len() as u16;
        let server_name_list_len = 1 + 2 + server_name_len;
        let sni_extension_len = 2 + server_name_list_len;

        let mut extensions = Vec::new();
        extensions.extend_from_slice(&0u16.to_be_bytes());
        extensions.extend_from_slice(&sni_extension_len.to_be_bytes());
        extensions.extend_from_slice(&server_name_list_len.to_be_bytes());
        extensions.push(0);
        extensions.extend_from_slice(&server_name_len.to_be_bytes());
        extensions.extend_from_slice(host);

        client_hello(Some(&extensions))
    }

    fn client_hello_without_extensions() -> Vec<u8> {
        client_hello(None)
    }

    fn client_hello(extensions: Option<&[u8]>) -> Vec<u8> {
        let extensions_len = extensions.map_or(0, <[u8]>::len) as u16;
        let body_len = 2 + 32 + 1 + 2 + 2 + 1 + 1 + 2 + extensions_len as usize;
        let record_len = 4 + body_len;

        let mut hello = Vec::new();
        hello.extend_from_slice(&[0x16, 0x03, 0x01]);
        hello.extend_from_slice(&(record_len as u16).to_be_bytes());
        hello.push(0x01);
        hello.extend_from_slice(&[
            (body_len >> 16) as u8,
            (body_len >> 8) as u8,
            body_len as u8,
        ]);
        hello.extend_from_slice(&[0x03, 0x03]);
        hello.extend_from_slice(&[0u8; 32]);
        hello.push(0);
        hello.extend_from_slice(&2u16.to_be_bytes());
        hello.extend_from_slice(&[0x13, 0x01]);
        hello.push(1);
        hello.push(0);
        hello.extend_from_slice(&extensions_len.to_be_bytes());
        if let Some(extensions) = extensions {
            hello.extend_from_slice(extensions);
        }
        hello
    }
}
