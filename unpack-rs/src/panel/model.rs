//! The panel's resource model: normalization from raw `chrome.devtools`
//! resource objects, filter matching and the sort orders, all with the
//! JavaScript semantics of the pre-port `page.js`.

use std::cmp::Ordering;

use serde::{Deserialize, Serialize};

/// A `{}`-style counter. JavaScript objects keep first-seen key order and
/// these maps are serialized straight into the exported analysis, so the
/// counter preserves insertion order instead of sorting.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Counts(serde_json::Map<String, Value>);

impl Counts {
    pub fn add(&mut self, key: impl Into<String>) {
        let key = key.into();
        let next = self.0.get(&key).and_then(|value| value.as_u64()).unwrap_or(0) + 1;
        self.0.insert(key, Value::from(next));
    }

    pub fn get(&self, key: &str) -> Option<u64> {
        self.0.get(key).and_then(|value| value.as_u64())
    }

    pub fn len(&self) -> usize {
        self.0.len()
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    pub fn keys(&self) -> impl Iterator<Item = &String> {
        self.0.keys()
    }

    pub fn to_value(&self) -> Value {
        Value::Object(self.0.clone())
    }
}

impl Serialize for Counts {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        self.0.serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for Counts {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Ok(Counts(serde_json::Map::deserialize(deserializer)?))
    }
}

use serde_json::Value;

use crate::jsnumber::{js_number_to_string, js_string_to_number};
use crate::panel::text::{js_locale_compare, js_trim};

/// A normalized resource row.
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct Resource {
    pub status: String,
    #[serde(rename = "type")]
    pub kind: String,
    pub source: String,
    pub url: String,
    #[serde(serialize_with = "crate::panel::text::serialize_js_number")]
    pub size: f64,
    #[serde(serialize_with = "crate::panel::text::serialize_js_number")]
    pub time: f64,
    pub order: usize,
}

/// JS truthiness for a JSON value.
fn js_truthy(value: &Value) -> bool {
    match value {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_f64().map(|f| f != 0.0 && !f.is_nan()).unwrap_or(false),
        Value::String(s) => !s.is_empty(),
        Value::Array(_) | Value::Object(_) => true,
    }
}

/// JS `String(value)` for the values the panel actually sees.
fn js_string(value: &Value) -> String {
    match value {
        Value::Null => "null".to_string(),
        Value::Bool(b) => b.to_string(),
        Value::Number(n) => js_number_to_string(n.as_f64().unwrap_or(f64::NAN)),
        Value::String(s) => s.clone(),
        Value::Array(items) => items
            .iter()
            .map(|item| match item {
                Value::Null => String::new(),
                other => js_string(other),
            })
            .collect::<Vec<_>>()
            .join(","),
        Value::Object(_) => "[object Object]".to_string(),
    }
}

/// JS `Number(value)` for a JSON value (`NaN` where JS would produce it).
pub fn js_number(value: &Value) -> f64 {
    match value {
        Value::Null => 0.0,
        Value::Bool(b) => {
            if *b {
                1.0
            } else {
                0.0
            }
        }
        Value::Number(n) => n.as_f64().unwrap_or(f64::NAN),
        Value::String(s) => js_string_to_number(s),
        Value::Array(items) => {
            if items.is_empty() {
                0.0
            } else if items.len() == 1 {
                js_number(&items[0])
            } else {
                f64::NAN
            }
        }
        Value::Object(_) => f64::NAN,
    }
}

/// `getResourceTime`: the first truthy timestamp field, coerced and required
/// to be finite.
fn get_resource_time(resource: &Value) -> f64 {
    for key in ["time", "timestamp", "seenAt", "startTime"] {
        let Some(raw) = resource.get(key) else {
            continue;
        };
        if !js_truthy(raw) {
            continue;
        }
        let value = js_number(raw);
        return if value.is_finite() { value } else { 0.0 };
    }
    0.0
}

/// `normalizeResource`.
pub fn normalize_resource(resource: &Value, status: &str, index: usize) -> Resource {
    let text = |key: &str| match resource.get(key) {
        Some(raw) if js_truthy(raw) => js_string(raw),
        _ => "?".to_string(),
    };
    let size = resource
        .get("size")
        .map(js_number)
        .filter(|value| *value != 0.0 && value.is_finite())
        .unwrap_or(0.0);
    Resource {
        status: status.to_string(),
        kind: text("type"),
        source: text("source"),
        url: text("url"),
        size,
        time: get_resource_time(resource),
        order: index,
    }
}

/// The filter/sort control values, as read from the DOM by the pre-port code.
#[derive(Debug, Clone, Default)]
pub struct ResourceFilters {
    pub status: String,
    pub kind: String,
    pub search: String,
    /// One of `newest` (the default), `largest`, `type`, `url`.
    pub sort: String,
}

/// `matchesResourceFilters`.
pub fn matches_resource_filters(item: &Resource, filters: &ResourceFilters) -> bool {
    if !filters.status.is_empty() && filters.status != "all" && item.status != filters.status {
        return false;
    }
    if !filters.kind.is_empty() && filters.kind != "all" && item.kind != filters.kind {
        return false;
    }
    let search = js_trim(&filters.search).to_lowercase();
    if search.is_empty() {
        return true;
    }
    let haystack = [&item.status, &item.kind, &item.source, &item.url]
        .map(|part| part.as_str())
        .join(" ")
        .to_lowercase();
    haystack.contains(&search)
}

/// `compareResources` for one of the four sort modes.
pub fn compare_resources(left: &Resource, right: &Resource, mode: &str) -> Ordering {
    match mode {
        "largest" => right
            .size
            .partial_cmp(&left.size)
            .unwrap_or(Ordering::Equal)
            .then_with(|| right.time.partial_cmp(&left.time).unwrap_or(Ordering::Equal)),
        "type" => js_locale_compare(&left.kind, &right.kind)
            .then_with(|| js_locale_compare(&left.url, &right.url)),
        "url" => js_locale_compare(&left.url, &right.url),
        _ => right
            .time
            .partial_cmp(&left.time)
            .unwrap_or(Ordering::Equal)
            .then_with(|| left.order.cmp(&right.order)),
    }
}

/// The distinct types in first-seen order, sorted the way the panel's
/// `Array.prototype.sort()` sorts: by UTF-16 code units.
pub fn collect_types(items: &[Resource]) -> Vec<String> {
    let mut seen: Vec<String> = Vec::new();
    for item in items {
        let kind = if item.kind.is_empty() {
            "?".to_string()
        } else {
            item.kind.clone()
        };
        if !seen.contains(&kind) {
            seen.push(kind);
        }
    }
    seen.sort_by(|a, b| a.encode_utf16().cmp(b.encode_utf16()));
    seen
}

/// `updateTypeFilterOptions`'s value preservation: keep the current selection
/// when it still exists (or is "all"), otherwise fall back to "all".
pub fn resolve_type_selection(current: &str, types: &[String]) -> String {
    let present = types.iter().any(|t| t == current);
    if present || current == "all" {
        current.to_string()
    } else {
        "all".to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // Oracles captured from node running the pre-port page.js functions.

    #[test]
    fn normalize_resource_matches_node() {
        let rows = [
            (
                json!({"type": "script", "source": "network", "url": "https://x/a.js", "size": 100, "time": 5}),
                "loaded",
                0,
            ),
            (json!({}), "unloaded", 3),
            (json!({"size": "2048", "timestamp": 12}), "loaded", 1),
            (json!({"size": "abc", "startTime": f64::INFINITY}), "loaded", 2),
            (Value::Null, "unloaded", 4),
            (json!({"seenAt": 7}), "loaded", 5),
        ];
        let got: Vec<Value> = rows
            .iter()
            .map(|(raw, status, index)| serde_json::to_value(normalize_resource(raw, status, *index)).unwrap())
            .collect();
        let want = json!([
            {"status": "loaded", "type": "script", "source": "network", "url": "https://x/a.js", "size": 100, "time": 5, "order": 0},
            {"status": "unloaded", "type": "?", "source": "?", "url": "?", "size": 0, "time": 0, "order": 3},
            {"status": "loaded", "type": "?", "source": "?", "url": "?", "size": 2048, "time": 12, "order": 1},
            {"status": "loaded", "type": "?", "source": "?", "url": "?", "size": 0, "time": 0, "order": 2},
            {"status": "unloaded", "type": "?", "source": "?", "url": "?", "size": 0, "time": 0, "order": 4},
            {"status": "loaded", "type": "?", "source": "?", "url": "?", "size": 0, "time": 7, "order": 5},
        ]);
        assert_eq!(Value::Array(got), want);
    }

    fn sample_items() -> Vec<Resource> {
        [
            ("loaded", "script", "network", "https://x/a.js", 300.0, 5.0, 0usize),
            ("unloaded", "image", "memory", "https://x/b.png", 100.0, 9.0, 1),
            ("loaded", "script", "network", "https://x/c.js", 100.0, 9.0, 2),
            ("loaded", "Script", "Network", "HTTPS://X/D.JS", 100.0, 1.0, 3),
        ]
        .into_iter()
        .map(|(status, kind, source, url, size, time, order)| Resource {
            status: status.to_string(),
            kind: kind.to_string(),
            source: source.to_string(),
            url: url.to_string(),
            size,
            time,
            order,
        })
        .collect()
    }

    #[test]
    fn filters_match_node() {
        let items = sample_items();
        let cases = [
            ("all", "all", "", [true, true, true, true]),
            ("loaded", "all", "", [true, false, true, true]),
            ("all", "script", "", [true, false, true, false]),
            ("all", "all", "NETWORK", [true, false, true, true]),
            ("all", "all", "b.png", [false, true, false, false]),
            ("all", "all", "  ", [true, true, true, true]),
        ];
        for (status, kind, search, want) in cases {
            let filters = ResourceFilters {
                status: status.to_string(),
                kind: kind.to_string(),
                search: search.to_string(),
                ..Default::default()
            };
            let got: Vec<bool> = items
                .iter()
                .map(|item| matches_resource_filters(item, &filters))
                .collect();
            assert_eq!(got, want.to_vec(), "filters {status}/{kind}/{search}");
        }
    }

    #[test]
    fn sorts_match_node() {
        let items = sample_items();
        let sorted_urls = |mode: &str| {
            let mut rows = items.clone();
            rows.sort_by(|a, b| compare_resources(a, b, mode));
            rows.into_iter().map(|r| r.url).collect::<Vec<_>>()
        };
        assert_eq!(
            sorted_urls("newest"),
            vec![
                "https://x/b.png",
                "https://x/c.js",
                "https://x/a.js",
                "HTTPS://X/D.JS"
            ]
        );
        assert_eq!(
            sorted_urls("largest"),
            vec![
                "https://x/a.js",
                "https://x/b.png",
                "https://x/c.js",
                "HTTPS://X/D.JS"
            ]
        );
        assert_eq!(
            sorted_urls("type"),
            vec![
                "https://x/b.png",
                "https://x/a.js",
                "https://x/c.js",
                "HTTPS://X/D.JS"
            ]
        );
        assert_eq!(
            sorted_urls("url"),
            vec![
                "https://x/a.js",
                "https://x/b.png",
                "https://x/c.js",
                "HTTPS://X/D.JS"
            ]
        );
    }

    #[test]
    fn resource_times_match_node() {
        assert_eq!(get_resource_time(&json!({"time": 5})), 5.0);
        assert_eq!(get_resource_time(&json!({"timestamp": 12})), 12.0);
        assert_eq!(get_resource_time(&json!({"startTime": f64::INFINITY})), 0.0);
        assert_eq!(get_resource_time(&json!({})), 0.0);
        assert_eq!(get_resource_time(&Value::Null), 0.0);
        assert_eq!(get_resource_time(&json!({"time": "3.5"})), 3.5);
    }

    #[test]
    fn type_options_preserve_selection() {
        let items = sample_items();
        let types = collect_types(&items);
        assert_eq!(types, vec!["Script", "image", "script"]);
        assert_eq!(resolve_type_selection("script", &types), "script");
        assert_eq!(resolve_type_selection("image", &types), "image");
        assert_eq!(resolve_type_selection("all", &types), "all");
        assert_eq!(resolve_type_selection("wasm", &types), "all");
    }
}
