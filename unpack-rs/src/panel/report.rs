//! The panel's report pages: the investigation console and the artifact
//! export wrappers, ported from `page.js` (generateInvestigationIndexHTML and
//! its neighbours).
//!
//! The long style/script blocks are transcribed verbatim from the JavaScript
//! source; the oracle test compares the rendered document byte for byte.

use serde_json::{json, Value};

use crate::panel::artifacts::serialize_inline_json;
use crate::panel::assets::{field_str, js_truthy};
use crate::panel::text::sanitize_path_part;
use crate::panel::view::escape_html;

/// The console stylesheet, one rule block per entry.
const STYLES: &[&str] = &[
    r#"*{box-sizing:border-box}"#,
    r#"body{margin:0;font-family:Inter,Segoe UI,Arial,sans-serif;background:#0b1020;color:#e6ebff}"#,
    r#"a{color:#8ec5ff}"#,
    r#"button{font:inherit}"#,
    r#"code{font-family:Consolas,monospace}"#,
    r#".shell{display:grid;grid-template-columns:280px 1fr;min-height:100vh}"#,
    r#".sidebar{padding:20px;border-right:1px solid rgba(255,255,255,.08);background:#111833}"#,
    r#".main{padding:24px}"#,
    r#".title{font-size:20px;font-weight:700;margin:0 0 6px}"#,
    r#".sub{color:#95a3d7;font-size:12px;line-height:1.5;margin-bottom:18px}"#,
    r#".section-title{font-size:11px;text-transform:uppercase;letter-spacing:.12em;color:#7f8cc9;margin:18px 0 10px}"#,
    r#".nav{display:flex;flex-wrap:wrap;gap:8px}"#,
    r#".nav button{width:100%;text-align:left;padding:10px 12px;border-radius:10px;border:1px solid rgba(255,255,255,.08);background:#18224a;color:#dfe7ff;cursor:pointer}"#,
    r#".nav button.active{background:#24408a;border-color:#6ea8ff}"#,
    r#".cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:12px;margin:18px 0}"#,
    r#".card{background:#121936;border:1px solid rgba(255,255,255,.08);border-radius:12px;padding:12px}"#,
    r#".card .label{font-size:11px;color:#91a0d4;text-transform:uppercase;letter-spacing:.08em}"#,
    r#".card .value{font-size:22px;font-weight:700;margin-top:4px}"#,
    r#".panel{background:#121936;border:1px solid rgba(255,255,255,.08);border-radius:14px;padding:16px;margin-top:16px}"#,
    r#".panel h2{margin:0 0 6px;font-size:18px}"#,
    r#".panel p{margin:0 0 12px;color:#b7c2ea;line-height:1.5}"#,
    r#".list{display:grid;gap:10px}"#,
    r#".item{padding:12px;border-radius:10px;background:#0f1530;border:1px solid rgba(255,255,255,.06)}"#,
    r#".item h3{margin:0 0 4px;font-size:14px}"#,
    r#".item .meta{font-size:12px;color:#90a0d6;line-height:1.5}"#,
    r#".chips{display:flex;flex-wrap:wrap;gap:6px;margin-top:6px}"#,
    r#".chip{padding:3px 8px;border-radius:999px;background:#243462;color:#dbe6ff;font-size:11px}"#,
    r#".empty{color:#7f8cc9;font-size:13px;padding:14px;border:1px dashed rgba(255,255,255,.14);border-radius:10px}"#,
    r#".kvs{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:10px}"#,
    r#".kv{background:#0f1530;border:1px solid rgba(255,255,255,.06);border-radius:10px;padding:10px}"#,
    r#".kv .k{font-size:11px;text-transform:uppercase;letter-spacing:.08em;color:#7f8cc9}"#,
    r#".kv .v{margin-top:4px;font-size:14px;font-weight:600}"#,
    r#".path{font-size:12px;color:#9fb0e9}"#,
    r#".split{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:16px;align-items:start}"#,
    r#".mono{font-family:Consolas,monospace}"#,
    r#".muted{color:#8e9cd2}"#,
    r#".links{display:flex;flex-wrap:wrap;gap:8px}"#,
    r#".links a{display:inline-flex;padding:8px 10px;border-radius:10px;background:#18224a;text-decoration:none}"#,
    r#".hero{display:flex;justify-content:space-between;gap:16px;align-items:flex-start;flex-wrap:wrap}"#,
    r#".hero .meta{max-width:820px}"#,
    r#".hero .badge{display:inline-flex;padding:6px 10px;border-radius:999px;background:#203a77;font-size:12px;color:#e6ebff;margin-bottom:10px}"#,
    r#"@media (max-width:900px){.shell{grid-template-columns:1fr}.sidebar{border-right:0;border-bottom:1px solid rgba(255,255,255,.08)}}"#,
];

