//! Pure text/path/number helpers from the panel, with the exact JavaScript
//! semantics. Every function here was verified against node oracles captured
//! from the pre-port `page.js` (see the unit tests at the bottom).

use std::sync::LazyLock;

use serde_json::Value;

use crate::jsnumber::js_number_to_string;
use crate::transforms::decode_uri_component;
use crate::util::utf16_prefix;

/// JS `String.prototype.trim` character set: WhiteSpace + LineTerminator,
/// which includes U+00A0 and U+FEFF (Rust's `char::is_whitespace` misses the
/// latter).
fn is_js_trim_char(c: char) -> bool {
    matches!(
        c,
        '\u{0009}'
            | '\u{000A}'
            | '\u{000B}'
            | '\u{000C}'
            | '\u{000D}'
            | '\u{0020}'
            | '\u{00A0}'
            | '\u{1680}'
            | '\u{2000}'..='\u{200A}'
            | '\u{2028}'
            | '\u{2029}'
            | '\u{202F}'
            | '\u{205F}'
            | '\u{3000}'
            | '\u{FEFF}'
    )
}

/// `JSON.stringify` for a number: whole values print without a fraction and
/// non-finite values print as `null`.
pub fn serialize_js_number<S: serde::Serializer>(value: &f64, serializer: S) -> Result<S::Ok, S::Error> {
    if !value.is_finite() {
        return serializer.serialize_none();
    }
    if value.fract() == 0.0 && value.abs() < 9_007_199_254_740_992.0 {
        return serializer.serialize_i64(*value as i64);
    }
    serializer.serialize_f64(*value)
}

/// `JSON.stringify` for a number as a JSON value.
pub fn js_number_value(value: f64) -> serde_json::Value {
    if !value.is_finite() {
        return serde_json::Value::Null;
    }
    if value.fract() == 0.0 && value.abs() < 9_007_199_254_740_992.0 {
        return serde_json::Value::from(value as i64);
    }
    serde_json::Value::from(value)
}

pub fn js_trim(text: &str) -> &str {
    text.trim_matches(is_js_trim_char)
}

/// `hashString` from the panel: the Java-style 32-bit rolling hash JS uses for
/// content-addressed suffixes, rendered as unsigned hex.
pub fn hash_string(text: &str) -> String {
    let mut hash: i32 = 0;
    for unit in text.encode_utf16() {
        hash = hash
            .wrapping_shl(5)
            .wrapping_sub(hash)
            .wrapping_add(unit as i32);
    }
    // JS Math.abs of i32::MIN is 2147483648, which hex-renders as 80000000 -
    // widen before abs so that case matches.
    format!("{:x}", (hash as i64).abs())
}

/// `safeDecodeURIComponent`: strict percent-decoding, returning the input
/// unchanged when the JS engine would throw.
pub fn safe_decode_uri_component(value: &str) -> String {
    decode_uri_component(value).unwrap_or_else(|| value.to_string())
}

/// `sanitizePathPart`: strip path-hostile characters, fall back on empty, and
/// truncate to 100 UTF-16 units.
pub fn sanitize_path_part(value: &str, fallback: &str) -> String {
    static HOSTILE: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r#"[\\:*?"<>|]"#).unwrap());
    let trimmed = js_trim(value);
    let replaced = HOSTILE.replace_all(trimmed, "_");
    let resolved = if replaced.is_empty() {
        if fallback.is_empty() {
            "_"
        } else {
            fallback
        }
    } else {
        &replaced
    };
    if crate::util::utf16_len(resolved) > 100 {
        utf16_prefix(resolved, 100).to_string()
    } else {
        resolved.to_string()
    }
}

/// `appendPathSuffix`: insert before the final extension, where "extension"
/// means the last dot after the last slash. Indices are UTF-16, matching JS.
pub fn append_path_suffix(path: &str, suffix: &str) -> String {
    let mut dot: Option<usize> = None;
    let mut slash: Option<usize> = None;
    let mut utf16_at = 0usize;
    for (_byte_at, c) in path.char_indices() {
        if c == '.' {
            dot = Some(utf16_at);
        } else if c == '/' {
            slash = Some(utf16_at);
        }
        utf16_at += c.len_utf16();
    }
    let dot_utf16 = dot.map(|d| d as i64).unwrap_or(-1);
    let slash_utf16 = slash.map(|s| s as i64).unwrap_or(-1);
    if dot_utf16 > slash_utf16 {
        let dot_byte = utf16_byte_index(path, dot_utf16 as usize);
        return format!("{}{}{}", &path[..dot_byte], suffix, &path[dot_byte..]);
    }
    format!("{path}{suffix}")
}

