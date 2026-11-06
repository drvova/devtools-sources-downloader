//! Artifact and export helpers from `page.js`: runtime payload paths and
//! extensions, the runtime unpack-asset builder, report merging, cookie
//! parsing, inline JSON serialization, the waterfall/recon stat markup and the
//! readable-artifact header.
//!
//! The zip seam stays where the engine put it (a writer closure owned by the
//! caller), so these functions build names and payloads only.

use std::collections::BTreeMap;
use std::sync::LazyLock;

use serde_json::Value;

use crate::panel::assets::{field_str, js_truthy};
use crate::panel::model::js_number;
use crate::panel::text::{format_ms, format_size, js_number_value};
use crate::panel::view::escape_html;
use crate::pipeline::Asset;

/// `runtimeFolderName`.
fn runtime_folder_name(kind: &str) -> &'static str {
    match kind {
        "eval" => "eval",
        "function" => "function",
        "blob" => "blob",
        "worker" => "workers",
        "shared-worker" => "shared-workers",
        "service-worker" => "service-workers",
        "script-injection" => "script-injections",
        "wasm" => "wasm",
        _ => "misc",
    }
}

/// The mime table, compiled once. It used to build a fresh `Regex` on every
/// call, inside the loop below, once per runtime entry.
static MIME_TABLE: LazyLock<Vec<(regex::Regex, &'static str)>> = LazyLock::new(|| {
    [
        (r"(?i)javascript|ecmascript|typescript", "js"),
        (r"(?i)json", "json"),
        (r"(?i)html", "html"),
        (r"(?i)css", "css"),
        (r"(?i)svg", "svg"),
        (r"(?i)xml", "xml"),
        (r"(?i)text", "txt"),
    ]
    .into_iter()
    .map(|(pattern, extension)| {
        (
            regex::Regex::new(pattern).expect("mime pattern compiles"),
            extension,
        )
    })
    .collect()
});

/// `runtimeExtension`.
fn runtime_extension(entry: &Value) -> String {
    static WASM: LazyLock<regex::Regex> = LazyLock::new(|| regex::Regex::new(r"(?i)wasm").unwrap());
    let kind = field_str(entry, "kind");
    let mime_type = field_str(entry, "mimeType");
    if kind == "wasm" || WASM.is_match(&mime_type) {
        return "wasm".to_string();
    }
    for (pattern, extension) in MIME_TABLE.iter() {
        if pattern.is_match(&mime_type) {
            return (*extension).to_string();
        }
    }
    match kind.as_str() {
        "eval" | "function" | "worker" | "shared-worker" | "service-worker"
        | "script-injection" => "js".to_string(),
        _ => {
            if entry.get("base64").map(js_truthy).unwrap_or(false) {
                "bin".to_string()
            } else {
                "txt".to_string()
            }
        }
    }
}

/// `buildRuntimePath`.
pub fn build_runtime_path(entry: &Value, counters: &mut BTreeMap<String, usize>) -> String {
    let folder = runtime_folder_name(&field_str(entry, "kind"));
    let count = counters.entry(folder.to_string()).or_insert(0);
    *count += 1;
    format!(
        "_runtime/{folder}/{:04}.{}",
        *count,
        runtime_extension(entry)
    )
}

/// `buildRuntimeUnpackAssets`: the text payloads the unpack engine can read,
/// with the manifest's recorded path.
pub fn build_runtime_unpack_assets(payloads: &[Value], manifest: &[Value]) -> Vec<Asset> {
    let mut assets: Vec<Asset> = Vec::new();
    for entry in payloads {
        let text = match entry.get("text") {
            Some(Value::String(text)) if !text.is_empty() => text.clone(),
            _ => continue,
        };
        if runtime_extension(entry) != "js" {
            continue;
        }
        let id = field_str(entry, "id");
        let raw_file = manifest
            .iter()
            .find(|item| field_str(item, "id") == id)
            .map(|item| field_str(item, "file"))
            .unwrap_or_default();
        let url = {
            let url = field_str(entry, "url");
            if !url.is_empty() {
                url
            } else {
                let label = field_str(entry, "label");
                if !label.is_empty() {
                    label
                } else {
                    id
                }
            }
        };
        assets.push(Asset::Text {
            url,
            content: text,
            zip_path: Some(raw_file),
        });
    }
    assets
}

