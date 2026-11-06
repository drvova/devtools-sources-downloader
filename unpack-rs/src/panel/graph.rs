//! The panel's module graph, startup chain and network/GraphQL operation
//! collection, ported from `page.js` with the JavaScript semantics of the
//! pre-port implementation (verified against node oracles).

use std::sync::LazyLock;

use serde_json::{json, Map, Value};

use crate::panel::assets::{
    field_number, field_str, find_asset_by_reference, get_bare_file_name, js_truthy,
    unique_strings, RuntimeOrigin, ScriptAsset,
};
use crate::panel::model::js_number;
use crate::panel::text::js_number_value;
use crate::util::{iso8601_now, utf16_prefix};

/// `looksLikeGraphQLBody`.
pub fn looks_like_graphql_body(body: &Value) -> bool {
    static KEYWORD: LazyLock<regex::Regex> = LazyLock::new(|| {
        regex::Regex::new(r"(?:^|(?-u:\b))(query|mutation|subscription)(?-u:\b)").unwrap()
    });
    match body {
        Value::String(text) => KEYWORD.is_match(text) || text.contains("operationName"),
        Value::Object(map) => ["query", "operationName", "extensions"]
            .iter()
            .any(|key| map.get(*key).map(js_truthy).unwrap_or(false)),
        Value::Array(_) => false,
        _ => false,
    }
}

/// `normalizeGraphQLPayload`.
fn normalize_graphql_payload(body: &Value) -> Value {
    static OPERATION: LazyLock<regex::Regex> = LazyLock::new(|| {
        regex::Regex::new(r"(?-u:\b)(query|mutation|subscription)[ \t\n\x0B\f\r]+([A-Za-z0-9_]+)")
            .unwrap()
    });
    let parsed = match body {
        Value::String(text) => match serde_json::from_str::<Value>(text) {
            Ok(value) => value,
            Err(_) => json!({ "query": text }),
        },
        other => other.clone(),
    };
    let payload = match &parsed {
        Value::Object(map) => map.clone(),
        _ => Map::new(),
    };
    let query = {
        let from_query = payload
            .get("query")
            .filter(|v| js_truthy(v))
            .map(value_text);
        let from_body = payload.get("body").filter(|v| js_truthy(v)).map(value_text);
        from_query.or(from_body).unwrap_or_default()
    };
    let capture = OPERATION.captures(&query);
    let operation_name = payload
        .get("operationName")
        .filter(|v| js_truthy(v))
        .map(value_text)
        .unwrap_or_else(|| {
            capture
                .as_ref()
                .and_then(|c| c.get(2))
                .map(|m| m.as_str().to_string())
                .unwrap_or_default()
        });
    let operation_type = capture
        .as_ref()
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .unwrap_or_default();
    json!({
        "operationName": operation_name,
        "operationType": operation_type,
        "queryPreview": utf16_prefix(&query, 240),
    })
}

fn value_text(value: &Value) -> String {
    match value {
        Value::String(s) => s.clone(),
        Value::Null => String::new(),
        Value::Number(n) => crate::jsnumber::js_number_to_string(n.as_f64().unwrap_or(f64::NAN)),
        Value::Bool(b) => b.to_string(),
        Value::Array(_) | Value::Object(_) => "[object Object]".to_string(),
    }
}

/// `parseGraphQLOperation`.
fn parse_graphql_operation(entry: &Value) -> Option<Value> {
    if entry.is_null() {
        return None;
    }
    let url = value_text(entry.get("url").unwrap_or(&Value::Null));
    let body = entry.get("requestBody").cloned().unwrap_or(Value::Null);
    if !url.to_lowercase().contains("graphql") && !looks_like_graphql_body(&body) {
        return None;
    }
    let payload = normalize_graphql_payload(&body);
    Some(json!({
        "url": url,
        "method": text_or(entry, "method", "POST"),
        "operationName": payload.get("operationName").cloned().unwrap_or(Value::Null),
        "operationType": payload.get("operationType").cloned().unwrap_or(Value::Null),
        "queryPreview": payload.get("queryPreview").cloned().unwrap_or(Value::Null),
        "timestamp": js_number_value(field_number(entry, "timestamp")),
        "status": js_number_value(field_number(entry, "status")),
    }))
}

