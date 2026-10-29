//! Boundary labeling and cross-boundary flow analysis, ported from
//! `page.js` (buildBoundaryLabels and its neighbours) with the JavaScript
//! semantics of the pre-port implementation.
//!
//! Boundary matches and flow records stay JSON objects: the JS mutates the
//! asset/origin objects it is handed and the later stages read the same keys.

use std::collections::BTreeMap;
use std::sync::LazyLock;

use serde_json::{json, Map, Value};

use crate::panel::assets::{
    field_number, field_str, get_bare_file_name, js_truthy, unique_strings, BoundaryDetail,
    RuntimeOrigin, ScriptAsset,
};
use crate::panel::graph::{collect_graphql_operations, collect_network_operations};
use crate::panel::model::js_number;
use crate::panel::text::{js_number_value, js_round};
use crate::util::{iso8601_now, utf16_prefix};

/// `arrayContainsAny`.
pub fn array_contains_any(values: &[String], candidates: &[String]) -> bool {
    candidates.iter().any(|candidate| values.contains(candidate))
}

/// `pushBoundaryLabel`.
pub fn push_boundary_label(matches: &mut Vec<Value>, label: &str, score: f64, reason: Option<&str>) {
    for item in matches.iter_mut() {
        if item.get("label").and_then(|v| v.as_str()) == Some(label) {
            let current = item.get("score").and_then(|v| v.as_f64()).unwrap_or(0.0);
            item["score"] = js_number_value(current + score);
            if let Some(reason) = reason {
                let reasons = item
                    .get_mut("reasons")
                    .and_then(|v| v.as_array_mut())
                    .expect("boundary match carries reasons");
                if !reasons.iter().any(|r| r.as_str() == Some(reason)) {
                    reasons.push(Value::String(reason.to_string()));
                }
            }
            return;
        }
    }
    matches.push(json!({
        "label": label,
        "score": js_number_value(score),
        "reasons": match reason {
            Some(reason) => json!([reason]),
            None => json!([]),
        },
    }));
}

/// `buildBoundarySample`.
pub fn build_boundary_sample(entry: &Value) -> String {
    let list = |key: &str| -> String {
        entry
            .get(key)
            .and_then(|v| v.as_array())
            .map(|items| {
                items
                    .iter()
                    .map(|item| item.as_str().unwrap_or_default())
                    .collect::<Vec<&str>>()
                    .join("\n")
            })
            .unwrap_or_default()
    };
    let mut parts: Vec<String> = vec![
        field_str(entry, "url"),
        field_str(entry, "file"),
        field_str(entry, "kind"),
        field_str(entry, "source"),
        field_str(entry, "originType"),
        field_str(entry, "classification"),
        list("frameworkHints"),
        list("routeHints"),
        list("startupSignals"),
        list("imports"),
        field_str(entry, "note"),
        field_str(entry, "mimeType"),
        field_str(entry, "stack"),
    ];
    for key in ["content", "text"] {
        if let Some(Value::String(text)) = entry.get(key) {
            parts.push(utf16_prefix(text, 120_000).to_string());
        }
    }
    parts.join("\n").to_lowercase()
}

/// `buildNetworkBoundarySample`.
pub fn build_network_boundary_sample(entry: &Value) -> String {
    [
        field_str(entry, "type"),
        field_str(entry, "url"),
        field_str(entry, "method"),
        stringify_loose_value(entry.get("requestBody").unwrap_or(&Value::Null)),
        stringify_loose_value(entry.get("requestHeaders").unwrap_or(&Value::Null)),
        stringify_loose_value(entry.get("responseHeaders").unwrap_or(&Value::Null)),
        stringify_loose_value(entry.get("responsePreview").unwrap_or(&Value::Null)),
    ]
    .join("\n")
    .to_lowercase()
}

/// `stringifyLooseValue`.
pub fn stringify_loose_value(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Null => String::new(),
        other => serde_json::to_string(other).unwrap_or_default(),
    }
}

fn label_regex(pattern: &str) -> regex::Regex {
    regex::Regex::new(pattern).expect("boundary pattern compiles")
}

/// `inferNetworkBoundaryLabels`.
pub fn infer_network_boundary_labels(entry: &Value) -> Vec<Value> {
    static AUTH: LazyLock<regex::Regex> = LazyLock::new(|| {
        label_regex(r"auth0|next-auth|firebase/auth|supabase\.auth|oauth|bearer|jwt|csrf|signin|signout|login|logout|session|token|refresh|clerk|okta|passport")
    });
    static ANALYTICS: LazyLock<regex::Regex> = LazyLock::new(|| {
        label_regex(r"google-analytics|googletagmanager|gtag|segment|mixpanel|amplitude|posthog|hotjar|fullstory|datadog|sentry|analytics|/collect(?-u:\b)|/track(?-u:\b)|/capture(?-u:\b)")
    });
    static DATA: LazyLock<regex::Regex> = LazyLock::new(|| {
        label_regex(r"graphql|apollo|relay|axios|tanstack|react-query|swr|trpc|/api/|jsonrpc|rpc|query=|mutation=|xmlhttprequest|fetch")
    });
    static ROUTER: LazyLock<regex::Regex> = LazyLock::new(|| {
        label_regex(r"_next/data/|prefetch|router|route|navigate|navigation|redirect=|callbackurl=")
    });
    static EDITOR: LazyLock<regex::Regex> = LazyLock::new(|| {
        label_regex(r"draft|editor|document|content|prosemirror|tiptap|quill|slate|monaco|codemirror")
    });
    static STATE: LazyLock<regex::Regex> =
        LazyLock::new(|| label_regex(r"persist|rehydrate|redux|zustand|state"));

    let sample = build_network_boundary_sample(entry);
    let mut matches: Vec<Value> = Vec::new();
    if AUTH.is_match(&sample) {
        push_boundary_label(
            &mut matches,
            "auth",
            28.0,
            Some("network activity contains authentication or session signals"),
        );
    }
    if ANALYTICS.is_match(&sample) {
        push_boundary_label(
            &mut matches,
            "analytics",
            26.0,
            Some("network activity contains analytics or telemetry signals"),
        );
    }
    if DATA.is_match(&sample) || looks_like_graphql_request(entry) {
        push_boundary_label(
            &mut matches,
            "data",
            24.0,
            Some("network activity contains data-fetching or API signals"),
        );
    }
    if ROUTER.is_match(&sample) {
        push_boundary_label(
            &mut matches,
            "router",
            18.0,
            Some("network activity contains routing or navigation signals"),
        );
    }
    if EDITOR.is_match(&sample) {
        push_boundary_label(
            &mut matches,
            "editor",
            18.0,
            Some("network activity contains editor or content workflow signals"),
        );
    }
    if STATE.is_match(&sample) {
        push_boundary_label(
            &mut matches,
            "state",
            14.0,
            Some("network activity contains state synchronization signals"),
        );
    }
    matches
}

fn looks_like_graphql_request(entry: &Value) -> bool {
    crate::panel::graph::looks_like_graphql_body(entry.get("requestBody").unwrap_or(&Value::Null))
}

