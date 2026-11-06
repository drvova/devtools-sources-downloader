// Small shared helpers: JS-string semantics, time formatting, and the one
// definition of the characters a generated file name may not contain.

use std::sync::LazyLock;

/// Characters a path segment may not contain. One definition on purpose:
/// widening the set for one producer used to leave the other four writing names
/// it would reject.
pub static BAD_PATH_CHARS: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new(r#"[\\:*?"<>|]"#).unwrap());

/// The same set plus `/`, for sanitising a whole path instead of one segment.
pub static BAD_PATH_CHARS_WITH_SLASH: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new(r#"[\\/:*?"<>|]"#).unwrap());

/// JS `String.length`: the number of UTF-16 code units.
pub fn utf16_len(text: &str) -> usize {
    text.chars().map(|c| c.len_utf16()).sum()
}

/// JS `text.slice(0, n)` on UTF-16 unit boundaries (astral chars never split).
pub fn utf16_prefix(text: &str, n: usize) -> &str {
    let mut units = 0usize;
    for (idx, ch) in text.char_indices() {
        if units + ch.len_utf16() > n {
            return &text[..idx];
        }
        units += ch.len_utf16();
    }
    text
}

/// JS `text.slice(-n)`: the last `n` UTF-16 units.
pub fn utf16_suffix(text: &str, n: usize) -> &str {
    let total = utf16_len(text);
    if total <= n {
        return text;
    }
    let skip = total - n;
    let mut units = 0usize;
    for (idx, ch) in text.char_indices() {
        if units >= skip {
            return &text[idx..];
        }
        units += ch.len_utf16();
    }
    text
}

/// `new Date().toISOString()` without a time crate: civil-from-days
/// (Howard Hinnant's algorithm) over the Unix epoch.
/// Civil date and time for a Unix second count: (year, month, day, hour,
/// minute, second). Howard Hinnant's `civil_from_days`, which the zip writer
/// needs for DOS timestamps as much as the reports need for ISO 8601.
pub fn civil_from_unix_secs(secs: u64) -> (i64, u32, u32, u32, u32, u32) {
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = doy - (153 * mp + 2) / 5 + 1; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 }; // [1, 12]
    let year = if m <= 2 { y + 1 } else { y };
    (
        year,
        m as u32,
        d as u32,
        (rem / 3600) as u32,
        ((rem % 3600) / 60) as u32,
        (rem % 60) as u32,
    )
}

pub fn iso8601_from_unix_secs(secs: u64) -> String {
    let (year, m, d, hour, minute, second) = civil_from_unix_secs(secs);
    format!("{year:04}-{m:02}-{d:02}T{hour:02}:{minute:02}:{second:02}.000Z")
}

pub fn iso8601_now() -> String {
    iso8601_from_unix_secs(now_unix_secs())
}

/// The current time in milliseconds. `wasm32-unknown-unknown` has no clock, so
/// the host supplies it (the bridge answers with `Date.now()`); every other
/// target reads the system clock.
pub fn now_unix_millis() -> u64 {
    #[cfg(target_arch = "wasm32")]
    {
        #[link(wasm_import_module = "env")]
        extern "C" {
            fn xu_host_now_ms() -> f64;
        }
        let ms = unsafe { xu_host_now_ms() };
        if ms.is_finite() && ms > 0.0 {
            ms as u64
        } else {
            0
        }
    }
    #[cfg(not(target_arch = "wasm32"))]
    {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0)
    }
}

/// The current time in seconds, from the same seam.
fn now_unix_secs() -> u64 {
    now_unix_millis() / 1000
}

