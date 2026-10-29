// Packer and obfuscation layers that decode by pure static rewriting:
// Dean Edwards' packer, aaencode/jjencode/jsfiretruck detection,
// obfuscator.io marker census, and the string-array + rotator rebuild
// with static decoder inlining.

use crate::util::{regex_escape, JS_S, JS_W};
use std::sync::LazyLock;

const PACKER_SIGNATURE: &str = "function(p,a,c,k,e,";
const MAX_PACKER_LAYERS: usize = 32;
const MAX_ROTATIONS: usize = 4096;

// ------------------------------------------------------------ Dean Edwards

fn unescape_js_literal(raw: &str) -> String {
    let chars: Vec<char> = raw.chars().collect();
    let mut out = String::with_capacity(raw.len());
    let mut i = 0usize;
    while i < chars.len() {
        let c = chars[i];
        if c != '\\' {
            out.push(c);
            i += 1;
            continue;
        }
        i += 1;
        let n = match chars.get(i) {
            Some(&n) => n,
            None => break,
        };
        match n {
            'n' => out.push('\n'),
            'r' => out.push('\r'),
            't' => out.push('\t'),
            'b' => out.push('\u{8}'),
            'f' => out.push('\u{c}'),
            'v' => out.push('\u{b}'),
            '0' => out.push('\0'),
            'x' => {
                let hex: String = chars[i + 1..(i + 3).min(chars.len())].iter().collect();
                let code = u32::from_str_radix(&hex, 16).unwrap_or(0);
                out.push(char::from_u32(code & 0xFFFF).unwrap_or('\u{FFFD}'));
                i += 2;
            }
            'u' => {
                let hex: String = chars[i + 1..(i + 5).min(chars.len())].iter().collect();
                let code = u32::from_str_radix(&hex, 16).unwrap_or(0);
                out.push(char::from_u32(code & 0xFFFF).unwrap_or('\u{FFFD}'));
                i += 4;
            }
            other => out.push(other),
        }
        i += 1;
    }
    out
}

fn digit_value(c: char) -> i64 {
    if c.is_ascii_digit() {
        c as i64 - 48
    } else if c.is_ascii_lowercase() {
        c as i64 - 87
    } else if c.is_ascii_uppercase() {
        c as i64 - 55
    } else {
        -1
    }
}

fn base_decode_token(token: &str, base: i64) -> i64 {
    let mut value: i64 = 0;
    for c in token.chars() {
        let d = digit_value(c);
        if d < 0 || d >= base {
            return -1;
        }
        value = value * base + d;
    }
    value
}

enum PackerArg {
    Str { value: String, split: Option<String> },
    Number(i64),
    Other,
}



fn is_js_space(c: char) -> bool {
    matches!(c, ' ' | '\t' | '\n' | '\u{b}' | '\u{c}' | '\r')
}

// Reads one argument after the packer's "}(" — a string literal, a number,
// or a balanced non-literal token we only need to skip.
fn read_packer_arg(text: &str, index: usize) -> Option<(PackerArg, usize)> {
    let b = text.as_bytes();
    let mut i = index;
    while i < b.len() && is_space_byte(b[i]) {
        i += 1;
    }
    let quote = *b.get(i)?;
    if quote == b'\'' || quote == b'"' {
        let mut j = i + 1;
        while j < b.len() && b[j] != quote {
            if b[j] == b'\\' {
                j += 1;
            }
            j += 1;
        }
        if j >= b.len() {
            return None;
        }
        return Some((
            PackerArg::Str {
                value: unescape_js_literal(&text[i + 1..j]),
                split: None,
            },
            j + 1,
        ));
    }
    let rest = &text[i..];
    static NUM_RE: LazyLock<regex::Regex> = LazyLock::new(|| {
        regex::Regex::new(r"^[-+]?(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?)").unwrap()
    });
    if let Some(m) = NUM_RE.find(rest) {
        let raw_num = m.as_str();
        // A literal must be followed by a delimiter, not by identifier junk.
        let after = &rest[raw_num.len()..];
        let delimited = after.is_empty()
            || after
                .bytes()
                .next()
                .map(|c| is_space_byte(c) || matches!(c, b',' | b')' | b'%'))
                .unwrap_or(false);
        if !delimited {
            return None;
        }
        let num = parse_int_literal(raw_num)?;
        return Some((PackerArg::Number(num), i + raw_num.len()));
    }
    if quote == b'{' || quote == b'[' || quote == b'(' {
        let mut depth = 0i64;
        let mut k = i;
        while k < b.len() {
            let c = b[k];
            if matches!(c, b'(' | b'[' | b'{') {
                depth += 1;
            } else if matches!(c, b')' | b']' | b'}') {
                depth -= 1;
                if depth == 0 {
                    return Some((PackerArg::Other, k + 1));
                }
            }
            k += 1;
        }
        return None;
    }
    if quote.is_ascii_lowercase() {
        let mut w = i;
        while w < b.len() && (b[w].is_ascii_alphanumeric() || b[w] == b'_' || b[w] == b'$') {
            w += 1;
        }
        if w > i {
            return Some((PackerArg::Other, w));
        }
    }
    None
}