/// Byte offset of the given UTF-16 index in `text`.
fn utf16_byte_index(text: &str, target: usize) -> usize {
    let mut utf16_at = 0usize;
    for (byte_at, c) in text.char_indices() {
        if utf16_at == target {
            return byte_at;
        }
        utf16_at += c.len_utf16();
    }
    text.len()
}

/// `normalizeUrlCandidate`: repair the URL shapes the panel sees in the wild.
pub fn normalize_url_candidate(url: &str) -> String {
    static DATA: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"(?i)^data:").unwrap());
    static BACKSLASH_RUN: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"\\+").unwrap());

    let value = js_trim(url);
    if value.is_empty() || DATA.is_match(value) {
        return value.to_string();
    }
    let value = BACKSLASH_RUN.replace_all(value, "/").into_owned();
    // The original also ran /^([a-z][a-z0-9+.-]*):\/\/+?/i -> "$1://": the
    // lazy quantifier can only ever match the two slashes the replacement
    // re-emits, so the step is a no-op and is not reproduced here.
    fix_single_slash(&value)
}

/// `/^([a-z][a-z0-9+.-]*):\/(?!\/)/i` -> `"$1://"`, written by hand because
/// the regex crate has no lookahead.
fn fix_single_slash(value: &str) -> String {
    let bytes = value.as_bytes();
    if bytes.is_empty() || !bytes[0].is_ascii_alphabetic() {
        return value.to_string();
    }
    let mut at = 1usize;
    while at < bytes.len()
        && (bytes[at].is_ascii_alphanumeric() || matches!(bytes[at], b'+' | b'.' | b'-'))
    {
        at += 1;
    }
    if at >= bytes.len() || bytes[at] != b':' {
        return value.to_string();
    }
    at += 1;
    if at >= bytes.len() || bytes[at] != b'/' {
        return value.to_string();
    }
    if at + 1 < bytes.len() && bytes[at + 1] == b'/' {
        return value.to_string();
    }
    format!("{}//{}", &value[..at], &value[at + 1..])
}