/// `mergeUnpackReports`: the script report absorbs the runtime report totals.
pub fn merge_unpack_reports(script_report: &mut Value, runtime_report: &Value) {
    let keys = ["assets", "unpacked", "modules", "sources", "beautified"];
    for key in keys {
        let runtime_total = runtime_report
            .get("totals")
            .and_then(|totals| totals.get(key))
            .and_then(|value| value.as_f64())
            .unwrap_or(0.0);
        if let Some(totals) = script_report
            .get_mut("totals")
            .and_then(|totals| totals.as_object_mut())
        {
            let current = totals
                .get(key)
                .and_then(|value| value.as_f64())
                .unwrap_or(0.0);
            totals.insert(key.to_string(), js_number_value(current + runtime_total));
        }
    }
}

/// `parseCookies`.
pub fn parse_cookies(cookie_str: &str) -> serde_json::Map<String, Value> {
    let mut result: serde_json::Map<String, Value> = serde_json::Map::new();
    for pair in cookie_str.split(';') {
        let Some(at) = pair.find('=') else {
            continue;
        };
        result.insert(
            pair[..at].trim().to_string(),
            Value::String(pair[at + 1..].trim().to_string()),
        );
    }
    result
}

/// `serializeInlineJson`.
pub fn serialize_inline_json(value: &Value) -> String {
    let subject = if js_truthy(value) {
        value.clone()
    } else {
        Value::Object(serde_json::Map::new())
    };
    serde_json::to_string(&subject)
        .unwrap_or_default()
        .replace('<', "\\u003c")
        .replace('>', "\\u003e")
        .replace('&', "\\u0026")
}

/// `escapeXml`.
pub fn escape_xml(value: &Value) -> String {
    match value {
        Value::Null => String::new(),
        Value::String(text) => escape_html(text),
        Value::Bool(flag) => escape_html(&flag.to_string()),
        Value::Number(number) => escape_html(&crate::jsnumber::js_number_to_string(
            number.as_f64().unwrap_or(f64::NAN),
        )),
        other => escape_html(&serde_json::to_string(other).unwrap_or_default()),
    }
}

/// `escapeAttr`: attributes do not escape single quotes.
pub fn escape_attr(value: &Value) -> String {
    let text = match value {
        Value::Null => String::new(),
        Value::String(text) => text.clone(),
        Value::Bool(flag) => flag.to_string(),
        Value::Number(number) => {
            crate::jsnumber::js_number_to_string(number.as_f64().unwrap_or(f64::NAN))
        }
        other => serde_json::to_string(other).unwrap_or_default(),
    };
    let mut out = String::with_capacity(text.len());
    for character in text.chars() {
        match character {
            '&' => out.push_str("&amp;"),
            '"' => out.push_str("&quot;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            _ => out.push(character),
        }
    }
    out
}

/// `computeReconStats`.
pub fn compute_recon_stats(timings: &[Value]) -> String {
    static DOMAIN: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"^https?://([^/]+)").unwrap());
    let mut total_bytes = 0.0f64;
    let mut slowest = 0.0f64;
    let mut domains: Vec<String> = Vec::new();
    let mut types: Vec<(String, usize)> = Vec::new();
    for timing in timings {
        let transfer = truthy_or(timing, "transferSize")
            .or_else(|| truthy_or(timing, "encodedBodySize"))
            .unwrap_or(0.0);
        total_bytes += transfer;
        let duration = {
            let span = timing
                .get("responseEnd")
                .and_then(|v| v.as_f64())
                .unwrap_or(0.0)
                - timing
                    .get("startTime")
                    .and_then(|v| v.as_f64())
                    .unwrap_or(0.0);
            if span != 0.0 && !span.is_nan() {
                span
            } else {
                truthy_or(timing, "duration").unwrap_or(0.0)
            }
        };
        if duration > slowest {
            slowest = duration;
        }
        let name = field_str(timing, "name");
        if let Some(capture) = DOMAIN.captures(&name) {
            let domain = capture.get(1).map(|m| m.as_str()).unwrap_or_default();
            if !domains.iter().any(|existing| existing == domain) {
                domains.push(domain.to_string());
            }
        }
        let kind = {
            let initiator = field_str(timing, "initiatorType");
            if initiator.is_empty() {
                "other".to_string()
            } else {
                initiator
            }
        };
        match types.iter_mut().find(|(name, _)| *name == kind) {
            Some((_, count)) => *count += 1,
            None => types.push((kind, 1)),
        }
    }
    let mut type_markup = String::new();
    for (kind, count) in &types {
        type_markup.push_str(&format!(
            "<div class=\"stat\"><div class=\"val\">{count}</div><div class=\"lbl\">{}</div></div>",
            escape_html(kind)
        ));
    }
    format!(
        "<div class=\"stat\"><div class=\"val\">{}</div><div class=\"lbl\">Requests</div></div>\
<div class=\"stat\"><div class=\"val\">{}</div><div class=\"lbl\">Total Size</div></div>\
<div class=\"stat\"><div class=\"val\">{}</div><div class=\"lbl\">Domains</div></div>\
<div class=\"stat\"><div class=\"val\">{}</div><div class=\"lbl\">Slowest</div></div>{type_markup}",
        timings.len(),
        format_size(total_bytes),
        domains.len(),
        format_ms(slowest),
    )
}

