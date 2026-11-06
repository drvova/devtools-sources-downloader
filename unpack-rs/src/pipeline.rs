// Asset pipeline: route each asset (text script or cached-bytecode binary)
// through the peel loop / binary detection ladder, and emit the report
// entry plus the file set the export zip should carry.

use crate::beautify::{beautify_js, looks_minified};
use crate::bundler::{extract_bundle_modules, module_file_name, safe_path};
use crate::jscbytecode::{
    analyze_jsc_module, detect_jsc_bytecode, find_jsc_shared_table, parse_jsc_header,
    recover_jsc_strings, JscSharedTableInfo, JscStats,
};
use crate::sourcemaps::{
    decode_inline_source_map, find_source_map_ref, parse_source_map, resolve_map_url, SourceMapRef,
};
use crate::transforms::{peel_text, BinaryStage, Stage};
use crate::util::{iso8601_now, utf16_len, utf16_prefix, utf16_suffix};
use crate::v8codecache::{detect_v8_code_cache, parse_sealed_v8, parse_v8_code_cache, InflateImpl};
use crate::wasm::{detect_wasm_module, parse_wasm_module};
use crate::{digest::sha256_hex, LIMITS};
use std::sync::LazyLock;

static SCHEME_RE: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new(r"(?i)^[a-z]+://").unwrap());
static QUERY_RE: LazyLock<regex::Regex> = LazyLock::new(|| regex::Regex::new(r"[?#].*$").unwrap());
static SLUG_SLASHES_RE: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new(r"/+").unwrap());
static BINARY_EXT_RE: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new(r"(?i)\.(jsc|bc|wasm)(\?|$)").unwrap());
static JS_EXT_RE: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new(r"(?i)\.js$").unwrap());

pub fn asset_slug(url: &str, index: usize) -> String {
    let cleaned = SCHEME_RE.replace(url, "");
    let cleaned = QUERY_RE.replace(&cleaned, "");
    let cleaned = crate::util::BAD_PATH_CHARS.replace_all(&cleaned, "_");
    let mut cleaned = SLUG_SLASHES_RE.replace_all(&cleaned, "__").into_owned();
    if utf16_len(&cleaned) > 90 {
        cleaned = utf16_suffix(&cleaned, 90).to_string();
    }
    if cleaned.is_empty() {
        cleaned = "inline".to_string();
    }
    if !JS_EXT_RE.is_match(&cleaned) {
        cleaned.push_str(".js");
    }
    let numbered = format!("000{index}");
    format!("{}-{}", utf16_suffix(&numbered, 4), cleaned)
}

/// Sync routing for resource collection: a script-shaped binary (V8 code
/// cache, JSC bytecode) or a .jsc/.bc/.wasm URL goes down the bytes path,
/// everything else stays text.
pub fn looks_binary_script(url: &str, bytes: Option<&[u8]>) -> bool {
    if BINARY_EXT_RE.is_match(url) {
        return true;
    }
    match bytes {
        Some(bytes) if bytes.len() >= 8 && detect_wasm_module(bytes) => true,
        Some(bytes)
            if bytes.len() >= 32 && (detect_v8_code_cache(bytes) || detect_jsc_bytecode(bytes)) =>
        {
            true
        }
        _ => false,
    }
}

#[derive(Debug, Clone)]
pub enum Asset {
    Text {
        url: String,
        content: String,
        zip_path: Option<String>,
    },
    Bytes {
        url: String,
        bytes: Vec<u8>,
        zip_path: Option<String>,
    },
}

impl Asset {
    pub fn url(&self) -> &str {
        match self {
            Asset::Text { url, .. } | Asset::Bytes { url, .. } => url,
        }
    }
    pub fn zip_path(&self) -> Option<&str> {
        match self {
            Asset::Text { zip_path, .. } | Asset::Bytes { zip_path, .. } => zip_path.as_deref(),
        }
    }
}
/// Injected text fetcher for external source-map resolution.
type FetchText<'a> = Option<&'a dyn Fn(&str) -> Option<String>>;

