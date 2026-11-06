//! The page-profile analyzer from `stack-profile.js`: technology and trait
//! detection over a captured page snapshot, plus the capture strategy derived
//! from it.
//!
//! The page world collects the snapshot - only it can read the page's globals
//! and DOM - and the analysis runs here, so the detector vocabulary and its
//! scoring live with the rest of the engine's scanning logic instead of in a
//! page-world bundle. `analyze` is pure apart from `generatedAt`, which comes
//! from the same clock seam as `util::iso8601_now`.

use regex::Regex;
use serde_json::{json, Map, Value};
use std::sync::LazyLock;

use crate::panel::assets::js_truthy;
use crate::panel::text::js_number_value;
use crate::util::now_unix_millis;

/// Reported by the profile, mirroring the page-world module's `VERSION`.
pub const VERSION: &str = "1.0.0";

static REACT_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)/react(?:-dom)?(?:@|\.|/)").unwrap());
static CHUNK_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)\.chunk\.[^/?#]+$").unwrap());
static WEBPACK_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)webpack(?:-|\.|/)").unwrap());
static HASHED_ASSETS_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)/assets/.+\.[a-f0-9]{6,}\.(?:js|css)").unwrap());
static PARCEL_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)parcel").unwrap());
static APOLLO_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)apollo").unwrap());
static RELAY_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)relay").unwrap());

/// `Math.max(min, Math.min(max, value))`.
fn clamp(value: f64, min: f64, max: f64) -> f64 {
    min.max(max.min(value))
}

/// `String(value || '').toLowerCase()`.
fn lower(value: Option<&Value>) -> String {
    match value {
        Some(v) if js_truthy(v) => match v {
            Value::String(s) => s.to_lowercase(),
            other => other.to_string().to_lowercase(),
        },
        _ => String::new(),
    }
}

/// `Array.isArray(list) ? list.filter(Boolean).map(String) : []`.
fn normalize_list(value: Option<&Value>) -> Vec<String> {
    match value.and_then(|v| v.as_array()) {
        Some(items) => items
            .iter()
            .filter(|item| js_truthy(item))
            .map(|item| match item {
                Value::String(s) => s.clone(),
                other => other.to_string(),
            })
            .collect(),
        None => Vec::new(),
    }
}

/// `addUnique`: trimmed, non-empty, first occurrence wins.
fn add_unique(list: &mut Vec<String>, value: &str) {
    let value = value.trim();
    if !value.is_empty() && !list.iter().any(|item| item == value) {
        list.push(value.to_string());
    }
}

fn any_regex(list: &[String], pattern: &Regex) -> bool {
    list.iter().any(|item| pattern.is_match(item))
}

/// `hasUrl`: lowercased substring search.
fn has_url(urls: &[String], needle: &str) -> bool {
    let needle = needle.to_lowercase();
    urls.iter().any(|url| url.to_lowercase().contains(&needle))
}

/// A snapshot field, treating a missing or non-object parent as `{}`.
fn field<'a>(parent: Option<&'a Value>, key: &str) -> Option<&'a Value> {
    parent.and_then(|p| p.get(key))
}

/// `(x || 0) > n`, the counter comparisons the detector table uses.
fn over(parent: Option<&Value>, key: &str, n: f64) -> bool {
    field(parent, key).and_then(|v| v.as_f64()).unwrap_or(0.0) > n
}

/// `x || 0` for the counter comparisons written without a guard.
fn num(parent: Option<&Value>, key: &str) -> f64 {
    field(parent, key).and_then(|v| v.as_f64()).unwrap_or(0.0)
}

fn flag(parent: Option<&Value>, key: &str) -> bool {
    field(parent, key).map(js_truthy).unwrap_or(false)
}

/// A registered technology: `{name, category, confidence, evidence}`.
struct Tech {
    name: String,
    category: &'static str,
    confidence: f64,
    evidence: Vec<String>,
}

/// The `tech()` closure: register, or merge into an existing entry by raising
/// the confidence and appending the signal.
fn tech(
    techs: &mut Vec<Tech>,
    name: &str,
    category: &'static str,
    confidence: f64,
    signal: Option<&str>,
) {
    let confidence = if confidence == 0.0 { 0.5 } else { confidence };
    if let Some(item) = techs.iter_mut().find(|item| item.name == name) {
        item.confidence = item.confidence.max(confidence);
        if let Some(signal) = signal {
            add_unique(&mut item.evidence, signal);
        }
        return;
    }
    let mut evidence = Vec::new();
    if let Some(signal) = signal {
        add_unique(&mut evidence, signal);
    }
    techs.push(Tech {
        name: name.to_string(),
        category,
        confidence,
        evidence,
    });
}