fn truthy_or(entry: &Value, key: &str) -> Option<f64> {
    match entry.get(key) {
        Some(value) if js_truthy(value) => Some(js_number(value)),
        _ => None,
    }
}

/// `generateDOMSnapshotHTML`.
pub fn generate_dom_snapshot_html(dom_html: &str, page_meta: &Value) -> String {
    let title = {
        let title = field_str(page_meta, "title");
        if title.is_empty() {
            "DOM Snapshot".to_string()
        } else {
            title
        }
    };
    let url = field_str(page_meta, "url");
    format!(
        "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"UTF-8\">\n<title>DOM Snapshot</title>\n<style>body{{font-family:system-ui,sans-serif;padding:20px;background:#fff;color:#222}}h1{{margin:0 0 8px}}p{{margin:0 0 16px;color:#555}}pre{{white-space:pre-wrap;word-break:break-word;font-family:Consolas,monospace;font-size:12px;line-height:1.5;background:#f7f7f7;border:1px solid #ddd;border-radius:6px;padding:16px}}</style>\n</head>\n<body><h1>{}</h1><p>{}</p><pre>{}</pre></body>\n</html>",
        escape_html(&title),
        escape_html(&url),
        escape_html(dom_html),
    )
}

/// `buildReadableArtifact` with an injectable beautifier seam (the engine
/// functions are what the default path uses).
pub fn build_readable_artifact_with(
    entry: &Value,
    record: &Value,
    looks_minified_fn: &dyn Fn(&str) -> bool,
    beautify_fn: &dyn Fn(&str) -> String,
) -> String {
    let body = {
        let field = if field_str(entry, "kind") == "chunk" {
            "content"
        } else {
            "text"
        };
        match record.get(field) {
            Some(Value::String(text)) if !text.is_empty() => text.clone(),
            _ => String::new(),
        }
    };
    let readable = if looks_minified_fn(&body) {
        beautify_fn(&body)
    } else {
        body.clone()
    };
    let facts = [
        format!("Kind: {}", field_str(entry, "kind")),
        format!("Label: {}", {
            let label = field_str(entry, "label");
            if label.is_empty() {
                field_str(entry, "id")
            } else {
                label
            }
        }),
        format!("URL: {}", field_str(entry, "url")),
        format!("File: {}", field_str(entry, "file")),
        format!("Boundaries: {}", {
            let labels = entry
                .get("boundaryLabels")
                .and_then(|v| v.as_array())
                .map(|items| {
                    items
                        .iter()
                        .filter_map(|item| item.as_str())
                        .collect::<Vec<&str>>()
                        .join(", ")
                })
                .unwrap_or_default();
            if labels.is_empty() {
                "none".to_string()
            } else {
                labels
            }
        }),
        format!("Why: {}", field_str(entry, "why")),
        format!(
            "Score: {}",
            crate::jsnumber::js_number_to_string(truthy_or(entry, "score").unwrap_or(0.0))
        ),
        format!(
            "Beautified: {}",
            if readable == body { "no" } else { "yes" }
        ),
    ];
    let mut header = String::from("/*\n * Semantic reconstruction");
    for fact in &facts {
        header.push_str("\n * ");
        header.push_str(fact);
    }
    header.push_str("\n */\n");
    format!("{header}{readable}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn fixture() -> Value {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/panel/artifacts-oracle.json"
        );
        serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
    }

    #[test]
    fn runtime_paths_match_oracle() {
        let fx = fixture();
        let exp = &fx["expected"];
        let kinds = [
            "eval",
            "function",
            "blob",
            "worker",
            "shared-worker",
            "service-worker",
            "script-injection",
            "wasm",
            "other",
            "",
        ];
        let want = exp["runtimeFolderName"].as_array().unwrap();
        for (index, kind) in kinds.iter().enumerate() {
            assert_eq!(
                runtime_folder_name(kind),
                want[index].as_str().unwrap(),
                "runtimeFolderName {index}"
            );
        }

        let entries = [
            json!({"kind": "wasm"}),
            json!({"kind": "eval", "mimeType": "application/javascript"}),
            json!({"kind": "eval", "mimeType": "application/json"}),
            json!({"kind": "eval", "mimeType": "text/html"}),
            json!({"kind": "eval", "mimeType": "text/css"}),
            json!({"kind": "eval", "mimeType": "image/svg+xml"}),
            json!({"kind": "eval", "mimeType": "application/xml"}),
            json!({"kind": "eval", "mimeType": "text/plain"}),
            json!({"kind": "eval"}),
            json!({"kind": "function"}),
            json!({"kind": "worker"}),
            json!({"kind": "shared-worker"}),
            json!({"kind": "service-worker"}),
            json!({"kind": "script-injection"}),
            json!({"kind": "blob"}),
            json!({"kind": "blob", "base64": "AAAA"}),
            json!({"kind": "blob", "mimeType": "application/wasm"}),
        ];
        let want = exp["runtimeExtension"].as_array().unwrap();
        for (index, entry) in entries.iter().enumerate() {
            assert_eq!(
                runtime_extension(entry),
                want[index].as_str().unwrap(),
                "runtimeExtension {index}"
            );
        }

        let path_entries = [
            json!({"kind": "eval", "mimeType": "application/javascript"}),
            json!({"kind": "eval"}),
            json!({"kind": "wasm"}),
            json!({"kind": "worker"}),
            json!({"kind": "worker"}),
            json!({"kind": "mystery"}),
        ];
        let want = exp["buildRuntimePath"].as_array().unwrap();
        let mut counters: BTreeMap<String, usize> = BTreeMap::new();
        for (index, entry) in path_entries.iter().enumerate() {
            assert_eq!(
                build_runtime_path(entry, &mut counters),
                want[index].as_str().unwrap(),
                "buildRuntimePath {index}"
            );
        }

        let payloads = [
            json!({"id": "r1", "kind": "eval", "text": "var a = 1", "url": "https://x/a.js"}),
            json!({"id": "r2", "kind": "wasm", "text": "WASMTEXT", "url": "https://x/b.wasm"}),
            json!({"id": "r3", "kind": "eval", "text": ""}),
            json!({"id": "r4", "kind": "eval", "label": "labelled", "text": "var b = 2"}),
            json!({"id": "r5", "kind": "eval", "text": "var c = 3"}),
        ];
        let manifest = [
            json!({"id": "r1", "file": "runtime/eval-1.js"}),
            json!({"id": "r4", "file": "runtime/eval-4.js"}),
        ];
        let got: Vec<Value> = build_runtime_unpack_assets(&payloads, &manifest)
            .into_iter()
            .map(|asset| match asset {
                Asset::Text {
                    url,
                    content,
                    zip_path,
                } => json!({
                    "url": url,
                    "content": content,
                    "zipPath": zip_path.unwrap_or_default(),
                }),
                Asset::Bytes { .. } => unreachable!("runtime payloads are text"),
            })
            .collect();
        assert_eq!(
            Value::Array(got),
            exp["buildRuntimeUnpackAssets"][0],
            "buildRuntimeUnpackAssets"
        );
        assert_eq!(
            Value::Array(Vec::new()),
            exp["buildRuntimeUnpackAssets"][1],
            "empty asset list"
        );
        assert!(build_runtime_unpack_assets(&[], &[]).is_empty());
    }

    #[test]
    fn export_helpers_match_oracle() {
        let fx = fixture();
        let exp = &fx["expected"];

        let mut script_report = json!({
            "totals": {"assets": 3, "unpacked": 2, "modules": 1, "sources": 4, "beautified": 1},
            "files": ["a.js"],
        });
        let runtime_report = json!({
            "totals": {"assets": 5, "unpacked": 4, "modules": 3, "sources": 2, "beautified": 2},
            "files": ["b.js"],
        });
        merge_unpack_reports(&mut script_report, &runtime_report);
        assert_eq!(
            script_report, exp["mergeUnpackReports"],
            "mergeUnpackReports"
        );

        let cookie_inputs = ["a=1; b = 2 ;; c=3=4; broken", ""];
        let want = exp["parseCookies"].as_array().unwrap();
        for (index, input) in cookie_inputs.iter().enumerate() {
            assert_eq!(
                serde_json::to_value(parse_cookies(input)).unwrap(),
                want[index],
                "parseCookies {index}"
            );
            // Insertion order is part of the port: the object is serialized
            // into _recon/cookies.json as written.
            let got_keys: Vec<String> = parse_cookies(input).keys().cloned().collect();
            let want_keys: Vec<String> = want[index]
                .as_object()
                .map(|map| map.keys().cloned().collect())
                .unwrap_or_default();
            assert_eq!(got_keys, want_keys, "parseCookies order {index}");
        }

        let inline_inputs = [json!({"a": "<b>&", "c": ["</script>"]}), Value::Null];
        let want = exp["serializeInlineJson"].as_array().unwrap();
        for (index, input) in inline_inputs.iter().enumerate() {
            assert_eq!(
                serialize_inline_json(input),
                want[index].as_str().unwrap(),
                "serializeInlineJson {index}"
            );
        }

        let escape_inputs = [json!("<a & \"b\" 'c'>"), json!(""), Value::Null, json!(7)];
        let want = exp["escapeXml"].as_array().unwrap();
        for (index, input) in escape_inputs.iter().enumerate() {
            assert_eq!(
                escape_xml(input),
                want[index].as_str().unwrap(),
                "escapeXml {index}"
            );
        }
        let want = exp["escapeAttr"].as_array().unwrap();
        for (index, input) in escape_inputs.iter().take(3).enumerate() {
            assert_eq!(
                escape_attr(input),
                want[index].as_str().unwrap(),
                "escapeAttr {index}"
            );
        }

        let timings = [
            json!({"name": "https://a.test/x.js", "transferSize": 1000, "startTime": 10, "responseEnd": 30, "duration": 20, "initiatorType": "script"}),
            json!({"name": "https://b.test/y.css", "encodedBodySize": 500, "startTime": 5, "duration": 5, "initiatorType": "link"}),
            json!({"name": "not a url", "transferSize": 0, "startTime": 1, "duration": 0}),
            json!({"name": "https://a.test/z.png", "transferSize": 2000, "startTime": 1, "responseEnd": 3, "initiatorType": "img"}),
        ];
        assert_eq!(
            compute_recon_stats(&timings),
            exp["computeReconStats"].as_str().unwrap(),
            "computeReconStats"
        );
        assert_eq!(
            compute_recon_stats(&[]),
            exp["computeReconStatsEmpty"].as_str().unwrap(),
            "computeReconStats empty"
        );

        assert_eq!(
            generate_dom_snapshot_html(
                "<div>&amp;</div>",
                &json!({"title": "<t>", "url": "https://x/?a=1&b=2"})
            ),
            exp["generateDOMSnapshotHTML"][0].as_str().unwrap(),
            "generateDOMSnapshotHTML"
        );
        assert_eq!(
            generate_dom_snapshot_html("", &Value::Null),
            exp["generateDOMSnapshotHTML"][1].as_str().unwrap(),
            "generateDOMSnapshotHTML without page meta"
        );
    }

    #[test]
    fn readable_artifact_matches_oracle() {
        let fx = fixture();
        let exp = &fx["expected"];
        // The oracle stubs the engine's beautifier at the seam, so the assembly
        // logic is compared with the same stub; the default path uses the
        // engine functions, which carry their own oracle tests.
        let looks = |text: &str| text.starts_with("MIN");
        let beautify = |text: &str| format!("BEAUTIFIED({text})");
        let cases = [
            (
                json!({
                    "kind": "chunk", "id": "c1", "label": "L", "url": "https://x/a.js",
                    "file": "a.js", "boundaryLabels": ["data", "auth"], "why": "why", "score": 30,
                }),
                json!({"content": "MINvar a=1", "text": "IGNORED"}),
            ),
            (
                json!({"kind": "runtime", "id": "r1"}),
                json!({"content": "IGNORED", "text": "plain text"}),
            ),
            (
                json!({"kind": "runtime", "id": "r2", "score": 0}),
                json!({"text": "MINx"}),
            ),
        ];
        let want = exp["buildReadableArtifact"].as_array().unwrap();
        for (index, (entry, record)) in cases.iter().enumerate() {
            assert_eq!(
                build_readable_artifact_with(entry, record, &looks, &beautify),
                want[index].as_str().unwrap(),
                "buildReadableArtifact {index}"
            );
        }
    }
}