/// The JS `entry[key] || fallback` string read.
fn text_or(entry: &Value, key: &str, fallback: &str) -> String {
    let value = field_str(entry, key);
    if value.is_empty() {
        fallback.to_string()
    } else {
        value
    }
}

/// `collectGraphQLOperations`.
pub fn collect_graphql_operations(recon: &Value) -> Vec<Value> {
    let mut operations: Vec<Value> = Vec::new();
    for key in ["xhr", "fetch"] {
        let items = recon
            .get(key)
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();
        for item in items {
            if let Some(parsed) = parse_graphql_operation(&item) {
                operations.push(parsed);
            }
        }
    }
    operations
}

/// `collectNetworkOperations`.
pub fn collect_network_operations(recon: Option<&Value>) -> Vec<Value> {
    let mut operations: Vec<Value> = Vec::new();
    for (kind, key) in [("xhr", "xhr"), ("fetch", "fetch")] {
        let items = recon
            .and_then(|r| r.get(key))
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();
        for item in items {
            let request_body = item
                .get("requestBody")
                .filter(|v| js_truthy(v))
                .cloned()
                .unwrap_or_else(|| Value::String(String::new()));
            let request_headers = item
                .get("requestHeaders")
                .filter(|v| js_truthy(v))
                .cloned()
                .unwrap_or_else(|| json!({}));
            let response_preview = ["responseText", "responseBodyExcerpt", "responsePreview"]
                .iter()
                .find_map(|key| item.get(*key).filter(|v| js_truthy(v)).cloned())
                .unwrap_or_else(|| Value::String(String::new()));
            operations.push(json!({
                "type": kind,
                "url": field_str(&item, "url"),
                "method": text_or(&item, "method", "GET"),
                "status": js_number_value(field_number(&item, "status")),
                "timestamp": js_number_value(field_number(&item, "timestamp")),
                "requestBody": request_body,
                "requestHeaders": request_headers,
                "responseHeaders": field_str(&item, "responseHeaders"),
                "responsePreview": response_preview,
            }));
        }
    }
    operations.sort_by(|left, right| {
        let a = js_number(left.get("timestamp").unwrap_or(&Value::Null));
        let b = js_number(right.get("timestamp").unwrap_or(&Value::Null));
        let a = if a.is_nan() { 0.0 } else { a };
        let b = if b.is_nan() { 0.0 } else { b };
        a.partial_cmp(&b).unwrap_or(std::cmp::Ordering::Equal)
    });
    operations
}