/// `inferBoundaryLabels`.
pub fn infer_boundary_labels(
    entry: &Value,
    is_runtime: bool,
    classifications: &BTreeMap<String, String>,
) -> Vec<Value> {
    static BOOTSTRAP: LazyLock<regex::Regex> = LazyLock::new(|| {
        label_regex(r"hydration|hydrateroot|reactdom\.hydrate|bootstrap|domcontentloaded|__webpack_require__|webpackchunk|parcelrequire|__vite__")
    });
    static ROUTER: LazyLock<regex::Regex> = LazyLock::new(|| {
        label_regex(r"router|routes(?-u:\b)|history\.pushstate|next/router|vue-router|react-router|createbrowserrouter|browserrouter|remix")
    });
    static STATE: LazyLock<regex::Regex> = LazyLock::new(|| {
        label_regex(r"redux|zustand|mobx|recoil|vuex|pinia|createstore|configurestore|createslice|dispatch\(|subscribe\(|setstate\(")
    });
    static DATA: LazyLock<regex::Regex> = LazyLock::new(|| {
        label_regex(r"graphql|apollo|relay|axios|tanstack/query|react-query|swr|trpc|fetch\(|xmlhttprequest|/api/|urql")
    });
    static AUTH: LazyLock<regex::Regex> = LazyLock::new(|| {
        label_regex(r"auth0|next-auth|firebase/auth|supabase\.auth|oauth|bearer|jwt|csrf|signin|signout|login|logout|session|tokenrefresh|clerk|okta|passport")
    });
    static ANALYTICS: LazyLock<regex::Regex> = LazyLock::new(|| {
        label_regex(r"gtag|google-analytics|googletagmanager|segment|mixpanel|amplitude|posthog|hotjar|fullstory|datadogrum|sentry|analytics\.track|fbq\(")
    });
    static EDITOR: LazyLock<regex::Regex> = LazyLock::new(|| {
        label_regex(r"monaco|codemirror|tiptap|prosemirror|quill|slate|draftjs|tinymce|ckeditor|editorjs|ace\.edit")
    });
    static VENDOR: LazyLock<regex::Regex> = LazyLock::new(|| {
        label_regex(r"node_modules|chunk-vendors|polyfill|core-js|regenerator-runtime|cdn")
    });
    static WORKER: LazyLock<regex::Regex> = LazyLock::new(|| label_regex(r"worker|service-worker"));

    let sample = build_boundary_sample(entry);
    let mut matches: Vec<Value> = Vec::new();
    let route_hints = string_list(entry, "routeHints");
    let startup_signals = string_list(entry, "startupSignals");
    let classification = field_str(entry, "classification");

    if (!is_runtime && classification == "runtime")
        || BOOTSTRAP.is_match(&sample)
        || array_contains_any(
            &startup_signals,
            &[
                "hydration".to_string(),
                "chunk-loader".to_string(),
                "service-worker-register".to_string(),
                "worker-bootstrap".to_string(),
                "wasm-bootstrap".to_string(),
            ],
        )
        || (is_runtime && WORKER.is_match(&field_str(entry, "kind")))
    {
        push_boundary_label(
            &mut matches,
            "bootstrap",
            30.0,
            Some("bootstraps the page or runtime loader"),
        );
    }
    if !route_hints.is_empty() || ROUTER.is_match(&sample) {
        push_boundary_label(
            &mut matches,
            "router",
            24.0,
            Some("contains route or navigation signals"),
        );
    }
    if STATE.is_match(&sample) {
        push_boundary_label(&mut matches, "state", 24.0, Some("contains state container signals"));
    }
    if DATA.is_match(&sample) || startup_signals.iter().any(|s| s == "graphql-client") {
        push_boundary_label(
            &mut matches,
            "data",
            24.0,
            Some("contains data-fetching or API signals"),
        );
    }
    if AUTH.is_match(&sample) {
        push_boundary_label(
            &mut matches,
            "auth",
            24.0,
            Some("contains authentication or session signals"),
        );
    }
    if ANALYTICS.is_match(&sample) {
        push_boundary_label(
            &mut matches,
            "analytics",
            22.0,
            Some("contains analytics or telemetry signals"),
        );
    }
    if EDITOR.is_match(&sample) {
        push_boundary_label(
            &mut matches,
            "editor",
            24.0,
            Some("contains editor/runtime authoring signals"),
        );
    }
    if (!is_runtime && (classification == "vendor" || classification == "framework"))
        || VENDOR.is_match(&sample)
    {
        push_boundary_label(
            &mut matches,
            "vendor",
            20.0,
            Some("looks like third-party or framework code"),
        );
    }
    if is_runtime {
        if let Some(related) = entry.get("relatedChunks").and_then(|v| v.as_array()) {
            for chunk in related {
                let id = chunk.as_str().unwrap_or_default();
                if let Some(classification) = classifications.get(id) {
                    if classification == "vendor" || classification == "framework" {
                        push_boundary_label(
                            &mut matches,
                            "vendor",
                            16.0,
                            Some("spawned from a vendor/framework chunk"),
                        );
                        break;
                    }
                }
            }
        }
    }
    matches
}

fn string_list(entry: &Value, key: &str) -> Vec<String> {
    entry
        .get(key)
        .and_then(|v| v.as_array())
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item.as_str().map(|s| s.to_string()))
                .collect()
        })
        .unwrap_or_default()
}

/// The outcome of `applyBoundaryLabels`, shared by the asset and JSON paths.
struct BoundaryOutcome {
    details: Vec<Value>,
    labels: Vec<String>,
    primary: String,
    reasons: Vec<String>,
}

fn boundary_outcome(mut matches: Vec<Value>) -> BoundaryOutcome {
    matches.sort_by(|left, right| {
        let a = left.get("score").and_then(|v| v.as_f64()).unwrap_or(0.0);
        let b = right.get("score").and_then(|v| v.as_f64()).unwrap_or(0.0);
        b.partial_cmp(&a).unwrap_or(std::cmp::Ordering::Equal)
    });
    let details: Vec<Value> = matches.into_iter().take(4).collect();
    let labels: Vec<String> = details
        .iter()
        .map(|item| field_str(item, "label"))
        .collect();
    let primary = labels.first().cloned().unwrap_or_default();
    let mut reasons: Vec<String> = Vec::new();
    for item in &details {
        let label = field_str(item, "label");
        for reason in item
            .get("reasons")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default()
        {
            reasons.push(format!("{label}: {}", reason.as_str().unwrap_or_default()));
        }
    }
    let reasons = unique_strings(&reasons).into_iter().take(8).collect();
    BoundaryOutcome {
        details,
        labels,
        primary,
        reasons,
    }
}

/// `applyBoundaryLabels` on a prepared asset.
pub fn apply_boundary_labels_asset(asset: &mut ScriptAsset, matches: Vec<Value>) {
    let outcome = boundary_outcome(matches);
    asset.boundary_details = outcome
        .details
        .iter()
        .map(|item| BoundaryDetail {
            label: field_str(item, "label"),
            score: field_number(item, "score"),
            reasons: item
                .get("reasons")
                .and_then(|v| v.as_array())
                .map(|items| {
                    items
                        .iter()
                        .filter_map(|reason| reason.as_str().map(|s| s.to_string()))
                        .collect()
                })
                .unwrap_or_default(),
        })
        .collect();
    asset.boundary_labels = outcome.labels;
    asset.primary_boundary = outcome.primary;
    asset.boundary_reasons = outcome.reasons;
}

/// `applyBoundaryLabels` on a JSON entry (runtime origins, network rows).
pub fn apply_boundary_labels(entry: &mut Value, matches: Vec<Value>) {
    let outcome = boundary_outcome(matches);
    if let Some(map) = entry.as_object_mut() {
        map.insert("boundaryDetails".to_string(), Value::Array(outcome.details));
        map.insert(
            "boundaryLabels".to_string(),
            serde_json::to_value(&outcome.labels).unwrap(),
        );
        map.insert("primaryBoundary".to_string(), Value::String(outcome.primary));
        map.insert(
            "boundaryReasons".to_string(),
            serde_json::to_value(&outcome.reasons).unwrap(),
        );
    }
}

/// `countBoundaryLabels` over JSON entries.
pub fn count_boundary_labels_values(items: &[Value]) -> BTreeMap<String, usize> {
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    for item in items {
        for label in item
            .get("boundaryLabels")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default()
        {
            if let Some(label) = label.as_str() {
                *counts.entry(label.to_string()).or_insert(0) += 1;
            }
        }
    }
    counts
}

/// `countTaggedEntries` over JSON entries.
pub fn count_tagged_entries_values(items: &[Value]) -> usize {
    items
        .iter()
        .filter(|item| {
            item.get("boundaryLabels")
                .and_then(|v| v.as_array())
                .map(|v| !v.is_empty())
                .unwrap_or(false)
        })
        .count()
}

/// `stripBoundaryEntry`.
pub fn strip_boundary_entry(entry: &Value, kind: &str) -> Value {
    let file_or_url = {
        let file = field_str(entry, "file");
        if !file.is_empty() {
            file
        } else {
            let url = field_str(entry, "url");
            if !url.is_empty() {
                url
            } else {
                field_str(entry, "id")
            }
        }
    };
    let label = {
        let bare = get_bare_file_name(&file_or_url);
        if bare.is_empty() {
            field_str(entry, "id")
        } else {
            bare
        }
    };
    let url = {
        let url = field_str(entry, "url");
        if url.is_empty() {
            field_str(entry, "objectUrl")
        } else {
            url
        }
    };
    json!({
        "kind": kind,
        "id": field_str(entry, "id"),
        "label": label,
        "file": field_str(entry, "file"),
        "url": url,
        "primaryBoundary": field_str(entry, "primaryBoundary"),
        "boundaryLabels": entry.get("boundaryLabels").cloned().unwrap_or_else(|| json!([])),
        "boundaryReasons": entry.get("boundaryReasons").cloned().unwrap_or_else(|| json!([])),
        "classification": field_str(entry, "classification"),
        "originType": field_str(entry, "originType"),
        "score": js_number_value(field_number(entry, "score")),
    })
}

