//! Script-asset analysis: bundler/framework/startup detection, route and
//! import extraction, classification, scoring, and the runtime-origin model.
//! Ported from `page.js` (prepareScriptAssets and its neighbours) with the
//! same semantics; the fixture-driven test compares whole outputs against
//! oracles captured from the pre-port implementation.

use std::collections::BTreeMap;
use std::sync::LazyLock;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::jsnumber::js_number_to_string;
use crate::panel::model::js_number;
use crate::panel::text::{
    hash_string, js_number_value, js_trim, safe_decode_uri_component, sanitize_filename,
    sanitize_path_part, serialize_js_number,
};
use crate::util::{utf16_len, utf16_prefix, JS_S};

/// `normalizeUrlKey`.
pub fn normalize_url_key(url: &str) -> String {
    url.split('#').next().unwrap_or("").to_string()
}

/// `stripUrlVariant`.
pub fn strip_url_variant(url: &str) -> String {
    normalize_url_key(url)
        .split('?')
        .next()
        .unwrap_or("")
        .to_string()
}

/// `getBareFileName`.
pub fn get_bare_file_name(value: &str) -> String {
    let value = strip_url_variant(value).replace('\\', "/");
    match value.rfind('/') {
        Some(at) => value[at + 1..].to_string(),
        None => value,
    }
}

/// `cleanStackReference`.
pub fn clean_stack_reference(value: &str) -> String {
    static TRAILING: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"[),]+$").unwrap());
    static LINE_COL: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r":\d+:\d+$").unwrap());
    static LINE: LazyLock<regex::Regex> = LazyLock::new(|| regex::Regex::new(r":\d+$").unwrap());
    let trimmed = js_trim(value);
    let stripped = TRAILING.replace_all(trimmed, "");
    let stripped = LINE_COL.replace_all(&stripped, "");
    LINE.replace_all(&stripped, "").into_owned()
}

/// `extractStackRefs`.
pub fn extract_stack_refs(stack: &str) -> Vec<String> {
    static REF: LazyLock<regex::Regex> = LazyLock::new(|| {
        regex::Regex::new(r"(https?://[^\s)]+|blob:[^\s)]+)").unwrap()
    });
    let mut refs: Vec<String> = Vec::new();
    for caps in REF.captures_iter(stack) {
        if refs.len() >= 12 {
            break;
        }
        if let Some(m) = caps.get(1) {
            refs.push(clean_stack_reference(m.as_str()));
        }
    }
    unique_strings(&refs)
}

/// `uniqueStrings`.
pub fn unique_strings(values: &[String]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for value in values {
        if value.is_empty() || out.contains(value) {
            continue;
        }
        out.push(value.clone());
    }
    out
}

/// `countMatches`: count non-overlapping regex matches.
pub fn count_matches(text: &str, pattern: &regex::Regex) -> usize {
    pattern.find_iter(text).count()
}

/// `detectBundlerName`.
pub fn detect_bundler_name(url: &str, content: &str) -> String {
    let sample = format!("{url}\n{content}").to_lowercase();
    if sample.contains("__webpack_require__")
        || sample.contains("webpackchunk")
        || sample.contains("/_next/static/chunks/")
    {
        return "webpack".to_string();
    }
    if sample.contains("parcelrequire") {
        return "parcel".to_string();
    }
    if sample.contains("import.meta.hot") || sample.contains("/@vite/") || sample.contains("__vite__")
    {
        return "vite".to_string();
    }
    "unknown".to_string()
}

/// `detectFrameworkHints`.
pub fn detect_framework_hints(url: &str, content: &str, stack_profile: Option<&Value>) -> Vec<String> {
    let sample = format!("{url}\n{content}").to_lowercase();
    let mut hints: Vec<String> = Vec::new();
    if sample.contains("__next_data__") || sample.contains("/_next/") {
        hints.push("Next.js".to_string());
    }
    if sample.contains("reactdom") || sample.contains("react") {
        hints.push("React".to_string());
    }
    if sample.contains("__nuxt") {
        hints.push("Nuxt".to_string());
    }
    if sample.contains("__vue") || sample.contains("createapp(") {
        hints.push("Vue".to_string());
    }
    if sample.contains("ng-version") || sample.contains("zone.js") {
        hints.push("Angular".to_string());
    }
    if sample.contains("svelte") {
        hints.push("SvelteKit".to_string());
    }
    if sample.contains("astro") {
        hints.push("Astro".to_string());
    }
    if sample.contains("remix") {
        hints.push("Remix".to_string());
    }
    if let Some(profile) = stack_profile {
        if let Some(techs) = profile.get("technologies").and_then(|v| v.as_array()) {
            for tech in techs {
                if let Some(name) = tech.get("name").and_then(|v| v.as_str()) {
                    if !name.is_empty() {
                        hints.push(name.to_string());
                    }
                }
            }
        }
    }
    unique_strings(&hints).into_iter().take(8).collect()
}