/// `buildModuleGraph`.
pub fn build_module_graph(
    recon: Option<&Value>,
    assets: &[ScriptAsset],
    origins: &[RuntimeOrigin],
) -> Value {
    let mut nodes: Vec<Value> = Vec::new();
    let mut edges: Vec<Value> = Vec::new();
    let mut node_ids: Vec<String> = Vec::new();
    let mut edge_keys: Vec<String> = Vec::new();

    let mut add_node = |id: String, kind: &str, label: String, meta: Option<Value>| {
        if node_ids.contains(&id) {
            return;
        }
        let mut node = json!({ "id": id, "type": kind, "label": label });
        if let (Some(meta), Some(map)) = (meta, node.as_object_mut()) {
            map.insert("meta".to_string(), meta);
        }
        node_ids.push(id);
        nodes.push(node);
    };
    let mut add_edge = |from: String, to: String, reason: String, meta: Option<Value>| {
        let key = format!("{from}->{to}:{reason}");
        if edge_keys.contains(&key) {
            return;
        }
        let mut edge = json!({ "from": from, "to": to, "reason": reason });
        if let (Some(meta), Some(map)) = (meta, edge.as_object_mut()) {
            map.insert("meta".to_string(), meta);
        }
        edge_keys.push(key);
        edges.push(edge);
    };

    let page_label = recon
        .and_then(|r| r.get("page"))
        .and_then(|p| p.get("url"))
        .filter(|v| js_truthy(v))
        .map(value_text)
        .unwrap_or_else(|| "page".to_string());
    add_node("page".to_string(), "page", page_label, None);

    for asset in assets {
        add_node(
            asset.id.clone(),
            "chunk",
            get_bare_file_name(&asset.url),
            Some(json!({
                "classification": asset.classification,
                "bundler": asset.bundler,
                "primaryBoundary": asset.primary_boundary,
            })),
        );
        add_edge(
            "page".to_string(),
            asset.id.clone(),
            "resource".to_string(),
            Some(json!({ "startTime": js_number_value(asset.start_time) })),
        );
        for specifier in &asset.imports {
            match find_asset_by_reference(specifier, assets) {
                Some(target) if target.id != asset.id => add_edge(
                    asset.id.clone(),
                    target.id.clone(),
                    "imports".to_string(),
                    Some(json!({ "specifier": specifier })),
                ),
                _ => {
                    let prefix = if specifier.starts_with('.') || specifier.contains('/') {
                        "ref:"
                    } else {
                        "pkg:"
                    };
                    let dep_id = format!("{prefix}{specifier}");
                    add_node(
                        dep_id.clone(),
                        if dep_id.starts_with("pkg:") {
                            "package"
                        } else {
                            "reference"
                        },
                        specifier.clone(),
                        None,
                    );
                    add_edge(
                        asset.id.clone(),
                        dep_id,
                        "imports".to_string(),
                        Some(json!({ "specifier": specifier })),
                    );
                }
            }
        }
    }

    for origin in origins {
        let origin_id = field_str(origin, "id");
        let runtime_id = format!("runtime:{origin_id}");
        add_node(
            runtime_id.clone(),
            "runtime",
            field_str(origin, "kind"),
            Some(json!({
                "originType": field_str(origin, "originType"),
                "file": field_str(origin, "file"),
                "primaryBoundary": field_str(origin, "primaryBoundary"),
            })),
        );
        let related = origin
            .get("relatedChunks")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();
        if !related.is_empty() {
            for chunk in related {
                add_edge(
                    value_text(&chunk),
                    runtime_id.clone(),
                    field_str(origin, "originType"),
                    None,
                );
            }
        } else if origin.get("blobId").map(js_truthy).unwrap_or(false) {
            add_edge(
                format!(
                    "runtime:{}",
                    value_text(origin.get("blobId").unwrap_or(&Value::Null))
                ),
                runtime_id.clone(),
                "spawns".to_string(),
                None,
            );
        } else {
            add_edge(
                "page".to_string(),
                runtime_id.clone(),
                field_str(origin, "originType"),
                None,
            );
        }
    }

    let graphql_ops = match recon.and_then(|r| r.get("recon")) {
        Some(recon_data) => collect_graphql_operations(recon_data),
        None => Vec::new(),
    };
    let endpoints: Vec<String> = unique_strings(
        &graphql_ops
            .iter()
            .map(|op| field_str(op, "url"))
            .collect::<Vec<String>>(),
    )
    .into_iter()
    .take(12)
    .collect();
    for endpoint in &endpoints {
        let node_id = format!("endpoint:{endpoint}");
        add_node(node_id.clone(), "endpoint", endpoint.clone(), None);
        add_edge("page".to_string(), node_id, "graphql".to_string(), None);
    }

    json!({
        "generatedAt": iso8601_now(),
        "summary": {
            "nodes": nodes.len(),
            "edges": edges.len(),
            "runtimeNodes": origins.len(),
            "chunkNodes": assets.len(),
        },
        "nodes": nodes,
        "edges": edges,
    })
}