/// `buildBoundaryLabels`: labels the assets and origins in place and returns
/// the report.
pub fn build_boundary_labels(
    assets: &mut [ScriptAsset],
    origins: &mut [RuntimeOrigin],
) -> Value {
    let classifications: BTreeMap<String, String> = assets
        .iter()
        .map(|asset| (asset.id.clone(), asset.classification.clone()))
        .collect();
    for asset in assets.iter_mut() {
        let value = serde_json::to_value(&*asset).unwrap();
        let matches = infer_boundary_labels(&value, false, &classifications);
        apply_boundary_labels_asset(asset, matches);
    }
    for origin in origins.iter_mut() {
        let matches = infer_boundary_labels(origin, true, &classifications);
        apply_boundary_labels(origin, matches);
    }

    let mut tagged_chunks: Vec<&ScriptAsset> = assets
        .iter()
        .filter(|asset| !asset.boundary_labels.is_empty())
        .collect();
    tagged_chunks.sort_by(|left, right| {
        right
            .score
            .partial_cmp(&left.score)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    let chunks: Vec<Value> = tagged_chunks
        .iter()
        .map(|asset| {
            strip_boundary_entry(&serde_json::to_value(*asset).unwrap(), "chunk")
        })
        .collect();

    let mut tagged_runtime: Vec<&RuntimeOrigin> = origins
        .iter()
        .filter(|origin| {
            origin
                .get("boundaryLabels")
                .and_then(|v| v.as_array())
                .map(|v| !v.is_empty())
                .unwrap_or(false)
        })
        .collect();
    tagged_runtime.sort_by(|left, right| {
        let a = field_number(left, "score");
        let b = field_number(right, "score");
        b.partial_cmp(&a).unwrap_or(std::cmp::Ordering::Equal)
    });
    let runtime: Vec<Value> = tagged_runtime
        .iter()
        .map(|origin| strip_boundary_entry(origin, "runtime"))
        .collect();

    let chunk_labels = crate::panel::assets::count_boundary_labels(assets);
    let runtime_labels = count_boundary_labels_values(origins);
    json!({
        "generatedAt": iso8601_now(),
        "categories": ["bootstrap", "router", "state", "data", "auth", "analytics", "editor", "vendor"],
        "summary": {
            "chunkLabels": chunk_labels,
            "runtimeLabels": runtime_labels,
            "taggedChunks": crate::panel::assets::count_tagged_entries(assets),
            "taggedRuntime": count_tagged_entries_values(origins),
        },
        "chunks": chunks,
        "runtime": runtime,
    })
}

/// `buildNetworkFlowEvents`.
pub fn build_network_flow_events(recon: Option<&Value>) -> Vec<Value> {
    let mut operations = collect_network_operations(recon);
    for (index, operation) in operations.iter_mut().enumerate() {
        let kind = field_str(operation, "type");
        let id = format!("{kind}-{:04}", index + 1);
        let label = {
            let method = {
                let method = field_str(operation, "method");
                if method.is_empty() {
                    "GET".to_string()
                } else {
                    method
                }
            };
            let file = get_bare_file_name(&field_str(operation, "url"));
            if !file.is_empty() {
                format!("{method} {file}")
            } else {
                let kind = field_str(operation, "type");
                if !kind.is_empty() {
                    format!("{method} {kind}")
                } else {
                    format!("{method} {id}")
                }
            }
        };
        if let Some(map) = operation.as_object_mut() {
            map.insert("id".to_string(), Value::String(id));
            map.insert("label".to_string(), Value::String(label));
        }
        let matches = infer_network_boundary_labels(operation);
        apply_boundary_labels(operation, matches);
    }
    operations
}

/// `buildFlowEvent`.
pub fn build_flow_event(kind: &str, record_id: &str, entry: &Value, approx_time: f64) -> Value {
    let label = {
        let explicit = field_str(entry, "label");
        if !explicit.is_empty() {
            explicit
        } else {
            let candidate = ["file", "url", "objectUrl", "id", "kind"]
                .iter()
                .find_map(|key| {
                    let value = entry.get(*key).cloned().unwrap_or(Value::Null);
                    if js_truthy(&value) {
                        Some(stringify_loose_value(&value))
                    } else {
                        None
                    }
                })
                .unwrap_or_else(|| record_id.to_string());
            let bare = get_bare_file_name(&candidate);
            if bare.is_empty() {
                record_id.to_string()
            } else {
                bare
            }
        }
    };
    let url = {
        let url = field_str(entry, "url");
        if url.is_empty() {
            field_str(entry, "objectUrl")
        } else {
            url
        }
    };
    let source = {
        let source = field_str(entry, "source");
        if source.is_empty() {
            field_str(entry, "type")
        } else {
            source
        }
    };
    let blob_id = match entry.get("blobId") {
        Some(value) if js_truthy(value) => value.clone(),
        _ => Value::Null,
    };
    json!({
        "id": format!("{kind}:{record_id}"),
        "recordId": record_id,
        "kind": kind,
        "label": label,
        "primaryBoundary": field_str(entry, "primaryBoundary"),
        "boundaryLabels": entry.get("boundaryLabels").cloned().unwrap_or_else(|| json!([])),
        "approxTime": js_number_value(if approx_time == 0.0 || approx_time.is_nan() {
            0.0
        } else {
            approx_time
        }),
        "timestamp": js_number_value(field_number(entry, "timestamp")),
        "url": url,
        "file": field_str(entry, "file"),
        "method": field_str(entry, "method"),
        "status": js_number_value(field_number(entry, "status")),
        "classification": field_str(entry, "classification"),
        "originType": field_str(entry, "originType"),
        "relatedChunks": entry.get("relatedChunks").cloned().unwrap_or_else(|| json!([])),
        "blobId": blob_id,
        "source": source,
        "boundaryReasons": entry.get("boundaryReasons").cloned().unwrap_or_else(|| json!([])),
    })
}

/// The flow-event set with the id lookup the flow builder uses.
pub struct FlowEvents {
    pub events: Vec<Value>,
    pub event_map: BTreeMap<String, Value>,
}

/// `collectFlowEvents`.
pub fn collect_flow_events(
    recon_data: Option<&Value>,
    assets: &[ScriptAsset],
    origins: &[RuntimeOrigin],
) -> FlowEvents {
    let mut events: Vec<Value> = Vec::new();
    let mut event_map: BTreeMap<String, Value> = BTreeMap::new();
    let mut asset_horizon = 0.0f64;
    let network_ops = build_network_flow_events(recon_data.and_then(|r| r.get("recon")));

    let mut absolute_times: Vec<f64> = Vec::new();
    for origin in origins {
        let timestamp = field_number(origin, "timestamp");
        if timestamp > 0.0 {
            absolute_times.push(timestamp);
        }
    }
    for operation in &network_ops {
        let timestamp = field_number(operation, "timestamp");
        if timestamp > 0.0 {
            absolute_times.push(timestamp);
        }
    }
    let absolute_base = absolute_times
        .iter()
        .cloned()
        .fold(f64::INFINITY, f64::min);
    let absolute_base = if absolute_base.is_finite() { absolute_base } else { 0.0 };

    for (index, asset) in assets.iter().enumerate() {
        let value = serde_json::to_value(asset).unwrap();
        let asset_time = match value.get("startTime").and_then(|v| v.as_f64()) {
            Some(time) => time,
            None => index as f64 * 25.0,
        };
        let event = build_flow_event("chunk", &asset.id, &value, asset_time);
        events.push(event.clone());
        event_map.insert(
            event.get("id").and_then(|v| v.as_str()).unwrap_or_default().to_string(),
            event,
        );
        asset_horizon = asset_horizon.max(asset_time + asset.duration);
    }

    let absolute_offset = asset_horizon + 50.0;
    for (index, origin) in origins.iter().enumerate() {
        let timestamp = field_number(origin, "timestamp");
        let runtime_time = if timestamp > 0.0 && absolute_base != 0.0 {
            absolute_offset + (timestamp - absolute_base)
        } else {
            absolute_offset + index as f64 * 25.0
        };
        let record_id = field_str(origin, "id");
        let event = build_flow_event("runtime", &record_id, origin, runtime_time);
        events.push(event.clone());
        event_map.insert(
            event.get("id").and_then(|v| v.as_str()).unwrap_or_default().to_string(),
            event,
        );
    }

    for (index, operation) in network_ops.iter().enumerate() {
        let timestamp = field_number(operation, "timestamp");
        let operation_time = if timestamp > 0.0 && absolute_base != 0.0 {
            absolute_offset + (timestamp - absolute_base)
        } else {
            absolute_offset + (origins.len() + index) as f64 * 25.0
        };
        let record_id = field_str(operation, "id");
        let event = build_flow_event("network", &record_id, operation, operation_time);
        events.push(event.clone());
        event_map.insert(
            event.get("id").and_then(|v| v.as_str()).unwrap_or_default().to_string(),
            event,
        );
    }

    events.sort_by(|left, right| {
        let a = field_number(left, "approxTime");
        let b = field_number(right, "approxTime");
        a.partial_cmp(&b).unwrap_or(std::cmp::Ordering::Equal)
    });
    FlowEvents { events, event_map }
}

/// `inferFlowRelation`.
pub fn infer_flow_relation(from_event: &Value, to_event: &Value) -> String {
    let from = field_str(from_event, "kind");
    let to = field_str(to_event, "kind");
    match (from.as_str(), to.as_str()) {
        ("chunk", "chunk") => "imports-boundary",
        ("chunk", "runtime") => "materializes-runtime",
        ("runtime", "runtime") => "spawns-runtime",
        (_, "network") => "triggers-request",
        ("network", _) => "follows-response",
        _ => "sequence",
    }
    .to_string()
}

/// `countSharedValues`.
pub fn count_shared_values(left: &[String], right: &[String]) -> usize {
    left.iter().filter(|value| right.contains(value)).count()
}

/// The JS truthy number read (`entry[key] || undefined`).
fn truthy_number(entry: &Value, key: &str) -> Option<f64> {
    match entry.get(key) {
        Some(value) if js_truthy(value) => Some(js_number(value)),
        _ => None,
    }
}

fn event_labels(event: &Value) -> Vec<String> {
    event
        .get("boundaryLabels")
        .and_then(|v| v.as_array())
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item.as_str().map(|s| s.to_string()))
                .collect()
        })
        .unwrap_or_default()
}

