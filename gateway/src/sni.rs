//! 从 TLS ClientHello 明文中提取 SNI，不做任何解密（TLS passthrough）。

use tls_parser::{
    TlsExtension, TlsMessage, TlsMessageHandshake, parse_tls_extensions,
    parse_tls_message_handshake,
};

const TLS_RECORD_HEADER_LEN: usize = 5;
const TLS_HANDSHAKE_CONTENT_TYPE: u8 = 22;
const TLS_CLIENT_HELLO_TYPE: u8 = 1;
const TLS_PLAINTEXT_MAX_FRAGMENT: usize = 1 << 14;
pub(crate) const MAX_CLIENT_HELLO_BYTES: usize = 64 * 1024;

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

/// 增量 ClientHello 重组器。调用方可反复传入不断增长的原始 wire buffer；
/// 已完成的 TLS record 只消费一次，避免碎片化输入触发重复扫描与复制。
pub struct ClientHelloSniParser {
    wire_offset: usize,
    handshake: Vec<u8>,
    message_len: Option<usize>,
}

impl ClientHelloSniParser {
    pub fn new() -> Self {
        Self {
            wire_offset: 0,
            handshake: Vec::with_capacity(2048),
            message_len: None,
        }
    }

    pub fn extract(&mut self, buf: &[u8]) -> SniResult {
        loop {
            let Some(header_end) = self.wire_offset.checked_add(TLS_RECORD_HEADER_LEN) else {
                return SniResult::Invalid;
            };
            if header_end > buf.len() {
                return SniResult::Incomplete;
            }
            if buf[self.wire_offset] != TLS_HANDSHAKE_CONTENT_TYPE {
                return SniResult::Invalid;
            }

            let fragment_len =
                u16::from_be_bytes([buf[self.wire_offset + 3], buf[self.wire_offset + 4]]) as usize;
            if fragment_len == 0 || fragment_len > TLS_PLAINTEXT_MAX_FRAGMENT {
                return SniResult::Invalid;
            }
            let Some(record_end) = header_end.checked_add(fragment_len) else {
                return SniResult::Invalid;
            };
            if record_end > buf.len() {
                return SniResult::Incomplete;
            }

            let fragment = &buf[header_end..record_end];
            let needed = self.message_len.map_or(fragment.len(), |len| {
                len.saturating_sub(self.handshake.len())
            });
            self.handshake
                .extend_from_slice(&fragment[..fragment.len().min(needed)]);

            if self.message_len.is_none() && self.handshake.len() >= 4 {
                if self.handshake[0] != TLS_CLIENT_HELLO_TYPE {
                    return SniResult::Invalid;
                }
                let body_len = ((self.handshake[1] as usize) << 16)
                    | ((self.handshake[2] as usize) << 8)
                    | self.handshake[3] as usize;
                let Some(message_len) = body_len.checked_add(4) else {
                    return SniResult::Invalid;
                };
                if message_len > MAX_CLIENT_HELLO_BYTES {
                    return SniResult::Invalid;
                }
                self.message_len = Some(message_len);
                self.handshake.truncate(message_len);
            }

            if self
                .message_len
                .is_some_and(|message_len| self.handshake.len() == message_len)
            {
                return extract_sni_from_handshake(&self.handshake);
            }

            self.wire_offset = record_end;
        }
    }
}

/// 尝试从缓冲区中解析出 SNI。
///
/// `buf` 应包含从客户端读取的原始 TLS 字节。ClientHello 可以跨多个
/// TLSPlaintext record，本函数会先重组完整握手消息再交给 `tls-parser`。
#[cfg(test)]
pub fn extract_sni(buf: &[u8]) -> SniResult {
    ClientHelloSniParser::new().extract(buf)
}

fn extract_sni_from_handshake(handshake: &[u8]) -> SniResult {
    match parse_tls_message_handshake(handshake) {
        Ok((_, TlsMessage::Handshake(TlsMessageHandshake::ClientHello(ch)))) => {
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
            SniResult::NoSni
        }
        Ok(_) => SniResult::Invalid,
        Err(tls_parser::nom::Err::Incomplete(_)) => SniResult::Incomplete,
        Err(_) => SniResult::Invalid,
    }
}

#[cfg(test)]
mod tests {
    use super::{ClientHelloSniParser, SniResult, extract_sni};

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

    #[test]
    fn extracts_sni_from_client_hello_fragmented_across_records() {
        let hello = client_hello_with_sni("api.example.com");
        let payload = &hello[5..];

        for split in 1..payload.len() {
            let fragmented = fragment_record(&hello, split);
            match extract_sni(&fragmented) {
                SniResult::Found(host) => assert_eq!(host, "api.example.com", "split={split}"),
                _ => panic!("expected fragmented SNI to be found at split={split}"),
            }
        }
    }

    #[test]
    fn incrementally_extracts_sni_from_one_byte_reads() {
        let hello = fragment_record(&client_hello_with_sni("api.example.com"), 17);
        let mut parser = ClientHelloSniParser::new();

        for end in 1..hello.len() {
            assert!(matches!(
                parser.extract(&hello[..end]),
                SniResult::Incomplete
            ));
        }
        match parser.extract(&hello) {
            SniResult::Found(host) => assert_eq!(host, "api.example.com"),
            _ => panic!("expected incrementally parsed SNI"),
        }
    }

    fn fragment_record(record: &[u8], split: usize) -> Vec<u8> {
        let payload = &record[5..];
        let mut fragmented = Vec::with_capacity(record.len() + 5);
        fragmented.extend_from_slice(&record[..3]);
        fragmented.extend_from_slice(&(split as u16).to_be_bytes());
        fragmented.extend_from_slice(&payload[..split]);
        fragmented.extend_from_slice(&record[..3]);
        fragmented.extend_from_slice(&((payload.len() - split) as u16).to_be_bytes());
        fragmented.extend_from_slice(&payload[split..]);
        fragmented
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