#[derive(Clone)]
pub struct UnpackOptions<'a> {
    pub index: Option<usize>,
    pub zip_path: String,
    pub max_depth: Option<usize>,
    pub max_modules: Option<usize>,
    pub max_beautify_bytes: Option<usize>,
    pub path_prefix: String,
    pub fetch_text: FetchText<'a>,
    pub inflate: Option<&'a InflateImpl<'a>>,
    pub shared_jsc_strings: Option<&'a [Option<String>]>,
    pub shared_jsc_source: Option<String>,
}

impl Default for UnpackOptions<'_> {
    fn default() -> Self {
        UnpackOptions {
            index: None,
            zip_path: String::new(),
            max_depth: None,
            max_modules: None,
            max_beautify_bytes: None,
            path_prefix: "_unpack".to_string(),
            fetch_text: None,
            inflate: None,
            shared_jsc_strings: None,
            shared_jsc_source: None,
        }
    }
}

#[derive(Debug, Clone, serde::Serialize, PartialEq)]
pub struct SourceMapSummary {
    pub kind: String,
    pub r#ref: String,
}

#[derive(Debug, Clone, serde::Serialize, PartialEq)]
pub struct ReportEntry {
    pub url: String,
    #[serde(rename = "zipPath")]
    pub zip_path: String,
    pub kind: &'static str,
    pub bytes: usize,
    pub digest: Option<String>,
    pub stages: Vec<Stage>,
    pub modules: usize,
    pub sources: usize,
    pub beautified: bool,
    #[serde(rename = "sourceMap")]
    pub source_map: Option<SourceMapSummary>,
    pub notes: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub refusals: Option<Vec<crate::packers::Refusal>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub functions: Option<usize>,
}

#[derive(Debug, Clone, serde::Serialize, PartialEq)]
pub struct File {
    pub path: String,
    pub content: String,
}

#[derive(Debug, Clone, serde::Serialize, PartialEq)]
pub struct AssetResult {
    pub entry: ReportEntry,
    pub files: Vec<File>,
}

/// A report that cannot be serialized is a bug, not an empty file. `serde_json`
/// only fails here on a non-finite float, and writing `""` in its place would
/// hide that behind a zero-byte artifact; a panic is a trap in wasm, which the
/// dispatcher records for `lastEngineFailure` to report.
fn pretty_json<T: serde::Serialize>(value: &T) -> String {
    serde_json::to_string_pretty(value).expect("a report must serialize")
}

