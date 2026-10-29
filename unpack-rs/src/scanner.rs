// One string/comment aware walker feeds literal extraction, balanced-region
// slicing and module splitting, so the three consumers cannot disagree.
//
// Scanning is byte-indexed over ASCII delimiters: multi-byte UTF-8 sequences
// never contain the delimiter bytes, so positions land on char boundaries for
// every delimiter-driven path (the only realistic payload shape).

#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct StringLiteral {
    pub start: usize,
    pub end: usize,
    pub quote: char,
    pub raw: String,
    pub value: String,
}

pub fn skip_quoted(text: &str, index: usize, quote: char) -> usize {
    let b = text.as_bytes();
    let q = quote as u8;
    let mut j = index + 1;
    while j < b.len() {
        let ch = b[j];
        if ch == b'\\' {
            j += 2;
            continue;
        }
        if ch == q {
            return j + 1;
        }
        if ch == b'\n' && quote != '`' {
            return j;
        }
        j += 1;
    }
    text.len()
}

pub fn skip_template(text: &str, index: usize) -> usize {
    let b = text.as_bytes();
    let mut j = index + 1;
    while j < b.len() {
        let ch = b[j];
        if ch == b'\\' {
            j += 2;
            continue;
        }
        if ch == b'`' {
            return j + 1;
        }
        if ch == b'$' && j + 1 < b.len() && b[j + 1] == b'{' {
            let close = find_balanced(text, j + 1);
            j = match close {
                Some(c) if c > 0 => c,
                _ => j + 2,
            };
            continue;
        }
        j += 1;
    }
    b.len()
}

pub fn skip_line_comment(text: &str, index: usize) -> usize {
    match text[index..].find('\n') {
        Some(rel) => index + rel + 1,
        None => text.len(),
    }
}

pub fn skip_block_comment(text: &str, index: usize) -> usize {
    match text[index + 2..].find("*/") {
        Some(rel) => index + 2 + rel + 2,
        None => text.len(),
    }
}

fn is_js_space(c: u8) -> bool {
    matches!(c, b' ' | b'\t' | b'\n' | 0x0B | b'\x0C' | b'\r')
}

pub fn is_regex_start(text: &str, index: usize) -> bool {
    let b = text.as_bytes();
    let mut j = index as isize - 1;
    while j >= 0 && is_js_space(b[j as usize]) {
        j -= 1;
    }
    if j < 0 {
        return true;
    }
    let c = b[j as usize];
    !(c.is_ascii_alphanumeric() || c == b'_' || c == b'$' || c == b')' || c == b']')
}

pub fn skip_regex(text: &str, index: usize) -> usize {
    let b = text.as_bytes();
    let mut j = index + 1;
    let mut in_class = false;
    while j < b.len() {
        let ch = b[j];
        if ch == b'\\' {
            j += 2;
            continue;
        }
        if ch == b'\n' {
            return index + 1;
        }
        if ch == b'[' {
            in_class = true;
        } else if ch == b']' {
            in_class = false;
        } else if ch == b'/' && !in_class {
            j += 1;
            while j < b.len() && b[j].is_ascii_alphabetic() {
                j += 1;
            }
            return j;
        }
        j += 1;
    }
    index + 1
}

/// JS `collectStringLiterals(text, {minLength})`.
pub fn collect_string_literals(text: &str, min_length: usize) -> Vec<StringLiteral> {
    let b = text.as_bytes();
    let mut out = Vec::new();
    let mut i = 0usize;
    while i < b.len() {
        let ch = b[i];
        if ch == b'"' || ch == b'\'' || ch == b'`' {
            let end = if ch == b'`' {
                skip_template(text, i)
            } else {
                skip_quoted(text, i, ch as char)
            };
            let raw = text.get(i + 1..end.saturating_sub(1)).unwrap_or("");
            let decoded = crate::decoders::decode_escapes(raw);
            if crate::util::utf16_len(&decoded) >= min_length {
                out.push(StringLiteral {
                    start: i,
                    end,
                    quote: ch as char,
                    raw: raw.to_string(),
                    value: decoded,
                });
            }
            i = end;
            continue;
        }
        if ch == b'/' && i + 1 < b.len() && b[i + 1] == b'/' {
            i = skip_line_comment(text, i);
            continue;
        }
        if ch == b'/' && i + 1 < b.len() && b[i + 1] == b'*' {
            i = skip_block_comment(text, i);
            continue;
        }
        if ch == b'/' && is_regex_start(text, i) {
            i = skip_regex(text, i);
            continue;
        }
        i += 1;
    }
    out
}

/// JS `findBalanced(text, openIndex)`: returns the index just past the closing
/// bracket, or None (the JS returns -1).
pub fn find_balanced(text: &str, open_index: usize) -> Option<usize> {
    let b = text.as_bytes();
    let open = *b.get(open_index)?;
    let close = match open {
        b'{' => b'}',
        b'[' => b']',
        b'(' => b')',
        _ => return None,
    };
    let mut depth = 0usize;
    let mut i = open_index;
    while i < b.len() {
        let ch = b[i];
        if ch == b'"' || ch == b'\'' || ch == b'`' {
            i = if ch == b'`' {
                skip_template(text, i)
            } else {
                skip_quoted(text, i, ch as char)
            };
            continue;
        }
        if ch == b'/' && i + 1 < b.len() && b[i + 1] == b'/' {
            i = skip_line_comment(text, i);
            continue;
        }
        if ch == b'/' && i + 1 < b.len() && b[i + 1] == b'*' {
            i = skip_block_comment(text, i);
            continue;
        }
        if ch == b'/' && is_regex_start(text, i) {
            i = skip_regex(text, i);
            continue;
        }
        if ch == open {
            depth += 1;
        } else if ch == close {
            depth = depth.saturating_sub(1);
            if depth == 0 {
                return Some(i + 1);
            }
        }
        i += 1;
    }
    None
}
