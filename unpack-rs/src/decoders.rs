// Text and byte decoders: escape decoding, base64, lossy UTF-8 text,
// printable ratio and gzip/deflate inflation.

use base64::Engine;
use flate2::read::{GzDecoder, ZlibDecoder};
use std::io::Read;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InflateFormat {
    Gzip,
    Deflate,
}

/// JS `decodeEscapes(raw)`. Lone surrogates produced by \uXXXX on surrogate
/// halves degrade to U+FFFD (a JS String can hold them, a Rust String cannot);
/// ASCII payloads are byte-identical. Two documented divergences: a `\u{`
/// escape with no closing brace terminates the scan (the JS cursor rewind
/// loops forever re-emitting NUL), and a code point above 0x10FFFF degrades
/// to U+FFFD where the JS fromCodePoint throws.
pub fn decode_escapes(raw: &str) -> String {
    let chars: Vec<char> = raw.chars().collect();
    let mut out = String::with_capacity(raw.len());
    let mut i = 0usize;
    while i < chars.len() {
        let ch = chars[i];
        if ch != '\\' {
            out.push(ch);
            i += 1;
            continue;
        }
        i += 1;
        let next = match chars.get(i) {
            Some(&n) => n,
            None => {
                // Quirk: a trailing backslash appends the literal text
                // "undefined" (JS string-concatenates the undefined read).
                out.push_str("undefined");
                break;
            }
        };
        match next {
            'n' => out.push('\n'),
            'r' => out.push('\r'),
            't' => out.push('\t'),
            'b' => out.push('\u{8}'),
            'f' => out.push('\u{c}'),
            'v' => out.push('\u{b}'),
            '0' => out.push('\0'),
            'x' => {
                let hex: String = chars[i + 1..(i + 3).min(chars.len())].iter().collect();
                let code = parse_hex_prefix(&hex);
                out.push(code_unit_to_char(code));
                i += 2;
            }
            'u' => {
                if chars.get(i + 1) == Some(&'{') {
                    let close = chars[i + 2..]
                        .iter()
                        .position(|&c| c == '}')
                        .map(|p| i + 2 + p);
                    match close {
                        Some(cl) => {
                            let hex: String = chars[i + 2..cl].iter().collect();
                            let code = parse_hex_prefix(&hex);
                            out.push(code_point_to_char(code));
                            i = cl;
                        }
                        None => {
                            // Divergence, documented: the JS rewinds the
                            // cursor to -1 and loops forever re-emitting the
                            // fallback NUL; terminate after one emission.
                            let hex: String = chars[i + 2..(chars.len().saturating_sub(1)).max(i + 2)].iter().collect();
                            let code = parse_hex_prefix(&hex);
                            out.push(code_point_to_char(code));
                            break;
                        }
                    }
                } else {
                    let hex: String = chars[i + 1..(i + 5).min(chars.len())].iter().collect();
                    let code = parse_hex_prefix(&hex);
                    out.push(code_unit_to_char(code));
                    i += 4;
                }
            }
            '\n' => {} // line continuation
            '1'..='7' => {
                let mut octal = String::new();
                octal.push(next);
                while octal.chars().count() < 3
                    && matches!(chars.get(i + 1), Some(&d) if ('0'..='7').contains(&d))
                {
                    i += 1;
                    octal.push(chars[i]);
                }
                let code = u32::from_str_radix(&octal, 8).unwrap_or(0);
                out.push(code_unit_to_char(code));
            }
            other => out.push(other),
        }
        i += 1;
    }
    out
}

/// JS `parseInt(s, 16)`: longest valid hex prefix, no digits -> 0.
fn parse_hex_prefix(s: &str) -> u32 {
    let digits: String = s
        .chars()
        .take_while(|c| c.is_ascii_hexdigit())
        .collect();
    u32::from_str_radix(&digits, 16).unwrap_or(0)
}

fn code_unit_to_char(code: u32) -> char {
    char::from_u32(code & 0xFFFF).unwrap_or('\u{FFFD}')
}

fn code_point_to_char(code: u32) -> char {
    char::from_u32(code).unwrap_or('\u{FFFD}')
}