// Binary pass for cached-bytecode assets (V8 code cache, JSC bytecode,
// brotli-sealed V8). The detection ladder is ordered exactly like the peel
// loop: every rung is a self-contained detector, the first match routes, and
// an unrecognized blob is a reported refusal, never a silent skip.
fn unpack_binary_asset(url: &str, bytes: &[u8], opts: &UnpackOptions) -> AssetResult {
    let index = opts.index.unwrap_or(0);
    let mut entry = ReportEntry {
        url: url.to_string(),
        zip_path: opts.zip_path.clone(),
        kind: "binary",
        bytes: bytes.len(),
        digest: crate::digest::sha256_hex_bytes(bytes),
        stages: Vec::new(),
        modules: 0,
        sources: 0,
        beautified: false,
        source_map: None,
        notes: Vec::new(),
        refusals: None,
        functions: None,
    };
    let mut files: Vec<File> = Vec::new();
    if bytes.len() > LIMITS.max_asset_bytes {
        entry.notes.push("asset exceeds unpack budget".to_string());
        return AssetResult { entry, files };
    }
    let base = format!("{}/{}", opts.path_prefix, asset_slug(url, index));
    let mut strings: Option<Vec<String>> = None;

    let cache_header_file = |files: &mut Vec<File>, base: &str, payload: &serde_json::Value| {
        files.push(File {
            path: format!("{base}/cache-header.json"),
            content: pretty_json(payload),
        });
    };

    if detect_wasm_module(bytes) {
        if let Some(wasm) = parse_wasm_module(bytes) {
            entry.stages.push(Stage::Binary(BinaryStage {
                depth: 0,
                tool: "wasm-module".to_string(),
                detail: format!(
                    "wasm module, {} sections, {} imports, {} exports, {} named functions",
                    wasm.sections.len(),
                    wasm.imports.len(),
                    wasm.exports.len(),
                    wasm.function_names.len()
                ),
            }));
            files.push(File {
                path: format!("{base}/wasm-info.json"),
                content: pretty_json(&serde_json::json!({
                    "version": wasm.version,
                    "moduleName": wasm.module_name,
                    "sections": wasm.sections,
                    "imports": wasm.imports,
                    "exports": wasm.exports,
                    "functionNames": wasm.function_names,
                    "typeNames": wasm.type_names,
                    "dataStrings": wasm.data_strings,
                    "notes": wasm.notes,
                })),
            });
        }
    }

    if detect_v8_code_cache(bytes) {
        if let Some(cache) = parse_v8_code_cache(bytes) {
            entry.stages.push(Stage::Binary(BinaryStage {
                depth: 0,
                tool: "v8-code-cache".to_string(),
                detail: format!(
                    "{} {}, payload {}B",
                    cache.runtime, cache.format, cache.payload_length
                ),
            }));
            strings = Some(cache.strings.clone());
            cache_header_file(
                &mut files,
                &base,
                &serde_json::json!({
                    "shape": "v8-code-cache",
                    "magic": cache.magic_hex,
                    "runtime": cache.runtime,
                    "format": cache.format,
                    "versionHash": cache.version_hash,
                    "sourceHash": cache.source_hash,
                    "flagHash": cache.flag_hash,
                    "payloadLength": cache.payload_length,
                }),
            );
        }
    }
    if entry.stages.is_empty() && detect_jsc_bytecode(bytes) {
        if let Some(header) = parse_jsc_header(bytes) {
            entry.stages.push(Stage::Binary(BinaryStage {
                depth: 0,
                tool: "jsc-bytecode".to_string(),
                detail: format!(
                    "JSC bytecode v{}, {}B",
                    header.version, header.declared_length
                ),
            }));
            strings = Some(recover_jsc_strings(bytes));
            cache_header_file(
                &mut files,
                &base,
                &serde_json::json!({
                    "shape": "jsc-bytecode",
                    "stamp": header.stamp,
                    "format": header.format,
                    "version": header.version,
                    "declaredLength": header.declared_length,
                    "bodyOffset": header.body_offset,
                }),
            );
            let mut structure: JscStats = analyze_jsc_module(bytes, opts.shared_jsc_strings);
            if structure.blocks > 0 {
                if let Some(Stage::Binary(stage)) = entry.stages.last_mut() {
                    stage.detail = format!(
                        "{}, {} functions, {} blocks, {} ops",
                        stage.detail,
                        structure.functions.len(),
                        structure.blocks,
                        structure.ops
                    );
                }
                entry.functions = Some(structure.functions.len());
                if let Some(shared) = opts.shared_jsc_strings {
                    let named = structure
                        .functions
                        .iter()
                        .filter(|f| {
                            f.name
                                .as_deref()
                                .map(|n| !n.is_empty() && !n.starts_with("<ordinal "))
                                .unwrap_or(false)
                        })
                        .count();
                    structure.shared_table = Some(JscSharedTableInfo {
                        source: opts
                            .shared_jsc_source
                            .clone()
                            .unwrap_or_else(|| "batch".to_string()),
                        ordinals: shared.len(),
                        resolved_names: named,
                    });
                    if let Some(Stage::Binary(stage)) = entry.stages.last_mut() {
                        stage.detail =
                            format!("{}, {} names via shared table", stage.detail, named);
                    }
                }
                files.push(File {
                    path: format!("{base}/functions.json"),
                    content: pretty_json(&structure),
                });
            } else {
                entry
                    .notes
                    .push("JSC function tree did not bind (build opcode drift)".to_string());
            }
        }
    }
    if entry.stages.is_empty() {
        if let Some(sealed) = parse_sealed_v8(bytes, opts.inflate) {
            entry.stages.push(Stage::Binary(BinaryStage {
                depth: 0,
                tool: "jsc-sealed-v8".to_string(),
                detail: format!(
                    "brotli-sealed V8 cache, {}B inflated",
                    sealed.inflated_bytes
                ),
            }));
            entry.stages.push(Stage::Binary(BinaryStage {
                depth: 1,
                tool: "v8-code-cache".to_string(),
                detail: format!(
                    "{} {}, payload {}B",
                    sealed.cache.runtime, sealed.cache.format, sealed.cache.payload_length
                ),
            }));
            strings = Some(sealed.cache.strings.clone());
            cache_header_file(
                &mut files,
                &base,
                &serde_json::json!({
                    "shape": "jsc-sealed-v8",
                    "inflatedBytes": sealed.inflated_bytes,
                    "magic": sealed.cache.magic_hex,
                    "runtime": sealed.cache.runtime,
                    "format": sealed.cache.format,
                }),
            );
        }
    }
    if let Some(list) = &strings {
        if !list.is_empty() {
            files.push(File {
                path: format!("{base}/strings.json"),
                content: pretty_json(&list),
            });
        }
    }
    if entry.stages.is_empty() {
        entry.notes.push(
            "binary asset: no V8 code-cache, JSC bytecode, wasm module, or brotli-sealed shape recognized"
                .to_string(),
        );
    }
    AssetResult { entry, files }
}

