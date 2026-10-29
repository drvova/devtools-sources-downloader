// Scores the obfuscation layers actually present: eval/Function payload
// collection, base64 literals, escape encodings, reversed and rot13 sources,
// plus the self-contained detectors from the packers and jsfuck modules.
// Highest score wins the stage.

use crate::jsfuck::detect_jsfuck;
use crate::packers::{detect_packer, detect_string_array};
use crate::util::utf16_len;
use std::sync::LazyLock;

const KEYWORD_GAIN: &str =
    r"(?:function|return|var |let |const |window\.|document\.|prototype|undefined|null|true|false)";
const BASE64_LITERAL: &str = r#"(?:atob\s*\(\s*)?["']([A-Za-z0-9+/=_-]{40,})["']"#;
const HEX_ESCAPE: &str = r"\\x[0-9a-fA-F]{2}";
const UNICODE_PERCENT: &str = r"%u[0-9a-fA-F]{4}";
const CHARCODE_CALL: &str = r"String\s*\.\s*fromCharCode\s*\(([\d\s,]{7,})\)";
const EVAL_HEAD: &str = r"(?:^|[^\w$.])eval\s*\(";
const FUNCTION_HEAD: &str = r"(?:^|[^\w$.])(?:new\s+)?Function\s*\(";

static GAIN_RE: LazyLock<regex::Regex> = LazyLock::new(|| regex::Regex::new(KEYWORD_GAIN).unwrap());
static BASE64_RE: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new(BASE64_LITERAL).unwrap());
static HEX_ESCAPE_RE: LazyLock<regex::Regex> = LazyLock::new(|| regex::Regex::new(HEX_ESCAPE).unwrap());
static UNICODE_PERCENT_RE: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new(UNICODE_PERCENT).unwrap());
static CHARCODE_RE: LazyLock<regex::Regex> = LazyLock::new(|| regex::Regex::new(CHARCODE_CALL).unwrap());
static EVAL_HEAD_RE: LazyLock<regex::Regex> = LazyLock::new(|| regex::Regex::new(EVAL_HEAD).unwrap());
static FUNCTION_HEAD_RE: LazyLock<regex::Regex> = LazyLock::new(|| regex::Regex::new(FUNCTION_HEAD).unwrap());

#[derive(Debug, Clone, serde::Serialize, PartialEq)]
pub struct Finding {
    pub tool: &'static str,
    pub score: f64,
    pub detail: String,
}

pub fn gain(text: &str) -> usize {
    GAIN_RE.find_iter(text).count()
}

pub fn longest_base64_literal(text: &str) -> Option<String> {
    let mut best: Option<String> = None;
    for caps in BASE64_RE.captures_iter(text) {
        let lit = caps.get(1).unwrap().as_str();
        if best.as_deref().map(|b| lit.len() > b.len()).unwrap_or(true) {
            best = Some(lit.to_string());
        }
    }
    best
}

pub fn eval_heads(text: &str) -> Vec<usize> {
    EVAL_HEAD_RE
        .find_iter(text)
        .map(|m| m.start() + m.as_str().rfind("eval").unwrap())
        .collect()
}

pub fn function_heads(text: &str) -> Vec<(usize, usize)> {
    FUNCTION_HEAD_RE
        .find_iter(text)
        .map(|m| (m.start(), m.end()))
        .collect()
}

/// Scores the obfuscation layers actually present. Highest score wins the stage.
pub fn detect_layers(text: &str) -> Vec<Finding> {
    let mut findings: Vec<Finding> = Vec::new();
    let eval_count = EVAL_HEAD_RE.find_iter(text).count();
    let fn_count = FUNCTION_HEAD_RE.find_iter(text).count();
    // The collector is the single source of truth for what eval()/Function()
    // can yield; the detector must not re-derive that gate or it routes
    // nothing.
    let payloads = if eval_count > 0 || fn_count > 0 {
        crate::transforms::collect_eval_payloads(text)
    } else {
        Vec::new()
    };
    if !payloads.is_empty() {
        findings.push(Finding {
            tool: "eval-unwrap",
            score: 0.7 + (payloads.len() as f64 / 20.0).min(0.3),
            detail: format!("{eval_count} eval() / {fn_count} Function() call(s)"),
        });
    }
    if let Some(base64) = longest_base64_literal(text) {
        let len = utf16_len(&base64);
        findings.push(Finding {
            tool: "base64",
            score: 0.5 + (len as f64 / 4000.0).min(0.3),
            detail: format!("{len} char literal"),
        });
    }
    let hex_escapes = HEX_ESCAPE_RE.find_iter(text).count();
    if hex_escapes > 8 && (hex_escapes * 4) as f64 > utf16_len(text) as f64 * 0.15 {
        findings.push(Finding {
            tool: "hex-escape",
            score: 0.6,
            detail: format!("{hex_escapes} \\x escapes"),
        });
    }
    if UNICODE_PERCENT_RE.find_iter(text).count() > 8 {
        findings.push(Finding {
            tool: "unescape",
            score: 0.6,
            detail: "%uXXXX encoding".to_string(),
        });
    }
    if CHARCODE_RE.is_match(text) {
        findings.push(Finding {
            tool: "charcode",
            score: 0.65,
            detail: "String.fromCharCode list".to_string(),
        });
    }
    let reversed: String = text.chars().rev().collect();
    if gain(&reversed) > gain(text) + 2 {
        findings.push(Finding {
            tool: "reverse",
            score: 0.45,
            detail: "reversed source".to_string(),
        });
    }
    let rot13 = rot13(text);
    if gain(&rot13) > gain(text) + 2 {
        findings.push(Finding {
            tool: "rot13",
            score: 0.42,
            detail: "rot13 source".to_string(),
        });
    }
    // Self-contained detectors: each one both detects and routes (its own
    // predicate is the collector), so the transform never guesses.
    if let Some(packer) = detect_packer(text) {
        findings.push(Finding {
            tool: "packer",
            score: 0.9,
            detail: format!(
                "Dean Edwards packer, base {}, {} words",
                packer.base,
                packer.words.len()
            ),
        });
    }
    let jsf = detect_jsfuck(text);
    if jsf.detected {
        findings.push(Finding {
            tool: "jsfuck",
            score: 0.95,
            detail: format!("jsfuck, purity {:.1}%", jsf.purity * 100.0),
        });
    }
    if let Some(string_array) = detect_string_array(text) {
        findings.push(Finding {
            tool: "string-array",
            score: 0.8,
            detail: format!(
                "string array {}, {} literals",
                string_array.array_id, string_array.literals
            ),
        });
    }
    findings.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
    findings
}

/// JS rot13 source transform: letters rotate, everything else is untouched.
pub fn rot13(text: &str) -> String {
    text.chars()
        .map(|c| {
            if c.is_ascii_uppercase() {
                ((c as u8 - b'A' + 13) % 26 + b'A') as char
            } else if c.is_ascii_lowercase() {
                ((c as u8 - b'a' + 13) % 26 + b'a') as char
            } else {
                c
            }
        })
        .collect()
}