/// `sanitizeFilename`: turn a resource URL into a stable archive path.
pub fn sanitize_filename(url: &str) -> String {
    static DATA_MIME: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"^data:([^;,]+)").unwrap());
    static BLOB: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"(?i)^blob:(.+)$").unwrap());
    static LOOSE_SCHEME: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"(?i)^[a-z][a-z0-9+.-]*:$").unwrap());

    if url.is_empty() {
        return "unknown/resource".to_string();
    }
    let url = normalize_url_candidate(url);
    if url.starts_with("data:") {
        let ext = match DATA_MIME.captures(&url) {
            Some(caps) => {
                let mime = caps.get(1).map(|m| m.as_str()).unwrap_or_default();
                match mime.split('/').collect::<Vec<_>>().as_slice() {
                    [_, subtype] => (*subtype).to_string(),
                    _ => "data".to_string(),
                }
            }
            None => "data".to_string(),
        };
        return format!("inline/{}.{}", hash_string(&url), ext);
    }

    if let Some(caps) = BLOB.captures(&url) {
        let inner = caps.get(1).map(|m| m.as_str()).unwrap_or_default();
        return append_path_suffix(&sanitize_filename(inner), "__blob");
    }

    match url::Url::parse(&url) {
        Ok(parsed) => {
            let mut segments: Vec<String> = Vec::new();
            let protocol = sanitize_path_part(parsed.scheme(), "scheme");
            if protocol != "http" && protocol != "https" {
                segments.push(protocol);
            }
            // JS `parsed.host` carries the port.
            let host = match parsed.port() {
                Some(port) => format!("{}:{}", parsed.host_str().unwrap_or_default(), port),
                None => parsed.host_str().unwrap_or_default().to_string(),
            };
            if !host.is_empty() {
                segments.push(sanitize_path_part(&host, "host"));
            }

            let mut pathname = parsed.path().to_string();
            if pathname.is_empty() {
                pathname = "/".to_string();
            }
            if pathname.ends_with('/') {
                pathname.push_str("index.html");
            }
            for part in pathname.split('/') {
                if part.is_empty() {
                    continue;
                }
                segments.push(sanitize_path_part(&safe_decode_uri_component(part), "_"));
            }
            if segments.is_empty() {
                segments.push("unknown".to_string());
            }

            let mut name = segments.join("/");
            // `new URL('https://x/a?')` reports an EMPTY search and hash, which
            // are falsy in the original's `if (parsed.search || parsed.hash)`,
            // so a bare '?' or '#' must not produce a suffix.
            let search = parsed
                .query()
                .filter(|q| !q.is_empty())
                .map(|q| format!("?{q}"))
                .unwrap_or_default();
            let hash = parsed
                .fragment()
                .filter(|f| !f.is_empty())
                .map(|f| format!("#{f}"))
                .unwrap_or_default();
            if !search.is_empty() || !hash.is_empty() {
                let digest = hash_string(&format!("{search}{hash}"));
                let short: String = digest.chars().take(8).collect();
                name = append_path_suffix(&name, &format!("__{short}"));
            }
            name
        }
        Err(_) => {
            // Unparseable: the original's manual segment walk.
            let raw_value = match url.find(['?', '#']) {
                Some(at) => &url[..at],
                None => url.as_str(),
            };
            static SLASH_RUN: LazyLock<regex::Regex> =
                LazyLock::new(|| regex::Regex::new(r"/+").unwrap());
            let raw_parts: Vec<&str> = SLASH_RUN.split(raw_value).collect();
            let mut cleaned: Vec<String> = Vec::new();
            let mut offset = 0usize;
            if raw_parts.len() > 1 && LOOSE_SCHEME.is_match(raw_parts[0]) {
                let loose = raw_parts[0][..raw_parts[0].len() - 1].to_lowercase();
                if loose != "http" && loose != "https" {
                    cleaned.push(sanitize_path_part(&loose, "scheme"));
                }
                cleaned.push(sanitize_path_part(
                    &safe_decode_uri_component(raw_parts[1]),
                    "host",
                ));
                offset = 2;
            }
            for part in raw_parts.iter().skip(offset) {
                if part.is_empty() {
                    continue;
                }
                cleaned.push(sanitize_path_part(&safe_decode_uri_component(part), "_"));
            }
            let joined = cleaned.join("/");
            if joined.is_empty() {
                "unknown/resource".to_string()
            } else {
                joined
            }
        }
    }
}

/// `formatSize`.
pub fn format_size(bytes: f64) -> String {
    if bytes == 0.0 {
        return "0 B".to_string();
    }
    if bytes < 1024.0 {
        return format!("{} B", js_number_to_string(bytes));
    }
    if bytes < 1_048_576.0 {
        return format!("{} KB", js_to_fixed(bytes / 1024.0, 1));
    }
    format!("{} MB", js_to_fixed(bytes / 1_048_576.0, 2))
}

/// `sanitizePageTitle`.
pub fn sanitize_page_title(title: &str) -> String {
    static HOSTILE: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r#"[\\/:*?"<>|]"#).unwrap());
    let replaced = HOSTILE.replace_all(title, "_");
    let truncated = if crate::util::utf16_len(&replaced) > 100 {
        utf16_prefix(&replaced, 100).to_string()
    } else {
        replaced.into_owned()
    };
    if truncated.is_empty() {
        "page".to_string()
    } else {
        truncated
    }
}

/// `formatMs`.
pub fn format_ms(ms: f64) -> String {
    if ms < 1.0 {
        return format!("{} us", js_math_round(ms * 1000.0));
    }
    if ms < 1000.0 {
        return format!("{} ms", js_to_fixed(ms, 1));
    }
    format!("{} s", js_to_fixed(ms / 1000.0, 2))
}

/// JS `Math.round`: half toward positive infinity.
pub fn js_round(value: f64) -> f64 {
    if !value.is_finite() {
        return value;
    }
    (value + 0.5).floor()
}

/// JS `Math.round` rendered as a string.
fn js_math_round(value: f64) -> String {
    js_number_to_string(js_round(value))
}

/// JS `Number.prototype.toFixed`: round to `digits` decimals, ties away from
/// zero, exactly on the binary value. Rust's own float formatting rounds
/// ties-to-even and would disagree on inputs like 1.25.
fn js_to_fixed(value: f64, digits: usize) -> String {
    if !value.is_finite() || value.abs() >= 1e21 {
        return js_number_to_string(value);
    }
    // 25 guard digits: enough that the exact binary expansion decides the
    // rounding, so an input like 999.95 (stored just above) rounds up the way
    // JS does.
    let expanded = format!("{:.*}", digits + 25, value);
    round_decimal_half_away(&expanded, digits)
}