/// The console client script, one line per entry.
const SCRIPT: &[&str] = &[
    r#"(function(){"#,
    r#"var data=JSON.parse(document.getElementById("investigation-data").textContent||"{}");"#,
    r#"var workspaceNav=document.getElementById("workspaceNav");"#,
    r#"var journeyNav=document.getElementById("journeyNav");"#,
    r#"var view=document.getElementById("view");"#,
    r#"var summaryCards=document.getElementById("summaryCards");"#,
    r#"var workspaces=data.workspaces||[];"#,
    r#"var journeys=data.journeys||[];"#,
    r#"var state={type:"workspace",id:workspaces.length?workspaces[0].id:(journeys.length?journeys[0].id:"")};"#,
    r#"function esc(value){return String(value==null?"":value).replace(/[&<>"']/g,function(ch){return {"&":"&amp;","<":"&lt;",">":"&gt;",""":"&quot;","'":"&#39;"}[ch]})}"#,
    r#"function pathHref(path){if(!path)return"";if(path.indexOf("_analysis/")===0)return path.replace(/^_analysis//,"");return"../"+path.replace(/^/+/,"")}"#,
    r#"function toTitle(key){return String(key||"").replace(/([A-Z])/g," $1").replace(/^./,function(ch){return ch.toUpperCase()})}"#,
    r#"function card(label,value){return "<div class="card"><div class="label">"+esc(label)+"</div><div class="value">"+esc(value)+"</div></div>"}"#,
    r#"function panel(title,body,description){return "<section class="panel"><h2>"+esc(title)+"</h2>"+(description?"<p>"+esc(description)+"</p>":"")+body+"</section>"}"#,
    r#"function list(items,renderItem,emptyText){if(!items||!items.length)return "<div class="empty">"+esc(emptyText)+"</div>";return "<div class="list">"+items.map(renderItem).join("")+"</div>"}"#,
    r#"function chips(items){if(!items||!items.length)return"";return "<div class="chips">"+items.map(function(item){return "<span class="chip">"+esc(item)+"</span>"}).join("")+"</div>"}"#,
    r#"function kvs(summary){var rows=[];for(var key in summary){if(Object.prototype.hasOwnProperty.call(summary,key))rows.push("<div class="kv"><div class="k">"+esc(toTitle(key))+"</div><div class="v">"+esc(summary[key])+"</div></div>")}return rows.length?"<div class="kvs">"+rows.join("")+"</div>":"<div class="empty">No summary metrics available.</div>"}"#,
    r#"function entryMeta(item){var parts=[];if(item.kind)parts.push(item.kind);if(item.classification)parts.push(item.classification);if(item.originType)parts.push(item.originType);if(item.primaryBoundary)parts.push(item.primaryBoundary);if(item.score!=null)parts.push("score "+item.score);return parts.join(" | ")}"#,
    r#"function renderEntrypoint(item){return "<div class="item"><h3>"+esc(item.label||item.id||"Entrypoint")+"</h3><div class="meta">"+esc(entryMeta(item))+"</div><div class="path mono">"+esc(item.url||item.file||"")+"</div>"+chips(item.boundaryLabels||[])+"</div>"}"#,
    r#"function renderChunk(item){var meta=[item.classification||"",item.bundler||"",item.transferSize?item.transferSize+" bytes":""].filter(Boolean).join(" | ");return "<div class="item"><h3>"+esc(item.id||item.file||"Chunk")+"</h3><div class="meta">"+esc(meta)+"</div><div class="path mono">"+esc(item.url||item.file||"")+"</div>"+chips((item.frameworkHints||[]).concat(item.boundaryLabels||[]).slice(0,8))+"</div>"}"#,
    r#"function renderRuntime(item){var meta=[item.kind||"",item.originType||"",item.size?item.size+" bytes":""].filter(Boolean).join(" | ");return "<div class="item"><h3>"+esc(item.id||item.file||"Runtime artifact")+"</h3><div class="meta">"+esc(meta)+"</div><div class="path mono">"+esc(item.file||item.url||item.objectUrl||"")+"</div>"+chips((item.relatedChunks||[]).slice(0,6))+"</div>"}"#,
    r#"function renderTransition(item){var from=(item.from&&item.from.label)||(item.from&&item.from.id)||item.fromBoundary||"Unknown";var to=(item.to&&item.to.label)||(item.to&&item.to.id)||item.toBoundary||"Unknown";var meta=[item.relation||"",item.fromBoundary||"",item.toBoundary||""].filter(Boolean).join(" | ");return "<div class="item"><h3>"+esc(from)+" -> "+esc(to)+"</h3><div class="meta">"+esc(meta)+"</div></div>"}"#,
    r#"function renderEvent(item){var meta=[item.kind||item.type||"",item.boundary||item.primaryBoundary||"",item.score!=null?"score "+item.score:""] .filter(Boolean).join(" | ");return "<div class="item"><h3>"+esc(item.label||item.id||item.type||"Event")+"</h3><div class="meta">"+esc(meta)+"</div><div class="path mono">"+esc(item.url||item.file||item.detail||"")+"</div></div>"}"#,
    r#"function renderChain(item){return "<div class="item"><h3>"+esc(item.label||item.id||"Chain")+"</h3><div class="meta">"+esc(item.description||"")+"</div>"+chips(item.path||[])+"</div>"}"#,
    r#"function renderQuestion(item){return "<div class="item"><h3>"+esc(item)+"</h3></div>"}"#,
    r#"function renderArtifact(item){var href=pathHref(item);return "<a href=""+esc(href)+"" target="_blank" rel="noopener noreferrer">"+esc(item)+"</a>"}"#,
    r#"function renderSupportingWorkspace(item){var body=kvs(item.summary||{});body+=panel("Sample entrypoints",list(item.entrypoints||[],renderEntrypoint,"No supporting entrypoints."),"");return "<div class="item"><h3>"+esc(item.title||item.id||"Workspace")+"</h3>"+body+"</div>"}"#,
    r#"function renderSummary(current){var summary=current.summary||{};return [card(state.type==="workspace"?"Workspace items":"Journey entrypoints",summary.totalItems||summary.entrypointCount||0),card("Transitions",summary.transitionCount||0),card("Events",summary.eventCount||0),card("Runtime",summary.runtimeCount||0),card("Chunks",summary.chunkCount||0),card("Chains",summary.chainCount||0)].join("")}"#,
    r#"function findCurrent(){if(state.type==="journey"){for(var i=0;i<journeys.length;i++)if(journeys[i].id===state.id)return journeys[i];return journeys[0]||null}for(var j=0;j<workspaces.length;j++)if(workspaces[j].id===state.id)return workspaces[j];return workspaces[0]||journeys[0]||null}"#,
    r#"function renderNav(){workspaceNav.innerHTML=workspaces.map(function(item){return "<button data-type="workspace" data-id=""+esc(item.id)+"" class=""+(state.type==="workspace"&&state.id===item.id?"active":"")+"">"+esc(item.title)+"</button>"}).join("");journeyNav.innerHTML=journeys.map(function(item){return "<button data-type="journey" data-id=""+esc(item.id)+"" class=""+(state.type==="journey"&&state.id===item.id?"active":"")+"">"+esc(item.title)+"</button>"}).join("");Array.prototype.forEach.call(document.querySelectorAll(".nav button"),function(btn){btn.onclick=function(){state.type=btn.getAttribute("data-type");state.id=btn.getAttribute("data-id");render()}})}"#,
    r#"function renderCurrent(current){var relatedArtifacts=current.relatedArtifacts||[];var supportingWorkspaces=current.supportingWorkspaces||[];var html="";html+=panel(current.title||current.id||"Investigation slice","<div class="hero"><div class="meta"><div class="badge">"+esc(state.type)+"</div><p>"+esc(current.description||"No description available.")+"</p>"+chips(current.focusBoundaries||[])+"</div><div class="meta"><div class="muted">Generated</div><div class="mono">"+esc(data.generatedAt||"")+"</div></div></div>","");html+=panel("Summary",kvs(current.summary||{}),"");html+=panel("Questions",list(current.questions||[],renderQuestion,"No questions recorded."),"");html+="<div class="split">"+panel("Entrypoints",list(current.entrypoints||[],renderEntrypoint,"No entrypoints recorded."),"")+panel("Transitions",list(current.transitions||[],renderTransition,"No transitions recorded."),"")+"</div>";html+="<div class="split">"+panel("Chunks",list(current.chunks||[],renderChunk,"No chunks recorded."),"")+panel("Runtime artifacts",list(current.runtime||[],renderRuntime,"No runtime artifacts recorded."),"")+"</div>";html+="<div class="split">"+panel("Events",list(current.events||[],renderEvent,"No events recorded."),"")+panel("Chains",list(current.chains||[],renderChain,"No chains recorded."),"")+"</div>";if(supportingWorkspaces.length)html+=panel("Supporting workspaces",list(supportingWorkspaces,renderSupportingWorkspace,"No supporting workspaces recorded."),"");if(relatedArtifacts.length)html+=panel("Related artifacts","<div class="links">"+relatedArtifacts.map(renderArtifact).join("")+"</div>","");return html}"#,
    r#"function render(){var current=findCurrent();renderNav();if(!current){summaryCards.innerHTML="";view.innerHTML="<section class="panel"><div class="empty">No investigation slice available.</div></section>";return}summaryCards.innerHTML=renderSummary(current);view.innerHTML=renderCurrent(current)}"#,
    r#"render();"#,
    r#"})();"#,
];

