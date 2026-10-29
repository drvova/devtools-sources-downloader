//! The export orchestration from `page.js`: `finalizeZipWithRecon` and the
//! synchronous recon-artifact writer it starts with.
//!
//! The JavaScript version is one async function that fetches runtime payloads
//! through the page and hands the finished blob to `saveAs`. The platform
//! halves stay on the caller's side here: payload fetching is the caller's
//! (`collectRuntimePayloads`), and the finished archive is the writer seam, so
//! everything this module does is synchronous and observable. The merged
//! report comes back as the JSON object the JavaScript builds.

use serde_json::{json, Value};

use crate::panel::artifacts::{
    build_runtime_unpack_assets, generate_dom_snapshot_html, merge_unpack_reports, parse_cookies,
};
use crate::panel::assets::{
    assets_from_inputs, field_number, field_str, js_truthy, keys_len, ScriptInput,
};
use crate::panel::graph::collect_graphql_operations;
use crate::panel::report::{
    export_framework_artifacts, export_runtime_artifacts, export_semantic_analysis,
    generate_waterfall_html,
};
use crate::pipeline::{unpack_assets_into, UnpackOptions};

/// Pretty-printed JSON, the shape every artifact file uses.
fn pretty(value: &Value) -> String {
    serde_json::to_string_pretty(value).unwrap_or_default()
}

/// The synchronous head of `finalizeZipWithRecon`: the `_recon/*` artifacts,
/// the framework slices and the DOM snapshot. Returns the runtime entries the
/// caller should fetch payloads for.
pub fn write_recon_artifacts(
    writer: &mut dyn FnMut(&str, &str),
    recon_data: Option<&Value>,
    page_snapshot: Option<&Value>,
) -> Vec<Value> {
    let mut runtime_entries: Vec<Value> = Vec::new();
    if let Some(data) = recon_data {
        let non_empty = |key: &str| {
            data.get(key)
                .filter(|value| js_truthy(value))
                .filter(|value| keys_len(value) > 0)
        };
        if let Some(value) = non_empty("ls") {
            writer("_recon/localStorage.json", &pretty(value));
        }
        if let Some(value) = non_empty("ss") {
            writer("_recon/sessionStorage.json", &pretty(value));
        }
        if let Some(cookies) = data.get("cookies").filter(|value| js_truthy(value)) {
            let cookies = cookies.as_str().unwrap_or_default();
            if !cookies.trim().is_empty() {
                let parsed = parse_cookies(cookies);
                writer("_recon/cookies.json", &pretty(&Value::Object(parsed)));
            }
        }
        if let Some(page) = data.get("page").filter(|value| js_truthy(value)) {
            writer("_recon/page.json", &pretty(page));
        }
        if let Some(profile) = data.get("stackProfile").filter(|value| js_truthy(value)) {
            writer("_recon/stack-profile.json", &pretty(profile));
            if let Some(evidence) = profile.get("evidence").filter(|value| js_truthy(value)) {
                writer("_recon/framework-signals.json", &pretty(evidence));
            }
            if let Some(strategy) = profile.get("strategy").filter(|value| js_truthy(value)) {
                writer("_recon/capture-strategy.json", &pretty(strategy));
            }
        }
        if let Some(status) = data.get("captureStatus").filter(|value| js_truthy(value)) {
            writer("_recon/capture-status.json", &pretty(status));
        }
        if let Some(state) = data.get("frameworkState").filter(|value| js_truthy(value)) {
            export_framework_artifacts(writer, Some(state));
        }
        if let Some(timings) = non_empty("timings") {
            writer("_recon/timings.json", &pretty(timings));
            let list = timings.as_array().cloned().unwrap_or_default();
            writer("_recon/waterfall.html", &generate_waterfall_html(&list));
        }
        if let Some(recon) = data.get("recon").filter(|value| js_truthy(value)) {
            for (key, path) in [
                ("xhr", "_recon/xhr.json"),
                ("fetch", "_recon/fetch.json"),
                ("websockets", "_recon/websockets.json"),
                ("sse", "_recon/sse.json"),
                ("mutations", "_recon/mutations.json"),
            ] {
                if let Some(value) = recon.get(key).filter(|value| keys_len(value) > 0) {
                    writer(path, &pretty(value));
                }
            }
            let captures_graphql = data
                .get("stackProfile")
                .and_then(|profile| profile.get("strategy"))
                .and_then(|strategy| strategy.get("captureGraphQLOps"))
                .map(js_truthy)
                .unwrap_or(false);
            if captures_graphql {
                let operations = collect_graphql_operations(recon);
                if !operations.is_empty() {
                    writer(
                        "_recon/graphql-operations.json",
                        &pretty(&Value::Array(operations)),
                    );
                }
            }
            if let Some(runtime) = recon.get("runtime").filter(|value| keys_len(value) > 0) {
                runtime_entries = runtime.as_array().cloned().unwrap_or_default();
            }
        }
    }
    if let Some(snapshot) = page_snapshot {
        let html = field_str(snapshot, "html");
        if !html.is_empty() {
            let page = recon_data
                .and_then(|data| data.get("page"))
                .filter(|value| js_truthy(value))
                .cloned()
                .unwrap_or_else(|| {
                    let title = {
                        let title = field_str(snapshot, "title");
                        if title.is_empty() {
                            "page".to_string()
                        } else {
                            title
                        }
                    };
                    json!({ "title": title })
                });
            writer("_recon/dom-snapshot.html", &generate_dom_snapshot_html(&html, &page));
        }
    }
    runtime_entries
}