/// `detectStartupSignals`.
pub fn detect_startup_signals(url: &str, content: &str) -> Vec<String> {
    let sample = format!("{url}\n{content}").to_lowercase();
    let mut signals: Vec<String> = Vec::new();
    if sample.contains("hydrateroot")
        || sample.contains("reactdom.hydrate")
        || sample.contains("__next_data__")
    {
        signals.push("hydration".to_string());
    }
    if sample.contains("serviceworker.register") {
        signals.push("service-worker-register".to_string());
    }
    if sample.contains("new worker(") || sample.contains("sharedworker(") {
        signals.push("worker-bootstrap".to_string());
    }
    if sample.contains("webassembly") {
        signals.push("wasm-bootstrap".to_string());
    }
    if sample.contains("graphql") || sample.contains("apollo") || sample.contains("relay") {
        signals.push("graphql-client".to_string());
    }
    if sample.contains("import(") {
        signals.push("dynamic-import".to_string());
    }
    if sample.contains("sourcemappingurl=data:") {
        signals.push("inline-source-map".to_string());
    }
    if sample.contains("webpackchunk")
        || sample.contains("__webpack_require__.e")
        || sample.contains("parcelrequire")
        || sample.contains("__vite__")
    {
        signals.push("chunk-loader".to_string());
    }
    if sample.contains("router") || sample.contains("history.pushstate") {
        signals.push("router".to_string());
    }
    unique_strings(&signals)
}

/// `extractRouteHintsFromUrl`.
pub fn extract_route_hints_from_url(url: &str) -> Vec<String> {
    static SKIP: LazyLock<regex::Regex> = LazyLock::new(|| {
        regex::Regex::new(r"(?i)^(static|assets|chunks|build|dist|js|runtime|vendor)$").unwrap()
    });
    static HASHY: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"(?i)^[0-9a-f_-]{8,}$").unwrap());
    static EXT: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"\.[A-Za-z0-9]+$").unwrap());
    let Ok(parsed) = url::Url::parse(url) else {
        return Vec::new();
    };
    let mut hints: Vec<String> = Vec::new();
    for part in parsed.path().split('/') {
        let part = EXT.replace(&safe_decode_uri_component(part), "").into_owned();
        if part.is_empty() || utf16_len(&part) < 3 {
            continue;
        }
        if SKIP.is_match(&part) || HASHY.is_match(&part) {
            continue;
        }
        hints.push(part);
    }
    unique_strings(&hints).into_iter().take(6).collect()
}

/// `extractImportSpecifiers`.
pub fn extract_import_specifiers(content: &str) -> Vec<String> {
    static PATTERNS: LazyLock<Vec<regex::Regex>> = LazyLock::new(|| {
        let ws = JS_S;
        vec![
            regex::Regex::new(&format!(
                r#"(?-u:\b)import[{ws}]*(?:[^"'\x60]*?from[{ws}]*)?["'\x60]([^"'\x60]+)["'\x60]"#
            ))
            .unwrap(),
            regex::Regex::new(&format!(
                r#"(?-u:\b)import[{ws}]*\([{ws}]*["'\x60]([^"'\x60]+)["'\x60][{ws}]*\)"#
            ))
            .unwrap(),
            regex::Regex::new(&format!(
                r#"(?-u:\b)require[{ws}]*\([{ws}]*["'\x60]([^"'\x60]+)["'\x60][{ws}]*\)"#
            ))
            .unwrap(),
        ]
    });
    let mut imports: Vec<String> = Vec::new();
    for pattern in PATTERNS.iter() {
        for caps in pattern.captures_iter(content) {
            if imports.len() >= 40 {
                break;
            }
            if let Some(m) = caps.get(1) {
                imports.push(m.as_str().to_string());
            }
        }
    }
    unique_strings(&imports)
}

/// `classifyScriptAsset`.
pub fn classify_script_asset(
    url: &str,
    content: &str,
    bundler: &str,
    framework_hints: &[String],
    startup_signals: &[String],
) -> String {
    static RUNTIME: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"runtime|manifest|polyfill|bootstrap").unwrap());
    static VENDOR: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"vendor|node_modules|chunk-vendors").unwrap());
    static FRAMEWORK: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"(?i)react|vue|angular|next|nuxt|svelte|astro|remix").unwrap());

    let sample = format!("{url}\n{content}").to_lowercase();
    let has_signal = |name: &str| startup_signals.iter().any(|s| s == name);
    if RUNTIME.is_match(&sample) || has_signal("chunk-loader") {
        return "runtime".to_string();
    }
    if VENDOR.is_match(&sample) {
        return "vendor".to_string();
    }
    if !framework_hints.is_empty() && FRAMEWORK.is_match(&framework_hints.join(" ")) {
        return "framework".to_string();
    }
    if bundler != "unknown" && has_signal("hydration") {
        return "app".to_string();
    }
    "app".to_string()
}