/// `generateInvestigationIndexHTML`.
pub fn generate_investigation_index_html(investigation: &Value) -> String {
    let page = if js_truthy(investigation) {
        investigation.get("page").filter(|v| js_truthy(v))
    } else {
        None
    };
    let page = page.cloned().unwrap_or_else(|| json!({}));
    let title = {
        let title = field_str(&page, "title");
        if !title.is_empty() {
            title
        } else {
            let url = field_str(&page, "url");
            if !url.is_empty() {
                url
            } else {
                "Investigation Console".to_string()
            }
        }
    };
    let page_url = field_str(&page, "url");
    let empty = json!({});
    let data = serialize_inline_json(if js_truthy(investigation) {
        investigation
    } else {
        &empty
    });
    let styles = STYLES.join("");
    let script = SCRIPT.join("\n");
    format!(
        r#"<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Investigation Console</title>
<style>{}</style>
</head>
<body>
<div class="shell">
<aside class="sidebar">
<h1 class="title">Investigation Console</h1>
<div class="sub">{}<br>{}</div>
<div class="section-title">Workspaces</div><div id="workspaceNav" class="nav"></div>
<div class="section-title">Journeys</div><div id="journeyNav" class="nav"></div>
</aside>
<main class="main">
<div id="summaryCards" class="cards"></div>
<div id="view"></div>
</main>
</div>
<script id="investigation-data" type="application/json">{}</script>
<script>{}</script>
</body>
</html>"#,
        styles, escape_html(&title), escape_html(&page_url), data, script,
    )
}