/// Full pass over one JavaScript asset: peel layers, split bundle modules,
/// beautify minified output, and follow the source map when one is served.
pub fn unpack_asset(asset: &Asset, opts: &UnpackOptions) -> AssetResult {
    match asset {
        Asset::Bytes { url, bytes, .. } => unpack_binary_asset(url, bytes, opts),
        Asset::Text { url, content, .. } => {
            let index = opts.index.unwrap_or(0);
            let mut entry = ReportEntry {
                url: url.to_string(),
                zip_path: opts.zip_path.clone(),
                kind: "text",
                bytes: utf16_len(content),
                digest: if content.is_empty() {
                    None
                } else {
                    Some(sha256_hex(content))
                },
                stages: Vec::new(),
                modules: 0,
                sources: 0,
                beautified: false,
                source_map: None,
                notes: Vec::new(),
                refusals: None,
                functions: None,
            };
            let mut files: Vec<File> = Vec::new();
            if content.is_empty() || utf16_len(content) > LIMITS.max_asset_bytes {
                if !content.is_empty() {
                    entry.notes.push("asset exceeds unpack budget".to_string());
                }
                return AssetResult { entry, files };
            }
            let base = format!("{}/{}", opts.path_prefix, asset_slug(url, index));
            let peeled = peel_text(content, opts.max_depth);
            entry.stages = peeled.stages.clone();
            entry.refusals = Some(peeled.refusals.clone());
            for refusal in &peeled.refusals {
                entry
                    .notes
                    .push(format!("refused: {} — {}", refusal.tool, refusal.detail));
            }
            let current = &peeled.final_text;

            for (s, stage) in peeled.stages.iter().enumerate() {
                if let Stage::Text(meta) = stage {
                    files.push(File {
                        path: format!("{base}/layers/0{}-{}.js", meta.depth, meta.tool),
                        content: utf16_prefix(&peeled.outputs[s], LIMITS.max_asset_bytes)
                            .to_string(),
                    });
                }
            }

            if !peeled.stages.is_empty() {
                files.push(File {
                    path: format!("{base}/00-original.js"),
                    content: content.clone(),
                });
            }

            let modules = extract_bundle_modules(current, opts.max_modules);
            entry.modules = modules.len();
            for module in &modules {
                files.push(File {
                    path: format!("{base}/modules/{}", safe_path(&module_file_name(module))),
                    content: module.code.clone(),
                });
            }

            if looks_minified(current) {
                let beautified = beautify_js(current, opts.max_beautify_bytes);
                if &beautified != current {
                    entry.beautified = true;
                    files.push(File {
                        path: format!("{base}/10-beautified.js"),
                        content: beautified,
                    });
                }
            }
            if !looks_minified(current) {
                files.push(File {
                    path: format!("{base}/10-source.js"),
                    content: current.clone(),
                });
            }

            let map_ref = find_source_map_ref(content).or_else(|| find_source_map_ref(current));
            if let Some(map_ref) = map_ref {
                entry.source_map = Some(SourceMapSummary {
                    kind: match &map_ref {
                        SourceMapRef::Inline { .. } => "inline".to_string(),
                        SourceMapRef::External { .. } => "external".to_string(),
                    },
                    r#ref: match &map_ref {
                        SourceMapRef::Inline { .. } => "inline data URI".to_string(),
                        SourceMapRef::External { value } => value.clone(),
                    },
                });
                let map_json: Option<String> = match &map_ref {
                    SourceMapRef::Inline { value } => decode_inline_source_map(value),
                    SourceMapRef::External { value } => match opts.fetch_text {
                        Some(fetch) => {
                            let map_url = resolve_map_url(url, value);
                            match fetch(&map_url) {
                                Some(text) if utf16_len(&text) <= LIMITS.max_map_bytes => {
                                    Some(text)
                                }
                                _ => {
                                    entry
                                        .notes
                                        .push(format!("source map fetch failed: {value}"));
                                    None
                                }
                            }
                        }
                        None => None,
                    },
                };
                if let Some(map_json) = map_json {
                    match parse_source_map(&map_json) {
                        Ok(parsed) => {
                            entry.sources = parsed.files.len();
                            files.push(File {
                                path: format!("{base}/source-map.json"),
                                content: map_json,
                            });
                            for file in &parsed.files {
                                files.push(File {
                                    path: format!("{base}/sources/{}", safe_path(&file.path)),
                                    content: file.content.clone(),
                                });
                            }
                        }
                        Err(_) => entry.notes.push("source map parse failed".to_string()),
                    }
                }
            }

            if entry.stages.is_empty() && entry.modules == 0 && entry.sources == 0 {
                entry.notes.push(
                    "no obfuscation layer, bundle structure, or source map content found"
                        .to_string(),
                );
            }
            AssetResult { entry, files }
        }
    }
}