/// Escapes every regex metacharacter, mirroring the JS idiom
/// `s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')`.
pub fn regex_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        if matches!(
            c,
            '.' | '*' | '+' | '?' | '^' | '$' | '{' | '}' | '(' | ')' | '|' | '[' | ']' | '\\'
        ) {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

/// The ASCII subset of ECMAScript whitespace, as a regex character class body:
/// space, tab, LF, VT, FF, CR.
///
/// This is deliberately NOT the full `\s`. ECMAScript `\s` also matches
/// U+00A0, U+FEFF, U+1680, U+2000-200A, U+2028, U+2029, U+202F, U+205F and
/// U+3000. Every pattern below scans minified source, where those characters do
/// not appear between tokens, and widening the class would change what all of
/// them match. `is_ecmascript_whitespace` is the full set; only `ToNumber` uses
/// it, because `Number(string)` trims `\s`.
pub const JS_S: &str = r" \t\n\x0B\f\r";

/// The ASCII subset of ECMAScript whitespace, for scanning decoded text.
pub fn is_ascii_js_space(c: char) -> bool {
    matches!(c, ' ' | '\t' | '\n' | '\u{b}' | '\u{c}' | '\r')
}

/// The byte form of [`is_ascii_js_space`], for scanning raw UTF-8.
pub fn is_ascii_js_space_byte(c: u8) -> bool {
    matches!(c, b' ' | b'\t' | b'\n' | 0x0B | b'\x0C' | b'\r')
}

/// The full ECMAScript `\s`: the ASCII subset plus U+00A0, U+FEFF, U+1680,
/// U+2000-200A, U+2028, U+2029, U+202F, U+205F and U+3000.
///
/// Used only where JavaScript itself would trim `\s` rather than where the
/// engine scans source, so the two sets stay distinguishable by name.
pub fn is_ecmascript_whitespace(c: char) -> bool {
    is_ascii_js_space(c)
        || c == '\u{a0}'
        || c == '\u{feff}'
        || c == '\u{1680}'
        || ('\u{2000}'..='\u{200a}').contains(&c)
        || matches!(
            c,
            '\u{2028}' | '\u{2029}' | '\u{202f}' | '\u{205f}' | '\u{3000}'
        )
}

/// JS `\w`: ASCII word characters only.
pub const JS_W: &str = r"A-Za-z0-9_";

#[cfg(test)]
mod tests {
    use super::*;

    /// The two whitespace sets exist because they mean different things, so this
    /// pins both directions: every ASCII member is in the full set, every
    /// ECMAScript extra is in the full set and NOT in the ASCII one, and a
    /// non-whitespace character is in neither. Without this the two could be
    /// silently collapsed back into one and nothing would notice.
    #[test]
    fn the_ascii_and_ecmascript_whitespace_sets_differ_by_the_extras() {
        for c in [' ', '\t', '\n', '\u{b}', '\u{c}', '\r'] {
            assert!(is_ascii_js_space(c), "{c:?} is ASCII JS whitespace");
            assert!(is_ecmascript_whitespace(c), "{c:?} is ECMAScript whitespace");
        }
        for c in [
            '\u{a0}', '\u{feff}', '\u{1680}', '\u{2000}', '\u{200a}', '\u{2028}', '\u{2029}',
            '\u{202f}', '\u{205f}', '\u{3000}',
        ] {
            assert!(
                !is_ascii_js_space(c),
                "{c:?} must not be in the ASCII subset"
            );
            assert!(is_ecmascript_whitespace(c), "{c:?} is ECMAScript whitespace");
        }
        assert!(!is_ascii_js_space('x'));
        assert!(!is_ecmascript_whitespace('x'));
    }

    /// The byte form scans raw UTF-8, so it must agree with the char form over
    /// the whole ASCII range rather than over a hand-picked few.
    #[test]
    fn the_byte_form_agrees_with_the_char_form_over_ascii() {
        for byte in 0u8..=0x7f {
            assert_eq!(
                is_ascii_js_space_byte(byte),
                is_ascii_js_space(byte as char),
                "byte {byte:#04x} disagrees between the two forms"
            );
        }
    }

    #[test]
    fn utf16_helpers() {
        assert_eq!(utf16_len("hello"), 5);
        assert_eq!(utf16_len("\u{1F600}"), 2);
        assert_eq!(utf16_prefix("abcd", 2), "ab");
        assert_eq!(utf16_suffix("abcd", 2), "cd");
        assert_eq!(utf16_prefix("\u{1F600}x", 1), "");
        assert_eq!(utf16_prefix("\u{1F600}x", 2), "\u{1F600}");
    }

    #[test]
    fn epoch_formatting() {
        assert_eq!(iso8601_from_unix_secs(0), "1970-01-01T00:00:00.000Z");
        assert_eq!(
            iso8601_from_unix_secs(1_767_225_600),
            "2026-01-01T00:00:00.000Z"
        );
    }
}