/// The `trait()` closure.
fn trait_hit(traits: &mut Vec<(String, Vec<String>)>, name: &str, signal: Option<&str>) {
    let entry = match traits.iter_mut().find(|(key, _)| key == name) {
        Some(entry) => entry,
        None => {
            traits.push((name.to_string(), Vec::new()));
            traits.last_mut().expect("just pushed")
        }
    };
    if let Some(signal) = signal {
        add_unique(&mut entry.1, signal);
    }
}

/// `createDefaultStrategy()`.
pub fn default_strategy() -> Map<String, Value> {
    let mut strategy = Map::new();
    strategy.insert("profile".into(), json!("generic-app"));
    strategy.insert("bootDelayMs".into(), json!(1200));
    strategy.insert("networkQuietMs".into(), json!(1000));
    strategy.insert("mutationQuietMs".into(), json!(1200));
    strategy.insert("runtimeQuietMs".into(), json!(1000));
    strategy.insert("socketQuietMs".into(), json!(2200));
    strategy.insert("workerGraceMs".into(), json!(1200));
    strategy.insert("maxCaptureMs".into(), json!(18000));
    strategy.insert("preferHydratedDom".into(), json!(false));
    strategy.insert("captureFrameworkState".into(), json!(false));
    strategy.insert("captureGraphQLOps".into(), json!(false));
    strategy.insert("prioritizeSourceMaps".into(), json!(false));
    strategy.insert("reasons".into(), json!(["Generic adaptive profile"]));
    strategy
}

fn strategy_num(strategy: &Map<String, Value>, key: &str) -> f64 {
    strategy.get(key).and_then(|v| v.as_f64()).unwrap_or(0.0)
}

fn set_num(strategy: &mut Map<String, Value>, key: &str, value: f64) {
    strategy.insert(key.to_string(), js_number_value(value));
}

/// `buildStrategy(profile)`: the capture timings the page world reads.
fn build_strategy(profile: &Value) -> Map<String, Value> {
    let mut strategy = default_strategy();
    let technologies = profile
        .get("technologies")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    let traits = normalize_list(profile.get("traits"));
    let mut reasons: Vec<String> = Vec::new();

    let has_tech = |name: &str| {
        technologies
            .iter()
            .any(|item| item.get("name").and_then(|v| v.as_str()) == Some(name))
    };
    let has_trait = |name: &str| traits.iter().any(|item| item == name);
    let profile_name = |strategy: &Map<String, Value>| {
        strategy
            .get("profile")
            .and_then(|v| v.as_str())
            .unwrap_or("generic-app")
            .to_string()
    };

    if has_tech("Next.js")
        || has_tech("Nuxt")
        || has_tech("Remix")
        || has_tech("Astro")
        || has_tech("SvelteKit")
    {
        strategy.insert("profile".into(), json!("spa-hydration"));
        set_num(&mut strategy, "bootDelayMs", 1600.0);
        set_num(&mut strategy, "networkQuietMs", 1500.0);
        set_num(&mut strategy, "mutationQuietMs", 1800.0);
        set_num(&mut strategy, "runtimeQuietMs", 1400.0);
        strategy.insert("preferHydratedDom".into(), json!(true));
        strategy.insert("captureFrameworkState".into(), json!(true));
        strategy.insert("prioritizeSourceMaps".into(), json!(true));
        add_unique(
            &mut reasons,
            "Hydration-oriented framework markers detected",
        );
    }

    if has_trait("graphql-heavy") || has_tech("Apollo") || has_tech("Relay") || has_tech("GraphQL")
    {
        if profile_name(&strategy) == "generic-app" {
            strategy.insert("profile".into(), json!("graphql-app"));
        }
        strategy.insert("captureGraphQLOps".into(), json!(true));
        let quiet = strategy_num(&strategy, "networkQuietMs").max(1600.0);
        set_num(&mut strategy, "networkQuietMs", quiet);
        add_unique(&mut reasons, "GraphQL traffic detected");
    }

    if has_trait("socket-heavy") {
        strategy.insert("profile".into(), json!("socket-streaming"));
        set_num(&mut strategy, "socketQuietMs", 3600.0);
        let max = strategy_num(&strategy, "maxCaptureMs").max(22000.0);
        set_num(&mut strategy, "maxCaptureMs", max);
        add_unique(&mut reasons, "Socket or SSE activity detected");
    }

    if has_trait("worker-heavy") || has_trait("wasm-heavy") {
        strategy.insert("profile".into(), json!("worker-runtime-heavy"));
        set_num(&mut strategy, "workerGraceMs", 2200.0);
        set_num(&mut strategy, "runtimeQuietMs", 1800.0);
        let max = strategy_num(&strategy, "maxCaptureMs").max(24000.0);
        set_num(&mut strategy, "maxCaptureMs", max);
        add_unique(&mut reasons, "Worker or WebAssembly activity detected");
    }

    if has_tech("WordPress") || has_tech("Shopify") {
        if profile_name(&strategy) == "generic-app" {
            strategy.insert("profile".into(), json!("static-site"));
        }
        let network = strategy_num(&strategy, "networkQuietMs").min(1100.0);
        set_num(&mut strategy, "networkQuietMs", network);
        let mutation = strategy_num(&strategy, "mutationQuietMs").min(1000.0);
        set_num(&mut strategy, "mutationQuietMs", mutation);
        add_unique(&mut reasons, "CMS or commerce platform markers detected");
    }

    if has_tech("Webpack") || has_tech("Vite") || has_tech("Parcel") {
        strategy.insert("prioritizeSourceMaps".into(), json!(true));
        add_unique(&mut reasons, "Bundler markers detected");
    }

    if !reasons.is_empty() {
        strategy.insert("reasons".into(), json!(reasons));
    }
    strategy
}

