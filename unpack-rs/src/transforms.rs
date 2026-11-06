// The detect -> route -> transform -> re-detect engine: eval payload
// collection, the unwrap transforms, the runtime-shell refusals, and the
// peel loop that walks one layer per iteration.

use crate::decoders::{
    bytes_to_text, decode_base64_to_bytes, inflate_bytes, printable_ratio, InflateFormat,
};
use crate::detectors::{eval_heads, function_heads, longest_base64_literal, rot13};
use crate::digest::sha256_hex;
use crate::jsfuck::decode_jsfuck;
use crate::packers::{
    detect_aaencode, detect_jjencode, detect_jsfiretruck, detect_obfuscator_io,
    detect_string_array, transform_string_array, unpack_packer, Refusal,
};
use crate::scanner::{collect_string_literals, find_balanced};
use crate::util::{utf16_len, JS_S};
use std::collections::HashSet;
use std::sync::LazyLock;

const DEFAULT_MAX_DEPTH: usize = 8;
pub const SOURCE_URL_COMMENT: &str = r"//[#@]\s*sourceURL\s*=\s*(\S+)";

static SOURCE_URL_RE: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new(SOURCE_URL_COMMENT).unwrap());

#[derive(Debug, Clone, serde::Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct TextStage {
    pub depth: usize,
    pub tool: String,
    pub input_bytes: usize,
    pub output_bytes: usize,
    pub digest: String,
    pub source_url: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, PartialEq)]
pub struct BinaryStage {
    pub depth: usize,
    pub tool: String,
    pub detail: String,
}

#[derive(Debug, Clone, serde::Serialize, PartialEq)]
#[serde(untagged)]
pub enum Stage {
    Text(TextStage),
    Binary(BinaryStage),
}

#[derive(Debug, Clone, PartialEq)]
pub struct EvalPayload {
    pub head: usize,
    pub code: String,
    pub end: usize,
}

#[derive(Debug, Clone, serde::Serialize, PartialEq)]
pub struct PeelResult {
    pub stages: Vec<Stage>,
    pub outputs: Vec<String>,
    #[serde(rename = "final")]
    pub final_text: String,
    pub refusals: Vec<Refusal>,
}

// True when everything left after removing the string literals is punctuation
// and whitespace, i.e. the argument is a concatenation of literals rather
// than an expression.
fn is_literal_only_arg(arg: &str) -> bool {
    static LITERAL_RE: LazyLock<regex::Regex> = LazyLock::new(|| {
        regex::Regex::new(r#""(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`"#).unwrap()
    });
    static SPACES_RE: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(&format!(r"[{JS_S}]+")).unwrap());
    static PUNCT_RE: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"[+(),]").unwrap());
    let stripped = LITERAL_RE.replace_all(arg, "");
    let stripped = SPACES_RE.replace_all(&stripped, "");
    PUNCT_RE.replace_all(&stripped, "").is_empty()
}

pub fn collect_eval_payloads(text: &str) -> Vec<EvalPayload> {
    let mut payloads: Vec<EvalPayload> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    let push = |payloads: &mut Vec<EvalPayload>,
                seen: &mut HashSet<String>,
                head: usize,
                code: String,
                end: usize| {
        if seen.contains(&code) {
            return;
        }
        seen.insert(code.clone());
        payloads.push(EvalPayload { head, code, end });
    };
    for head in eval_heads(text) {
        let Some(paren_rel) = text[head..].find('(') else {
            continue;
        };
        let paren_idx = head + paren_rel;
        let Some(close) = find_balanced(text, paren_idx) else {
            continue;
        };
        let arg = &text[paren_idx + 1..close - 1];
        let parts = collect_string_literals(arg, 0);
        // A packer usually passes one literal, or literals joined by '+' / commas.
        if !parts.is_empty() && is_literal_only_arg(arg) {
            let joined: String = parts.iter().map(|p| p.value.as_str()).collect();
            if utf16_len(&joined) >= crate::LIMITS.min_payload_length {
                push(&mut payloads, &mut seen, head, joined, close);
            }
            continue;
        }
        // eval(expression) keeps the expression as the payload so the next
        // pass can peel it (atob, decodeURIComponent, a function call, ...).
        if utf16_len(arg) >= crate::LIMITS.min_payload_length {
            push(&mut payloads, &mut seen, head, arg.to_string(), close);
        }
    }
    // Function(...) payloads: the body is the last string argument.
    for (match_start, match_end) in function_heads(text) {
        let fp_rel = text[match_end - 1..].find('(').map(|r| match_end - 1 + r);
        let Some(fp) = fp_rel else {
            continue;
        };
        let Some(fclose) = find_balanced(text, fp) else {
            continue;
        };
        let args = collect_string_literals(&text[fp + 1..fclose - 1], 0);
        if args.is_empty() {
            continue;
        }
        let body = args[args.len() - 1].value.clone();
        if utf16_len(&body) >= crate::LIMITS.min_payload_length {
            push(&mut payloads, &mut seen, match_start, body, fclose);
        }
    }
    payloads.sort_by_key(|p| p.head);
    payloads
}