/// `scoreScriptAsset`.
pub fn score_script_asset(entry: &ScriptAsset) -> f64 {
    let mut score = match entry.classification.as_str() {
        "app" => 48.0,
        "runtime" => 34.0,
        "framework" => 24.0,
        _ => 18.0,
    };
    score += entry.startup_signals.len() as f64 * 7.0;
    score += entry.route_hints.len() as f64 * 4.0;
    score += (entry.module_signals.dynamic_imports as f64 * 2.0
        + entry.module_signals.import_count as f64)
        .min(12.0);
    if entry.source_map_embedded {
        score += 6.0;
    }
    if entry.transfer_size != 0.0 {
        score += (entry.transfer_size / 50000.0).round().min(12.0);
    }
    score
}

/// The module-signal counters.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModuleSignals {
    pub import_count: usize,
    pub dynamic_imports: usize,
    pub requires: usize,
    pub exports: usize,
}

/// A prepared script asset.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScriptAsset {
    pub id: String,
    pub url: String,
    pub file: String,
    pub size: usize,
    #[serde(serialize_with = "serialize_js_number")]
    pub transfer_size: f64,
    #[serde(serialize_with = "serialize_js_number")]
    pub start_time: f64,
    #[serde(serialize_with = "serialize_js_number")]
    pub duration: f64,
    pub imports: Vec<String>,
    pub module_signals: ModuleSignals,
    pub bundler: String,
    pub framework_hints: Vec<String>,
    pub route_hints: Vec<String>,
    pub startup_signals: Vec<String>,
    pub source_map_embedded: bool,
    pub content: String,
    pub classification: String,
    #[serde(serialize_with = "serialize_js_number")]
    pub score: f64,
    #[serde(default)]
    pub boundary_labels: Vec<String>,
    #[serde(default)]
    pub primary_boundary: String,
    #[serde(default)]
    pub boundary_reasons: Vec<String>,
    #[serde(default)]
    pub boundary_details: Vec<BoundaryDetail>,
}

/// One boundary match, as recorded by `applyBoundaryLabels`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BoundaryDetail {
    pub label: String,
    #[serde(serialize_with = "serialize_js_number")]
    pub score: f64,
    pub reasons: Vec<String>,
}

/// A navigation-timing record.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Timing {
    pub name: String,
    #[serde(default)]
    pub transfer_size: Value,
    #[serde(default)]
    pub start_time: Value,
    #[serde(default)]
    pub duration: Value,
}

/// A raw script input.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ScriptInput {
    #[serde(default)]
    pub url: Option<String>,
    #[serde(default)]
    pub content: Value,
}

/// `buildTimingLookup`: full URL and query-stripped URL, first writer wins.
pub fn build_timing_lookup(timings: &[Timing]) -> BTreeMap<String, Timing> {
    let mut lookup: BTreeMap<String, Timing> = BTreeMap::new();
    for item in timings {
        if item.name.is_empty() {
            continue;
        }
        let full = normalize_url_key(&item.name);
        let bare = strip_url_variant(&item.name);
        lookup.entry(full).or_insert_with(|| item.clone());
        lookup.entry(bare).or_insert_with(|| item.clone());
    }
    lookup
}

/// `prepareScriptAssets`.
pub fn prepare_script_assets(inputs: &[ScriptInput], recon: Option<&Value>) -> Vec<ScriptAsset> {
    static DYN_IMPORT: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"(?-u:\b)import[ \t\n\x0B\f\r]*\(").unwrap());
    static REQUIRE: LazyLock<regex::Regex> = LazyLock::new(|| {
        regex::Regex::new(r#"(?-u:\b)require[ \t\n\x0B\f\r]*\([ \t\n\x0B\f\r]*["'\x60]"#).unwrap()
    });
    static EXPORT: LazyLock<regex::Regex> = LazyLock::new(|| {
        regex::Regex::new(r"(?-u:\b)export[ \t\n\x0B\f\r]+(?:default|const|function|class|\{)")
            .unwrap()
    });
    static SOURCE_MAP: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"(?i)sourceMappingURL[ \t\n\x0B\f\r]*=[ \t\n\x0B\f\r]*data:").unwrap());

    let empty: Vec<Timing> = Vec::new();
    let timings: Vec<Timing> = recon
        .and_then(|r| r.get("timings"))
        .and_then(|v| serde_json::from_value(v.clone()).ok())
        .unwrap_or(empty);
    let timing_lookup = build_timing_lookup(&timings);
    let stack_profile = recon.and_then(|r| r.get("stackProfile")).filter(|v| !v.is_null());

    let mut assets: Vec<ScriptAsset> = Vec::new();
    for (index, item) in inputs.iter().enumerate() {
        let url = match item.url.as_deref() {
            Some(url) if !url.is_empty() => url.to_string(),
            _ => format!("inline/script-{}.js", index + 1),
        };
        let content = match &item.content {
            Value::String(text) => text.clone(),
            _ => String::new(),
        };
        let scan_text = if utf16_len(&content) > 200_000 {
            utf16_prefix(&content, 200_000).to_string()
        } else {
            content.clone()
        };
        let timing = timing_lookup
            .get(&normalize_url_key(&url))
            .or_else(|| timing_lookup.get(&strip_url_variant(&url)));

        let imports = extract_import_specifiers(&scan_text);
        let module_signals = ModuleSignals {
            import_count: imports.len(),
            dynamic_imports: count_matches(&scan_text, &DYN_IMPORT),
            requires: count_matches(&scan_text, &REQUIRE),
            exports: count_matches(&scan_text, &EXPORT),
        };
        let bundler = detect_bundler_name(&url, &scan_text);
        let framework_hints = detect_framework_hints(&url, &scan_text, stack_profile);
        let route_hints = extract_route_hints_from_url(&url);
        let startup_signals = detect_startup_signals(&url, &scan_text);
        let classification = classify_script_asset(
            &url,
            &scan_text,
            &bundler,
            &framework_hints,
            &startup_signals,
        );
        let bare = {
            let bare = get_bare_file_name(&url);
            if bare.is_empty() {
                format!("script-{}", index + 1)
            } else {
                bare
            }
        };
        let digest = hash_string(&url);
        let mut asset = ScriptAsset {
            id: format!(
                "chunk-{}-{}",
                sanitize_path_part(&bare, "script"),
                digest.chars().take(8).collect::<String>()
            ),
            url: url.clone(),
            file: sanitize_filename(&url),
            size: utf16_len(&content),
            transfer_size: timing
                .map(|t| {
                    if is_truthy(&t.transfer_size) {
                        js_number(&t.transfer_size)
                    } else {
                        0.0
                    }
                })
                .unwrap_or(0.0),
            start_time: timing
                .map(|t| match &t.start_time {
                    Value::Number(n) => n.as_f64().unwrap_or(0.0),
                    _ => 0.0,
                })
                .unwrap_or(0.0),
            duration: timing
                .map(|t| match &t.duration {
                    Value::Number(n) => n.as_f64().unwrap_or(0.0),
                    _ => 0.0,
                })
                .unwrap_or(0.0),
            imports,
            module_signals,
            bundler,
            framework_hints,
            route_hints,
            startup_signals,
            source_map_embedded: SOURCE_MAP.is_match(&scan_text),
            content,
            classification,
            score: 0.0,
            boundary_labels: Vec::new(),
            primary_boundary: String::new(),
            boundary_reasons: Vec::new(),
            boundary_details: Vec::new(),
        };
        asset.score = score_script_asset(&asset);
        assets.push(asset);
    }
    assets
}