/// JS `decodeBase64ToBytes`: whitespace stripped, URL-safe alphabet folded,
/// padded to a multiple of 4; decode failure yields None (JS null).
pub fn decode_base64_to_bytes(base64: &str) -> Option<Vec<u8>> {
    let mut normalized: String = base64
        .chars()
        .filter(|c| !matches!(c, ' ' | '\t' | '\n' | '\u{b}' | '\r' | '\u{c}'))
        .map(|c| match c {
            '-' => '+',
            '_' => '/',
            other => other,
        })
        .collect();
    while !normalized.len().is_multiple_of(4) {
        normalized.push('=');
    }
    base64::engine::general_purpose::STANDARD
        .decode(normalized.as_bytes())
        .ok()
}

/// The base64 alphabet encoder: the inverse of [`decode_base64_to_bytes`],
/// used when binary payloads have to cross a text boundary.
pub fn encode_base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = *chunk.get(1).unwrap_or(&0) as u32;
        let b2 = *chunk.get(2).unwrap_or(&0) as u32;
        let triple = (b0 << 16) | (b1 << 8) | b2;
        out.push(ALPHABET[(triple >> 18) as usize & 0x3f] as char);
        out.push(ALPHABET[(triple >> 12) as usize & 0x3f] as char);
        out.push(if chunk.len() > 1 {
            ALPHABET[(triple >> 6) as usize & 0x3f] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            ALPHABET[triple as usize & 0x3f] as char
        } else {
            '='
        });
    }
    out
}

/// JS `bytesToText`: TextDecoder('utf-8', { fatal: false }).
pub fn bytes_to_text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

/// JS `printableRatio`, counted over characters.
pub fn printable_ratio(text: &str) -> f64 {
    let total = text.chars().count();
    if total == 0 {
        return 0.0;
    }
    let printable = text
        .chars()
        .filter(|&c| {
            let code = c as u32;
            code == 9 || code == 10 || code == 13 || (code >= 32 && code != 127)
        })
        .count();
    printable as f64 / total as f64
}

/// JS `inflateBytes(bytes, format)` over the platform stream; flate2 is the
/// Rust equivalent and is always available, so None only means "not this
/// format / corrupt stream".
pub fn inflate_bytes(bytes: &[u8], format: InflateFormat) -> Option<Vec<u8>> {
    match format {
        InflateFormat::Gzip => {
            let mut out = Vec::new();
            GzDecoder::new(bytes).read_to_end(&mut out).ok()?;
            Some(out)
        }
        InflateFormat::Deflate => {
            let mut out = Vec::new();
            ZlibDecoder::new(bytes).read_to_end(&mut out).ok()?;
            Some(out)
        }
    }
}

pub fn gzip_format(bytes: &[u8]) -> Option<InflateFormat> {
    if bytes.len() > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b {
        return Some(InflateFormat::Gzip);
    }
    if bytes.len() > 2
        && bytes[0] == 0x78
        && (bytes[1] == 0x01 || bytes[1] == 0x9c || bytes[1] == 0xda)
    {
        return Some(InflateFormat::Deflate);
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mixed_escapes() {
        assert_eq!(decode_escapes("a\\tb\\nc\\\\d\\x41\\u0042"), "a\tb\nc\\dAB");
    }

    #[test]
    fn base64_and_ratio() {
        assert_eq!(bytes_to_text(&decode_base64_to_bytes("aGVsbG8=").unwrap()), "hello");
        assert_eq!(printable_ratio("hello\nworld"), 1.0);
        assert!(printable_ratio("\u{0}\u{1}") < 0.1);
    }
}

#[cfg(test)]
mod base64_tests {
    use super::{decode_base64_to_bytes, encode_base64};

    #[test]
    fn encode_base64_round_trips_every_tail_length() {
        for case in [
            Vec::new(),
            vec![0x00],
            vec![0x61],
            vec![0x00, 0x61, 0x73, 0x6d],
            vec![0xff, 0xfe, 0xfd],
            (0u8..=255).collect::<Vec<u8>>(),
        ] {
            let encoded = encode_base64(&case);
            assert_eq!(
                decode_base64_to_bytes(&encoded).as_deref(),
                Some(case.as_slice()),
                "round trip for {case:?}"
            );
        }
        assert_eq!(encode_base64(b"a"), "YQ==");
        assert_eq!(encode_base64(b"ab"), "YWI=");
        assert_eq!(encode_base64(b"abc"), "YWJj");
    }
}