#[derive(Debug, Clone, serde::Serialize, PartialEq)]
pub struct Totals {
    pub assets: usize,
    pub unpacked: usize,
    pub modules: usize,
    pub sources: usize,
    pub beautified: usize,
}

#[derive(Debug, Clone, serde::Serialize, PartialEq)]
pub struct Report {
    #[serde(rename = "generatedBy")]
    pub generated_by: &'static str,
    pub assets: Vec<ReportEntry>,
    pub totals: Totals,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub root: Option<String>,
    #[serde(rename = "unpackedAt", skip_serializing_if = "Option::is_none")]
    pub unpacked_at: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, PartialEq)]
pub struct BatchResult {
    pub report: Report,
    pub files: Vec<File>,
}

fn first_non_empty(parts: &[&str], fallback: String) -> String {
    for part in parts {
        if !part.is_empty() {
            return part.to_string();
        }
    }
    fallback
}

pub fn unpack_assets(assets: &[Asset], opts: &UnpackOptions) -> BatchResult {
    let mut report = Report {
        generated_by: "unpack.js",
        assets: Vec::new(),
        totals: Totals {
            assets: assets.len(),
            unpacked: 0,
            modules: 0,
            sources: 0,
            beautified: 0,
        },
        root: None,
        unpacked_at: None,
    };
    let mut all_files: Vec<File> = Vec::new();
    // Shared JSC string table: chunks reach this batch as loose assets with
    // no module graph, so the container-wide EncoderStringTable is
    // discovered by structure (hash-validated) in any binary asset and
    // shared with every chunk, resolving `<ordinal N>` name slots.
    let mut shared: Option<Vec<Option<String>>> = opts.shared_jsc_strings.map(|s| s.to_vec());
    let mut shared_source: Option<String> = opts.shared_jsc_source.clone();
    if shared.is_none() {
        let wants_table = assets.iter().any(|a| match a {
            Asset::Bytes { bytes, .. } => detect_jsc_bytecode(bytes),
            _ => false,
        });
        if wants_table {
            for (s, asset) in assets.iter().enumerate() {
                let Asset::Bytes {
                    url,
                    bytes,
                    zip_path,
                } = asset
                else {
                    continue;
                };
                if bytes.len() < 24 || bytes.len() > LIMITS.max_asset_bytes {
                    continue;
                }
                if let Some(found) = find_jsc_shared_table(bytes) {
                    if found.resolved >= 8 {
                        shared_source = Some(first_non_empty(
                            &[url, zip_path.as_deref().unwrap_or("")],
                            format!("asset {s}"),
                        ));
                        shared = Some(found.strings);
                        break;
                    }
                }
            }
        }
    }
    for (i, asset) in assets.iter().enumerate() {
        let result = unpack_asset(
            asset,
            &UnpackOptions {
                index: Some(i),
                zip_path: asset.zip_path().unwrap_or("").to_string(),
                max_depth: opts.max_depth,
                max_modules: opts.max_modules,
                max_beautify_bytes: opts.max_beautify_bytes,
                path_prefix: opts.path_prefix.clone(),
                fetch_text: opts.fetch_text,
                inflate: opts.inflate,
                shared_jsc_strings: shared.as_deref(),
                shared_jsc_source: shared_source.clone(),
            },
        );
        if !result.entry.stages.is_empty() || result.entry.sources > 0 || result.entry.modules > 0 {
            report.totals.unpacked += 1;
        }
        report.totals.modules += result.entry.modules;
        report.totals.sources += result.entry.sources;
        if result.entry.beautified {
            report.totals.beautified += 1;
        }
        report.assets.push(result.entry);
        all_files.extend(result.files);
    }
    BatchResult {
        report,
        files: all_files,
    }
}

