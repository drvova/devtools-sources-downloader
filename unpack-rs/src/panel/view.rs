//! The panel's view layer: view models plus the HTML strings the platform
//! shim applies to the DOM. The pre-port renderers built elements with
//! `createElement`/`textContent`; the produced markup here is the same
//! structure with the same classes, labels and inline styles, so the CSS and
//! the e2e selectors keep working.

use serde::Serialize;

use crate::panel::model::{
    collect_types, compare_resources, matches_resource_filters, normalize_resource,
    resolve_type_selection, Resource, ResourceFilters,
};

/// Escape text for both element and attribute contexts.
pub fn escape_html(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(c),
        }
    }
    out
}

/// One `<tr>` per row, mirroring `appendResourceRow`.
fn resource_rows_html(items: &[Resource]) -> String {
    let mut out = String::new();
    for row in items {
        let dot = if row.status == "loaded" {
            "#48c774"
        } else {
            "#f14668"
        };
        let kind = if row.kind.is_empty() { "?" } else { &row.kind };
        let source = if row.source.is_empty() {
            "?"
        } else {
            &row.source
        };
        let url = if row.url.is_empty() { "?" } else { &row.url };
        out.push_str("<tr>");
        out.push_str(&format!(
            "<td data-label=\"Status\"><span style=\"display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:4px;background-color:{dot}\"></span>{}</td>",
            escape_html(&row.status)
        ));
        out.push_str(&format!(
            "<td data-label=\"Type\">{}</td>",
            escape_html(kind)
        ));
        out.push_str(&format!(
            "<td data-label=\"Source\">{}</td>",
            escape_html(source)
        ));
        out.push_str(&format!(
            "<td data-label=\"URL\" class=\"url-cell mono\" title=\"{}\">{}</td>",
            escape_html(url),
            escape_html(url)
        ));
        out.push_str(&format!(
            "<td data-label=\"Size\">{}</td>",
            escape_html(&crate::panel::text::format_size(row.size))
        ));
        out.push_str("</tr>");
    }
    out
}

/// The type filter's `<option>` list, mirroring `updateTypeFilterOptions`.
fn type_options_html(types: &[String]) -> String {
    let mut out = String::from("<option value=\"all\">All types</option>");
    for kind in types {
        out.push_str(&format!(
            "<option value=\"{}\">{}</option>",
            escape_html(kind),
            escape_html(kind)
        ));
    }
    out
}

/// The complete tracker view: counters, filter state and the row markup.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TrackerView {
    pub loaded: usize,
    pub unloaded: usize,
    pub visible: usize,
    pub total: usize,
    pub type_selection: String,
    pub show_status_bar: bool,
    pub show_list: bool,
    pub show_empty: bool,
    pub rows_html: String,
    pub types_html: String,
}

/// Build the tracker view from the raw tracker payload and the control
/// values, following `renderTrackerView` exactly.
pub fn tracker_view(tracker: &serde_json::Value, filters: &ResourceFilters) -> TrackerView {
    let empty = Vec::new();
    let loaded = tracker
        .get("loaded")
        .and_then(|v| v.as_array())
        .unwrap_or(&empty);
    let unloaded = tracker
        .get("unloaded")
        .and_then(|v| v.as_array())
        .unwrap_or(&empty);

    let mut items: Vec<Resource> = Vec::new();
    for (index, raw) in loaded.iter().enumerate() {
        items.push(normalize_resource(raw, "loaded", index));
    }
    for (index, raw) in unloaded.iter().enumerate() {
        items.push(normalize_resource(raw, "unloaded", loaded.len() + index));
    }

    let types = collect_types(&items);
    let type_selection = resolve_type_selection(&filters.kind, &types);

    let mut filtered: Vec<Resource> = items
        .iter()
        .filter(|item| matches_resource_filters(item, filters))
        .cloned()
        .collect();
    filtered.sort_by(|a, b| compare_resources(a, b, &filters.sort));

    let has_items = !items.is_empty();
    TrackerView {
        loaded: loaded.len(),
        unloaded: unloaded.len(),
        visible: filtered.len(),
        total: items.len(),
        type_selection,
        show_status_bar: true,
        show_list: has_items && !filtered.is_empty(),
        show_empty: has_items && filtered.is_empty(),
        rows_html: if has_items {
            resource_rows_html(&filtered)
        } else {
            String::new()
        },
        types_html: type_options_html(&types),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn rows() -> Vec<Resource> {
        vec![
            Resource {
                status: "loaded".to_string(),
                kind: "script".to_string(),
                source: "network".to_string(),
                url: "https://x/a.js?a=1&b=2".to_string(),
                size: 2048.0,
                time: 5.0,
                order: 0,
            },
            Resource {
                status: "unloaded".to_string(),
                kind: "image".to_string(),
                source: "memory".to_string(),
                url: "<img>.png".to_string(),
                size: 0.0,
                time: 1.0,
                order: 1,
            },
        ]
    }

    #[test]
    fn rows_html_structure_and_escaping() {
        let html = resource_rows_html(&rows());
        assert!(html.starts_with("<tr>"));
        assert!(html.contains("data-label=\"Status\""));
        assert!(html.contains("background-color:#48c774"));
        assert!(html.contains("background-color:#f14668"));
        assert!(html.contains("data-label=\"URL\" class=\"url-cell mono\""));
        assert!(html.contains("title=\"https://x/a.js?a=1&amp;b=2\""));
        assert!(html.contains("&lt;img&gt;.png"));
        assert!(html.contains("2.0 KB"));
        assert_eq!(html.matches("<tr>").count(), 2);
    }

    #[test]
    fn type_options_render_all_first() {
        let html = type_options_html(&["Script".to_string(), "script".to_string()]);
        assert_eq!(
            html,
            "<option value=\"all\">All types</option>\
             <option value=\"Script\">Script</option>\
             <option value=\"script\">script</option>"
        );
    }

    #[test]
    fn tracker_view_counts_and_visibility() {
        let tracker = json!({
            "loaded": [{"type": "script", "url": "https://x/a.js", "size": 10, "time": 2}],
            "unloaded": [{"type": "image", "url": "https://x/b.png"}],
        });
        let view = tracker_view(&tracker, &ResourceFilters::default());
        assert_eq!(view.loaded, 1);
        assert_eq!(view.unloaded, 1);
        assert_eq!(view.total, 2);
        assert_eq!(view.visible, 2);
        assert!(view.show_list);
        assert!(!view.show_empty);
        assert!(view.types_html.contains("image"));

        // A search that matches nothing shows the empty state, not the list.
        let filtered = tracker_view(
            &tracker,
            &ResourceFilters {
                search: "zzz".to_string(),
                ..Default::default()
            },
        );
        assert_eq!(filtered.visible, 0);
        assert!(!filtered.show_list);
        assert!(filtered.show_empty);

        // No items at all hides both.
        let none = tracker_view(&json!({}), &ResourceFilters::default());
        assert_eq!(none.total, 0);
        assert!(!none.show_list);
        assert!(!none.show_empty);
    }

    #[test]
    fn tracker_view_preserves_type_selection() {
        let tracker = json!({
            "loaded": [{"type": "script"}, {"type": "image"}],
            "unloaded": [],
        });
        let kept = tracker_view(
            &tracker,
            &ResourceFilters {
                kind: "script".to_string(),
                ..Default::default()
            },
        );
        assert_eq!(kept.type_selection, "script");
        let reset = tracker_view(
            &tracker,
            &ResourceFilters {
                kind: "wasm".to_string(),
                ..Default::default()
            },
        );
        assert_eq!(reset.type_selection, "all");
    }
}