fn parse_packer_call(text: &str, call_start: usize) -> Option<(Vec<(PackerArg, usize)>, usize)> {
    let b = text.as_bytes();
    let mut args: Vec<(PackerArg, usize)> = Vec::new();
    let mut i = call_start + 1;
    loop {
        while i < b.len() && (is_space_byte(b[i]) || b[i] == b',') {
            i += 1;
        }
        if *b.get(i)? == b')' {
            return Some((args, i + 1));
        }
        let (mut arg, mut end) = read_packer_arg(text, i)?;
        // `.split('|')` suffix on the words literal. The JS pattern is
        // /^\s*\.split\s*\(\s*(['"]).*?\1\s*\)/ — a backreference the regex
        // crate lacks, so the minimal-quote match is done by hand.
        if matches!(arg, PackerArg::Str { .. }) {
            if let Some(consumed) = match_split_suffix(text, end) {
                let inner = &text[consumed.0..consumed.1];
                if let PackerArg::Str { split, .. } = &mut arg {
                    *split = Some(unescape_js_literal(inner));
                }
                end = consumed.2;
            }
        }
        i = end;
        args.push((arg, end));
        if args.len() > 8 {
            return None;
        }
    }
}

/// Hand-match of /^\s*\.split\s*\(\s*(['"]).*?\1\s*\)/ anchored at `from`.
/// Returns (inner_start, inner_end, position after the closing paren).
fn match_split_suffix(text: &str, from: usize) -> Option<(usize, usize, usize)> {
    let b = text.as_bytes();
    let mut p = from;
    while p < b.len() && is_space_byte(b[p]) {
        p += 1;
    }
    if !text[p..].starts_with(".split") {
        return None;
    }
    p += 6;
    while p < b.len() && is_space_byte(b[p]) {
        p += 1;
    }
    if p >= b.len() || b[p] != b'(' {
        return None;
    }
    p += 1;
    while p < b.len() && is_space_byte(b[p]) {
        p += 1;
    }
    let quote = *b.get(p)?;
    if quote != b'\'' && quote != b'"' {
        return None;
    }
    // .*?\1\s*\) — the first closing quote followed by optional spaces and ')'.
    let inner_start = p + 1;
    let mut search = inner_start;
    while let Some(rel) = text[search..].find(quote as char) {
        let close_quote = search + rel;
        let mut q2 = close_quote + 1;
        while q2 < b.len() && is_space_byte(b[q2]) {
            q2 += 1;
        }
        if b.get(q2) == Some(&b')') {
            return Some((inner_start, close_quote, q2 + 1));
        }
        search = close_quote + 1;
    }
    None
}

fn is_space_byte(b: u8) -> bool {
    matches!(b, b' ' | b'\t' | b'\n' | 0x0B | b'\x0c' | b'\r')
}

#[derive(serde::Serialize)]
pub struct PackerFound {
    pub payload: String,
    pub base: i64,
    pub count: i64,
    pub words: Vec<String>,
}

pub fn detect_packer(text: &str) -> Option<PackerFound> {
    let sig_idx = text.find(PACKER_SIGNATURE)?;
    let call_idx = text[sig_idx..].find("}(")? + sig_idx;
    let (args, _end) = parse_packer_call(text, call_idx + 1)?;
    if args.len() < 4 {
        return None;
    }
    let (payload, _) = &args[0];
    let (base, _) = &args[1];
    let (count, _) = &args[2];
    let (words, _) = &args[3];
    let (payload_value, _) = match payload {
        PackerArg::Str { value, split } => (value, split),
        _ => return None,
    };
    let base_value = match base {
        PackerArg::Number(n) => *n,
        _ => return None,
    };
    let count_value = match count {
        PackerArg::Number(n) => *n,
        _ => return None,
    };
    let (words_value, words_split) = match words {
        PackerArg::Str { value, split } => (value, split),
        _ => return None,
    };
    if !(2..=62).contains(&base_value) {
        return None;
    }
    let separator = words_split.clone().unwrap_or_else(|| "|".to_string());
    let word_list: Vec<String> = words_value
        .split(separator.as_str())
        .map(|s| s.to_string())
        .collect();
    Some(PackerFound {
        payload: payload_value.clone(),
        base: base_value,
        count: count_value,
        words: word_list,
    })
}

