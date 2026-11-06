// webpack bundle module splitting: locate the module map (named
// __webpack_modules__ or the push-array form), then slice every
// `id: function(params){...}` member into its own module.

use crate::scanner::find_balanced;
use crate::util::{JS_S, JS_W};
use crate::LIMITS;
use std::sync::LazyLock;

static PUSH_RE: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new(r"\[\s*\[[^\]]*\]\s*,\s*\{").unwrap());

// The JS header regex is /(^|[,\s])(\d{1,7})\s*:\s*(?:function\s*\(([^)]*)\)|(?:\(([^)]*)\)|([\w$]+))\s*=>)/g
// with lastIndex resumption. ^ can only match at body position 0, so the
// continuation regex drops it (searches resume at the last region end).
static HEADER_FULL: LazyLock<regex::Regex> = LazyLock::new(|| {
    regex::Regex::new(&format!(
        r"(?:^|[{JS_S},])(\d{{1,7}})[{JS_S}]*:[{JS_S}]*(?:function[{JS_S}]*\(([^)]*)\)|(?:\(([^)]*)\)|([{JS_W}$]+))[{JS_S}]*=>)"
    ))
    .unwrap()
});

static HEADER_CONT: LazyLock<regex::Regex> = LazyLock::new(|| {
    regex::Regex::new(&format!(
        r"[{JS_S},](\d{{1,7}})[{JS_S}]*:[{JS_S}]*(?:function[{JS_S}]*\(([^)]*)\)|(?:\(([^)]*)\)|([{JS_W}$]+))[{JS_S}]*=>)"
    ))
    .unwrap()
});

static SOURCE_URL_RE: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new(r"//[#@]\s*sourceURL\s*=\s*(\S+)").unwrap());

#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct BundleModule {
    pub id: String,
    pub params: String,
    pub code: String,
}

pub fn extract_bundle_modules(text: &str, max_modules: Option<usize>) -> Vec<BundleModule> {
    // JS quirk preserved: maxModules || LIMITS.maxModules — zero is falsy.
    let cap = match max_modules {
        Some(0) | None => LIMITS.max_modules,
        Some(n) => n,
    };
    let map_start = text.find("__webpack_modules__");
    let open_index = match map_start {
        Some(at) => text[at..].find('{').map(|r| at + r),
        None => PUSH_RE
            .find(text)
            .and_then(|m| text[m.start()..].find('{').map(|r| m.start() + r)),
    };
    let Some(open_index) = open_index else {
        return Vec::new();
    };
    let Some(end) = find_balanced(text, open_index) else {
        return Vec::new();
    };
    let body = &text[open_index + 1..end - 1];
    let mut modules: Vec<BundleModule> = Vec::new();
    let mut cursor = 0usize;
    while modules.len() < cap {
        let re = if cursor == 0 {
            &*HEADER_FULL
        } else {
            &*HEADER_CONT
        };
        let Some(m) = re.captures(&body[cursor..]) else {
            break;
        };
        let whole_start = cursor + m.get(0).unwrap().start();
        let whole_end = cursor + m.get(0).unwrap().end();
        let key = m.get(1).unwrap().as_str().to_string();
        let key_index = body[whole_start..]
            .find(&key)
            .map(|r| whole_start + r)
            .unwrap_or(whole_start);
        let Some(brace_index) = body[whole_end..].find('{').map(|r| whole_end + r) else {
            continue;
        };
        let arrowless = &body[whole_end..brace_index];
        // Arrow-expression bodies (`(a) => ({...})` style) are skipped — a
        // preserved quirk of the original, never "fixed" silently.
        let is_expression_body = arrowless.contains("=>")
            && !arrowless.trim().is_empty()
            && arrowless.contains(')')
            && body.as_bytes()[brace_index - 1] == b')';
        if is_expression_body {
            continue;
        }
        let Some(region_end) = find_balanced(body, brace_index) else {
            continue;
        };
        let params = m
            .get(2)
            .or_else(|| m.get(3))
            .or_else(|| m.get(4))
            .map(|g| g.as_str().to_string())
            .unwrap_or_default();
        modules.push(BundleModule {
            id: key,
            params,
            code: body[key_index..region_end].to_string(),
        });
        cursor = region_end;
    }
    if cursor == 0 {
        return Vec::new();
    }
    modules
}

pub fn module_file_name(module: &BundleModule) -> String {
    let Some(url) = SOURCE_URL_RE
        .captures(&module.code)
        .and_then(|c| c.get(1))
        .map(|g| g.as_str().to_string())
    else {
        return format!("module-{}.js", module.id);
    };
    static WEBPACK_PREFIX: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"^webpack(-internal)?://").unwrap());
    static DOT_SLASH: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"^\./").unwrap());
    static LEADING_SLASHES: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"^/+").unwrap());
    let cleaned = WEBPACK_PREFIX.replace(&url, "");
    let cleaned = DOT_SLASH.replace(&cleaned, "");
    let cleaned = crate::util::BAD_PATH_CHARS.replace_all(&cleaned, "_");
    LEADING_SLASHES.replace(&cleaned, "").into_owned()
}

/// JS `safePath`: one sanitised pass per path segment.
pub fn safe_path(path: &str) -> String {
    static DOT_SEGMENTS: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"^\.+$").unwrap());
    path.split('/')
        .map(|segment| {
            let cleaned = crate::util::BAD_PATH_CHARS.replace_all(segment, "_");
            DOT_SEGMENTS.replace(&cleaned, "_").into_owned()
        })
        .collect::<Vec<_>>()
        .join("/")
}
