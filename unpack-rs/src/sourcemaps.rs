// sourceMappingURL discovery and source-map payload decoding: the ref can
// be a trailing comment line (external file) or a data: URI (inline map);
// the map's sourcesContent slice is the recoverable original source.

use crate::decoders::{bytes_to_text, decode_base64_to_bytes};
use crate::util::JS_S;
use crate::LIMITS;
use std::sync::LazyLock;

#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub enum SourceMapRef {
    #[serde(rename = "inline")]
    Inline { value: String },
    #[serde(rename = "external")]
    External { value: String },
}

impl SourceMapRef {
    pub fn value(&self) -> &str {
        match self {
            SourceMapRef::Inline { value } | SourceMapRef::External { value } => value,
        }
    }
}

static MAP_REF_PREFIX: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new(&format!(r"^sourceMappingURL[{JS_S}]*=[{JS_S}]*")).unwrap());

pub fn find_source_map_ref(text: &str) -> Option<SourceMapRef> {
    let index = text.rfind("sourceMappingURL")?;
    let line_end = text[index..]
        .find('\n')
        .map(|rel| index + rel)
        .unwrap_or(text.len());
    let line = &text[index..line_end];
    let value = MAP_REF_PREFIX.replace(line, "").trim().to_string();
    if value.is_empty() {
        return None;
    }
    if value.starts_with("data:") {
        // The full data: URI survives in value so the decoder can re-match
        // the prefix (JS keeps the whole string in the ref).
        return Some(SourceMapRef::Inline { value });
    }
    Some(SourceMapRef::External { value })
}

#[derive(Debug, Clone, PartialEq)]
pub struct SourceFile {
    pub path: String,
    pub content: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ParsedSourceMap {
    pub files: Vec<SourceFile>,
    pub source_root: String,
    pub file: String,
}

#[derive(serde::Deserialize)]
struct RawSourceMap {
    #[serde(default)]
    sources: Vec<String>,
    #[serde(default)]
    #[serde(rename = "sourcesContent")]
    sources_content: Vec<Option<String>>,
    #[serde(default)]
    #[serde(rename = "sourceRoot")]
    source_root: Option<String>,
    #[serde(default)]
    file: Option<String>,
}


/// JS `parseSourceMap`: throws on malformed JSON (the caller maps that to a
/// note); here the Result carries the parse error.
pub fn parse_source_map(json: &str) -> Result<ParsedSourceMap, serde_json::Error> {
    let map: RawSourceMap = serde_json::from_str(json)?;
    let mut files: Vec<SourceFile> = Vec::new();
    for (i, source) in map.sources.iter().enumerate() {
        if files.len() >= LIMITS.max_sources {
            break;
        }
        let Some(content) = map.sources_content.get(i).and_then(|c| c.as_deref()) else {
            continue;
        };
        if content.is_empty() {
            continue;
        }
        let mut path = clean_source_path(source);
        if path.is_empty() || path.ends_with('/') {
            path.push_str("index.js");
        }
        files.push(SourceFile {
            path,
            content: content.to_string(),
        });
    }
    Ok(ParsedSourceMap {
        files,
        source_root: map.source_root.unwrap_or_default(),
        file: map.file.unwrap_or_default(),
    })
}

fn clean_source_path(source: &str) -> String {
    static WEBPACK_HTTP: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"^webpack://").unwrap());
    static WEBPACK_SLASH: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"^webpack//").unwrap());
    static DOT_SLASH: LazyLock<regex::Regex> = LazyLock::new(|| regex::Regex::new(r"^\./").unwrap());
    static BACKSLASH: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"\\").unwrap());
    static LEADING_SLASHES: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"^/+").unwrap());
    let path = WEBPACK_HTTP.replace(source, "");
    let path = WEBPACK_SLASH.replace(&path, "");
    let path = DOT_SLASH.replace(&path, "");
    let path = BACKSLASH.replace_all(&path, "/");
    let path = LEADING_SLASHES.replace(&path, "");
    crate::util::BAD_PATH_CHARS.replace_all(&path, "_").into_owned()
}

static DATA_URI_RE: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new(r"^data:([^;,]*)(;base64)?,([\s\S]*)$").unwrap());

pub fn decode_inline_source_map(data_uri: &str) -> Option<String> {
    let m = DATA_URI_RE.captures(data_uri)?;
    let payload = m.get(3).unwrap().as_str();
    if m.get(2).is_some() {
        // A failed base64 payload decodes to empty text (the JS TextDecoder
        // path), which the caller then treats as no map.
        return Some(bytes_to_text(&decode_base64_to_bytes(payload).unwrap_or_default()));
    }
    crate::transforms::decode_uri_component(payload)
}

/// JS `resolveMapUrl`: new URL(mapRef, scriptUrl).href, falling back to the
/// raw ref when either side is not a parseable absolute URL.
pub fn resolve_map_url(script_url: &str, map_ref: &str) -> String {
    match url::Url::parse(script_url) {
        Ok(base) => match base.join(map_ref) {
            Ok(joined) => joined.to_string(),
            Err(_) => map_ref.to_string(),
        },
        Err(_) => map_ref.to_string(),
    }
}