fn unpack_with(payload: &str, base: i64, words: &[String]) -> String {
    static WORD_TOKEN: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"[A-Za-z0-9_]+").unwrap());
    WORD_TOKEN
        .replace_all(payload, |caps: &regex::Captures| -> String {
            let token = caps.get(0).unwrap().as_str();
            let idx = base_decode_token(token, base);
            if idx >= 0 && (idx as usize) < words.len() && !words[idx as usize].is_empty() {
                words[idx as usize].clone()
            } else {
                token.to_string()
            }
        })
        .into_owned()
}

/// Peels every packer layer present (repacked outputs nest).
pub fn unpack_packer(text: &str) -> Option<String> {
    let mut current = text.to_string();
    for _ in 0..MAX_PACKER_LAYERS {
        let Some(found) = detect_packer(&current) else {
            break;
        };
        let next = unpack_with(&found.payload, found.base, &found.words);
        if next == current {
            break;
        }
        current = next;
    }
    if current == text {
        None
    } else {
        Some(current)
    }
}

// ------------------------------------------------------- esoteric detectors

const AA_KAOMOJI: [char; 12] = [
    '\u{FF9F}', 'ω', '\u{FF89}', 'Θ', '\u{FF70}', 'Д', 'Σ', 'ε', 'ノ', '∇', '°', '・',
];

#[derive(Debug, Clone, serde::Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Refusal {
    pub tool: &'static str,
    pub detail: String,
    pub banner_hits: Option<u32>,
    pub density: Option<f64>,
    pub purity: Option<f64>,
    pub markers: Option<Vec<MarkerHit>>,
}

#[derive(Debug, serde::Serialize, Clone, PartialEq)]
pub struct MarkerHit {
    pub marker: String,
    pub count: usize,
}

pub fn detect_aaencode(source: &str) -> Option<Refusal> {
    let trimmed = source.trim();
    if trimmed.chars().count() < 80 {
        return None;
    }
    let mut banner_hits = 0u32;
    if trimmed.contains("\u{FF9F}ω\u{FF89}") {
        banner_hits += 1;
    }
    if trimmed.contains("\u{FF9F}Д\u{FF9F}") {
        banner_hits += 1;
    }
    if trimmed.contains("(\u{FF9F}Θ\u{FF9F})") || trimmed.contains("(\u{FF9F}\u{FF70}\u{FF9F})") {
        banner_hits += 1;
    }
    let mut kaomoji = 0usize;
    let mut total = 0usize;
    for c in trimmed.chars() {
        total += 1;
        if AA_KAOMOJI.contains(&c) {
            kaomoji += 1;
        }
    }
    let density = if total > 0 { kaomoji as f64 / total as f64 } else { 0.0 };
    if banner_hits >= 1 && density >= 0.05 {
        return Some(Refusal {
            tool: "aaencode",
            detail: "kaomoji shell (execution required to decode)".to_string(),
            banner_hits: Some(banner_hits),
            density: Some(density),
            purity: None,
            markers: None,
        });
    }
    None
}

pub fn detect_jjencode(source: &str) -> Option<Refusal> {
    let trimmed = source.trim();
    if trimmed.chars().count() < 80 {
        return None;
    }
    if trimmed.contains("=~[]") && (trimmed.contains("{___:++") || trimmed.contains("{ ___:++")) {
        return Some(Refusal {
            tool: "jjencode",
            detail: "$=~[] global-object shell (execution required to decode)".to_string(),
            banner_hits: None,
            density: None,
            purity: None,
            markers: None,
        });
    }
    None
}

pub fn detect_jsfiretruck(source: &str) -> Option<Refusal> {
    let trimmed = source.trim();
    if trimmed.chars().count() < 256 {
        return None;
    }
    let mut hits = 0usize;
    let mut dot_slash = 0usize;
    let mut whitespace = 0usize;
    let mut units = 0usize;
    for c in trimmed.chars() {
        units += c.len_utf16();
        if matches!(c, '[' | ']' | '(' | ')' | '!' | '+' | '.' | '/') {
            hits += 1;
            if c == '.' || c == '/' {
                dot_slash += 1;
            }
        } else if matches!(c, ' ' | '\n' | '\r' | '\t') {
            whitespace += c.len_utf16();
        }
    }
    let counted = units.saturating_sub(whitespace);
    if counted == 0 {
        return None;
    }
    let purity = hits as f64 / counted as f64;
    let ds_density = dot_slash as f64 / counted as f64;
    if purity >= 0.9 && ds_density > 0.005 && hits >= 256 {
        return Some(Refusal {
            tool: "jsfiretruck",
            detail: "[]()!+./ shell (execution required to decode)".to_string(),
            banner_hits: None,
            density: None,
            purity: Some(purity),
            markers: None,
        });
    }
    None
}