/// `addBoundaryFlow`.
#[allow(clippy::too_many_arguments)]
pub fn add_boundary_flow(
    flows: &mut Vec<Value>,
    flow_map: &mut BTreeMap<String, bool>,
    from_event: &Value,
    to_event: &Value,
    relation: &str,
    confidence: f64,
    evidence: &str,
    delta_ms: Option<f64>,
) {
    let from_id = field_str(from_event, "id");
    let to_id = field_str(to_event, "id");
    if from_id.is_empty() || to_id.is_empty() || from_id == to_id {
        return;
    }
    let from_boundary = field_str(from_event, "primaryBoundary");
    let to_boundary = field_str(to_event, "primaryBoundary");
    if from_boundary.is_empty() || to_boundary.is_empty() {
        return;
    }
    let cross_boundary = from_boundary != to_boundary;
    if !cross_boundary && relation != "materializes-runtime" && relation != "spawns-runtime" {
        return;
    }
    let key = format!("{from_id}|{to_id}|{relation}|{from_boundary}|{to_boundary}");
    if flow_map.contains_key(&key) {
        return;
    }
    flow_map.insert(key, true);
    let timestamp = truthy_number(to_event, "timestamp")
        .or_else(|| truthy_number(to_event, "approxTime"))
        .or_else(|| truthy_number(from_event, "timestamp"))
        .or_else(|| truthy_number(from_event, "approxTime"))
        .unwrap_or(0.0);
    flows.push(json!({
        "id": format!("flow-{:04}", flows.len() + 1),
        "relation": relation,
        "crossBoundary": cross_boundary,
        "fromBoundary": from_boundary,
        "toBoundary": to_boundary,
        "confidence": js_number_value(confidence),
        "deltaMs": match delta_ms {
            Some(value) => js_number_value(js_round(value)),
            None => Value::Null,
        },
        "timestamp": js_number_value(timestamp),
        "evidence": evidence,
        "from": strip_flow_event(from_event),
        "to": strip_flow_event(to_event),
    }));
}

/// `scoreFlowTransition`.
pub fn score_flow_transition(from_event: &Value, to_event: &Value, delta_ms: Option<f64>) -> f64 {
    let from_boundary = field_str(from_event, "primaryBoundary");
    let to_boundary = field_str(to_event, "primaryBoundary");
    let from_id = field_str(from_event, "id");
    let to_id = field_str(to_event, "id");
    if from_boundary.is_empty()
        || to_boundary.is_empty()
        || (!from_id.is_empty() && from_id == to_id)
    {
        return 0.0;
    }
    let from_kind = field_str(from_event, "kind");
    let to_kind = field_str(to_event, "kind");
    let cross_boundary = from_boundary != to_boundary;
    let structural = (from_kind == "chunk" && to_kind == "runtime")
        || (from_kind == "runtime" && to_kind == "runtime");
    if !cross_boundary && !structural {
        return 0.0;
    }
    let mut score = 0.0;
    if from_kind == "chunk" && to_kind == "chunk" {
        score += 12.0;
    }
    if from_kind == "runtime" && to_kind == "network" {
        score += 18.0;
    }
    if from_kind == "network" && to_kind == "runtime" {
        score += 18.0;
    }
    if from_kind == "network" && to_kind == "network" {
        score += 8.0;
    }
    let boundary_list = |items: &[&str]| items.iter().map(|s| s.to_string()).collect::<Vec<String>>();
    let contains = |candidates: &[&str]| -> bool {
        array_contains_any(&boundary_list(candidates), std::slice::from_ref(&to_boundary))
    };
    if from_boundary == "bootstrap" && contains(&["router", "state", "data", "auth"]) {
        score += 18.0;
    }
    if from_boundary == "auth" && contains(&["data", "router", "analytics"]) {
        score += 22.0;
    }
    if from_boundary == "data" && contains(&["router", "analytics", "state", "editor"]) {
        score += 20.0;
    }
    if from_boundary == "router" && contains(&["data", "analytics"]) {
        score += 16.0;
    }
    if from_boundary == "state" && contains(&["data", "router"]) {
        score += 14.0;
    }
    if from_boundary == "editor" && contains(&["data", "state", "analytics"]) {
        score += 14.0;
    }
    if from_boundary == "vendor" && contains(&["analytics", "auth", "data"]) {
        score += 8.0;
    }
    score += (count_shared_values(&event_labels(from_event), &event_labels(to_event)) as f64 * 3.0)
        .min(10.0);
    if let Some(delta) = delta_ms {
        if delta >= 0.0 {
            score += (12.0 - (delta / 350.0).floor()).max(0.0);
        }
    }
    score
}

/// `describeFlowTransition`.
pub fn describe_flow_transition(from_event: &Value, to_event: &Value, delta_ms: Option<f64>) -> String {
    let lag = match delta_ms {
        Some(delta) if delta >= 0.0 => format!(" {}ms later", js_round(delta) as i64),
        _ => String::new(),
    };
    let from_kind = field_str(from_event, "kind");
    let to_kind = field_str(to_event, "kind");
    let text = match (from_kind.as_str(), to_kind.as_str()) {
        ("runtime", "network") => "runtime activity was followed by a labeled request".to_string(),
        ("network", "runtime") => {
            "network activity was followed by a labeled runtime effect".to_string()
        }
        ("network", "network") => {
            "one labeled request preceded another labeled request".to_string()
        }
        ("chunk", "chunk") => "one labeled chunk imported another labeled chunk".to_string(),
        _ => format!(
            "{} activity led into {} activity",
            field_str(from_event, "primaryBoundary"),
            field_str(to_event, "primaryBoundary")
        ),
    };
    format!("{text}{lag}")
}