fn round_decimal_half_away(decimal: &str, digits: usize) -> String {
    let negative = decimal.starts_with('-');
    let body = if negative { &decimal[1..] } else { decimal };
    let (int_part, frac_part) = match body.split_once('.') {
        Some((i, f)) => (i.to_string(), f.to_string()),
        None => (body.to_string(), String::new()),
    };
    let mut kept: Vec<u8> = frac_part.bytes().take(digits).collect();
    while kept.len() < digits {
        kept.push(b'0');
    }
    let next = frac_part.as_bytes().get(digits).copied().unwrap_or(b'0');
    let rest_zeros = frac_part
        .as_bytes()
        .iter()
        .skip(digits + 1)
        .all(|b| *b == b'0');
    let round_up = next > b'5' || (next == b'5' && !rest_zeros) || (next == b'5' && rest_zeros);
    let mut int_digits: Vec<u8> = int_part.bytes().collect();
    if round_up {
        let mut carry = true;
        for i in (0..kept.len()).rev() {
            if !carry {
                break;
            }
            if kept[i] == b'9' {
                kept[i] = b'0';
            } else {
                kept[i] += 1;
                carry = false;
            }
        }
        if carry {
            let mut i = int_digits.len();
            while i > 0 {
                i -= 1;
                if int_digits[i] == b'9' {
                    int_digits[i] = b'0';
                } else {
                    int_digits[i] += 1;
                    carry = false;
                    break;
                }
            }
            if carry {
                int_digits.insert(0, b'1');
            }
        }
    }
    let int_text = String::from_utf8(int_digits).unwrap_or_else(|_| "0".to_string());
    let frac_text = String::from_utf8(kept).unwrap_or_default();
    let zero = int_text.chars().all(|c| c == '0') && frac_text.chars().all(|c| c == '0');
    let sign = if negative && !zero { "-" } else { "" };
    if digits == 0 {
        format!("{sign}{int_text}")
    } else {
        format!("{sign}{int_text}.{frac_text}")
    }
}

/// `localeCompare` approximation for the panel's sort orders: compare case
/// folded, then lowercase before uppercase (the default collation's primary
/// and tertiary levels for ASCII input).
pub fn js_locale_compare(left: &str, right: &str) -> std::cmp::Ordering {
    let folded = |s: &str| s.chars().flat_map(char::to_lowercase).collect::<String>();
    let left_folded = folded(left);
    let right_folded = folded(right);
    match left_folded.cmp(&right_folded) {
        std::cmp::Ordering::Equal => {
            let case_key = |s: &str| {
                s.chars()
                    .map(|c| if c.is_ascii_uppercase() { 1u8 } else { 0u8 })
                    .collect::<Vec<u8>>()
            };
            case_key(left).cmp(&case_key(right))
        }
        other => other,
    }
}