/// Zip seam: JSZip is the browser route; Rust takes a writer closure that
/// receives (path, content) pairs. The report lands at `report_path`
/// (default `{prefix}/index.json`), pretty-printed.
/// One file the panel collected for the archive. The panel sends text entries
/// as `content` and binary ones as `base64` - the same shape the engine's own
/// file lists use, so nothing has to be re-encoded on the way in.
#[derive(Debug, Clone, serde::Deserialize)]
pub struct ZipFile {
    pub path: String,
    #[serde(default)]
    pub content: Option<String>,
    #[serde(default)]
    pub base64: Option<String>,
}

/// Assembles the download archive, replacing the JSZip step the panel used to
/// run: the engine owns the names and the report, so it owns the archive too.
/// `now_ms` stamps the entries (the panel passes the host clock).
pub fn build_zip(files: &[ZipFile], now_ms: i64) -> Result<Vec<u8>, String> {
    let mut writer = crate::zip::ZipWriter::with_ms(now_ms);
    for file in files {
        match &file.base64 {
            Some(encoded) => {
                let bytes = crate::decoders::decode_base64_to_bytes(encoded)
                    .ok_or_else(|| format!("zip entry {}: invalid base64 payload", file.path))?;
                writer.add(&file.path, &bytes)?;
            }
            None => writer.add_text(&file.path, file.content.as_deref().unwrap_or_default())?,
        }
    }
    writer.finish()
}

pub fn unpack_assets_into(
    writer: &mut dyn FnMut(&str, &str),
    assets: &[Asset],
    opts: &UnpackOptions,
    report_path: Option<&str>,
) -> Report {
    let prefix = if opts.path_prefix.is_empty() {
        "_unpack".to_string()
    } else {
        opts.path_prefix.clone()
    };
    let result = unpack_assets(assets, opts);
    for file in &result.files {
        writer(&file.path, &file.content);
    }
    let mut report = result.report;
    report.root = Some(prefix.clone());
    report.unpacked_at = Some(iso8601_now());
    let report_path = report_path
        .map(str::to_string)
        .unwrap_or_else(|| format!("{prefix}/index.json"));
    writer(&report_path, &pretty_json(&report));
    report
}