fn unwrap_eval(text: &str) -> Option<String> {
    let payloads = collect_eval_payloads(text);
    if payloads.is_empty() {
        return None;
    }
    Some(
        payloads
            .iter()
            .map(|p| p.code.as_str())
            .collect::<Vec<_>>()
            .join("\n;\n"),
    )
}

enum Base64Unwrap {
    NeedsInflate(InflateFormat, Vec<u8>),
    Text(String),
}

fn unwrap_base64(text: &str) -> Option<Base64Unwrap> {
    let literal = longest_base64_literal(text)?;
    let bytes = decode_base64_to_bytes(&literal)?;
    if bytes.is_empty() {
        return None;
    }
    if let Some(format) = crate::decoders::gzip_format(&bytes) {
        return Some(Base64Unwrap::NeedsInflate(format, bytes));
    }
    let decoded = bytes_to_text(&bytes);
    if printable_ratio(&decoded) < 0.85 {
        return None;
    }
    Some(Base64Unwrap::Text(decoded))
}

fn unwrap_hex_escapes(text: &str) -> Option<String> {
    static X_RE: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"\\x([0-9a-fA-F]{2})").unwrap());
    static U_RE: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"\\u([0-9a-fA-F]{4})").unwrap());
    if !X_RE.is_match(text) {
        return None;
    }
    let stage = X_RE.replace_all(text, |caps: &regex::Captures| {
        let code = u16::from_str_radix(caps.get(1).unwrap().as_str(), 16).unwrap_or(0);
        char::from_u32(code as u32)
            .unwrap_or('\u{FFFD}')
            .to_string()
    });
    Some(
        U_RE.replace_all(&stage, |caps: &regex::Captures| {
            let code = u16::from_str_radix(caps.get(1).unwrap().as_str(), 16).unwrap_or(0);
            char::from_u32(code as u32)
                .unwrap_or('\u{FFFD}')
                .to_string()
        })
        .into_owned(),
    )
}

/// JS decodeURIComponent: strict %XX decoding, '+' is NOT a space, invalid
/// sequences throw (None here).
pub fn decode_uri_component(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0usize;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            if i + 2 >= bytes.len() {
                return None;
            }
            let hi = (bytes[i + 1] as char).to_digit(16)?;
            let lo = (bytes[i + 2] as char).to_digit(16)?;
            out.push((hi * 16 + lo) as u8);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

fn unwrap_unescape(text: &str) -> Option<String> {
    // %uXXXX -> %XX%XX (the encodeURIComponent form), then strict decode.
    static U_PERCENT_RE: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"%u([0-9a-fA-F]{4})").unwrap());
    let windows = U_PERCENT_RE.replace_all(text, |caps: &regex::Captures| {
        let code = u16::from_str_radix(caps.get(1).unwrap().as_str(), 16).unwrap_or(0);
        let ch = char::from_u32(code as u32).unwrap_or('\u{FFFD}');
        let mut encoded = percent_encode_utf8(&ch.to_string());
        encoded.remove(0);
        encoded
    });
    decode_uri_component(&windows)
}

fn percent_encode_utf8(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 3);
    for b in s.as_bytes() {
        out.push('%');
        out.push_str(&format!("{:02X}", b));
    }
    out
}

fn unwrap_charcode(text: &str) -> Option<String> {
    static CHARCODE_RE: LazyLock<regex::Regex> = LazyLock::new(|| {
        regex::Regex::new(r"String\s*\.\s*fromCharCode\s*\(([\d\s,]{7,})\)").unwrap()
    });
    let mut changed = false;
    let out = CHARCODE_RE.replace_all(text, |caps: &regex::Captures| -> String {
        let numbers = caps.get(1).unwrap().as_str();
        let codes: Vec<f64> = numbers
            .split(',')
            .map(|part| js_parse_int(part.trim()))
            .filter(|n| n.is_finite())
            .collect();
        if codes.len() < 7 {
            return String::new();
        }
        changed = true;
        let joined: String = codes
            .iter()
            .map(|&c| char::from_u32(to_uint16(c) as u32).unwrap_or('\u{FFFD}'))
            .collect();
        serde_json::to_string(&joined).unwrap_or_default()
    });
    if !changed {
        return None;
    }
    Some(out.into_owned())
}

/// JS parseInt(s, 10): leading whitespace, optional sign, digit prefix.
/// No digits -> NaN.
fn js_parse_int(s: &str) -> f64 {
    let t = s.trim_start();
    let signed = t
        .strip_prefix('-')
        .or_else(|| t.strip_prefix('+'))
        .unwrap_or(t);
    let digits: String = signed.chars().take_while(|c| c.is_ascii_digit()).collect();
    if digits.is_empty() {
        return f64::NAN;
    }
    digits.parse::<f64>().unwrap_or(f64::NAN)
}