fn is_truthy(value: &Value) -> bool {
    match value {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_f64().map(|f| f != 0.0 && !f.is_nan()).unwrap_or(false),
        Value::String(s) => !s.is_empty(),
        Value::Array(_) | Value::Object(_) => true,
    }
}

/// `countPropertyValues`: values keyed by the given property, falsy -> unknown.
pub fn count_property_values(items: &[ScriptAsset], key: &str) -> BTreeMap<String, usize> {
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    for item in items {
        let value = match key {
            "classification" => item.classification.clone(),
            "bundler" => item.bundler.clone(),
            _ => String::new(),
        };
        let value = if value.is_empty() { "unknown".to_string() } else { value };
        *counts.entry(value).or_insert(0) += 1;
    }
    counts
}

/// `countBoundaryLabels`.
pub fn count_boundary_labels(items: &[ScriptAsset]) -> BTreeMap<String, usize> {
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    for item in items {
        for label in &item.boundary_labels {
            *counts.entry(label.clone()).or_insert(0) += 1;
        }
    }
    counts
}

/// `countTaggedEntries`.
pub fn count_tagged_entries(items: &[ScriptAsset]) -> usize {
    items.iter().filter(|item| !item.boundary_labels.is_empty()).count()
}

/// `buildChunkSummary`.
pub fn build_chunk_summary(assets: &[ScriptAsset]) -> Value {
    let bundlers: Vec<String> = assets.iter().map(|a| a.bundler.clone()).collect();
    let bundlers_observed: Vec<String> = unique_strings(&bundlers)
        .into_iter()
        .filter(|b| b != "unknown")
        .collect();
    let mut source_map_embedded = 0usize;
    let mut dynamic_importers = 0usize;
    for asset in assets {
        if asset.source_map_embedded {
            source_map_embedded += 1;
        }
        if asset.module_signals.dynamic_imports > 0 {
            dynamic_importers += 1;
        }
    }
    serde_json::json!({
        "totalScripts": assets.len(),
        "bundlersObserved": bundlers_observed,
        "classifications": count_property_values(assets, "classification"),
        "boundaryLabels": count_boundary_labels(assets),
        "sourceMapEmbedded": source_map_embedded,
        "dynamicImporters": dynamic_importers,
        "labeledScripts": count_tagged_entries(assets),
    })
}

/// `stripChunkAsset`.
pub fn strip_chunk_asset(asset: &ScriptAsset) -> Value {
    serde_json::json!({
        "id": asset.id,
        "url": asset.url,
        "file": asset.file,
        "size": asset.size,
        "transferSize": js_number_value(asset.transfer_size),
        "startTime": js_number_value(asset.start_time),
        "duration": js_number_value(asset.duration),
        "classification": asset.classification,
        "bundler": asset.bundler,
        "frameworkHints": asset.framework_hints,
        "routeHints": asset.route_hints,
        "startupSignals": asset.startup_signals,
        "boundaryLabels": asset.boundary_labels,
        "primaryBoundary": asset.primary_boundary,
        "boundaryReasons": asset.boundary_reasons,
        "imports": asset.imports,
        "moduleSignals": asset.module_signals,
        "sourceMapEmbedded": asset.source_map_embedded,
        "score": js_number_value(asset.score),
    })
}