/// `exportReadableArtifacts` with the engine's beautifier.
pub fn export_readable_artifacts(writer: &mut dyn FnMut(&str, &str), analysis: &Value) {
    export_readable_artifacts_with(
        writer,
        analysis,
        &crate::beautify::looks_minified,
        &|text| crate::beautify::beautify_js(text, None),
    );
}

/// `exportReadableArtifacts` with an injectable beautifier seam.
pub fn export_readable_artifacts_with(
    writer: &mut dyn FnMut(&str, &str),
    analysis: &Value,
    looks_minified: &dyn Fn(&str) -> bool,
    beautify: &dyn Fn(&str) -> String,
) {
    let mut asset_map: std::collections::BTreeMap<String, Value> =
        std::collections::BTreeMap::new();
    for asset in analysis
        .get("assets")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default()
    {
        asset_map.insert(field_str(&asset, "id"), asset);
    }
    let mut runtime_map: std::collections::BTreeMap<String, Value> =
        std::collections::BTreeMap::new();
    for record in analysis
        .get("runtimeRecords")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default()
    {
        runtime_map.insert(field_str(&record, "id"), record);
    }
    let mut written = 0usize;
    for entry in analysis
        .get("interestingEntrypoints")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default()
    {
        if written >= 10 {
            break;
        }
        let id = field_str(&entry, "id");
        let kind = field_str(&entry, "kind");
        let record = if kind == "chunk" {
            asset_map.get(&id)
        } else {
            runtime_map.get(&id)
        };
        let Some(record) = record else { continue };
        if kind == "chunk" && !record.get("content").map(js_truthy).unwrap_or(false) {
            continue;
        }
        if kind == "runtime" && !matches!(record.get("text"), Some(Value::String(_))) {
            continue;
        }
        written += 1;
        let label = {
            let label = field_str(&entry, "label");
            if label.is_empty() {
                id.clone()
            } else {
                label
            }
        };
        let file = format!(
            "_analysis/readable/{:04}-{}.js",
            written,
            sanitize_path_part(&label, &kind)
        );
        writer(
            &file,
            &crate::panel::artifacts::build_readable_artifact_with(
                &entry,
                record,
                looks_minified,
                beautify,
            ),
        );
    }
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
    fn investigation_console_matches_oracle() {
        let fx = fixture();
        let exp = &fx["expected"];
        let cases = [
            json!({
                "page": {"title": "<Investigation>", "url": "https://demo.test/app?a=1&b=2"},
                "generatedAt": "2026-01-01T00:00:00.000Z",
                "workspaces": [{"id": "bootstrap", "title": "Bootstrap workspace", "summary": {"totalItems": 2}}],
                "journeys": [{"id": "initial-load", "title": "Initial load", "summary": {"eventCount": 1}}],
            }),
            json!({"page": {"url": "https://x"}}),
            Value::Null,
        ];
        let want = exp["generateInvestigationIndexHTML"].as_array().unwrap();
        let lengths = exp["generateInvestigationIndexHTMLLengths"].as_array().unwrap();
        for (index, input) in cases.iter().enumerate() {
            let html = generate_investigation_index_html(input);
            let expected = want[index].as_str().unwrap();
            if html != expected {
                let at = html
                    .char_indices()
                    .zip(expected.chars())
                    .find(|((_, left), right)| left != right)
                    .map(|((offset, _), _)| offset)
                    .unwrap_or_else(|| html.len().min(expected.len()));
                let start = at.saturating_sub(60);
                panic!(
                    "console {index} diverges at byte {at}\n  got: {:?}\n want: {:?}",
                    &html[start..(at + 60).min(html.len())],
                    &expected[start..(at + 60).min(expected.len())],
                );
            }
            assert_eq!(
                html.len(),
                lengths[index].as_u64().unwrap() as usize,
                "console length {index}"
            );
        }
    }

    #[test]
    fn readable_artifact_export_matches_oracle() {
        let fx = fixture();
        let exp = &fx["expected"];
        let analysis = json!({
            "assets": [
                {"id": "c1", "url": "https://x/a.js", "content": "MINvar a=1"},
                {"id": "c2", "url": "https://x/b.js", "content": ""},
            ],
            "runtimeRecords": [
                {"id": "r1", "kind": "eval", "text": "MINruntime"},
                {"id": "r2", "kind": "wasm", "bytes": [1, 2]},
            ],
            "interestingEntrypoints": [
                {"kind": "chunk", "id": "c1", "label": "a.js", "url": "https://x/a.js", "boundaryLabels": ["data"], "score": 40},
                {"kind": "chunk", "id": "c2", "label": "b.js", "url": "https://x/b.js"},
                {"kind": "runtime", "id": "r1", "label": "runtime/one"},
                {"kind": "runtime", "id": "r2", "label": "wasm/two"},
                {"kind": "runtime", "id": "missing", "label": "nope"},
            ],
        });
        let looks = |text: &str| text.starts_with("MIN");
        let beautify = |text: &str| format!("BEAUTIFIED({text})");
        let mut written: Vec<Value> = Vec::new();
        export_readable_artifacts_with(
            &mut |path, content| {
                written.push(json!([path, content]));
            },
            &analysis,
            &looks,
            &beautify,
        );
        assert_eq!(
            Value::Array(written),
            exp["exportReadableArtifacts"],
            "exportReadableArtifacts"
        );
    }
}