/// `collectRuntimePayloads`: resolves the text of the runtime entries that
/// have one on the page, walking the list in order and leaving the rest
/// untouched.
///
/// The JavaScript version fetches asynchronously through
/// `chrome.devtools.inspectedWindow.eval`; here the page read is the `fetch`
/// seam, which receives the entry's index and returns the payload object (or
/// nothing when the page has no payload for it).
pub fn collect_runtime_payloads(
    runtime_entries: &[Value],
    fetch: &mut dyn FnMut(usize) -> Option<Value>,
) -> Vec<Value> {
    if runtime_entries.is_empty() {
        return Vec::new();
    }
    let mut entries = runtime_entries.to_vec();
    let mut cursor = 0usize;
    while cursor < entries.len() {
        let needs_payload = {
            let entry = &entries[cursor];
            !js_truthy(entry.get("hasText").unwrap_or(&Value::Null))
                && !js_truthy(entry.get("hasBase64").unwrap_or(&Value::Null))
        };
        if needs_payload {
            cursor += 1;
            continue;
        }
        let index = field_number(&entries[cursor], "index");
        let index = if index >= 0.0 { index as usize } else { cursor };
        cursor += 1;
        if let Some(payload) = fetch(index) {
            if let Some(text) = payload.get("text").filter(|value| value.is_string()) {
                entries[cursor - 1]["text"] = text.clone();
            }
            if let Some(base64) = payload.get("base64").filter(|value| value.is_string()) {
                entries[cursor - 1]["base64"] = base64.clone();
            }
        }
    }
    entries
}

/// `finalizeZipWithRecon`: the recon artifacts, the runtime payloads, the
/// semantic analysis and the two unpack passes, in the JavaScript's order.
///
/// `runtime_payloads` is what `collectRuntimePayloads` resolves on the page
/// side, and `options.path_prefix` carries the runtime pass prefix
/// (`_unpack-runtime` in the panel). The returned value is the merged unpack
/// report, exactly the object the JavaScript keeps for its summary line.
pub fn finalize_zip_with_recon(
    writer: &mut dyn FnMut(&str, &[u8]),
    js_assets: &[ScriptInput],
    recon_data: Option<&Value>,
    page_snapshot: Option<&Value>,
    runtime_payloads: &[Value],
    options: &UnpackOptions,
) -> Value {
    {
        let mut text = |path: &str, content: &str| writer(path, content.as_bytes());
        write_recon_artifacts(&mut text, recon_data, page_snapshot);
    }
    let manifest = export_runtime_artifacts(writer, runtime_payloads);
    {
        let mut text = |path: &str, content: &str| writer(path, content.as_bytes());
        export_semantic_analysis(&mut text, js_assets, recon_data, runtime_payloads, &manifest);
    }

    let runtime_assets = build_runtime_unpack_assets(runtime_payloads, &manifest);
    let script_assets = assets_from_inputs(js_assets);
    // The JavaScript hardcodes this prefix at the runtime call site, so the
    // script pass's prefix never applies to the runtime pass.
    let mut runtime_options = clone_options(options);
    runtime_options.path_prefix = "_unpack-runtime".to_string();

    let (script_report, runtime_report) = {
        let mut text = |path: &str, content: &str| writer(path, content.as_bytes());
        let script_report = unpack_assets_into(&mut text, &script_assets, options, None);
        let runtime_report = unpack_assets_into(&mut text, &runtime_assets, &runtime_options, None);
        (script_report, runtime_report)
    };

    let mut merged = serde_json::to_value(&script_report).unwrap_or(Value::Null);
    let runtime_value = serde_json::to_value(&runtime_report).unwrap_or(Value::Null);
    merge_unpack_reports(&mut merged, &runtime_value);
    merged
}