/// JS ToUint16: truncate, wrap mod 65536; NaN/Inf -> 0.
fn to_uint16(value: f64) -> u16 {
    if !value.is_finite() {
        return 0;
    }
    let m = value.trunc() % 65536.0;
    let m = if m < 0.0 { m + 65536.0 } else { m };
    m as u16
}

fn unwrap_reverse(text: &str) -> String {
    text.chars().rev().collect()
}

/// JS applyTransform: routes a tool to its transform; None = the layer did
/// not yield fresh text.
fn apply_transform(tool: crate::detectors::Tool, text: &str) -> Option<String> {
    match tool {
        crate::detectors::Tool::EvalUnwrap => unwrap_eval(text),
        crate::detectors::Tool::Base64 => {
            let result = unwrap_base64(text)?;
            match result {
                Base64Unwrap::NeedsInflate(format, bytes) => {
                    let inflated = inflate_bytes(&bytes, format)?;
                    Some(bytes_to_text(&inflated))
                }
                Base64Unwrap::Text(decoded) => {
                    let as_bytes = decode_base64_to_bytes(text.trim());
                    if let Some(as_bytes) = as_bytes {
                        if let Some(nested) = crate::decoders::gzip_format(&as_bytes) {
                            if let Some(inner) = inflate_bytes(&as_bytes, nested) {
                                return Some(bytes_to_text(&inner));
                            }
                        }
                    }
                    Some(decoded)
                }
            }
        }
        crate::detectors::Tool::HexEscape => unwrap_hex_escapes(text),
        crate::detectors::Tool::Unescape => unwrap_unescape(text),
        crate::detectors::Tool::CharCode => unwrap_charcode(text),
        crate::detectors::Tool::Reverse => Some(unwrap_reverse(text)),
        crate::detectors::Tool::Rot13 => Some(rot13(text)),
        crate::detectors::Tool::Packer => unpack_packer(text),
        crate::detectors::Tool::StringArray => transform_string_array(text),
        crate::detectors::Tool::JsFuck => {
            let decoded = decode_jsfuck(text);
            decoded.value
        }
    }
}

// Shell encodings whose payload only exists at RUNTIME: detected and
// reported, never transformed. The string-array pass covers the static slice
// of obfuscator.io output, so it is reported only when it did NOT match.
fn collect_refusals(text: &str) -> Vec<Refusal> {
    let mut refusals = Vec::new();
    if let Some(aa) = detect_aaencode(text) {
        refusals.push(aa);
    }
    if let Some(jj) = detect_jjencode(text) {
        refusals.push(jj);
    }
    if let Some(ft) = detect_jsfiretruck(text) {
        refusals.push(ft);
    }
    if let Some(ob) = detect_obfuscator_io(text) {
        if detect_string_array(text).is_none() {
            refusals.push(Refusal {
                tool: "obfuscator-io",
                detail: format!(
                    "{} (runtime shell; static string-array pass did not match)",
                    ob.detail
                ),
                banner_hits: None,
                density: None,
                purity: None,
                markers: None,
            });
        }
    }
    refusals
}

/// The detect -> route -> transform -> re-detect loop, one layer per
/// iteration. `outputs[i]` is the text produced by stage i; `stages[i]` is
/// its metadata, so a caller can write real layer artifacts without
/// inflating the JSON report.
pub fn peel_text(text: &str, max_depth: Option<usize>) -> PeelResult {
    let max_depth = crate::util::limit_or(max_depth, DEFAULT_MAX_DEPTH);
    let mut stages: Vec<Stage> = Vec::new();
    let mut outputs: Vec<String> = Vec::new();
    let refusals = collect_refusals(text);
    let mut current = text.to_string();
    let mut seen: HashSet<String> = HashSet::new();
    seen.insert(sha256_hex(&current));
    for depth in 0..max_depth {
        let findings = crate::detectors::detect_layers(&current);
        if findings.is_empty() {
            break;
        }
        let mut produced: Option<String> = None;
        let mut used_tool: Option<String> = None;
        for finding in &findings {
            if let Some(candidate) = apply_transform(finding.tool, &current) {
                if !candidate.is_empty() && candidate != current {
                    let digest = sha256_hex(&candidate);
                    if !seen.contains(&digest) {
                        produced = Some(candidate);
                        used_tool = Some(finding.tool.to_string());
                        seen.insert(digest);
                        break;
                    }
                }
            }
        }
        let Some(produced) = produced else {
            break;
        };
        let digest = sha256_hex(&produced);
        let source_url = SOURCE_URL_RE
            .captures(&produced)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().to_string());
        stages.push(Stage::Text(TextStage {
            depth: depth + 1,
            tool: used_tool.unwrap_or_default(),
            input_bytes: utf16_len(&current),
            output_bytes: utf16_len(&produced),
            digest,
            source_url,
        }));
        outputs.push(produced.clone());
        current = produced;
    }
    PeelResult {
        stages,
        outputs,
        final_text: current,
        refusals,
    }
}