// ---------------------------------------------------- obfuscator.io markers

struct ObfuscatorMarker {
    name: &'static str,
    pattern: &'static str,
    case_insensitive: bool,
}

const OBFUSCATOR_MARKER_TABLE: &[ObfuscatorMarker] = &[
    ObfuscatorMarker { name: "banner", pattern: r"obfuscator\.io|javascript-obfuscator", case_insensitive: false },
    ObfuscatorMarker { name: "hex identifiers", pattern: r"\b_0x[0-9a-fA-F]{3,}\b", case_insensitive: false },
    ObfuscatorMarker { name: "string array rotation", pattern: r#"\[\s*['"][^'"]+['"]\s*\]\s*\.\s*concat|\.shift\s*\(\s*\)|\.push\s*\(\s*[\w$]+\s*\[\s*0\s*\]"#, case_insensitive: false },
    ObfuscatorMarker { name: "rotation IIFE", pattern: r"\(\s*function\s*\([^)]*\)\s*\{[\s\S]*?parseInt", case_insensitive: false },
    ObfuscatorMarker { name: "base64 decoder", pattern: r"atob\s*\(|ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz", case_insensitive: false },
    ObfuscatorMarker { name: "rc4 decoder", pattern: r"\b_0x[0-9a-fA-F]+\s*\(\s*_0x[0-9a-fA-F]+\s*,\s*_0x[0-9a-fA-F]+", case_insensitive: false },
    ObfuscatorMarker { name: "switch dispatcher", pattern: r"switch\s*\(\s*_?0x[\w$]*\s*\)|switch\s*\(\s*[\w$]+\s*\+\s*parseInt", case_insensitive: false },
    ObfuscatorMarker { name: "boolean shorthand", pattern: r"!!\[\]|\[\s*\]", case_insensitive: false },
    ObfuscatorMarker { name: "hex literals", pattern: r"=\s*0x[0-9a-fA-F]{2,}\b", case_insensitive: false },
    ObfuscatorMarker { name: "self defending", pattern: r"self.?defending", case_insensitive: true },
    ObfuscatorMarker { name: "debug protection", pattern: r"debug.?protect", case_insensitive: true },
    ObfuscatorMarker { name: "console disable", pattern: r"console\s*\[|call\s*\(\s*this\s*,\s*console\)", case_insensitive: false },
    ObfuscatorMarker { name: "opaque predicate", pattern: r#"\?\s*['"][^'"]*['"]\s*:\s*['"][^'"]*['"]"#, case_insensitive: false },
    ObfuscatorMarker { name: "split string concat", pattern: r#"['"][^'"]{0,3}['"\s]\s*\+\s*concat"#, case_insensitive: false },
    ObfuscatorMarker { name: "renamed properties", pattern: r"\.\s*_0x[0-9a-fA-F]{3,}\b", case_insensitive: false },
];

pub fn detect_obfuscator_io(text: &str) -> Option<Refusal> {
    let window: &str = crate::util::utf16_prefix(text, 256 * 1024);
    let mut markers = Vec::new();
    for m in OBFUSCATOR_MARKER_TABLE {
        let pattern = if m.case_insensitive {
            format!("(?i){}", m.pattern)
        } else {
            m.pattern.to_string()
        };
        let re = match regex::Regex::new(&pattern) {
            Ok(re) => re,
            Err(_) => continue,
        };
        let count = re.find_iter(window).take(200).count();
        if count > 0 {
            markers.push(MarkerHit {
                marker: m.name.to_string(),
                count,
            });
        }
    }
    if markers.is_empty() {
        return None;
    }
    let score = markers.len();
    let has_strong = markers
        .iter()
        .any(|m| m.marker == "banner" || m.marker == "string array rotation" || m.marker == "rc4 decoder");
    if !has_strong && score < 3 {
        return None;
    }
    let detail = markers
        .iter()
        .map(|m| m.marker.clone())
        .collect::<Vec<_>>()
        .join(", ");
    Some(Refusal {
        tool: "obfuscator-io",
        detail,
        banner_hits: None,
        density: None,
        purity: None,
        markers: Some(markers),
    })
}

// --------------------------------------------------- string array + rotator

fn parse_array_literals(body: &str) -> Option<Vec<String>> {
    let chars: Vec<char> = body.chars().collect();
    let mut out = Vec::new();
    let mut i = 0usize;
    while i < chars.len() {
        let c = chars[i];
        if c == '\'' || c == '"' {
            let quote = c;
            let mut buf = String::new();
            i += 1;
            while i < chars.len() && chars[i] != quote {
                if chars[i] == '\\' {
                    i += 1;
                    let n = *chars.get(i)?;
                    match n {
                        'n' => buf.push('\n'),
                        't' => buf.push('\t'),
                        'r' => buf.push('\r'),
                        '\\' => buf.push('\\'),
                        '\'' => buf.push('\''),
                        '"' => buf.push('"'),
                        '0' => buf.push('\0'),
                        'x' => {
                            let hex: String = chars[i + 1..(i + 3).min(chars.len())].iter().collect();
                            if hex.chars().count() != 2 || !hex.chars().all(|h| h.is_ascii_hexdigit()) {
                                return None;
                            }
                            let code = u32::from_str_radix(&hex, 16).ok()?;
                            buf.push(char::from_u32(code & 0xFFFF).unwrap_or('\u{FFFD}'));
                            i += 2;
                        }
                        other => buf.push(other),
                    }
                    i += 1;
                } else {
                    buf.push(chars[i]);
                    i += 1;
                }
            }
            i += 1; // consume the closing quote
            if i > chars.len() {
                return None; // unterminated literal
            }
            out.push(buf);
        } else if c == ',' || is_js_space(c) {
            i += 1;
        } else {
            return None; // expressions in the array -> refuse (stay static)
        }
    }
    if out.is_empty() {
        None
    } else {
        Some(out)
    }
}

pub struct StringArrayFound {
    pub array_id: String,
    pub literals: Vec<String>,
    pub decl_range: (usize, usize),
}

static STRING_ARRAY_RE: LazyLock<regex::Regex> = LazyLock::new(|| {
    regex::Regex::new(&format!(
        r"(?m)^(?:var|let|const)[{JS_S}]+(_?0x[0-9a-fA-F]+|[a-zA-Z_][{JS_W}]*)[{JS_S}]*=[{JS_S}]*\[([^\]]*)\][{JS_S}]*;"
    ))
    .unwrap()
});

pub fn find_string_array(source: &str) -> Option<StringArrayFound> {
    let m = STRING_ARRAY_RE.captures(source)?;
    let literals = parse_array_literals(m.get(2).unwrap().as_str())?;
    Some(StringArrayFound {
        array_id: m.get(1).unwrap().as_str().to_string(),
        literals,
        decl_range: (m.get(0).unwrap().start(), m.get(0).unwrap().end()),
    })
}

/// JS parseIntLiteral: hex accepts a valid prefix (quirk preserved — no
/// round-trip check on hex), decimal must round-trip exactly.
pub fn parse_int_literal(raw: &str) -> Option<i64> {
    let t = raw.trim();
    let negative = t.starts_with('-');
    let t = if negative || t.starts_with('+') {
        &t[1..]
    } else {
        t
    };
    if t.to_lowercase().starts_with("0x") {
        let hex = &t[2..];
        let valid: String = hex
            .chars()
            .take_while(|c| c.is_ascii_hexdigit())
            .collect();
        if valid.is_empty() {
            return None;
        }
        let v = i64::from_str_radix(&valid, 16).ok()?;
        return Some(if negative { -v } else { v });
    }
    let valid: String = t.chars().take_while(|c| c.is_ascii_digit()).collect();
    if valid != t {
        return None;
    }
    let d: i64 = t.parse().ok()?;
    Some(if negative { -d } else { d })
}

pub struct RotatorFound {
    pub pivot_index: i64,
    pub pivot_value: i64,
    pub iife_range: (usize, usize),
}

static PIVOT_RE: LazyLock<regex::Regex> = LazyLock::new(|| {
    regex::Regex::new(r"parseInt\([^)]*\(\s*(0x[0-9a-fA-F]+|\d+)\)").unwrap()
});

pub fn find_rotator(source: &str, array_id: &str) -> Option<RotatorFound> {
    let needle = regex_escape(array_id);
    let pattern = format!(
        r"(?ms)\(\s*function\s*\(([^)]*)\)\s*\{{(.+?)\}}\s*\(\s*{needle}\s*,\s*([-+]?0x[0-9a-fA-F]+|\d+)\s*\)\s*\)\s*;"
    );
    let re = regex::Regex::new(&pattern).ok()?;
    let m = re.captures(source)?;
    let body = m.get(2).unwrap().as_str();
    if !looks_like_rotator(body) {
        return None;
    }
    let pivot_value = parse_int_literal(m.get(3).unwrap().as_str())?;
    let pivot_index = find_pivot_index(body);
    let whole = m.get(0).unwrap();
    Some(RotatorFound {
        pivot_index,
        pivot_value,
        iife_range: (whole.start(), whole.end()),
    })
}

fn looks_like_rotator(body: &str) -> bool {
    let has_loop = body.contains("while") && (body.contains("!![]") || body.contains("true"));
    let has_push_shift = body.contains("push") && body.contains("shift");
    let has_parse_int = body.contains("parseInt");
    has_loop && has_push_shift && has_parse_int
}

fn find_pivot_index(body: &str) -> i64 {
    let v = PIVOT_RE
        .captures(body)
        .and_then(|m| parse_int_literal(m.get(1).unwrap().as_str()));
    match v {
        Some(v) if v >= 0 => v,
        _ => 0,
    }
}

/// The runtime loop push/shifts until parseInt(strings[0]) equals the pivot;
/// find the rotation that satisfies it instead of executing anything.
pub fn simulate_rotation(strings: &[String], pivot_value: i64) -> (Vec<String>, usize) {
    if strings.is_empty() {
        return (strings.to_vec(), 0);
    }
    for k in 0..=MAX_ROTATIONS {
        let index = k % strings.len();
        let n = parse_int_literal(&strings[index]);
        if n == Some(pivot_value) {
            let mut rotated: Vec<String> = strings[index..].to_vec();
            rotated.extend_from_slice(&strings[..index]);
            return (rotated, index);
        }
    }
    (strings.to_vec(), 0)
}

fn js_quote_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '\'' => out.push_str("\\'"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            other => out.push(other),
        }
    }
    out
}

fn emit_array_decl(id: &str, literals: &[String]) -> String {
    let joined: Vec<String> = literals
        .iter()
        .map(|lit| format!("'{}'", js_quote_escape(lit)))
        .collect();
    format!("var {id} = [{}];", joined.join(", "))
}

/// Replaces the array declaration with its rotated form and deletes the
/// rotator IIFE. Order-independent.
pub fn rebuild_string_array_source(
    source: &str,
    found: &StringArrayFound,
    rotator: &RotatorFound,
    rotated: &[String],
) -> String {
    let decl_start = found.decl_range.0;
    let iife_start = rotator.iife_range.0;
    let first_is_decl = decl_start < iife_start;
    let (first_start, first_end) = if first_is_decl {
        found.decl_range
    } else {
        rotator.iife_range
    };
    let (second_start, second_end) = if first_is_decl {
        rotator.iife_range
    } else {
        found.decl_range
    };
    let mut out = String::with_capacity(source.len());
    out.push_str(&source[..first_start]);
    if first_is_decl {
        out.push_str(&emit_array_decl(&found.array_id, rotated));
    }
    out.push_str(&source[first_end..second_start]);
    if !first_is_decl {
        out.push_str(&emit_array_decl(&found.array_id, rotated));
    }
    out.push_str(&source[second_end..]);
    out
}

// ------------------------------------------------- static decoder inlining

pub struct InlineResult {
    pub source: String,
    pub decoder_name: Option<String>,
    pub inlined: usize,
    pub total: usize,
    pub refusal: Option<String>,
}

struct DecoderIndex {
    offset: i64,
    sign: char,
}

pub fn inline_decoder_calls(source: &str, array_id: &str) -> InlineResult {
    let found = match find_decoder_decl(source, array_id) {
        Some(f) => f,
        None => {
            return InlineResult {
                source: source.to_string(),
                decoder_name: None,
                inlined: 0,
                total: 0,
                refusal: Some("decoder declaration not found".to_string()),
            }
        }
    };
    let index = match analyze_decoder_body(&found.body, &found.params, array_id) {
        Some(i) => i,
        None => {
            return InlineResult {
                source: source.to_string(),
                decoder_name: Some(found.name),
                inlined: 0,
                total: 0,
                refusal: Some("decoder is not a plain array index (execution required)".to_string()),
            }
        }
    };
    let sites = find_decoder_call_sites(source, &found.name, found.range);
    let literals = match current_array_literals(source, array_id) {
        Some(l) => l,
        None => {
            return InlineResult {
                source: source.to_string(),
                decoder_name: Some(found.name),
                inlined: 0,
                total: sites.sites.len(),
                refusal: Some("array literals unreadable".to_string()),
            }
        }
    };
    let mut events: Vec<(usize, usize, Option<i64>)> = sites
        .sites
        .iter()
        .map(|s| (s.range.0, s.range.1, Some(s.arg)))
        .collect();
    if !sites.has_unresolved
        && !sites.sites.is_empty()
        && sites
            .sites
            .iter()
            .all(|s| decode_index(s.arg, &index, &literals).is_some())
    {
        events.push((found.range.0, found.range.1, None)); // decoder decl removal
    }
    events.sort_by_key(|e| e.0);
    let mut out = String::with_capacity(source.len());
    let mut cursor = 0usize;
    let mut inlined = 0usize;
    for (start, end, arg) in events {
        if start < cursor {
            continue;
        }
        out.push_str(&source[cursor..start]);
        match arg {
            None => {} // decoder declaration removed
            Some(arg) => {
                if let Some(decoded) = decode_index(arg, &index, &literals) {
                    out.push('\'');
                    out.push_str(&js_quote_escape(&decoded));
                    out.push('\'');
                    inlined += 1;
                } else {
                    out.push_str(&source[start..end]);
                }
            }
        }
        cursor = end;
    }
    out.push_str(&source[cursor..]);
    InlineResult {
        source: out,
        decoder_name: Some(found.name),
        inlined,
        total: sites.sites.len(),
        refusal: None,
    }
}

fn decode_index(call_arg: i64, index: &DecoderIndex, literals: &[String]) -> Option<String> {
    let effective = call_arg + if index.sign == '-' {
        -index.offset
    } else {
        index.offset
    };
    if effective < 0 || effective as usize >= literals.len() {
        return None;
    }
    Some(literals[effective as usize].clone())
}

struct DecoderDecl {
    name: String,
    params: Vec<String>,
    body: String,
    range: (usize, usize),
}

fn find_decoder_decl(source: &str, array_id: &str) -> Option<DecoderDecl> {
    let needle = regex_escape(array_id);
    let patterns = [
        format!(
            r"(?ms)(?:var|let|const)[{JS_S}]+([\w$]+)[{JS_S}]*=[{JS_S}]*function[{JS_S}]*\(([^)]*)\)[{JS_S}]*\{{[{JS_S}]*(?:var[{JS_S}]+[\w$]+[{JS_S}]*=[{JS_S}]*{needle}[{JS_S}]*;[{JS_S}]*)?([^}}]*{needle}[{JS_S}]*\[[^\]]+\][^}}]*)\}}[{JS_S}]*;"
        ),
        format!(
            r"(?ms)function[{JS_S}]+([\w$]+)[{JS_S}]*\(([^)]*)\)[{JS_S}]*\{{[{JS_S}]*(?:var[{JS_S}]+[\w$]+[{JS_S}]*=[{JS_S}]*{needle}[{JS_S}]*;[{JS_S}]*)?([^}}]*{needle}[{JS_S}]*\[[^\]]+\][^}}]*)\}}"
        ),
    ];
    for pattern in patterns {
        let re = regex::Regex::new(&pattern).ok()?;
        if let Some(m) = re.captures(source) {
            let whole = m.get(0).unwrap();
            return Some(DecoderDecl {
                name: m.get(1).unwrap().as_str().to_string(),
                params: m
                    .get(2)
                    .unwrap()
                    .as_str()
                    .split(',')
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty())
                    .collect(),
                body: m.get(3).unwrap().as_str().to_string(),
                range: (whole.start(), whole.end()),
            });
        }
    }
    None
}