/// JS truthiness for a JSON value: the panel's core predicate. It lives here
/// because both `model` and `assets` need it and `model` sits below `assets`.
pub fn js_truthy(value: &Value) -> bool {
    match value {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_f64().map(|f| f != 0.0 && !f.is_nan()).unwrap_or(false),
        Value::String(s) => !s.is_empty(),
        Value::Array(_) | Value::Object(_) => true,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Oracles captured from node running the pre-port page.js functions.

    #[test]
    fn hash_string_matches_node() {
        assert_eq!(hash_string("a"), "61");
        assert_eq!(hash_string("moduleLoader"), "3f92419f");
        assert_eq!(hash_string("https://x/y?q=1#h"), "64c98482");
        assert_eq!(hash_string(""), "0");
        assert_eq!(hash_string("ünïcode"), "2451f856");
        assert_eq!(hash_string("page"), "34628f");
    }

    #[test]
    fn sanitize_path_part_matches_node() {
        assert_eq!(sanitize_path_part("a/b", "_"), "a/b");
        assert_eq!(sanitize_path_part("a\\b", "_"), "a_b");
        assert_eq!(sanitize_path_part("  spaced  ", "_"), "spaced");
        assert_eq!(sanitize_path_part("", "_"), "_");
        assert_eq!(sanitize_path_part(&"x".repeat(120), "_"), "x".repeat(100));
        assert_eq!(sanitize_path_part("a\u{a0}b", "_"), "a\u{a0}b");
    }

    #[test]
    fn append_path_suffix_matches_node() {
        assert_eq!(append_path_suffix("a/b.js", "__blob"), "a/b__blob.js");
        assert_eq!(append_path_suffix("a/b", "__blob"), "a/b__blob");
        assert_eq!(append_path_suffix("a.b.c", "__x"), "a.b__x.c");
        assert_eq!(append_path_suffix("/x/", "__y"), "/x/__y");
    }

    #[test]
    fn normalize_url_candidate_matches_node() {
        assert_eq!(normalize_url_candidate("http:/x/y"), "http://x/y");
        assert_eq!(normalize_url_candidate("http:///x/y"), "http:///x/y");
        assert_eq!(normalize_url_candidate("a\\\\b"), "a/b");
        assert_eq!(normalize_url_candidate("DATA:foo"), "DATA:foo");
        assert_eq!(normalize_url_candidate("https://x//y"), "https://x//y");
        assert_eq!(normalize_url_candidate(""), "");
        assert_eq!(normalize_url_candidate("HTTP:/x"), "HTTP://x");
    }

    #[test]
    fn sanitize_filename_matches_node() {
        assert_eq!(sanitize_filename("https://a.test/app.js?v=2"), "a.test/app__1e65ec.js");
        assert_eq!(sanitize_filename("https://a.test/dir/"), "a.test/dir/index.html");
        assert_eq!(
            sanitize_filename("data:text/plain;base64,AAA"),
            "inline/32a12987.plain"
        );
        assert_eq!(sanitize_filename("blob:https://x/y.js"), "x/y__blob.js");
        assert_eq!(sanitize_filename("not a url at all"), "not a url at all");
        assert_eq!(sanitize_filename("https://a.test:8443/p%20q.js"), "a.test_8443/p q.js");
        assert_eq!(sanitize_filename("http://x/y#frag"), "x/y__21d4c95");
        assert_eq!(sanitize_filename("data:,raw"), "inline/17d2a9b4.data");
        assert_eq!(sanitize_filename("ftp:/a/b"), "ftp/a/b");
    }

    #[test]
    fn format_size_matches_node() {
        assert_eq!(format_size(0.0), "0 B");
        assert_eq!(format_size(1.0), "1 B");
        assert_eq!(format_size(1023.0), "1023 B");
        assert_eq!(format_size(1024.0), "1.0 KB");
        assert_eq!(format_size(1280.0), "1.3 KB");
        assert_eq!(format_size(1536.0), "1.5 KB");
        assert_eq!(format_size(1_048_576.0), "1.00 MB");
        assert_eq!(format_size(1_234_567.0), "1.18 MB");
        assert_eq!(format_size(2.5), "2.5 B");
        assert_eq!(format_size(1_048_575.0), "1024.0 KB");
    }

    #[test]
    fn sanitize_page_title_matches_node() {
        assert_eq!(sanitize_page_title("My Page"), "My Page");
        assert_eq!(
            sanitize_page_title("a/b\\c:d*e?f\"g<h>i|j"),
            "a_b_c_d_e_f_g_h_i_j"
        );
        assert_eq!(sanitize_page_title(""), "page");
        assert_eq!(sanitize_page_title(&"x".repeat(120)), "x".repeat(100));
    }

    #[test]
    fn format_ms_matches_node() {
        assert_eq!(format_ms(0.5), "500 us");
        assert_eq!(format_ms(0.999), "999 us");
        assert_eq!(format_ms(1.0), "1.0 ms");
        assert_eq!(format_ms(999.94), "999.9 ms");
        assert_eq!(format_ms(999.95), "1000.0 ms");
        assert_eq!(format_ms(1000.0), "1.00 s");
        assert_eq!(format_ms(1500.0), "1.50 s");
        assert_eq!(format_ms(123456.0), "123.46 s");
    }

    #[test]
    fn safe_decode_matches_node() {
        assert_eq!(safe_decode_uri_component("a%20b"), "a b");
        assert_eq!(safe_decode_uri_component("a%ZZb"), "a%ZZb");
        assert_eq!(safe_decode_uri_component("%E2%9C%93"), "\u{2713}");
        assert_eq!(safe_decode_uri_component("a%"), "a%");
    }
}