/// `findAssetByReference`.
pub fn find_asset_by_reference<'a>(
    reference: &str,
    assets: &'a [ScriptAsset],
) -> Option<&'a ScriptAsset> {
    let cleaned = clean_stack_reference(reference);
    if cleaned.is_empty() {
        return None;
    }
    let full = normalize_url_key(&cleaned);
    let bare = strip_url_variant(&cleaned);
    let file = get_bare_file_name(&cleaned);
    assets.iter().find(|asset| {
        asset.url == cleaned
            || normalize_url_key(&asset.url) == full
            || strip_url_variant(&asset.url) == bare
            || get_bare_file_name(&asset.url) == file
    })
}

/// A runtime origin: the manifest entry merged with the collected record,
/// then annotated. Kept as a JSON object because the JS copies whatever keys
/// the page supplied and every later step reads it with JS truthiness.
pub type RuntimeOrigin = Value;

/// JS truthiness for a JSON value.
pub fn js_truthy(value: &Value) -> bool {
    match value {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_f64().map(|f| f != 0.0 && !f.is_nan()).unwrap_or(false),
        Value::String(s) => !s.is_empty(),
        Value::Array(_) | Value::Object(_) => true,
    }
}

fn field<'a>(entry: &'a Value, key: &str) -> Option<&'a Value> {
    entry.get(key).filter(|v| js_truthy(v))
}

/// The JS `entry[key] || ''` string read.
pub fn field_str(entry: &Value, key: &str) -> String {
    match field(entry, key) {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Number(n)) => crate::jsnumber::js_number_to_string(n.as_f64().unwrap_or(f64::NAN)),
        _ => String::new(),
    }
}

/// The JS truthy-number read (`entry[key] || 0`).
pub fn field_number(entry: &Value, key: &str) -> f64 {
    match field(entry, key) {
        Some(value) => js_number(value),
        None => 0.0,
    }
}

/// `String(value)`: the JavaScript string coercion the panel uses whenever a
/// reference value is interpolated into text.
pub fn value_text(value: &Value) -> String {
    match value {
        Value::String(s) => s.clone(),
        Value::Null => String::new(),
        other => crate::jsnumber::js_number_to_string(js_number(other)),
    }
}

/// `buildRuntimeOrigins`.
pub fn build_runtime_origins(
    entries: &[Value],
    manifest: &[Value],
    assets: &[ScriptAsset],
) -> Vec<RuntimeOrigin> {
    let mut manifest_by_id: BTreeMap<String, &Value> = BTreeMap::new();
    for item in manifest {
        if let Some(id) = item.get("id").and_then(|v| v.as_str()) {
            manifest_by_id.insert(id.to_string(), item);
        }
    }
    let mut origins: Vec<RuntimeOrigin> = Vec::new();
    for source in entries {
        let mut merged = serde_json::Map::new();
        let id = source.get("id").and_then(|v| v.as_str()).unwrap_or_default();
        if let Some(manifest_item) = manifest_by_id.get(id).and_then(|v| v.as_object()) {
            for (key, value) in manifest_item {
                merged.insert(key.clone(), value.clone());
            }
        }
        if let Some(map) = source.as_object() {
            for (key, value) in map {
                merged.insert(key.clone(), value.clone());
            }
        }
        let mut item = Value::Object(merged);
        let stack = field_str(&item, "stack");
        let stack_refs = extract_stack_refs(&stack);
        let mut related: Vec<String> = Vec::new();
        let direct_reference = match field(&item, "url") {
            Some(url) => url.clone(),
            None => item.get("objectUrl").cloned().unwrap_or(Value::Null),
        };
        if let Some(asset) = find_asset_by_reference(&value_text(&direct_reference), assets) {
            related.push(asset.id.clone());
        }
        for reference in &stack_refs {
            if let Some(asset) = find_asset_by_reference(reference, assets) {
                related.push(asset.id.clone());
            }
        }
        let related = unique_strings(&related);
        if let Some(map) = item.as_object_mut() {
            map.insert(
                "stackRefs".to_string(),
                serde_json::to_value(&stack_refs).unwrap(),
            );
            map.insert(
                "relatedChunks".to_string(),
                serde_json::to_value(&related).unwrap(),
            );
        }
        let origin_type = determine_runtime_origin_type(&item);
        let score = score_runtime_entry(&item);
        if let Some(map) = item.as_object_mut() {
            map.insert("originType".to_string(), Value::String(origin_type));
            map.insert("score".to_string(), js_number_value(score));
        }
        origins.push(item);
    }
    origins
}