fn analyze_decoder_body(body: &str, params: &[String], array_id: &str) -> Option<DecoderIndex> {
    let p0 = params.first()?;
    if body.matches('[').count() != 1 {
        return None;
    }
    static INDEX_RE: LazyLock<regex::Regex> = LazyLock::new(|| {
        regex::Regex::new(r"([\w$]+)\s*\[\s*([\w$]+)\s*(?:([+-])\s*(0x[0-9a-fA-F]+|\d+))?\s*\]")
            .unwrap()
    });
    let m = INDEX_RE.captures(body)?;
    // The base may be the array itself or a local alias bound to it.
    let alias_re = regex::Regex::new(&format!(
        r"var\s+([\w$]+)\s*=\s*{}\s*;",
        regex_escape(array_id)
    ))
    .ok()?;
    let alias = alias_re.captures(body).map(|a| a.get(1).unwrap().as_str().to_string());
    let base = m.get(1).unwrap().as_str();
    let base_ok = base == array_id || alias.as_deref() == Some(base);
    if !base_ok {
        return None;
    }
    if m.get(2).unwrap().as_str() != p0 {
        return None;
    }
    let offset = match m.get(4) {
        Some(raw) => parse_int_literal(raw.as_str())?,
        None => 0,
    };
    if offset < 0 {
        return None;
    }
    static PREFIX_RE: LazyLock<regex::Regex> = LazyLock::new(|| {
        regex::Regex::new(r"^\s*(?:var\s+[\w$]+\s*=\s*[\w$]+\s*;\s*)?return\s+(?:[\w$]+\s*=\s*)?$")
            .unwrap()
    });
    static SUFFIX_BAD_RE: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"[\w$\s=]\s*;").unwrap());
    static SUFFIX_TAIL_RE: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"\s*\]\s*;?\s*$").unwrap());
    static SUFFIX_ONLY_RE: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"^\s*\]\s*;?\s*$").unwrap());
    let match_start = m.get(0).unwrap().start();
    let match_end = m.get(0).unwrap().end();
    if !PREFIX_RE.is_match(&body[..match_start]) {
        return None;
    }
    let tail = SUFFIX_TAIL_RE.replace(&body[match_end..], "");
    if SUFFIX_BAD_RE.is_match(&tail) && !SUFFIX_ONLY_RE.is_match(&body[match_end..]) {
        return None;
    }
    Some(DecoderIndex {
        offset,
        sign: m.get(3).map(|s| s.as_str().chars().next().unwrap()).unwrap_or('+'),
    })
}

