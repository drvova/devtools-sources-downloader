// Minified-source detection and a scanner-aware reformatter. The original
// routes through the external js-beautify bundle when the panel loads it;
// this port carries a simplified structural formatter instead (documented
// divergence in PORTING.md): string/comment/template-aware brace layout,
// two-space indent, newline after statement semicolons.

use crate::scanner::{
    skip_block_comment, skip_line_comment, skip_quoted, skip_regex, skip_template,
};
use crate::util::utf16_len;
use crate::LIMITS;

static CODE_SIGNAL: std::sync::LazyLock<regex::Regex> = std::sync::LazyLock::new(|| {
    regex::Regex::new(
        r"(?:^|[^\w$])(?:function|return|var|let|const|class|new|typeof|window\.|document\.|module\.exports|exports\.|prototype)\b|=>",
    )
    .unwrap()
});

pub fn looks_minified(text: &str) -> bool {
    let probe = crate::util::utf16_prefix(text, 200000);
    if !CODE_SIGNAL.is_match(probe) {
        return false;
    }
    let lines: Vec<&str> = probe.split('\n').collect();
    if lines.len() < 4 {
        return true;
    }
    let longest = lines.iter().map(|l| l.len()).max().unwrap_or(0);
    longest > 500 || (utf16_len(probe) as f64 / lines.len() as f64) > 220.0
}

/// Simplified js-beautify stand-in: brace blocks get one statement per line
/// with two-space indent; content inside parentheses stays inline; strings,
/// templates, comments and regexes pass through untouched.
pub fn beautify_js(text: &str, max_bytes: Option<usize>) -> String {
    // JS quirk preserved: maxBytes || LIMITS.maxBeautifyBytes — zero is falsy.
    let limit = match max_bytes {
        Some(0) | None => LIMITS.max_beautify_bytes,
        Some(n) => n,
    };
    if utf16_len(text) > limit {
        return text.to_string();
    }
    let b = text.as_bytes();
    let mut out = String::with_capacity(text.len() + 64);
    let mut indent = 0usize;
    let mut paren_depth: i64 = 0;
    let mut line_has_code = false;
    let mut i = 0usize;
    while i < b.len() {
        let ch = b[i];
        if ch == b'"' || ch == b'\'' || ch == b'`' {
            let end = if ch == b'`' {
                skip_template(text, i)
            } else {
                skip_quoted(text, i, ch as char)
            };
            out.push_str(&text[i..end]);
            line_has_code = true;
            i = end;
            continue;
        }
        if ch == b'/' && i + 1 < b.len() && b[i + 1] == b'/' {
            let end = skip_line_comment(text, i);
            out.push_str(&text[i..end]);
            i = end;
            continue;
        }
        if ch == b'/' && i + 1 < b.len() && b[i + 1] == b'*' {
            let end = skip_block_comment(text, i);
            out.push_str(&text[i..end]);
            i = end;
            continue;
        }
        if ch == b'/' && crate::scanner::is_regex_start(text, i) {
            let end = skip_regex(text, i);
            out.push_str(&text[i..end]);
            line_has_code = true;
            i = end;
            continue;
        }
        match ch {
            b'(' | b'[' => {
                paren_depth += 1;
                out.push(ch as char);
            }
            b')' | b']' => {
                paren_depth -= 1;
                out.push(ch as char);
            }
            b'{' => {
                // '){' becomes ') {'; parenthesised object literals stay inline.
                if paren_depth <= 0 {
                    if out.ends_with(|c: char| !c.is_whitespace()) {
                        out.push(' ');
                    }
                    out.push('{');
                    out.push('\n');
                    indent += 1;
                    out.push_str(&" ".repeat(indent * 2));
                } else {
                    out.push('{');
                }
                line_has_code = false;
            }
            b'}' => {
                if paren_depth <= 0 {
                    if line_has_code {
                        out.push('\n');
                    }
                    indent = indent.saturating_sub(1);
                    out.push_str(&" ".repeat(indent * 2));
                    out.push('}');
                    out.push('\n');
                    out.push_str(&" ".repeat(indent * 2));
                    line_has_code = false;
                } else {
                    out.push('}');
                }
            }
            b';' => {
                out.push(';');
                if paren_depth <= 0 {
                    out.push('\n');
                    out.push_str(&" ".repeat(indent * 2));
                    line_has_code = false;
                } else {
                    line_has_code = true;
                }
            }
            _ => {
                if !(ch as char).is_whitespace() {
                    line_has_code = true;
                }
                out.push(ch as char);
            }
        }
        i += 1;
    }
    // js-beautify's `end_with_newline` default, which the original relied on:
    // the reformatter always leaves the output ending in a newline.
    if !out.ends_with('\n') {
        out.push('\n');
    }
    out
}