/// The unpack options are borrowed through `fetch_text` and `inflate`, so the
/// runtime pass gets its own copy with a different prefix.
fn clone_options<'a>(options: &UnpackOptions<'a>) -> UnpackOptions<'a> {
    UnpackOptions {
        index: options.index,
        zip_path: options.zip_path.clone(),
        max_depth: options.max_depth,
        max_modules: options.max_modules,
        max_beautify_bytes: options.max_beautify_bytes,
        path_prefix: options.path_prefix.clone(),
        fetch_text: options.fetch_text,
        inflate: options.inflate,
        shared_jsc_strings: options.shared_jsc_strings,
        shared_jsc_source: options.shared_jsc_source.clone(),
    }
}

/// The panel's export summary line, built from the merged report's totals.
pub fn export_summary(report: &Value) -> String {
    let totals = report.get("totals").cloned().unwrap_or(Value::Null);
    format!(
        "Export ready. Unpacked {} of {} scripts ({} beautified, {} original sources, {} bundle modules).",
        field_number(&totals, "unpacked"),
        field_number(&totals, "assets"),
        field_number(&totals, "beautified"),
        field_number(&totals, "sources"),
        field_number(&totals, "modules"),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::panel::analysis::build_semantic_analysis;
    use crate::panel::assets::ScriptInput;
    use crate::panel::report::describe_capture_reason;

    fn fixture() -> Value {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/panel/artifacts-oracle.json"
        );
        serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
    }

    /// A recon payload with every guarded field present and non-empty.
    fn full_recon() -> Value {
        json!({
            "ls": {"token": "a"},
            "ss": {"step": "1"},
            "cookies": "a=1; b=2",
            "page": {"title": "Demo", "url": "https://demo.test/"},
            "stackProfile": {
                "framework": "react",
                "evidence": ["data-reactroot"],
                "strategy": {"profile": "balanced", "captureGraphQLOps": true},
            },
            "captureStatus": {"ready": true},
            "frameworkState": {"summary": {"roots": 1}, "router": {"path": "/"}},
            "timings": [{"name": "https://demo.test/a.js", "startTime": 0, "duration": 5}],
            "recon": {
                "xhr": [{"url": "https://demo.test/api"}],
                "fetch": [{"url": "https://demo.test/api2"}],
                "websockets": [{"url": "wss://demo.test/ws"}],
                "sse": [{"url": "https://demo.test/sse"}],
                "mutations": [{"type": "childList"}],
                "runtime": [{"id": "r1", "kind": "eval", "text": "var a = 1"}],
            },
        })
    }

    fn collect_text(
        recon: Option<&Value>,
        snapshot: Option<&Value>,
    ) -> (Vec<String>, Vec<Value>) {
        let mut paths: Vec<String> = Vec::new();
        let entries = {
            let mut writer = |path: &str, _: &str| paths.push(path.to_string());
            write_recon_artifacts(&mut writer, recon, snapshot)
        };
        (paths, entries)
    }

    #[test]
    fn recon_artifacts_cover_every_censused_path() {
        let fx = fixture();
        let census: Vec<String> = fx["sourceCensus"]["finalizeZipReconPaths"]
            .as_array()
            .unwrap()
            .iter()
            .map(|value| value.as_str().unwrap().to_string())
            .collect();
        let mut recon = full_recon();
        recon["recon"]["fetch"] = json!([{
            "url": "https://demo.test/graphql",
            "method": "POST",
            "requestBody": "{\"operationName\":\"GetUser\",\"query\":\"query GetUser { user { id } }\"}",
        }]);
        let snapshot = json!({"html": "<html><body>x</body></html>", "title": "Snapshot"});
        let (paths, entries) = collect_text(Some(&recon), Some(&snapshot));

        // The framework slices are written from inside exportFrameworkArtifacts,
        // which sits between capture-status and timings in the source order.
        let recon_only: Vec<String> = paths
            .iter()
            .filter(|path| !path.starts_with("_framework/"))
            .cloned()
            .collect();
        assert_eq!(recon_only, census, "recon artifact paths and order");
        assert_eq!(
            entries,
            vec![json!({"id": "r1", "kind": "eval", "text": "var a = 1"})],
            "runtime entries"
        );
    }

    #[test]
    fn recon_artifacts_skip_empty_and_missing_sections() {
        let (paths, entries) = collect_text(None, None);
        assert!(paths.is_empty(), "no recon data writes nothing: {paths:?}");
        assert!(entries.is_empty());

        let sparse = json!({
            "ls": {},
            "ss": {},
            "cookies": "   ",
            "timings": [],
            "recon": {"xhr": [], "runtime": []},
        });
        let (paths, entries) = collect_text(Some(&sparse), None);
        assert!(paths.is_empty(), "empty sections write nothing: {paths:?}");
        assert!(entries.is_empty());

        let partial = json!({
            "page": {"title": "Only page"},
            "recon": {"fetch": [{"url": "https://x"}]},
        });
        let (paths, entries) = collect_text(Some(&partial), None);
        assert_eq!(
            paths,
            vec!["_recon/page.json", "_recon/fetch.json"],
            "present sections only"
        );
        assert!(entries.is_empty());
    }

    #[test]
    fn dom_snapshot_uses_the_recon_page_or_the_fallback_title() {
        let snapshot = json!({"html": "<html><body>x</body></html>", "title": "Snapshot"});
        let (paths, _) = collect_text(None, Some(&snapshot));
        assert_eq!(paths, vec!["_recon/dom-snapshot.html"]);

        let recon = json!({"page": {"title": "From recon", "url": "https://demo.test/"}});
        let mut with_page = String::new();
        let mut without_page = String::new();
        {
            let mut writer = |_: &str, content: &str| with_page = content.to_string();
            write_recon_artifacts(&mut writer, Some(&recon), Some(&snapshot));
        }
        {
            let mut writer = |_: &str, content: &str| without_page = content.to_string();
            write_recon_artifacts(&mut writer, None, Some(&snapshot));
        }
        assert!(with_page.contains("<h1>From recon</h1>"), "recon page title wins");
        assert!(with_page.contains("&lt;html&gt;&lt;body&gt;x&lt;/body&gt;&lt;/html&gt;"));
        assert!(without_page.contains("<h1>Snapshot</h1>"), "snapshot title fallback");
        assert!(without_page.contains("&lt;html&gt;&lt;body&gt;x&lt;/body&gt;&lt;/html&gt;"));
    }

    #[test]
    fn runtime_payloads_are_fetched_in_order_and_skipped_when_present() {
        let entries = json!([
            {"index": 0, "id": "a", "hasText": true, "hasBase64": false, "text": "page text"},
            {"index": 1, "id": "b", "hasText": false, "hasBase64": false, "note": "not captured"},
            {"index": 2, "id": "c", "hasText": false, "hasBase64": true},
            {"index": 3, "id": "d", "hasText": true, "hasBase64": false},
        ]);
        let entries = entries.as_array().unwrap();
        let mut asked: Vec<usize> = Vec::new();
        let collected = collect_runtime_payloads(entries, &mut |index| {
            asked.push(index);
            match index {
                2 => Some(json!({"base64": "AGFzbQ=="})),
                3 => None,
                _ => Some(json!({"text": "fetched"})),
            }
        });
        // Entries that report a payload are read from the page (their text is
        // the page's, not the placeholder), entries that report neither are
        // skipped entirely.
        assert_eq!(asked, vec![0, 2, 3], "only entries that have a payload");
        assert_eq!(collected[0]["text"], json!("fetched"), "text comes from the page");
        assert_eq!(collected[1]["note"], json!("not captured"), "untouched");
        assert_eq!(collected[2]["base64"], json!("AGFzbQ=="));
        assert!(collected[3].get("text").is_none(), "failed fetch leaves none");
        assert!(collect_runtime_payloads(&[], &mut |_| None).is_empty());
    }

    /// The parity oracle is the *text* page.js produced, not a JSON value: it
    /// gates object field order and counter key order, which value equality
    /// cannot see and which the exported analysis files carry verbatim.
    #[test]
    fn panel_surface_matches_page_js_text() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/panel/parity-oracle.json"
        );
        let oracle: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        static STAMP: std::sync::LazyLock<regex::Regex> = std::sync::LazyLock::new(|| {
            regex::Regex::new(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z").unwrap()
        });
        let normalize = |text: &str| STAMP.replace_all(text, "<timestamp>").to_string();
        let text = |value: &Value| normalize(&serde_json::to_string(value).unwrap());
        let assert_text = |got: &str, want: &Value, label: &str| {
            // Both sides carry the current time (the console embeds it in its
            // data blob), so both are normalized before comparing.
            let got = normalize(got);
            let got = got.as_str();
            let want = normalize(want.as_str().unwrap());
            if got == want {
                return;
            }
            let at = got
                .char_indices()
                .zip(want.chars())
                .find(|((_, left), right)| left != right)
                .map(|((offset, _), _)| offset)
                .unwrap_or_else(|| got.len().min(want.len()));
            let start = at.saturating_sub(70);
            panic!(
                "{label} diverges at byte {at} (got {} bytes, want {} bytes)\n  got: {:?}\n want: {:?}",
                got.len(),
                want.len(),
                &got[start..(at + 70).min(got.len())],
                &want[start..(at + 70).min(want.len())],
            );
        };

        let timings = json!([
            {"name": "https://demo.test/static/app.js?v=3", "initiatorType": "script", "startTime": 0,
             "domainLookupStart": 0.4, "domainLookupEnd": 3.2, "connectStart": 3.2, "connectEnd": 14.6,
             "secureConnectionStart": 6.1, "requestStart": 15, "responseStart": 42.75, "responseEnd": 118.5,
             "duration": 118.5, "transferSize": 20480, "encodedBodySize": 19000, "decodedBodySize": 51000},
            {"name": "https://cdn.other.test/lib/vendor.css", "initiatorType": "link", "startTime": 12.25,
             "requestStart": 31, "responseStart": 55.5, "responseEnd": 90, "duration": 77.75},
        ]);
        let js_assets = vec![ScriptInput {
            url: Some("https://demo.test/app.js".to_string()),
            content: json!("var a = 1;\nfunction at(){}"),
        }];
        let recon_data = json!({
            "page": {"title": "Demo", "url": "https://demo.test/"},
            "timings": timings.clone(),
            "recon": {"fetch": [{"url": "https://demo.test/api", "method": "POST"}]},
            "frameworkState": {"summary": {"roots": 1}, "roots": [{"id": "app"}]},
        });
        let runtime_entries = json!([
            {"index": 0, "id": "r1", "kind": "eval", "url": "https://demo.test/eval.js",
             "text": "var b = 2;", "hasText": true},
        ]);
        let runtime_manifest = json!([{"id": "r1", "file": "_runtime/eval/0001.js"}]);
        let snapshot = json!({"html": "<html><body>x</body></html>", "title": "Snapshot"});

        let analysis = build_semantic_analysis(
            &js_assets,
            Some(&recon_data),
            runtime_entries.as_array().unwrap(),
            runtime_manifest.as_array().unwrap(),
        );
        assert_text(&text(&analysis), &oracle["analysisText"], "analysis");

        let investigation = analysis.get("investigation").cloned().unwrap_or(Value::Null);
        assert_text(
            &crate::panel::report::generate_investigation_index_html(&investigation),
            &oracle["consoleText"],
            "console",
        );
        let timing_list = timings.as_array().unwrap();
        assert_text(
            &crate::panel::report::generate_waterfall_html(timing_list),
            &oracle["waterfallText"],
            "waterfall",
        );
        assert_text(
            &crate::panel::report::generate_table(timing_list),
            &oracle["tableText"],
            "table",
        );
        assert_text(
            &crate::panel::artifacts::generate_dom_snapshot_html(
                "<html><body>x</body></html>",
                &json!({"title": "Snapshot"}),
            ),
            &oracle["domSnapshotText"],
            "dom snapshot",
        );
        assert_eq!(
            describe_capture_reason(Some(&json!({"ready": true})), None),
            oracle["reason"].as_str().unwrap(),
            "capture reason"
        );

        let mut recon_files: Vec<Value> = Vec::new();
        {
            let mut writer = |path: &str, content: &str| {
                if path.starts_with("_recon/") {
                    recon_files.push(json!({"path": path, "content": content}));
                }
            };
            write_recon_artifacts(&mut writer, Some(&recon_data), Some(&snapshot));
        }
        let want_recon = oracle["reconFiles"].as_array().unwrap();
        assert_eq!(recon_files.len(), want_recon.len(), "recon file count");
        for (index, want) in want_recon.iter().enumerate() {
            let got = &recon_files[index];
            assert_eq!(
                got.get("path"),
                want.get("path"),
                "recon path {index}"
            );
            assert_eq!(
                got.get("content").and_then(|v| v.as_str()).map(normalize),
                want.get("content")
                    .and_then(|v| v.as_str())
                    .map(normalize),
                "recon content {}",
                want.get("path").and_then(|v| v.as_str()).unwrap_or("?")
            );
        }

        let mut framework_files: Vec<Value> = Vec::new();
        {
            let mut writer = |path: &str, content: &str| {
                framework_files.push(json!({"path": path, "content": content}));
            };
            export_framework_artifacts(&mut writer, recon_data.get("frameworkState"));
        }
        assert_eq!(
            Value::Array(framework_files),
            oracle["frameworkFiles"],
            "framework files"
        );

        let mut runtime_files: Vec<Value> = Vec::new();
        let manifest = {
            let mut writer = |path: &str, bytes: &[u8]| {
                let text = std::str::from_utf8(bytes).unwrap_or_default();
                runtime_files.push(json!({"path": path, "content": text, "base64": false}));
            };
            export_runtime_artifacts(&mut writer, runtime_entries.as_array().unwrap())
        };
        assert_eq!(
            Value::Array(runtime_files),
            oracle["runtimeFiles"],
            "runtime files"
        );
        assert_eq!(
            Value::Array(manifest),
            oracle["runtimeManifest"],
            "runtime manifest"
        );
    }

    #[test]
    fn finalize_writes_every_stage_and_merges_the_report() {
        let assets = vec![ScriptInput {
            url: Some("https://demo.test/app.js".to_string()),
            content: json!("var a = 1;"),
        }];
        let payloads = vec![json!({
            "id": "r1", "kind": "eval", "url": "https://demo.test/eval.js",
            "text": "var b = 2;", "hasText": true,
        })];
        let recon = json!({
            "page": {"title": "Demo", "url": "https://demo.test/"},
            "timings": [{"name": "https://demo.test/app.js", "startTime": 0, "duration": 3}],
            "recon": {"fetch": [{"url": "https://demo.test/api"}]},
        });
        let options = UnpackOptions {
            path_prefix: "_unpack".to_string(),
            ..UnpackOptions::default()
        };
        let mut files: Vec<(String, usize)> = Vec::new();
        let report = {
            let mut writer = |path: &str, bytes: &[u8]| {
                files.push((path.to_string(), bytes.len()));
            };
            finalize_zip_with_recon(
                &mut writer,
                &assets,
                Some(&recon),
                None,
                &payloads,
                &options,
            )
        };
        let paths: Vec<&str> = files.iter().map(|(path, _)| path.as_str()).collect();
        for expected in [
            "_recon/page.json",
            "_recon/timings.json",
            "_recon/waterfall.html",
            "_recon/fetch.json",
            "_runtime/eval/0001.js",
            "_runtime/runtime-manifest.json",
            "_analysis/chunk-map.json",
            "_analysis/index.html",
        ] {
            assert!(
                paths.contains(&expected),
                "missing {expected} in {paths:?}"
            );
        }
        assert!(
            paths.iter().any(|path| path.starts_with("_unpack/")),
            "script unpack pass wrote nothing: {paths:?}"
        );
        assert!(
            paths.iter().any(|path| path.starts_with("_unpack-runtime/")),
            "runtime unpack pass wrote nothing: {paths:?}"
        );
        // The recon block comes first, then the runtime payloads, then the
        // analysis, then the two unpack passes.
        let index_of = |needle: &str| paths.iter().position(|path| *path == needle).unwrap();
        assert!(index_of("_recon/page.json") < index_of("_runtime/runtime-manifest.json"));
        assert!(index_of("_runtime/runtime-manifest.json") < index_of("_analysis/chunk-map.json"));

        // The merge is what the test is about: both passes' asset counts are
        // summed into the script report. The per-asset "unpacked" count is the
        // engine's own (a plain script has no layers to peel).
        let totals = report.get("totals").unwrap();
        assert_eq!(totals["assets"], json!(2), "script and runtime assets");
        let summary = export_summary(&report);
        assert!(summary.starts_with("Export ready. Unpacked "), "{summary}");
        assert!(summary.contains(" of 2 scripts"), "{summary}");
        assert!(summary.contains(" bundle modules)."), "{summary}");
    }
}