struct CallSite {
    range: (usize, usize),
    arg: i64,
}

struct CallSites {
    sites: Vec<CallSite>,
    has_unresolved: bool,
}

fn find_decoder_call_sites(source: &str, decoder_name: &str, decoder_range: (usize, usize)) -> CallSites {
    let re = regex::Regex::new(&regex_escape(decoder_name)).expect("escaped name compiles");
    let mut sites = Vec::new();
    let mut has_unresolved = false;
    for m in re.find_iter(source) {
        let start = m.start();
        let end = m.end();
        if start >= decoder_range.0 && start < decoder_range.1 {
            continue;
        }
        if start > 0
            && source[..start]
                .chars()
                .next_back()
                .map(|c| c.is_ascii_alphanumeric() || c == '_' || c == '$')
                .unwrap_or(false)
        {
            continue;
        }
        if end < source.len()
            && source[end..]
                .chars()
                .next()
                .map(|c| c.is_ascii_alphanumeric() || c == '_' || c == '$')
                .unwrap_or(false)
        {
            continue;
        }
        let before = source[..start].trim_end();
        if before.ends_with('.') {
            has_unresolved = true;
            continue;
        }
        let mut open = end;
        while open < source.len() && source[open..].starts_with(|c: char| is_js_space(c)) {
            open += 1;
        }
        if !source[open..].starts_with('(') {
            has_unresolved = true;
            continue;
        }
        let mut close = open + 1;
        let mut depth = 1i64;
        while close < source.len() && depth > 0 {
            if source[close..].starts_with('(') {
                depth += 1;
            } else if source[close..].starts_with(')') {
                depth -= 1;
            }
            if depth == 0 {
                break;
            }
            close += 1;
        }
        if close >= source.len() {
            has_unresolved = true;
            continue;
        }
        let arg_text = source[open + 1..close].trim();
        let arg = match parse_int_literal(arg_text) {
            Some(a) => a,
            None => {
                has_unresolved = true;
                continue;
            }
        };
        sites.push(CallSite {
            range: (start, close + 1),
            arg,
        });
    }
    CallSites {
        sites,
        has_unresolved,
    }
}

fn current_array_literals(source: &str, array_id: &str) -> Option<Vec<String>> {
    let found = find_string_array(source)?;
    if found.array_id == array_id {
        Some(found.literals)
    } else {
        None
    }
}

/// Full static string-array stage: rotate + rebuild, then attempt inlining.
pub fn transform_string_array(source: &str) -> Option<String> {
    let found = find_string_array(source)?;
    let rotator = find_rotator(source, &found.array_id)?;
    let (rotated, _rotations) = simulate_rotation(&found.literals, rotator.pivot_value);
    let rebuilt = rebuild_string_array_source(source, &found, &rotator, &rotated);
    let inline = inline_decoder_calls(&rebuilt, &found.array_id);
    if inline.source == source {
        return None;
    }
    Some(inline.source)
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StringArrayDetected {
    pub array_id: String,
    pub literals: usize,
    pub pivot: i64,
}

pub fn detect_string_array(source: &str) -> Option<StringArrayDetected> {
    let found = find_string_array(source)?;
    let rotator = find_rotator(source, &found.array_id)?;
    Some(StringArrayDetected {
        array_id: found.array_id,
        literals: found.literals.len(),
        pivot: rotator.pivot_value,
    })
}