/// `buildStartupChain`.
pub fn build_startup_chain(
    recon: Option<&Value>,
    assets: &[ScriptAsset],
    origins: &[RuntimeOrigin],
) -> Value {
    let recon_data = recon.and_then(|r| r.get("recon"));
    let network_ops = collect_network_operations(recon_data);
    let graphql_ops = match recon_data {
        Some(data) => collect_graphql_operations(data),
        None => Vec::new(),
    };

    let mut sorted_scripts: Vec<&ScriptAsset> = assets.iter().collect();
    sorted_scripts.sort_by(|left, right| {
        left.start_time
            .partial_cmp(&right.start_time)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    let scripts: Vec<Value> = sorted_scripts
        .iter()
        .take(40)
        .map(|asset| {
            json!({
                "id": asset.id,
                "url": asset.url,
                "classification": asset.classification,
                "primaryBoundary": asset.primary_boundary,
                "startTime": js_number_value(asset.start_time),
                "duration": js_number_value(asset.duration),
                "startupSignals": asset.startup_signals,
            })
        })
        .collect();

    let mut sorted_runtime: Vec<&RuntimeOrigin> = origins.iter().collect();
    sorted_runtime.sort_by(|left, right| {
        let a = js_number(left.get("timestamp").unwrap_or(&Value::Null));
        let b = js_number(right.get("timestamp").unwrap_or(&Value::Null));
        let a = if a.is_nan() { 0.0 } else { a };
        let b = if b.is_nan() { 0.0 } else { b };
        a.partial_cmp(&b).unwrap_or(std::cmp::Ordering::Equal)
    });
    let runtime: Vec<Value> = sorted_runtime
        .iter()
        .take(40)
        .map(|origin| {
            json!({
                "id": field_str(origin, "id"),
                "kind": field_str(origin, "kind"),
                "originType": field_str(origin, "originType"),
                "primaryBoundary": field_str(origin, "primaryBoundary"),
                "timestamp": js_number_value(field_number(origin, "timestamp")),
                "relatedChunks": origin.get("relatedChunks").cloned()
                    .unwrap_or_else(|| json!([])),
                "file": field_str(origin, "file"),
            })
        })
        .collect();

    let profile = recon
        .and_then(|r| r.get("captureStatus"))
        .and_then(|s| s.get("profile"))
        .filter(|v| js_truthy(v))
        .or_else(|| {
            recon
                .and_then(|r| r.get("stackProfile"))
                .and_then(|s| s.get("strategy"))
                .and_then(|s| s.get("profile"))
                .filter(|v| js_truthy(v))
        })
        .map(value_text)
        .unwrap_or_else(|| "generic-app".to_string());

    json!({
        "generatedAt": iso8601_now(),
        "profile": profile,
        "scripts": scripts,
        "runtime": runtime,
        "data": network_ops.iter().take(40).cloned().collect::<Vec<Value>>(),
        "graphql": graphql_ops.iter().take(20).cloned().collect::<Vec<Value>>(),
        "summary": {
            "scripts": assets.len(),
            "runtime": origins.len(),
            "dataRequests": network_ops.len(),
            "graphqlOperations": graphql_ops.len(),
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> Value {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/panel/graph-oracle.json"
        );
        serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
    }

    /// `looksLikeGraphQLBody` returns `undefined` for objects without any
    /// GraphQL field, and the JS only ever reads it in a boolean position, so
    /// the oracle is compared by truthiness.
    #[test]
    fn graphql_bodies_match_oracle() {
        let fx = fixture();
        let exp = &fx["expected"];
        let bodies = [
            json!("{\"query\":\"query Foo { a }\"}"),
            json!("query Foo { a }"),
            json!("mutation Bar($x:Int){b}"),
            json!("{\"operationName\":\"X\"}"),
            json!("{\"a\":1}"),
            json!(""),
            Value::Null,
            json!({ "query": "query A" }),
            json!({ "operationName": "B" }),
            json!({ "extensions": {} }),
            json!({ "other": 1 }),
            json!(["query A"]),
        ];
        let want = exp["looksLikeGraphQLBody"].as_array().unwrap();
        assert_eq!(bodies.len(), want.len(), "oracle arity");
        for (index, body) in bodies.iter().enumerate() {
            assert_eq!(
                looks_like_graphql_body(body),
                crate::panel::assets::js_truthy(&want[index]),
                "looksLikeGraphQLBody {index}"
            );
        }
        let payloads = [
            json!("{\"query\":\"query Foo($x:Int){a}\",\"operationName\":\"Explicit\"}"),
            json!("{\"body\":\"mutation Baz { b }\"}"),
            json!("not json at all"),
            json!({ "query": "subscription Sub { c }" }),
            json!({ "query": "plain text" }),
            Value::Null,
            json!("{\"query\":\"\"}"),
        ];
        let want = exp["normalizeGraphQLPayload"].as_array().unwrap();
        assert_eq!(payloads.len(), want.len(), "oracle arity");
        for (index, body) in payloads.iter().enumerate() {
            assert_eq!(
                normalize_graphql_payload(body),
                want[index],
                "normalizeGraphQLPayload {index}"
            );
        }
        let entries = [
            json!({"url": "https://api.test/graphql", "method": "POST", "requestBody": "{\"query\":\"query Q{a}\"}", "timestamp": 5, "status": 200}),
            json!({"url": "https://api.test/rest", "requestBody": "{\"query\":\"query R{a}\"}", "timestamp": 0}),
            json!({"url": "https://api.test/rest", "requestBody": "nope", "status": 500}),
            json!({"url": "https://api.test/graphql", "requestBody": {"query": "query S{a}"}}),
            Value::Null,
        ];
        let want = exp["parseGraphQLOperation"].as_array().unwrap();
        assert_eq!(entries.len(), want.len(), "oracle arity");
        for (index, entry) in entries.iter().enumerate() {
            match parse_graphql_operation(entry) {
                Some(value) => assert_eq!(value, want[index], "parseGraphQLOperation {index}"),
                None => assert!(want[index].is_null(), "parseGraphQLOperation {index}"),
            }
        }
    }

    #[test]
    fn graph_and_chain_match_oracle() {
        let fx = fixture();
        let exp = &fx["expected"];
        let input = &fx["input"];
        let recon = input["graphRecon"].clone();
        assert_eq!(
            serde_json::to_value(collect_graphql_operations(&recon)).unwrap(),
            exp["collectGraphQLOperations"],
            "collectGraphQLOperations"
        );
        assert_eq!(
            serde_json::to_value(collect_network_operations(Some(&recon))).unwrap(),
            exp["collectNetworkOperations"],
            "collectNetworkOperations"
        );

        let scripts: Vec<crate::panel::assets::ScriptInput> =
            serde_json::from_value(input["scriptFixture"].clone()).unwrap();
        let recon_fixture = input["reconFixture"].clone();
        let entries = input["runtimeEntries"].as_array().unwrap().clone();
        let manifest = input["runtimeManifest"].as_array().unwrap().clone();
        let assets = crate::panel::assets::prepare_script_assets(&scripts, Some(&recon_fixture));
        let origins = crate::panel::assets::build_runtime_origins(&entries, &manifest, &assets);

        let mut recon_data = recon_fixture.clone();
        for key in ["graphRecon", "page", "captureStatus"] {
            let target = if key == "graphRecon" { "recon" } else { key };
            recon_data[target] = input[key].clone();
        }

        let mut graph = build_module_graph(Some(&recon_data), &assets, &origins);
        graph.as_object_mut().unwrap().remove("generatedAt");
        assert_eq!(graph, exp["buildModuleGraph"], "buildModuleGraph");

        let mut chain = build_startup_chain(Some(&recon_data), &assets, &origins);
        chain.as_object_mut().unwrap().remove("generatedAt");
        assert_eq!(chain, exp["buildStartupChain"], "buildStartupChain");

        let mut stack_recon = recon_fixture.clone();
        stack_recon["stackProfile"] = json!({ "strategy": { "profile": "ssr" } });
        let chain = build_startup_chain(Some(&stack_recon), &assets, &origins);
        assert_eq!(
            chain["profile"], exp["buildStartupChainProfileFromStack"],
            "profile from the stack strategy"
        );
    }
}