/// `analyze(snapshot)`: the technology/trait profile plus its capture strategy.
pub fn analyze(snapshot: &Value) -> Value {
    let urls: Vec<String> = normalize_list(snapshot.get("resourceUrls"))
        .into_iter()
        .chain(normalize_list(snapshot.get("scriptUrls")))
        .collect();
    let globals = snapshot.get("globals");
    let dom = snapshot.get("dom");
    let network = snapshot.get("network");
    let runtime = snapshot.get("runtime");
    let activity = snapshot.get("activity");

    let mut techs: Vec<Tech> = Vec::new();
    let mut traits: Vec<(String, Vec<String>)> = Vec::new();

    if flag(globals, "nextData") || flag(dom, "hasNextRoot") || has_url(&urls, "/_next/") {
        tech(
            &mut techs,
            "Next.js",
            "framework",
            0.97,
            Some(if flag(globals, "nextData") {
                "window.__NEXT_DATA__"
            } else {
                "/_next/ assets"
            }),
        );
    }
    if flag(globals, "reactDevtoolsHook")
        || has_url(&urls, "react-dom")
        || any_regex(&urls, &REACT_RE)
    {
        tech(
            &mut techs,
            "React",
            "library",
            0.86,
            Some(if flag(globals, "reactDevtoolsHook") {
                "__REACT_DEVTOOLS_GLOBAL_HOOK__"
            } else {
                "React bundle markers"
            }),
        );
    }
    if flag(globals, "nuxt") || flag(dom, "hasNuxtRoot") || has_url(&urls, "/_nuxt/") {
        tech(
            &mut techs,
            "Nuxt",
            "framework",
            0.95,
            Some(if flag(dom, "hasNuxtRoot") {
                "#__nuxt"
            } else {
                "/_nuxt/ assets"
            }),
        );
    } else if flag(globals, "vue") || flag(globals, "vueDevtoolsHook") || flag(dom, "hasVueApp") {
        tech(
            &mut techs,
            "Vue",
            "framework",
            0.84,
            Some(if flag(globals, "vueDevtoolsHook") {
                "__VUE_DEVTOOLS_GLOBAL_HOOK__"
            } else {
                "Vue mount markers"
            }),
        );
    }
    if flag(globals, "angular") || flag(dom, "hasNgVersion") {
        tech(
            &mut techs,
            "Angular",
            "framework",
            0.85,
            Some(if flag(dom, "hasNgVersion") {
                "[ng-version]"
            } else {
                "Angular global markers"
            }),
        );
    }
    if flag(globals, "svelteKit")
        || flag(dom, "hasSvelteData")
        || has_url(&urls, "/_app/immutable/")
    {
        tech(
            &mut techs,
            "SvelteKit",
            "framework",
            0.9,
            Some(if flag(globals, "svelteKit") {
                "__SVELTEKIT_APP_VERSION__"
            } else {
                "SvelteKit asset markers"
            }),
        );
    }
    if flag(dom, "hasAstroIsland") || has_url(&urls, "/_astro/") {
        tech(
            &mut techs,
            "Astro",
            "framework",
            0.9,
            Some(if flag(dom, "hasAstroIsland") {
                "<astro-island>"
            } else {
                "/_astro/ assets"
            }),
        );
    }
    if flag(globals, "remix") || flag(dom, "hasRemixData") {
        tech(
            &mut techs,
            "Remix",
            "framework",
            0.88,
            Some(if flag(globals, "remix") {
                "__remixContext"
            } else {
                "Remix DOM markers"
            }),
        );
    }

    if flag(globals, "webpackChunk")
        || flag(globals, "webpackJsonp")
        || any_regex(&urls, &CHUNK_RE)
        || any_regex(&urls, &WEBPACK_RE)
    {
        tech(
            &mut techs,
            "Webpack",
            "bundler",
            0.88,
            Some(if flag(globals, "webpackChunk") {
                "webpackChunk* global"
            } else {
                "Chunk naming"
            }),
        );
    }
    if flag(globals, "vitePreamble") || has_url(&urls, "/@vite/client") {
        tech(
            &mut techs,
            "Vite",
            "bundler",
            0.95,
            Some(if flag(globals, "vitePreamble") {
                "__vite_plugin_react_preamble_installed__"
            } else {
                "/@vite/client"
            }),
        );
    } else if any_regex(&urls, &HASHED_ASSETS_RE) {
        tech(
            &mut techs,
            "Vite",
            "bundler",
            0.72,
            Some("Hashed /assets/ bundles"),
        );
    }
    if any_regex(&urls, &PARCEL_RE) {
        tech(
            &mut techs,
            "Parcel",
            "bundler",
            0.67,
            Some("Parcel URL marker"),
        );
    }

    let generator = field(dom, "metaGenerator").map(|v| lower(Some(v)));
    let generator_is_wordpress = generator
        .as_deref()
        .map(|value| value.contains("wordpress"))
        .unwrap_or(false);
    if generator_is_wordpress || has_url(&urls, "/wp-content/") || has_url(&urls, "/wp-includes/") {
        tech(
            &mut techs,
            "WordPress",
            "platform",
            0.94,
            Some(if generator_is_wordpress {
                "generator meta tag"
            } else {
                "wp-content assets"
            }),
        );
    }
    if flag(globals, "shopify")
        || flag(dom, "hasShopify")
        || has_url(&urls, "cdn.shopify.com")
        || has_url(&urls, "/shopifycloud/")
    {
        tech(
            &mut techs,
            "Shopify",
            "platform",
            0.95,
            Some(if flag(globals, "shopify") {
                "window.Shopify"
            } else {
                "Shopify asset markers"
            }),
        );
    }

    if over(network, "graphqlCount", 0.0) {
        tech(
            &mut techs,
            "GraphQL",
            "protocol",
            0.9,
            Some("GraphQL requests observed"),
        );
    }
    let endpoints = normalize_list(field(network, "graphqlEndpoints"));
    if flag(globals, "apolloClient")
        || flag(globals, "apolloState")
        || any_regex(&endpoints, &APOLLO_RE)
    {
        tech(
            &mut techs,
            "Apollo",
            "data",
            0.82,
            Some(if flag(globals, "apolloClient") {
                "__APOLLO_CLIENT__"
            } else {
                "Apollo/GraphQL markers"
            }),
        );
    }
    if flag(globals, "relay") || any_regex(&endpoints, &RELAY_RE) {
        tech(
            &mut techs,
            "Relay",
            "data",
            0.76,
            Some(if flag(globals, "relay") {
                "__RELAY_DEVTOOLS_HOOK__"
            } else {
                "Relay markers"
            }),
        );
    }

    if over(runtime, "wasmCount", 0.0) {
        tech(
            &mut techs,
            "WebAssembly",
            "runtime",
            0.88,
            Some("WASM bytes captured"),
        );
    }
    if flag(globals, "serviceWorkerController") || over(runtime, "serviceWorkerCount", 0.0) {
        tech(
            &mut techs,
            "Service Worker",
            "runtime",
            0.8,
            Some("serviceWorker activity"),
        );
    }

    if flag(globals, "nextData")
        || flag(dom, "hasNuxtRoot")
        || flag(dom, "hasVueApp")
        || flag(dom, "hasSvelteData")
        || flag(dom, "hasRemixData")
        || flag(dom, "hasAstroIsland")
    {
        trait_hit(
            &mut traits,
            "spa-hydration",
            Some("Framework hydration markers"),
        );
    }
    if over(dom, "mutationCount", 20.0) {
        trait_hit(
            &mut traits,
            "dynamic-dom",
            Some("Sustained DOM mutation activity"),
        );
    }
    if over(network, "graphqlCount", 0.0) {
        trait_hit(
            &mut traits,
            "graphql-heavy",
            Some("GraphQL endpoints observed"),
        );
    }
    if over(network, "websocketCount", 0.0)
        || over(network, "sseCount", 0.0)
        || over(activity, "openSockets", 0.0)
    {
        trait_hit(
            &mut traits,
            "socket-heavy",
            Some("WebSocket or SSE activity"),
        );
    }
    if over(runtime, "workerCount", 0.0) {
        trait_hit(&mut traits, "worker-heavy", Some("Worker runtime observed"));
    }
    if over(runtime, "wasmCount", 0.0) {
        trait_hit(
            &mut traits,
            "wasm-heavy",
            Some("WebAssembly runtime observed"),
        );
    }
    if num(network, "fetchCount") + num(network, "xhrCount") > 10.0 {
        trait_hit(&mut traits, "api-heavy", Some("High XHR/fetch volume"));
    }
    if over(runtime, "runtimeCount", 6.0) {
        trait_hit(
            &mut traits,
            "runtime-generated-code",
            Some("In-memory code generation observed"),
        );
    }
    if num(dom, "scriptCount") <= 6.0
        && num(network, "fetchCount") <= 2.0
        && num(network, "xhrCount") <= 1.0
    {
        trait_hit(
            &mut traits,
            "static-ish",
            Some("Low script and API activity"),
        );
    }

    if techs.is_empty() {
        tech(
            &mut techs,
            "Generic Web App",
            "profile",
            0.45,
            Some("Fallback profile"),
        );
    }

    // `localeCompare` orders every name in this fixed vocabulary the same way a
    // code-unit comparison does; `tests/stack_profile_test.rs` pins that.
    techs.sort_by(|left, right| {
        right
            .confidence
            .partial_cmp(&left.confidence)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| left.name.cmp(&right.name))
    });
    let mut trait_names: Vec<String> = traits.iter().map(|(name, _)| name.clone()).collect();
    trait_names.sort();

    let mut evidence_technologies = Map::new();
    for item in &techs {
        evidence_technologies.insert(item.name.clone(), json!(item.evidence));
    }
    let mut evidence_traits = Map::new();
    for (name, signals) in &traits {
        evidence_traits.insert(name.clone(), json!(signals));
    }
    let mut evidence = Map::new();
    evidence.insert("technologies".into(), Value::Object(evidence_technologies));
    evidence.insert("traits".into(), Value::Object(evidence_traits));
    evidence.insert(
        "globals".into(),
        match snapshot.get("globalsDetected") {
            Some(value) if js_truthy(value) => value.clone(),
            _ => json!([]),
        },
    );
    evidence.insert(
        "endpoints".into(),
        json!(endpoints.iter().take(20).collect::<Vec<_>>()),
    );

    let confidence_base = techs
        .first()
        .map(|item| item.confidence * 100.0)
        .unwrap_or(45.0);
    let confidence = clamp(
        confidence_base
            + (techs.len().min(4) as f64) * 4.0
            + (trait_names.len().min(5) as f64) * 3.0,
        35.0,
        99.0,
    )
    .round();

    let technologies: Vec<Value> = techs
        .iter()
        .map(|item| {
            let mut entry = Map::new();
            entry.insert("name".into(), json!(item.name));
            entry.insert("category".into(), json!(item.category));
            entry.insert("confidence".into(), js_number_value(item.confidence));
            entry.insert("evidence".into(), json!(item.evidence));
            Value::Object(entry)
        })
        .collect();

    let mut profile = Map::new();
    profile.insert("version".into(), json!(VERSION));
    profile.insert("generatedAt".into(), json!(now_unix_millis()));
    profile.insert("technologies".into(), json!(technologies));
    profile.insert("traits".into(), json!(trait_names));
    profile.insert("confidence".into(), js_number_value(confidence));
    profile.insert("evidence".into(), Value::Object(evidence));
    let profile_value = Value::Object(profile.clone());
    let strategy = build_strategy(&profile_value);
    let summary = format!(
        "{} | {}",
        strategy
            .get("profile")
            .and_then(|v| v.as_str())
            .unwrap_or("generic-app"),
        techs
            .iter()
            .take(3)
            .map(|item| item.name.as_str())
            .collect::<Vec<_>>()
            .join(", ")
    );
    profile.insert("strategy".into(), Value::Object(strategy));
    profile.insert("summary".into(), json!(summary));
    Value::Object(profile)
}