/// `determineRuntimeOriginType`.
pub fn determine_runtime_origin_type(entry: &Value) -> String {
    if field(entry, "blobId").is_some() {
        return "blob-derived".to_string();
    }
    let kind = field_str(entry, "kind");
    match kind.as_str() {
        "script-injection" => return "inline-script".to_string(),
        "worker" | "shared-worker" | "service-worker" => return "worker-bootstrap".to_string(),
        "wasm" => return "wasm-module".to_string(),
        _ => {}
    }
    if entry
        .get("relatedChunks")
        .and_then(|v| v.as_array())
        .map(|v| !v.is_empty())
        .unwrap_or(false)
    {
        return "bundle-linked".to_string();
    }
    let url = field_str(entry, "url").to_lowercase();
    if !url.is_empty() && url.starts_with("blob:") {
        return "object-url".to_string();
    }
    if !url.is_empty() && url.starts_with("data:") {
        return "data-url".to_string();
    }
    "runtime-generated".to_string()
}

/// `scoreRuntimeEntry`.
pub fn score_runtime_entry(entry: &Value) -> f64 {
    let kind = field_str(entry, "kind");
    let mut score = match kind.as_str() {
        "eval" | "function" => 46.0,
        "wasm" => 42.0,
        "script-injection" => 38.0,
        _ => 28.0,
    };
    if let Some(chunks) = entry.get("relatedChunks").and_then(|v| v.as_array()) {
        if !chunks.is_empty() {
            score += chunks.len() as f64 * 8.0;
        }
    }
    if field(entry, "blobId").is_some() {
        score += 10.0;
    }
    if matches!(entry.get("text"), Some(Value::String(_))) {
        score += 6.0;
    }
    if field(entry, "timestamp").is_some() {
        score += 4.0;
    }
    score
}

/// `stripRuntimeEntry`.
pub fn strip_runtime_entry(entry: &Value) -> Value {
    let blob_id = match field(entry, "blobId") {
        Some(value) => value.clone(),
        None => Value::Null,
    };
    let related = entry
        .get("relatedChunks")
        .cloned()
        .unwrap_or_else(|| Value::Array(Vec::new()));
    let stack_refs = entry
        .get("stackRefs")
        .cloned()
        .unwrap_or_else(|| Value::Array(Vec::new()));
    serde_json::json!({
        "id": entry.get("id").cloned().unwrap_or(Value::Null),
        "kind": entry.get("kind").cloned().unwrap_or(Value::Null),
        "file": field_str(entry, "file"),
        "source": field_str(entry, "source"),
        "url": field_str(entry, "url"),
        "objectUrl": field_str(entry, "objectUrl"),
        "blobId": blob_id,
        "originType": entry.get("originType").cloned().unwrap_or(Value::Null),
        "relatedChunks": related,
        "stackRefs": stack_refs,
        "timestamp": js_number_value(field_number(entry, "timestamp")),
        "mimeType": field_str(entry, "mimeType"),
        "size": js_number_value(field_number(entry, "size")),
        "truncated": js_truthy(entry.get("truncated").unwrap_or(&Value::Null)),
        "note": field_str(entry, "note"),
        "score": js_number_value(field_number(entry, "score")),
    })
}

/// `countPropertyValues` over runtime origins.
fn count_origin_property(origins: &[RuntimeOrigin], key: &str) -> BTreeMap<String, usize> {
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    for item in origins {
        let value = field_str(item, key);
        let value = if value.is_empty() { "unknown".to_string() } else { value };
        *counts.entry(value).or_insert(0) += 1;
    }
    counts
}

/// `buildRuntimeSummary`.
pub fn build_runtime_summary(origins: &[RuntimeOrigin]) -> Value {
    let linked = origins
        .iter()
        .filter(|item| {
            item.get("relatedChunks")
                .and_then(|v| v.as_array())
                .map(|v| !v.is_empty())
                .unwrap_or(false)
        })
        .count();
    let labeled = origins
        .iter()
        .filter(|item| {
            item.get("boundaryLabels")
                .and_then(|v| v.as_array())
                .map(|v| !v.is_empty())
                .unwrap_or(false)
        })
        .count();
    let mut boundary_labels: BTreeMap<String, usize> = BTreeMap::new();
    for item in origins {
        for label in item
            .get("boundaryLabels")
            .and_then(|v| v.as_array())
            .map(|v| v.to_vec())
            .unwrap_or_default()
        {
            if let Some(label) = label.as_str() {
                *boundary_labels.entry(label.to_string()).or_insert(0) += 1;
            }
        }
    }
    serde_json::json!({
        "totalRuntimeEntries": origins.len(),
        "kinds": count_origin_property(origins, "kind"),
        "originTypes": count_origin_property(origins, "originType"),
        "boundaryLabels": boundary_labels,
        "linkedToChunks": linked,
        "labeledEntries": labeled,
    })
}