/// `summarizeBoundaryTransitions`.
pub fn summarize_boundary_transitions(flows: &[Value]) -> Vec<Value> {
    struct Group {
        from_boundary: String,
        to_boundary: String,
        count: usize,
        total_confidence: f64,
        relations: Vec<(String, usize)>,
    }
    let mut order: Vec<String> = Vec::new();
    let mut grouped: BTreeMap<String, Group> = BTreeMap::new();
    for flow in flows {
        let from_boundary = field_str(flow, "fromBoundary");
        let to_boundary = field_str(flow, "toBoundary");
        let key = format!("{from_boundary}->{to_boundary}");
        let group = grouped.entry(key.clone()).or_insert_with(|| {
            order.push(key.clone());
            Group {
                from_boundary: from_boundary.clone(),
                to_boundary: to_boundary.clone(),
                count: 0,
                total_confidence: 0.0,
                relations: Vec::new(),
            }
        });
        group.count += 1;
        group.total_confidence += field_number(flow, "confidence");
        let relation = field_str(flow, "relation");
        match group.relations.iter_mut().find(|(name, _)| *name == relation) {
            Some((_, count)) => *count += 1,
            None => group.relations.push((relation, 1)),
        }
    }
    let mut summary: Vec<Value> = order
        .iter()
        .map(|key| {
            let group = &grouped[key];
            let mut relations = group.relations.clone();
            relations.sort_by_key(|item| std::cmp::Reverse(item.1));
            json!({
                "path": key,
                "fromBoundary": group.from_boundary,
                "toBoundary": group.to_boundary,
                "count": group.count,
                "averageConfidence": if group.count > 0 {
                    js_number_value(js_round(group.total_confidence / group.count as f64))
                } else {
                    js_number_value(0.0)
                },
                "relations": relations.iter().map(|(name, _)| name.clone()).collect::<Vec<String>>(),
            })
        })
        .collect();
    summary.sort_by(|left, right| {
        let left_count = left.get("count").and_then(|v| v.as_u64()).unwrap_or(0);
        let right_count = right.get("count").and_then(|v| v.as_u64()).unwrap_or(0);
        if left_count != right_count {
            return right_count.cmp(&left_count);
        }
        let left_confidence = left.get("averageConfidence").and_then(|v| v.as_f64()).unwrap_or(0.0);
        let right_confidence = right.get("averageConfidence").and_then(|v| v.as_f64()).unwrap_or(0.0);
        right_confidence
            .partial_cmp(&left_confidence)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    summary.into_iter().take(24).collect()
}

/// `buildBoundaryChains`.
pub fn build_boundary_chains(flows: &[Value]) -> Vec<Value> {
    let mut timed: Vec<&Value> = flows
        .iter()
        .filter(|flow| {
            flow.get("crossBoundary").map(js_truthy).unwrap_or(false)
                && field_number(flow, "timestamp") > 0.0
        })
        .collect();
    timed.sort_by(|left, right| {
        let a = field_number(left, "timestamp");
        let b = field_number(right, "timestamp");
        a.partial_cmp(&b).unwrap_or(std::cmp::Ordering::Equal)
    });

    struct Chain {
        path: Vec<String>,
        count: usize,
        total_confidence: f64,
        examples: Vec<Value>,
    }
    let mut order: Vec<String> = Vec::new();
    let mut chains: BTreeMap<String, Chain> = BTreeMap::new();
    for i in 0..timed.len() {
        let mut j = i + 1;
        while j < timed.len() && j < i + 5 {
            let delta = field_number(timed[j], "timestamp") - field_number(timed[i], "timestamp");
            if delta <= 0.0 || delta > 6000.0 {
                break;
            }
            if field_str(timed[i], "toBoundary") != field_str(timed[j], "fromBoundary") {
                j += 1;
                continue;
            }
            let path = vec![
                field_str(timed[i], "fromBoundary"),
                field_str(timed[i], "toBoundary"),
                field_str(timed[j], "toBoundary"),
            ];
            if path[0] == path[2] {
                j += 1;
                continue;
            }
            let key = path.join(" -> ");
            let chain = chains.entry(key.clone()).or_insert_with(|| {
                order.push(key.clone());
                Chain {
                    path: path.clone(),
                    count: 0,
                    total_confidence: 0.0,
                    examples: Vec::new(),
                }
            });
            chain.count += 1;
            chain.total_confidence +=
                field_number(timed[i], "confidence") + field_number(timed[j], "confidence");
            if chain.examples.len() < 3 {
                chain.examples.push(json!([
                    field_str(timed[i], "relation"),
                    field_str(timed[j], "relation"),
                ]));
            }
            j += 1;
        }
    }
    let mut items: Vec<Value> = order
        .iter()
        .map(|key| {
            let chain = &chains[key];
            json!({
                "path": chain.path,
                "label": key,
                "count": chain.count,
                "averageConfidence": if chain.count > 0 {
                    js_number_value(js_round(chain.total_confidence / (chain.count as f64 * 2.0)))
                } else {
                    js_number_value(0.0)
                },
                "examples": chain.examples,
            })
        })
        .collect();
    items.sort_by(|left, right| {
        let left_count = left.get("count").and_then(|v| v.as_u64()).unwrap_or(0);
        let right_count = right.get("count").and_then(|v| v.as_u64()).unwrap_or(0);
        if left_count != right_count {
            return right_count.cmp(&left_count);
        }
        let left_confidence = left.get("averageConfidence").and_then(|v| v.as_f64()).unwrap_or(0.0);
        let right_confidence = right.get("averageConfidence").and_then(|v| v.as_f64()).unwrap_or(0.0);
        right_confidence
            .partial_cmp(&left_confidence)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    items.into_iter().take(20).collect()
}

/// `stripFlowTransition`.
pub fn strip_flow_transition(flow: &Value) -> Value {
    json!({
        "id": flow.get("id").cloned().unwrap_or(Value::Null),
        "relation": flow.get("relation").cloned().unwrap_or(Value::Null),
        "crossBoundary": flow.get("crossBoundary").cloned().unwrap_or(Value::Null),
        "fromBoundary": flow.get("fromBoundary").cloned().unwrap_or(Value::Null),
        "toBoundary": flow.get("toBoundary").cloned().unwrap_or(Value::Null),
        "confidence": flow.get("confidence").cloned().unwrap_or(Value::Null),
        "deltaMs": flow.get("deltaMs").cloned().unwrap_or(Value::Null),
        "evidence": flow.get("evidence").cloned().unwrap_or(Value::Null),
        "from": flow.get("from").cloned().unwrap_or(Value::Null),
        "to": flow.get("to").cloned().unwrap_or(Value::Null),
    })
}

/// `stripFlowEvent`. The identity fields are copied as-is, so a source that
/// does not carry one produces no key at all (the JS leaves them `undefined`).
pub fn strip_flow_event(event: &Value) -> Value {
    let mut stripped = Map::new();
    for key in ["id", "recordId", "kind", "label", "primaryBoundary"] {
        if let Some(value) = event.get(key) {
            stripped.insert(key.to_string(), value.clone());
        }
    }
    stripped.insert(
        "boundaryLabels".to_string(),
        event.get("boundaryLabels").cloned().unwrap_or_else(|| json!([])),
    );
    stripped.insert(
        "approxTime".to_string(),
        js_number_value(js_round(field_number(event, "approxTime"))),
    );
    stripped.insert(
        "timestamp".to_string(),
        js_number_value(field_number(event, "timestamp")),
    );
    stripped.insert("url".to_string(), Value::String(field_str(event, "url")));
    stripped.insert("file".to_string(), Value::String(field_str(event, "file")));
    stripped.insert("method".to_string(), Value::String(field_str(event, "method")));
    stripped.insert(
        "status".to_string(),
        js_number_value(field_number(event, "status")),
    );
    stripped.insert(
        "classification".to_string(),
        Value::String(field_str(event, "classification")),
    );
    stripped.insert(
        "originType".to_string(),
        Value::String(field_str(event, "originType")),
    );
    Value::Object(stripped)
}

/// `buildCrossBoundaryFlows`.
pub fn build_cross_boundary_flows(
    recon_data: Option<&Value>,
    assets: &[ScriptAsset],
    origins: &[RuntimeOrigin],
) -> Value {
    let flow_data = collect_flow_events(recon_data, assets, origins);
    let event_map = &flow_data.event_map;
    let mut flows: Vec<Value> = Vec::new();
    let mut flow_map: BTreeMap<String, bool> = BTreeMap::new();

    for asset in assets {
        let from_event = match event_map.get(&format!("chunk:{}", asset.id)) {
            Some(event) => event,
            None => continue,
        };
        for specifier in &asset.imports {
            let target = match crate::panel::assets::find_asset_by_reference(specifier, assets) {
                Some(target) if target.id != asset.id => target,
                _ => continue,
            };
            let to_event = match event_map.get(&format!("chunk:{}", target.id)) {
                Some(event) => event,
                None => continue,
            };
            let from_boundary = field_str(from_event, "primaryBoundary");
            let to_boundary = field_str(to_event, "primaryBoundary");
            if from_boundary.is_empty() || to_boundary.is_empty() || from_boundary == to_boundary {
                continue;
            }
            let confidence = 46.0
                + count_shared_values(&event_labels(from_event), &event_labels(to_event)) as f64
                    * 3.0;
            let delta = (field_number(to_event, "approxTime")
                - field_number(from_event, "approxTime"))
            .max(0.0);
            add_boundary_flow(
                &mut flows,
                &mut flow_map,
                from_event,
                to_event,
                "imports-boundary",
                confidence,
                "chunk imports a differently labeled dependency",
                Some(delta),
            );
        }
    }

    for origin in origins {
        let record_id = field_str(origin, "id");
        let runtime_event = match event_map.get(&format!("runtime:{record_id}")) {
            Some(event) => event,
            None => continue,
        };
        for chunk in origin
            .get("relatedChunks")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default()
        {
            let chunk_event = match event_map.get(&format!("chunk:{}", value_text(&chunk))) {
                Some(event) => event,
                None => continue,
            };
            let confidence = 68.0
                + count_shared_values(&event_labels(chunk_event), &event_labels(runtime_event))
                    as f64
                    * 2.0;
            let delta = (field_number(runtime_event, "approxTime")
                - field_number(chunk_event, "approxTime"))
            .max(0.0);
            add_boundary_flow(
                &mut flows,
                &mut flow_map,
                chunk_event,
                runtime_event,
                "materializes-runtime",
                confidence,
                "runtime artifact links back to its originating chunk",
                Some(delta),
            );
        }
        if let Some(blob) = origin.get("blobId").filter(|v| js_truthy(v)) {
            if let Some(parent) = event_map.get(&format!("runtime:{}", value_text(blob))) {
                let delta = (field_number(runtime_event, "approxTime")
                    - field_number(parent, "approxTime"))
                .max(0.0);
                add_boundary_flow(
                    &mut flows,
                    &mut flow_map,
                    parent,
                    runtime_event,
                    "spawns-runtime",
                    64.0,
                    "blob ancestry connects these runtime artifacts",
                    Some(delta),
                );
            }
        }
    }

    let mut timed_events: Vec<&Value> = flow_data
        .events
        .iter()
        .filter(|event| !field_str(event, "primaryBoundary").is_empty())
        .collect();
    timed_events.sort_by(|left, right| {
        let a = field_number(left, "approxTime");
        let b = field_number(right, "approxTime");
        a.partial_cmp(&b).unwrap_or(std::cmp::Ordering::Equal)
    });
    for a in 0..timed_events.len() {
        let mut b = a + 1;
        while b < timed_events.len() && b < a + 5 {
            let delta_ms =
                field_number(timed_events[b], "approxTime") - field_number(timed_events[a], "approxTime");
            if delta_ms <= 0.0 || delta_ms > 4000.0 {
                break;
            }
            let score = score_flow_transition(timed_events[a], timed_events[b], Some(delta_ms));
            if score < 34.0 {
                b += 1;
                continue;
            }
            let relation = infer_flow_relation(timed_events[a], timed_events[b]);
            let evidence = describe_flow_transition(timed_events[a], timed_events[b], Some(delta_ms));
            add_boundary_flow(
                &mut flows,
                &mut flow_map,
                timed_events[a],
                timed_events[b],
                &relation,
                score,
                &evidence,
                Some(delta_ms),
            );
            b += 1;
        }
    }

    let labeled: Vec<&Value> = flow_data
        .events
        .iter()
        .filter(|event| !field_str(event, "primaryBoundary").is_empty())
        .collect();
    let cross = flows
        .iter()
        .filter(|flow| flow.get("crossBoundary").map(js_truthy).unwrap_or(false))
        .count();
    json!({
        "generatedAt": iso8601_now(),
        "summary": {
            "totalFlows": flows.len(),
            "crossBoundaryFlows": cross,
            "structuralFlows": flows.len() - cross,
            "labeledEvents": labeled.len(),
            "eventKinds": count_property(flow_data.events.iter(), "kind"),
            "relations": count_property(flows.iter(), "relation"),
        },
        "topTransitions": summarize_boundary_transitions(&flows),
        "chains": build_boundary_chains(&flows),
        "events": labeled.iter().take(120).map(|event| strip_flow_event(event)).collect::<Vec<Value>>(),
        "transitions": flows.iter().take(180).map(strip_flow_transition).collect::<Vec<Value>>(),
    })
}

fn value_text(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Null => String::new(),
        other => crate::jsnumber::js_number_to_string(js_number(other)),
    }
}

/// `countPropertyValues` over an iterator of JSON objects.
fn count_property<'a>(items: impl Iterator<Item = &'a Value>, key: &str) -> BTreeMap<String, usize> {
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    for item in items {
        let value = field_str(item, key);
        let value = if value.is_empty() { "unknown".to_string() } else { value };
        *counts.entry(value).or_insert(0) += 1;
    }
    counts
}

/// `buildFrameworkStateSummary`.
pub fn build_framework_state_summary(framework_state: Option<&Value>) -> Value {
    let state = match framework_state.filter(|v| js_truthy(v)) {
        Some(state) => state,
        None => return Value::Null,
    };
    let router = state.get("router").cloned().unwrap_or_else(|| json!({}));
    let summary = state.get("summary").cloned().unwrap_or_else(|| json!({}));
    let technologies = state
        .get("technologies")
        .filter(|v| v.is_array())
        .cloned()
        .unwrap_or_else(|| json!([]));

    let length_of = |key: &str| -> usize {
        state
            .get(key)
            .and_then(|v| v.as_array())
            .map(|items| items.len())
            .unwrap_or(0)
    };
    let detected: Vec<String> = {
        let mut names: Vec<String> = technologies
            .as_array()
            .map(|items| {
                items
                    .iter()
                    .map(|item| {
                        if js_truthy(item) {
                            field_str(item, "name")
                        } else {
                            String::new()
                        }
                    })
                    .collect()
            })
            .unwrap_or_default();
        names.extend(
            summary
                .get("detectedTechnologies")
                .and_then(|v| v.as_array())
                .map(|items| {
                    items
                        .iter()
                        .filter_map(|item| item.as_str().map(|s| s.to_string()))
                        .collect::<Vec<String>>()
                })
                .unwrap_or_default(),
        );
        unique_strings(&names)
            .into_iter()
            .filter(|name| !name.is_empty())
            .collect()
    };
    let router_framework = {
        let framework = field_str(&router, "framework");
        if framework.is_empty() {
            let fallback = field_str(&summary, "routerFramework");
            if fallback.is_empty() {
                "generic".to_string()
            } else {
                fallback
            }
        } else {
            framework
        }
    };
    let route = {
        let route = field_str(&router, "route");
        if route.is_empty() {
            field_str(&router, "pathname")
        } else {
            route
        }
    };
    let profile = {
        let profile = field_str(state, "profile");
        if profile.is_empty() {
            "generic-app".to_string()
        } else {
            profile
        }
    };
    json!({
        "profile": profile,
        "generatedAt": field_str(state, "generatedAt"),
        "reason": field_str(state, "reason"),
        "rootCount": length_of("roots"),
        "storeCount": length_of("stores"),
        "queryCount": length_of("queries"),
        "hydrationCount": length_of("hydration"),
        "authCount": length_of("auth"),
        "routerFramework": router_framework,
        "route": route,
        "routerSource": field_str(&router, "source"),
        "queryKeyCount": router
            .get("queryKeys")
            .and_then(|v| v.as_array())
            .map(|items| items.len())
            .unwrap_or(0),
        "detectedTechnologies": detected,
        "roots": state.get("roots").cloned().unwrap_or_else(|| json!([])),
        "stores": state.get("stores").cloned().unwrap_or_else(|| json!([])),
        "queries": state.get("queries").cloned().unwrap_or_else(|| json!([])),
        "hydration": state.get("hydration").cloned().unwrap_or_else(|| json!([])),
        "auth": state.get("auth").cloned().unwrap_or_else(|| json!([])),
        "relatedArtifacts": collect_framework_artifact_paths(Some(state)),
    })
}

/// `collectFrameworkArtifactPaths`.
pub fn collect_framework_artifact_paths(framework_state: Option<&Value>) -> Vec<String> {
    let state = match framework_state {
        Some(state) if js_truthy(state) => state,
        _ => return Vec::new(),
    };
    let non_empty_object = |key: &str| -> bool {
        state
            .get(key)
            .and_then(|v| v.as_object())
            .map(|map| !map.is_empty())
            .unwrap_or(false)
    };
    let non_empty_array = |key: &str| -> bool {
        state
            .get(key)
            .and_then(|v| v.as_array())
            .map(|items| !items.is_empty())
            .unwrap_or(false)
    };
    let mut artifacts: Vec<String> = Vec::new();
    if non_empty_object("summary") {
        artifacts.push("_framework/summary.json".to_string());
    }
    if non_empty_object("router") {
        artifacts.push("_framework/router-state.json".to_string());
    }
    for (key, path) in [
        ("roots", "_framework/framework-roots.json"),
        ("stores", "_framework/store-snapshots.json"),
        ("queries", "_framework/query-caches.json"),
        ("hydration", "_framework/hydration-payloads.json"),
        ("auth", "_framework/auth-state.json"),
    ] {
        if non_empty_array(key) {
            artifacts.push(path.to_string());
        }
    }
    artifacts
}

/// `buildFrameworkRuntimeSummary`.
#[allow(clippy::too_many_arguments)]
pub fn build_framework_runtime_summary(
    recon_data: Option<&Value>,
    assets: &[ScriptAsset],
    origins: &[RuntimeOrigin],
    interesting_entrypoints: &[Value],
    boundary_labels: Option<&Value>,
    cross_boundary_flows: Option<&Value>,
) -> Value {
    let stack_profile = recon_data
        .and_then(|r| r.get("stackProfile"))
        .cloned()
        .unwrap_or_else(|| json!({}));
    let capture_status = recon_data
        .and_then(|r| r.get("captureStatus"))
        .cloned()
        .unwrap_or_else(|| json!({}));
    let graphql_ops = recon_data
        .and_then(|r| r.get("recon"))
        .map(collect_graphql_operations)
        .unwrap_or_default();
    let framework_state = build_framework_state_summary(
        recon_data
            .and_then(|r| r.get("frameworkState"))
            .filter(|v| js_truthy(v)),
    );
    let page = recon_data
        .and_then(|r| r.get("page"))
        .cloned()
        .unwrap_or_else(|| json!({}));
    let profile = {
        let from_capture = field_str(&capture_status, "profile");
        if !from_capture.is_empty() {
            from_capture
        } else {
            let from_stack = stack_profile
                .get("strategy")
                .map(|strategy| field_str(strategy, "profile"))
                .unwrap_or_default();
            if !from_stack.is_empty() {
                from_stack
            } else {
                "generic-app".to_string()
            }
        }
    };
    let confidence = truthy_number(&stack_profile, "confidence")
        .or_else(|| truthy_number(&capture_status, "confidence"))
        .unwrap_or(0.0);
    let bundlers: Vec<String> = unique_strings(
        &assets
            .iter()
            .map(|asset| asset.bundler.clone())
            .collect::<Vec<String>>(),
    )
    .into_iter()
    .filter(|bundler| !bundler.is_empty() && bundler != "unknown")
    .collect();
    let top_flows = cross_boundary_flows
        .and_then(|flows| flows.get("topTransitions"))
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    let entrypoints: Vec<Value> = interesting_entrypoints.iter().take(6).cloned().collect();
    json!({
        "generatedAt": iso8601_now(),
        "page": page,
        "profile": profile,
        "confidence": js_number_value(confidence),
        "technologies": stack_profile.get("technologies").cloned().unwrap_or_else(|| json!([])),
        "traits": stack_profile.get("traits").cloned().unwrap_or_else(|| json!([])),
        "strategy": match stack_profile.get("strategy") {
            Some(value) if js_truthy(value) => value.clone(),
            _ => Value::Null,
        },
        "captureReason": field_str(&capture_status, "reasonText"),
        "assetClasses": crate::panel::assets::count_property_values(assets, "classification"),
        "bundlersObserved": bundlers,
        "boundaries": match boundary_labels {
            Some(labels) => labels.get("summary").cloned().unwrap_or(Value::Null),
            None => Value::Null,
        },
        "runtimeKinds": count_origin_kinds(origins),
        "graphQLEndpoints": unique_strings(
            &graphql_ops
                .iter()
                .map(|op| field_str(op, "url"))
                .collect::<Vec<String>>(),
        )
        .into_iter()
        .take(20)
        .collect::<Vec<String>>(),
        "topBoundaryFlows": top_flows.into_iter().take(8).collect::<Vec<Value>>(),
        "likelyEntrypoints": entrypoints,
        "frameworkState": framework_state,
        "signals": match capture_status.get("signals") {
            Some(value) if js_truthy(value) => value.clone(),
            _ => Value::Null,
        },
    })
}

fn count_origin_kinds(origins: &[RuntimeOrigin]) -> BTreeMap<String, usize> {
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    for origin in origins {
        let value = field_str(origin, "kind");
        let value = if value.is_empty() { "unknown".to_string() } else { value };
        *counts.entry(value).or_insert(0) += 1;
    }
    counts
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::panel::assets::{
        build_runtime_origins, prepare_script_assets, ScriptInput,
    };
    use crate::panel::text::js_number_value;
    use crate::util::utf16_len;

    fn fixture() -> Value {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/panel/boundary-oracle.json"
        );
        serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
    }

    fn prepared() -> (Vec<ScriptAsset>, Vec<RuntimeOrigin>, Value, Value) {
        let fx = fixture();
        let input = &fx["input"];
        let scripts: Vec<ScriptInput> =
            serde_json::from_value(input["scriptFixture"].clone()).unwrap();
        let recon_fixture = input["reconFixture"].clone();
        let entries = input["runtimeEntries"].as_array().unwrap().clone();
        let manifest = input["runtimeManifest"].as_array().unwrap().clone();
        let assets = prepare_script_assets(&scripts, Some(&recon_fixture));
        let origins = build_runtime_origins(&entries, &manifest, &assets);
        let mut recon_data = recon_fixture.clone();
        recon_data["recon"] = input["recon"].clone();
        (assets, origins, recon_data, recon_fixture)
    }

    fn without_generated_at(mut value: Value) -> Value {
        value.as_object_mut().unwrap().remove("generatedAt");
        value
    }

    fn event(kind: &str, boundary: &str, labels: &[&str], time: i64) -> Value {
        json!({
            "id": format!("{kind}:{boundary}:{time}"),
            "kind": kind,
            "primaryBoundary": boundary,
            "boundaryLabels": labels,
            "approxTime": time,
            "timestamp": time,
        })
    }

    #[test]
    fn boundary_labeling_matches_oracle() {
        let fx = fixture();
        let exp = &fx["expected"];

        let sample_entry = json!({
            "url": "https://demo.test/A.JS", "file": "F.js", "kind": "eval", "source": "Src",
            "originType": "ot", "classification": "app", "frameworkHints": ["React"],
            "routeHints": ["app"], "startupSignals": ["hydration"], "imports": ["react"],
            "note": "N", "mimeType": "M", "stack": "S", "content": "CONTENT", "text": "TEXT",
        });
        let samples = exp["buildBoundarySample"].as_array().unwrap();
        assert_eq!(
            utf16_len(&build_boundary_sample(&sample_entry)),
            samples[0].as_u64().unwrap() as usize,
            "boundary sample length"
        );
        assert_eq!(
            build_boundary_sample(&Value::Null),
            samples[1].as_str().unwrap(),
            "empty boundary sample"
        );

        let entries = [
            json!({}),
            json!({"classification": "runtime", "url": "https://x/runtime.js"}),
            json!({"classification": "vendor", "url": "https://x/vendor.js"}),
            json!({"classification": "framework", "url": "https://x/app.js"}),
            json!({"url": "https://x/a.js", "routeHints": ["app"]}),
            json!({"url": "https://x/a.js", "startupSignals": ["chunk-loader"]}),
            json!({"url": "https://x/a.js", "content": "redux createStore dispatch(x)"}),
            json!({"url": "https://x/a.js", "content": "axios.get(\"/api/x\")"}),
            json!({"url": "https://x/a.js", "content": "localStorage token signin()"}),
            json!({"url": "https://x/a.js", "content": "gtag(\"event\")"}),
            json!({"url": "https://x/a.js", "content": "monaco.editor.create()"}),
            json!({"url": "https://x/a.js", "content": "node_modules/core-js polyfill"}),
            json!({"kind": "worker", "url": "blob:https://x/w"}),
        ];
        let want = exp["inferBoundaryLabels"].as_array().unwrap();
        let empty_map = BTreeMap::new();
        for (index, entry) in entries.iter().enumerate() {
            assert_eq!(
                Value::Array(infer_boundary_labels(entry, false, &empty_map)),
                want[index],
                "inferBoundaryLabels {index}"
            );
        }

        let runtime_entries = [
            json!({"kind": "worker", "url": "blob:https://x/w"}),
            json!({"kind": "eval", "relatedChunks": ["vendor-1"]}),
            json!({"kind": "eval", "relatedChunks": ["app-1"]}),
        ];
        let asset_map: BTreeMap<String, String> = [
            ("vendor-1".to_string(), "vendor".to_string()),
            ("app-1".to_string(), "app".to_string()),
        ]
        .into_iter()
        .collect();
        let want = exp["inferBoundaryLabelsRuntime"].as_array().unwrap();
        for (index, entry) in runtime_entries.iter().enumerate() {
            assert_eq!(
                Value::Array(infer_boundary_labels(entry, true, &asset_map)),
                want[index],
                "inferBoundaryLabels runtime {index}"
            );
        }

        let mut target = json!({
            "url": "https://x/a.js",
            "content": "axios.get(\"/api/x\") redux dispatch(x)",
        });
        let matches = infer_boundary_labels(&target, false, &empty_map);
        apply_boundary_labels(&mut target, matches);
        assert_eq!(target, exp["applyBoundaryLabels"], "applyBoundaryLabels");
    }

    #[test]
    fn network_boundaries_match_oracle() {
        let fx = fixture();
        let exp = &fx["expected"];
        let entries = [
            json!({"type": "xhr", "url": "https://api.test/graphql", "method": "POST", "requestBody": "{\"query\":\"query Q{a}\"}"}),
            json!({"type": "fetch", "url": "https://x/_next/data/a.json", "method": "GET"}),
            json!({"type": "xhr", "url": "https://x/token/refresh", "method": "POST", "requestHeaders": {"authorization": "Bearer 1"}}),
            json!({"type": "xhr", "url": "https://x/collect", "method": "POST"}),
            json!({"type": "fetch", "url": "https://x/draft/save", "method": "PUT", "responsePreview": "{\"content\":1}"}),
            json!({"type": "fetch", "url": "https://x/persist", "method": "POST"}),
            json!({"type": "fetch", "url": "https://x/plain", "method": "GET"}),
        ];
        let want_samples = exp["buildNetworkBoundarySample"].as_array().unwrap();
        let want_labels = exp["inferNetworkBoundaryLabels"].as_array().unwrap();
        for (index, entry) in entries.iter().enumerate() {
            assert_eq!(
                build_network_boundary_sample(entry),
                want_samples[index].as_str().unwrap(),
                "network sample {index}"
            );
            assert_eq!(
                Value::Array(infer_network_boundary_labels(entry)),
                want_labels[index],
                "network labels {index}"
            );
        }
        let loose = [
            json!("str"),
            Value::Null,
            json!({"a": 1}),
            json!(7),
            json!([1, 2]),
        ];
        let want = exp["stringifyLooseValue"].as_array().unwrap();
        for (index, value) in loose.iter().enumerate() {
            assert_eq!(
                stringify_loose_value(value),
                want[index].as_str().unwrap(),
                "stringifyLooseValue {index}"
            );
        }
        let recon = fx["input"]["recon"].clone();
        assert_eq!(
            Value::Array(build_network_flow_events(Some(&recon))),
            exp["buildNetworkFlowEvents"],
            "buildNetworkFlowEvents"
        );
    }

    #[test]
    fn boundary_report_and_flows_match_oracle() {
        let fx = fixture();
        let exp = &fx["expected"];
        let (mut assets, mut origins, recon_data, _) = prepared();

        let report = build_boundary_labels(&mut assets, &mut origins);
        assert_eq!(
            without_generated_at(report),
            exp["buildBoundaryLabels"],
            "buildBoundaryLabels"
        );
        let tagged: Vec<Value> = assets
            .iter()
            .map(|asset| {
                json!([
                    asset.id,
                    asset.primary_boundary,
                    asset.boundary_labels,
                    asset.boundary_reasons
                ])
            })
            .collect();
        assert_eq!(Value::Array(tagged), exp["taggedAssets"], "tagged assets");

        let flows = build_cross_boundary_flows(Some(&recon_data), &assets, &origins);
        assert_eq!(
            without_generated_at(flows.clone()),
            exp["buildCrossBoundaryFlows"],
            "buildCrossBoundaryFlows"
        );

        let flow_data = collect_flow_events(Some(&recon_data), &assets, &origins);
        assert_eq!(
            Value::Array(flow_data.events.clone()),
            exp["collectFlowEvents"]["events"],
            "flow events"
        );
        let mut got_keys: Vec<String> = flow_data.event_map.keys().cloned().collect();
        let mut want_keys: Vec<String> = exp["collectFlowEvents"]["keys"]
            .as_array()
            .unwrap()
            .iter()
            .map(|key| key.as_str().unwrap().to_string())
            .collect();
        // The Rust lookup is a BTreeMap (the JS object keeps insertion order);
        // only the key SET is part of the behaviour, so compare it sorted.
        got_keys.sort();
        want_keys.sort();
        assert_eq!(got_keys, want_keys, "flow event map keys");
    }

    #[test]
    fn flow_scoring_and_summaries_match_oracle() {
        let fx = fixture();
        let exp = &fx["expected"];
        let pairs = [
            (
                event("chunk", "bootstrap", &["bootstrap"], 0),
                event("chunk", "router", &["router"], 100),
            ),
            (
                event("runtime", "data", &[], 0),
                event("network", "auth", &[], 100),
            ),
            (
                event("network", "data", &[], 0),
                event("runtime", "analytics", &[], 100),
            ),
            (
                event("network", "data", &[], 0),
                event("network", "data", &[], 100),
            ),
            (
                event("chunk", "data", &["data"], 0),
                event("runtime", "data", &["data"], 100),
            ),
            (
                event("chunk", "data", &[], 0),
                event("chunk", "data", &[], 100),
            ),
            (
                event("runtime", "data", &[], 0),
                event("runtime", "data", &[], 100),
            ),
            (
                event("chunk", "auth", &[], 0),
                event("chunk", "data", &[], 5000),
            ),
            (
                event("network", "data", &[], 0),
                event("chunk", "auth", &[], 100),
            ),
        ];
        let want_scores = exp["scoreFlowTransition"].as_array().unwrap();
        let want_descriptions = exp["describeFlowTransition"].as_array().unwrap();
        let want_relations = exp["inferFlowRelation"].as_array().unwrap();
        for (index, (from, to)) in pairs.iter().enumerate() {
            assert_eq!(
                js_number_value(score_flow_transition(from, to, Some(300.0))),
                want_scores[index],
                "scoreFlowTransition {index}"
            );
            assert_eq!(
                describe_flow_transition(from, to, Some(300.0)),
                want_descriptions[index].as_str().unwrap(),
                "describeFlowTransition {index}"
            );
            assert_eq!(
                infer_flow_relation(from, to),
                want_relations[index].as_str().unwrap(),
                "inferFlowRelation {index}"
            );
        }
        assert_eq!(
            describe_flow_transition(&pairs[0].0, &pairs[0].1, None),
            exp["describeFlowTransitionNoLag"].as_str().unwrap(),
            "describeFlowTransition without lag"
        );

        let mut flows: Vec<Value> = Vec::new();
        let mut flow_map: BTreeMap<String, bool> = BTreeMap::new();
        add_boundary_flow(
            &mut flows,
            &mut flow_map,
            &pairs[0].0,
            &pairs[0].1,
            "imports-boundary",
            50.0,
            "e1",
            Some(250.6),
        );
        add_boundary_flow(
            &mut flows,
            &mut flow_map,
            &pairs[0].0,
            &pairs[0].1,
            "imports-boundary",
            50.0,
            "e1",
            Some(250.6),
        );
        add_boundary_flow(
            &mut flows,
            &mut flow_map,
            &pairs[4].0,
            &pairs[4].1,
            "materializes-runtime",
            68.0,
            "e2",
            Some(10.0),
        );
        add_boundary_flow(
            &mut flows,
            &mut flow_map,
            &pairs[2].0,
            &pairs[2].1,
            "follows-response",
            40.0,
            "e3",
            None,
        );
        add_boundary_flow(
            &mut flows,
            &mut flow_map,
            &pairs[1].0,
            &pairs[1].1,
            "triggers-request",
            46.0,
            "e4",
            Some(5.0),
        );
        assert_eq!(Value::Array(flows.clone()), exp["addBoundaryFlow"], "addBoundaryFlow");
        assert_eq!(
            Value::Array(summarize_boundary_transitions(&flows)),
            exp["summarizeBoundaryTransitions"],
            "summarizeBoundaryTransitions"
        );
        assert_eq!(
            Value::Array(build_boundary_chains(&flows)),
            exp["buildBoundaryChains"],
            "buildBoundaryChains"
        );
        assert_eq!(strip_flow_transition(&flows[0]), exp["stripFlowTransition"], "stripFlowTransition");
        assert_eq!(
            strip_flow_event(&flows[0]["from"]),
            exp["stripFlowEvent"],
            "stripFlowEvent"
        );
        assert_eq!(
            strip_boundary_entry(
                &json!({
                    "id": "c1", "file": "https://x/a.js", "url": "https://x/a.js", "score": 30,
                    "primaryBoundary": "data", "boundaryLabels": ["data"], "boundaryReasons": ["r"],
                    "classification": "app",
                }),
                "chunk"
            ),
            exp["stripBoundaryEntry"],
            "stripBoundaryEntry"
        );
    }

    #[test]
    fn framework_summaries_match_oracle() {
        let fx = fixture();
        let exp = &fx["expected"];
        let (mut assets, mut origins, recon_data, _) = prepared();
        let framework_state = json!({
            "profile": "next",
            "generatedAt": "2026-01-01T00:00:00.000Z",
            "reason": "why",
            "roots": [1, 2],
            "stores": [1],
            "queries": [1, 2, 3],
            "hydration": [],
            "auth": [1],
            "router": {"framework": "next", "route": "/a", "source": "x", "queryKeys": ["q"]},
            "summary": {"routerFramework": "fallback", "detectedTechnologies": ["Redux"]},
            "technologies": [{"name": "Next.js"}, {"name": "Next.js"}, {}, null],
        });
        assert_eq!(
            build_framework_state_summary(Some(&framework_state)),
            exp["buildFrameworkStateSummary"],
            "buildFrameworkStateSummary"
        );
        assert_eq!(
            build_framework_state_summary(None),
            exp["buildFrameworkStateSummaryNull"],
            "buildFrameworkStateSummary null"
        );
        assert_eq!(
            Value::Array(
                collect_framework_artifact_paths(Some(&framework_state))
                    .into_iter()
                    .map(Value::String)
                    .collect()
            ),
            exp["collectFrameworkArtifactPaths"],
            "collectFrameworkArtifactPaths"
        );
        assert_eq!(
            Value::Array(
                collect_framework_artifact_paths(Some(&json!({})))
                    .into_iter()
                    .map(Value::String)
                    .collect()
            ),
            exp["collectFrameworkArtifactPathsEmpty"],
            "collectFrameworkArtifactPaths empty"
        );

        let report = build_boundary_labels(&mut assets, &mut origins);
        let flows = build_cross_boundary_flows(Some(&recon_data), &assets, &origins);
        let entrypoints = [json!({"id": "ep1"}), json!({"id": "ep2"})];
        let summary = build_framework_runtime_summary(
            Some(&recon_data),
            &assets,
            &origins,
            &entrypoints,
            Some(&report),
            Some(&flows),
        );
        assert_eq!(
            without_generated_at(summary),
            exp["buildFrameworkRuntimeSummary"],
            "buildFrameworkRuntimeSummary"
        );
    }
}