/// JS number rendering for diagnostics.
pub fn render_number(value: f64) -> String {
    js_number_to_string(value)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn fixture() -> Value {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/panel/assets-oracle.json"
        );
        serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
    }

    /// Keep only the keys the oracle template carries: the prepared-asset
    /// oracle was captured before the boundary pass, so it has no boundary
    /// keys on the entries (the JS object gains them later).
    fn project(value: &Value, template: &Value) -> Value {
        match (value, template) {
            (Value::Object(got), Value::Object(want)) => Value::Object(
                want.iter()
                    .filter_map(|(key, tpl)| got.get(key).map(|v| (key.clone(), project(v, tpl))))
                    .collect(),
            ),
            (Value::Array(got), Value::Array(want)) => Value::Array(
                got.iter()
                    .enumerate()
                    .filter_map(|(i, v)| want.get(i).map(|tpl| project(v, tpl)))
                    .collect(),
            ),
            _ => value.clone(),
        }
    }

    fn inputs() -> (Vec<ScriptInput>, Value, Vec<Value>, Vec<Value>) {
        let fx = fixture();
        let scripts: Vec<ScriptInput> =
            serde_json::from_value(fx["input"]["scriptFixture"].clone()).unwrap();
        let recon = fx["input"]["reconFixture"].clone();
        let entries = fx["input"]["runtimeEntries"].as_array().unwrap().clone();
        let manifest = fx["input"]["runtimeManifest"].as_array().unwrap().clone();
        (scripts, recon, entries, manifest)
    }

    #[test]
    fn helpers_match_oracles() {
        let fx = fixture();
        let exp = &fx["expected"];
        for (i, value) in exp["normalizeUrlKey"].as_array().unwrap().iter().enumerate() {
            let input = ["https://x/y?a=1#f", "https://x/y#f", "", ""][i];
            assert_eq!(normalize_url_key(input), value.as_str().unwrap(), "normalizeUrlKey {i}");
        }
        for (i, value) in exp["stripUrlVariant"].as_array().unwrap().iter().enumerate() {
            let input = ["https://x/y?a=1#f", "https://x/y", ""][i];
            assert_eq!(strip_url_variant(input), value.as_str().unwrap(), "stripUrlVariant {i}");
        }
        for (i, value) in exp["getBareFileName"].as_array().unwrap().iter().enumerate() {
            let input = ["/a/b/c.js", "https://x/y/z.js?v=1", "plain.js", "", "a\\b\\c.js"][i];
            assert_eq!(get_bare_file_name(input), value.as_str().unwrap(), "getBareFileName {i}");
        }
        for (i, value) in exp["cleanStackReference"].as_array().unwrap().iter().enumerate() {
            let input = [
                "https://x/a.js:10:5",
                "https://x/a.js:10",
                "https://x/a.js),",
                "  https://x/a.js  ",
                "",
            ][i];
            assert_eq!(clean_stack_reference(input), value.as_str().unwrap(), "cleanStackReference {i}");
        }
        let stack_inputs = [
            "Error\n    at f (https://x/a.js:1:2)\n    at g (blob:https://x/b)",
            "no refs",
        ];
        for (i, value) in exp["extractStackRefs"].as_array().unwrap().iter().take(2).enumerate() {
            assert_eq!(
                serde_json::to_value(extract_stack_refs(stack_inputs[i])).unwrap(),
                *value,
                "extractStackRefs {i}"
            );
        }
        let bundler_inputs = [
            ("https://x/app.js", "var x = __webpack_require__(1);"),
            ("https://x/_next/static/chunks/main.js", ""),
            ("https://x/app.js", "parcelRequire(\"a\")"),
            ("https://x/app.js", "if (import.meta.hot) {}"),
            ("https://x/@vite/client", ""),
            ("https://x/app.js", "console.log(1)"),
        ];
        for (i, value) in exp["detectBundlerName"].as_array().unwrap().iter().enumerate() {
            let (u, c) = bundler_inputs[i];
            assert_eq!(detect_bundler_name(u, c), value.as_str().unwrap(), "bundler {i}");
        }
        let hint_inputs = [
            ("https://x/app.js", "ReactDOM.hydrate(x)"),
            ("https://x/app.js", "__NEXT_DATA__"),
            ("https://x/app.js", "createApp({})"),
            ("https://x/app.js", "ng-version"),
            ("https://x/app.js", "SvelteKit"),
            ("https://x/app.js", "plain"),
        ];
        for (i, value) in exp["detectFrameworkHints"].as_array().unwrap().iter().enumerate() {
            let (u, c) = hint_inputs[i];
            assert_eq!(
                serde_json::to_value(detect_framework_hints(u, c, None)).unwrap(),
                *value,
                "frameworkHints {i}"
            );
        }
        let profile = json!({"technologies": [{"name": "jQuery"}, {"name": "React"}, null, {}]});
        assert_eq!(
            serde_json::to_value(detect_framework_hints("https://x/app.js", "plain", Some(&profile))).unwrap(),
            exp["detectFrameworkHintsWithProfile"]
        );
        let signal_inputs = [
            "ReactDOM.hydrate()",
            "navigator.serviceWorker.register(\"/sw.js\")",
            "new Worker(\"w.js\")",
            "WebAssembly.instantiate(b)",
            "apolloClient",
            "import(\"./x\")",
            "//# sourceMappingURL=data:application/json;base64,AA",
            "__webpack_require__.e(1)",
            "history.pushState({}, \"\", \"/a\")",
            "nothing here",
        ];
        for (i, value) in exp["detectStartupSignals"].as_array().unwrap().iter().enumerate() {
            assert_eq!(
                serde_json::to_value(detect_startup_signals("https://x/app.js", signal_inputs[i])).unwrap(),
                *value,
                "startupSignals {i}"
            );
        }
        let route_inputs = [
            "https://x/static/js/app.js",
            "https://x/account/settings/profile.js",
            "https://x/chunks/abcdef1234.js",
            "https://x/a/b/c.js",
            "https://x/",
            "not a url",
        ];
        for (i, value) in exp["extractRouteHintsFromUrl"].as_array().unwrap().iter().enumerate() {
            assert_eq!(
                serde_json::to_value(extract_route_hints_from_url(route_inputs[i])).unwrap(),
                *value,
                "routeHints {i}"
            );
        }
        let import_inputs = [
            "import a from \"react\";import(\"./dyn.js\");const b = require(\"lodash\");",
            "import { x } from \"./x.js\"; import \"./side.css\";",
            "require(\"a\");require(\"a\");",
        ];
        for (i, value) in exp["extractImportSpecifiers"].as_array().unwrap().iter().enumerate() {
            assert_eq!(
                serde_json::to_value(extract_import_specifiers(import_inputs[i])).unwrap(),
                *value,
                "imports {i}"
            );
        }
        let classify_inputs: Vec<(String, String, Vec<String>, Vec<String>)> = vec![
            ("https://x/runtime.js".into(), "plain".into(), vec![], vec![]),
            ("https://x/app.js".into(), "plain".into(), vec![], vec!["chunk-loader".into()]),
            ("https://x/vendor.js".into(), "plain".into(), vec![], vec![]),
            ("https://x/app.js".into(), "plain".into(), vec!["React".into()], vec![]),
            ("https://x/app.js".into(), "plain".into(), vec![], vec!["hydration".into()]),
            ("https://x/app.js".into(), "plain".into(), vec![], vec!["router".into()]),
            ("https://x/app.js".into(), "plain".into(), vec![], vec![]),
            ("https://x/account/profile.js".into(), "plain".into(), vec![], vec![]),
        ];
        let bundlers = ["unknown", "webpack", "unknown", "unknown", "webpack", "unknown", "unknown", "unknown"];
        for (i, value) in exp["classifyScriptAsset"].as_array().unwrap().iter().enumerate() {
            let (u, c, f, s) = &classify_inputs[i];
            assert_eq!(
                classify_script_asset(u, c, bundlers[i], f, s),
                value.as_str().unwrap(),
                "classify {i}"
            );
        }
    }

    #[test]
    fn pipeline_matches_oracle() {
        let fx = fixture();
        let exp = &fx["expected"];
        let (scripts, recon, entries, manifest) = inputs();

        let prepared = prepare_script_assets(&scripts, Some(&recon));
        assert_eq!(
            project(&serde_json::to_value(&prepared).unwrap(), &exp["prepareScriptAssets"]),
            exp["prepareScriptAssets"],
            "prepareScriptAssets"
        );
        let prepared_no_recon = prepare_script_assets(&scripts, None);
        assert_eq!(
            project(
                &serde_json::to_value(&prepared_no_recon).unwrap(),
                &exp["prepareScriptAssetsNoRecon"]
            ),
            exp["prepareScriptAssetsNoRecon"],
            "prepareScriptAssets without recon"
        );
        assert_eq!(build_chunk_summary(&prepared), exp["buildChunkSummary"], "chunk summary");
        assert_eq!(
            strip_chunk_asset(&prepared[0]),
            exp["stripChunkAsset"],
            "stripChunkAsset"
        );

        let origins = build_runtime_origins(&entries, &manifest, &prepared);
        let keys = [
            "id",
            "kind",
            "file",
            "source",
            "url",
            "objectUrl",
            "blobId",
            "stackRefs",
            "relatedChunks",
            "originType",
            "timestamp",
            "mimeType",
            "size",
            "truncated",
            "note",
            "score",
        ];
        let got: Vec<Value> = origins
            .iter()
            .map(|o| {
                let mut picked = serde_json::Map::new();
                for key in keys {
                    picked.insert(
                        key.to_string(),
                        o.get(key).cloned().unwrap_or(Value::Null),
                    );
                }
                Value::Object(picked)
            })
            .collect();
        let want: Vec<Value> = exp["buildRuntimeOrigins"]
            .as_array()
            .unwrap()
            .iter()
            .map(|o| {
                let mut picked = serde_json::Map::new();
                for key in keys {
                    picked.insert(
                        key.to_string(),
                        o.get(key).cloned().unwrap_or(Value::Null),
                    );
                }
                Value::Object(picked)
            })
            .collect();
        assert_eq!(got, want, "runtime origins");
        assert_eq!(
            build_runtime_summary(&origins),
            exp["buildRuntimeSummary"],
            "runtime summary"
        );
        assert_eq!(strip_runtime_entry(&origins[0]), exp["stripRuntimeEntry"], "stripRuntimeEntry");
    }
}
