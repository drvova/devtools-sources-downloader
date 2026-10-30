//! The panel's report pages: the investigation console and the artifact
//! export wrappers, ported from `page.js` (generateInvestigationIndexHTML and
//! its neighbours).
//!
//! The long style/script blocks are transcribed verbatim from the JavaScript
//! source; the oracle test compares the rendered document byte for byte.

use serde_json::{json, Value};

use crate::jsnumber::js_number_to_string;
use crate::panel::artifacts::{compute_recon_stats, escape_attr, escape_xml, serialize_inline_json};
use crate::panel::analysis::build_semantic_analysis;
use crate::panel::assets::{field_number, field_str, js_truthy, keys_len, ScriptInput};
use crate::panel::text::{format_ms, format_size, sanitize_path_part};

use crate::panel::assets::value_text;
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
fn export_readable_artifacts(writer: &mut dyn FnMut(&str, &str), analysis: &Value) {
    export_readable_artifacts_with(
        writer,
        analysis,
        &crate::beautify::looks_minified,
        &|text| crate::beautify::beautify_js(text, None),
    );
}

/// `exportReadableArtifacts` with an injectable beautifier seam.
fn export_readable_artifacts_with(
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

// The waterfall report's colours and its fixed markup blocks, transcribed
// verbatim from the JavaScript source.
const COLOR_DNS: &str = "rgba(3,169,244,0.6)";
const COLOR_TCP: &str = "rgba(255,152,0,0.6)";
const COLOR_SSL: &str = "rgba(156,39,176,0.6)";
const COLOR_TTFB: &str = "rgba(76,175,80,0.6)";
const COLOR_DOWNLOAD: &str = "rgba(3,169,244,0.9)";
const COLOR_TEXT: &str = "#ccc";
const COLOR_BG: &str = "#242424";
const COLOR_STRIPE: &str = "#2a2a2a";
/// `e.name.replace(/^https?:\/\/[^\/]+\//, '')`: drops the origin and the
/// first path separator.
static STRIP_ORIGIN: std::sync::LazyLock<regex::Regex> =
    std::sync::LazyLock::new(|| regex::Regex::new(r"^https?://[^/]+/").unwrap());

const ROW_H: f64 = 22.0;
const LABEL_W: f64 = 360.0;
const BAR_START: f64 = LABEL_W + 8.0;
const TOTAL_W: f64 = 1200.0;
const BAR_W: f64 = TOTAL_W - BAR_START - 10.0;

const WF_0: &str = r#"<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Waterfall Report</title>
<style>*{margin:0;padding:0;box-sizing:border-box}body{background:#1a1a2e;color:#e0e0e0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;padding:20px}h1{font-size:20px;margin-bottom:6px;color:#03a9f4}.sub{color:#888;font-size:12px;margin-bottom:16px}.summary{display:flex;flex-wrap:wrap;gap:8px;margin-bottom:20px}.stat{background:#16213e;border-radius:6px;padding:8px 14px;border:1px solid #2a2a4a}.stat .val{font-size:18px;font-weight:600;color:#03a9f4}.stat .lbl{font-size:10px;color:#888;text-transform:uppercase;letter-spacing:.5px}.chart{background:#1e1e36;border-radius:8px;padding:16px;overflow-x:auto;border:1px solid #2a2a4a}.legend{display:flex;gap:16px;margin-bottom:10px;flex-wrap:wrap}.legend span{display:flex;align-items:center;gap:4px;font-size:11px}.legend .sw{width:12px;height:12px;border-radius:2px}.controls{display:flex;gap:8px;margin-bottom:12px}.controls button{background:#16213e;color:#e0e0e0;border:1px solid #2a2a4a;padding:6px 12px;border-radius:4px;cursor:pointer;font-size:11px}.controls button:hover{background:#1e1e46;border-color:#03a9f4}.controls input{background:#16213e;color:#e0e0e0;border:1px solid #2a2a4a;padding:6px 10px;border-radius:4px;font-size:11px;width:240px}.controls input:focus{outline:none;border-color:#03a9f4}.controls select{background:#16213e;color:#e0e0e0;border:1px solid #2a2a4a;padding:6px;border-radius:4px;font-size:11px}.dark{background:#f5f5f5;color:#333}.dark h1{color:#0288d1}.dark .stat{background:#fff;border:1px solid #ddd}.dark .stat .val{color:#0288d1}.dark .chart{background:#fff;border:1px solid #ddd}.dark .controls button{background:#eee;color:#333;border:1px solid #ccc}.dark .controls input{background:#fff;color:#333;border:1px solid #ccc}.dark .controls select{background:#fff;color:#333;border:1px solid #ccc}table{width:100%;border-collapse:collapse;margin-top:10px;font-size:11px}th,td{text-align:left;padding:4px 8px;border-bottom:1px solid #2a2a4a}th{color:#888;font-weight:500;position:sticky;top:0;background:#1e1e36}tr:hover{background:rgba(3,169,244,.1)}.dark th{background:#fff;color:#666}.dark td{border-color:#eee}</style>
</head>
<body><h1>Network Waterfall</h1><div class="sub">Generated "#;
const WF_2: &str = r#" | "#;
const WF_4: &str = r#" requests | Total: "#;
const WF_6: &str = r#"</div><div class="summary">"#;
const WF_8: &str = r#"</div><div class="controls"><button onclick="toggleTheme()">Toggle Dark/Light</button><input id="search" placeholder="Filter by URL..." oninput="filterTable()"><select id="typeFilter" onchange="filterTable()"><option value="">All types</option></select></div><div class="chart"><div class="legend"><span><span class="sw" style="background:"#;
const WF_10: &str = r#""></span> DNS</span><span><span class="sw" style="background:"#;
const WF_12: &str = r#""></span> TCP</span><span><span class="sw" style="background:"#;
const WF_14: &str = r#""></span> SSL</span><span><span class="sw" style="background:"#;
const WF_16: &str = r#""></span> TTFB</span><span><span class="sw" style="background:"#;
const WF_18: &str = r#""></span> Download</span></div><svg viewBox="0 0 "#;
const WF_20: &str = r#" "#;
const WF_22: &str = r#"" style="width:100%;height:auto;min-width:"#;
const WF_24: &str = r#"px"><rect width=""#;
const WF_26: &str = r#"" height=""#;
const WF_28: &str = r#"" fill=""#;
const WF_30: &str = r#"" rx="6"/>"#;
const WF_33: &str = r#"</svg></div>"#;
const WF_35: &str = r#"<script>var timings="#;
const WF_37: &str = r##";function toggleTheme(){document.body.classList.toggle("dark")}var types=[...new Set(timings.map(function(t){return t.initiatorType||"other"}))];var sel=document.getElementById("typeFilter");for(var i=0;i<types.length;i++){var o=document.createElement("option");o.value=types[i];o.textContent=types[i];sel.appendChild(o)}function filterTable(){var q=(document.getElementById("search").value||"").toLowerCase();var tp=sel.value;var rows=document.querySelectorAll("#resTable tbody tr");for(var i=0;i<rows.length;i++){var r=rows[i];var url=(r.cells[0].textContent||"").toLowerCase();var type=r.cells[1].textContent||"";var show=!q||url.indexOf(q)>-1;if(tp&&type!==tp)show=false;r.style.display=show?"":"none"}}</script></body></html>"##;

/// `formatMs`-style duration with a JavaScript truthiness fallback.
fn number_or(value: f64, fallback: f64) -> f64 {
    if value != 0.0 && !value.is_nan() {
        value
    } else {
        fallback
    }
}

/// `generateWaterfallHTML`: the request waterfall chart page.
pub fn generate_waterfall_html(timings: &[Value]) -> String {
    if timings.is_empty() {
        return "<html><body>No timing data available.</body></html>".to_string();
    }
    let mut sorted = timings.to_vec();
    sorted.sort_by(|a, b| {
        field_number(a, "startTime")
            .partial_cmp(&field_number(b, "startTime"))
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    let mut max_end = 0.0f64;
    for entry in &sorted {
        let end = number_or(
            field_number(entry, "responseEnd"),
            field_number(entry, "startTime") + field_number(entry, "duration"),
        );
        if end > max_end {
            max_end = end;
        }
    }
    let total_time = max_end;
    let chart_height = sorted.len() as f64 * ROW_H + 60.0;
    let svg_height = chart_height + 120.0;
    let to_x = |t: f64| BAR_START + (t / total_time) * BAR_W;

    let mut rows = String::new();
    for (r, entry) in sorted.iter().enumerate() {
        let y = 40.0 + r as f64 * ROW_H;
        if r % 2 == 0 {
            rows.push_str("<rect x=\"");
            rows.push_str(&js_number_to_string(BAR_START));
            rows.push_str("\" y=\"");
            rows.push_str(&js_number_to_string(y));
            rows.push_str("\" width=\"");
            rows.push_str(&js_number_to_string(BAR_W));
            rows.push_str("\" height=\"");
            rows.push_str(&js_number_to_string(ROW_H));
            rows.push_str("\" fill=\"");
            rows.push_str(COLOR_STRIPE);
            rows.push_str("\" opacity=\"0.3\"/>");
        }
        let label = {
            let name = field_str(entry, "name");
            let stripped = STRIP_ORIGIN.replace(&name, "").to_string();
            stripped.chars().take(55).collect::<String>()
        };
        rows.push_str("<text x=\"");
        rows.push_str(&js_number_to_string(BAR_START - 6.0));
        rows.push_str("\" y=\"");
        rows.push_str(&js_number_to_string(y + 14.0));
        rows.push_str("\" fill=\"");
        rows.push_str(COLOR_TEXT);
        rows.push_str("\" font-size=\"11\" font-family=\"monospace\" text-anchor=\"end\">");
        rows.push_str(&escape_xml(&Value::String(label)));
        rows.push_str("</text>");

        let dns_start = field_number(entry, "domainLookupStart");
        let dns_end = field_number(entry, "domainLookupEnd");
        if dns_start > 0.0 && dns_end > dns_start {
            rows.push_str("<rect x=\"");
            rows.push_str(&js_number_to_string(to_x(dns_start)));
            rows.push_str("\" y=\"");
            rows.push_str(&js_number_to_string(y + 4.0));
            rows.push_str("\" width=\"");
            rows.push_str(&js_number_to_string(f64::max(
                1.0,
                to_x(dns_end) - to_x(dns_start),
            )));
            rows.push_str("\" height=\"");
            rows.push_str(&js_number_to_string(ROW_H - 8.0));
            rows.push_str("\" fill=\"");
            rows.push_str(COLOR_DNS);
            rows.push_str("\"><title>DNS: ");
            rows.push_str(&format_ms(dns_end - dns_start));
            rows.push_str("</title></rect>");
        }

        let connect_start = field_number(entry, "connectStart");
        let connect_end = field_number(entry, "connectEnd");
        let secure_start = field_number(entry, "secureConnectionStart");
        if connect_start > 0.0 && connect_end > 0.0 {
            let mut tcp_width = f64::max(1.0, to_x(connect_end) - to_x(connect_start));
            if secure_start > 0.0 && secure_start > connect_start {
                tcp_width = f64::max(1.0, to_x(secure_start) - to_x(connect_start));
            }
            if tcp_width > 0.0 {
                rows.push_str("<rect x=\"");
                rows.push_str(&js_number_to_string(to_x(connect_start)));
                rows.push_str("\" y=\"");
                rows.push_str(&js_number_to_string(y + 4.0));
                rows.push_str("\" width=\"");
                rows.push_str(&js_number_to_string(tcp_width));
                rows.push_str("\" height=\"");
                rows.push_str(&js_number_to_string(ROW_H - 8.0));
                rows.push_str("\" fill=\"");
                rows.push_str(COLOR_TCP);
                rows.push_str("\"><title>TCP: ");
                rows.push_str(&format_ms(connect_end - connect_start));
                rows.push_str("</title></rect>");
            }
        }

        if secure_start > 0.0 && connect_end > secure_start {
            rows.push_str("<rect x=\"");
            rows.push_str(&js_number_to_string(to_x(secure_start)));
            rows.push_str("\" y=\"");
            rows.push_str(&js_number_to_string(y + 4.0));
            rows.push_str("\" width=\"");
            rows.push_str(&js_number_to_string(f64::max(
                1.0,
                to_x(connect_end) - to_x(secure_start),
            )));
            rows.push_str("\" height=\"");
            rows.push_str(&js_number_to_string(ROW_H - 8.0));
            rows.push_str("\" fill=\"");
            rows.push_str(COLOR_SSL);
            rows.push_str("\"><title>SSL: ");
            rows.push_str(&format_ms(connect_end - secure_start));
            rows.push_str("</title></rect>");
        }

        let request_start = field_number(entry, "requestStart");
        let response_start = field_number(entry, "responseStart");
        if request_start > 0.0 && response_start > request_start {
            rows.push_str("<rect x=\"");
            rows.push_str(&js_number_to_string(to_x(request_start)));
            rows.push_str("\" y=\"");
            rows.push_str(&js_number_to_string(y + 4.0));
            rows.push_str("\" width=\"");
            rows.push_str(&js_number_to_string(f64::max(
                1.0,
                to_x(response_start) - to_x(request_start),
            )));
            rows.push_str("\" height=\"");
            rows.push_str(&js_number_to_string(ROW_H - 8.0));
            rows.push_str("\" fill=\"");
            rows.push_str(COLOR_TTFB);
            rows.push_str("\"><title>TTFB: ");
            rows.push_str(&format_ms(response_start - request_start));
            rows.push_str("</title></rect>");
        }

        let response_end = field_number(entry, "responseEnd");
        if response_start > 0.0 && response_end > response_start {
            rows.push_str("<rect x=\"");
            rows.push_str(&js_number_to_string(to_x(response_start)));
            rows.push_str("\" y=\"");
            rows.push_str(&js_number_to_string(y + 4.0));
            rows.push_str("\" width=\"");
            rows.push_str(&js_number_to_string(f64::max(
                1.0,
                to_x(response_end) - to_x(response_start),
            )));
            rows.push_str("\" height=\"");
            rows.push_str(&js_number_to_string(ROW_H - 8.0));
            rows.push_str("\" fill=\"");
            rows.push_str(COLOR_DOWNLOAD);
            rows.push_str("\"><title>Download: ");
            rows.push_str(&format_ms(response_end - response_start));
            rows.push_str("</title></rect>");
        }

        let duration = number_or(
            response_end - field_number(entry, "startTime"),
            field_number(entry, "duration"),
        );
        rows.push_str("<text x=\"");
        rows.push_str(&js_number_to_string(to_x(number_or(
            response_end,
            field_number(entry, "startTime") + duration,
        )) + 6.0));
        rows.push_str("\" y=\"");
        rows.push_str(&js_number_to_string(y + 14.0));
        rows.push_str("\" fill=\"#888\" font-size=\"10\" font-family=\"monospace\">");
        rows.push_str(&format_ms(duration));
        rows.push_str("</text>");
    }

    let num_ticks = f64::min(10.0, (total_time / 100.0).ceil());
    let mut grid_lines = String::new();
    let mut t = 0.0f64;
    while t <= num_ticks {
        let tx = BAR_START + (t / num_ticks) * BAR_W;
        grid_lines.push_str("<line x1=\"");
        grid_lines.push_str(&js_number_to_string(tx));
        grid_lines.push_str("\" y1=\"40\" x2=\"");
        grid_lines.push_str(&js_number_to_string(tx));
        grid_lines.push_str("\" y2=\"");
        grid_lines.push_str(&js_number_to_string(chart_height - 10.0));
        grid_lines.push_str("\" stroke=\"#333\" stroke-width=\"0.5\"/>");
        grid_lines.push_str("<text x=\"");
        grid_lines.push_str(&js_number_to_string(tx));
        grid_lines.push_str(
            "\" y=\"30\" fill=\"#777\" font-size=\"10\" font-family=\"monospace\" text-anchor=\"middle\">",
        );
        grid_lines.push_str(&format_ms((t / num_ticks) * total_time));
        grid_lines.push_str("</text>");
        t += 1.0;
    }

    let mut out = String::new();
    out.push_str(WF_0);
    out.push_str(&crate::util::iso8601_now());
    out.push_str(WF_2);
    out.push_str(&sorted.len().to_string());
    out.push_str(WF_4);
    out.push_str(&format_ms(total_time));
    out.push_str(WF_6);
    out.push_str(&compute_recon_stats(timings));
    out.push_str(WF_8);
    out.push_str(COLOR_DNS);
    out.push_str(WF_10);
    out.push_str(COLOR_TCP);
    out.push_str(WF_12);
    out.push_str(COLOR_SSL);
    out.push_str(WF_14);
    out.push_str(COLOR_TTFB);
    out.push_str(WF_16);
    out.push_str(COLOR_DOWNLOAD);
    out.push_str(WF_18);
    out.push_str(&js_number_to_string(TOTAL_W));
    out.push_str(WF_20);
    out.push_str(&js_number_to_string(svg_height));
    out.push_str(WF_22);
    out.push_str(&js_number_to_string(TOTAL_W));
    out.push_str(WF_24);
    out.push_str(&js_number_to_string(TOTAL_W));
    out.push_str(WF_26);
    out.push_str(&js_number_to_string(svg_height));
    out.push_str(WF_28);
    out.push_str(COLOR_BG);
    out.push_str(WF_30);
    out.push_str(&grid_lines);
    out.push_str(&rows);
    out.push_str(WF_33);
    out.push_str(&generate_table(&sorted));
    out.push_str(WF_35);
    out.push_str(&serde_json::to_string(&sorted).unwrap_or_default());
    out.push_str(WF_37);
    out
}

/// `generateTable`: the waterfall page's request table.
pub fn generate_table(timings: &[Value]) -> String {
    let mut html = String::from(
        "<table id=\"resTable\"><thead><tr><th>URL</th><th>Type</th><th>Status</th><th>Size</th><th>Time</th><th>DNS</th><th>TCP</th><th>SSL</th><th>TTFB</th><th>Download</th></tr></thead><tbody>",
    );
    for entry in timings {
        let dns = number_or(
            field_number(entry, "domainLookupEnd") - field_number(entry, "domainLookupStart"),
            0.0,
        );
        let tcp = number_or(
            field_number(entry, "connectEnd") - field_number(entry, "connectStart"),
            0.0,
        );
        let ssl = if field_number(entry, "secureConnectionStart") > 0.0
            && field_number(entry, "connectEnd") > 0.0
        {
            field_number(entry, "connectEnd") - field_number(entry, "secureConnectionStart")
        } else {
            0.0
        };
        let ttfb = number_or(
            field_number(entry, "responseStart") - field_number(entry, "requestStart"),
            0.0,
        );
        let download = number_or(
            field_number(entry, "responseEnd") - field_number(entry, "responseStart"),
            0.0,
        );
        let status = if field_number(entry, "transferSize") > 0.0
            || field_number(entry, "encodedBodySize") > 0.0
        {
            "OK"
        } else {
            "from cache"
        };
        let size = format_size(number_or(
            number_or(
                field_number(entry, "transferSize"),
                field_number(entry, "encodedBodySize"),
            ),
            number_or(field_number(entry, "decodedBodySize"), 0.0),
        ));
        let name = field_str(entry, "name");
        html.push_str(
            "<tr><td style=\"max-width:320px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap\" title=\"",
        );
        html.push_str(&escape_attr(&Value::String(name.clone())));
        html.push_str("\">");
        html.push_str(&escape_html(&name));
        html.push_str("</td><td>");
        let initiator = {
            let value = field_str(entry, "initiatorType");
            if value.is_empty() {
                "other".to_string()
            } else {
                value
            }
        };
        html.push_str(&escape_html(&initiator));
        html.push_str("</td><td>");
        html.push_str(status);
        html.push_str("</td><td>");
        html.push_str(&size);
        html.push_str("</td><td>");
        html.push_str(&format_ms(number_or(field_number(entry, "duration"), 0.0)));
        html.push_str("</td><td>");
        html.push_str(&if dns > 0.0 { format_ms(dns) } else { "-".to_string() });
        html.push_str("</td><td>");
        html.push_str(&if tcp > 0.0 { format_ms(tcp) } else { "-".to_string() });
        html.push_str("</td><td>");
        html.push_str(&if ssl > 0.0 { format_ms(ssl) } else { "-".to_string() });
        html.push_str("</td><td>");
        html.push_str(&if ttfb > 0.0 { format_ms(ttfb) } else { "-".to_string() });
        html.push_str("</td><td>");
        html.push_str(&if download > 0.0 {
            format_ms(download)
        } else {
            "-".to_string()
        });
        html.push_str("</td></tr>");
    }
    html.push_str("</tbody></table>");
    html
}

/// `describeCaptureReason`: the one-line explanation of the current capture
/// window, preferring the runtime status over the stack profile.
pub fn describe_capture_reason(status: Option<&Value>, profile: Option<&Value>) -> String {
    if let Some(reason) = status.map(|s| field_str(s, "reasonText")) {
        if !reason.is_empty() {
            return reason;
        }
    }
    if let Some(status) = status {
        if js_truthy(status.get("ready").unwrap_or(&Value::Null)) {
            return "Adaptive capture window satisfied. Export can proceed.".to_string();
        }
    }
    let reasons = profile
        .and_then(|p| p.get("strategy"))
        .and_then(|s| s.get("reasons"))
        .and_then(|r| r.as_array());
    if let Some(reasons) = reasons {
        if !reasons.is_empty() {
            let profile_name = profile
                .and_then(|p| p.get("strategy"))
                .map(|s| field_str(s, "profile"))
                .unwrap_or_default();
            let first = value_text(&reasons[0]);
            return format!("Adaptive mode: {profile_name}. {first}.");
        }
    }
    "Profiler idle until capture starts.".to_string()
}

/// `exportFrameworkArtifacts`: the framework state slices, one JSON file each,
/// written only when the corresponding slice is non-empty.
pub fn export_framework_artifacts(
    writer: &mut dyn FnMut(&str, &str),
    framework_state: Option<&Value>,
) {
    let Some(state) = framework_state else { return };
    let pretty = |value: &Value| serde_json::to_string_pretty(value).unwrap_or_default();
    let files: [(&str, &str); 7] = [
        ("_framework/summary.json", "summary"),
        ("_framework/router-state.json", "router"),
        ("_framework/framework-roots.json", "roots"),
        ("_framework/store-snapshots.json", "stores"),
        ("_framework/query-caches.json", "queries"),
        ("_framework/hydration-payloads.json", "hydration"),
        ("_framework/auth-state.json", "auth"),
    ];
    for (path, key) in files {
        let value = state.get(key);
        if value.map(keys_len).unwrap_or(0) == 0 {
            continue;
        }
        if let Some(value) = value {
            writer(path, &pretty(value));
        }
    }
}

/// `exportRuntimeArtifacts`: writes each runtime payload through the byte
/// writer (base64 payloads are decoded), then the manifest. Returns the
/// manifest rows.
pub fn export_runtime_artifacts(
    writer: &mut dyn FnMut(&str, &[u8]),
    runtime_entries: &[Value],
) -> Vec<Value> {
    let mut manifest = Vec::new();
    let mut counters: std::collections::BTreeMap<String, usize> = std::collections::BTreeMap::new();
    for entry in runtime_entries {
        let mut manifest_entry = serde_json::Map::new();
        if let Some(object) = entry.as_object() {
            for (key, value) in object {
                if matches!(
                    key.as_str(),
                    "index" | "text" | "base64" | "hasText" | "hasBase64"
                ) {
                    continue;
                }
                manifest_entry.insert(key.clone(), value.clone());
            }
        }
        let text = entry.get("text").filter(|v| v.is_string());
        let base64 = entry.get("base64").filter(|v| v.is_string());
        if text.is_some() || base64.is_some() {
            let path = crate::panel::artifacts::build_runtime_path(entry, &mut counters);
            if let Some(text) = text {
                writer(&path, text.as_str().unwrap().as_bytes());
            } else if let Some(base64) = base64 {
                if let Some(bytes) = crate::decoders::decode_base64_to_bytes(base64.as_str().unwrap())
                {
                    writer(&path, &bytes);
                }
            }
            manifest_entry.insert("file".to_string(), Value::String(path));
        }
        manifest.push(Value::Object(manifest_entry));
    }
    let manifest_value = Value::Array(manifest.clone());
    writer(
        "_runtime/runtime-manifest.json",
        serde_json::to_string_pretty(&manifest_value)
            .unwrap_or_default()
            .as_bytes(),
    );
    manifest
}

/// `exportSemanticAnalysis`: the analysis JSON files, the readable
/// reconstructions and the console page.
pub fn export_semantic_analysis(
    writer: &mut dyn FnMut(&str, &str),
    js_assets: &[ScriptInput],
    recon_data: Option<&Value>,
    runtime_entries: &[Value],
    runtime_manifest: &[Value],
) {
    let analysis = build_semantic_analysis(js_assets, recon_data, runtime_entries, runtime_manifest);
    export_readable_artifacts(writer, &analysis);
    let pretty = |value: &Value| serde_json::to_string_pretty(value).unwrap_or_default();
    for (path, key) in [
        ("_analysis/chunk-map.json", "chunkMap"),
        ("_analysis/cross-boundary-flows.json", "crossBoundaryFlows"),
        ("_analysis/module-graph.json", "moduleGraph"),
        ("_analysis/startup-chain.json", "startupChain"),
        ("_analysis/runtime-origins.json", "runtimeOrigins"),
        ("_analysis/boundary-labels.json", "boundaryLabels"),
        ("_analysis/framework-runtime.json", "frameworkRuntime"),
        (
            "_analysis/interesting-entrypoints.json",
            "interestingEntrypoints",
        ),
    ] {
        if let Some(value) = analysis.get(key) {
            writer(path, &pretty(value));
        }
    }
    let investigation = analysis.get("investigation").cloned().unwrap_or(Value::Null);
    writer(
        "_analysis/index.html",
        &generate_investigation_index_html(&investigation),
    );
    for workspace in investigation
        .get("workspaces")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default()
    {
        writer(
            &format!("_analysis/workspaces/{}.json", field_str(&workspace, "id")),
            &pretty(&workspace),
        );
    }
    for journey in investigation
        .get("journeys")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default()
    {
        writer(
            &format!("_analysis/journeys/{}.json", field_str(&journey, "id")),
            &pretty(&journey),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::panel::text::js_number_value;
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

    /// Mirrors the oracle's `timing()` helper: every field is present, the
    /// ones a case does not override stay zero.
    fn timing_case() -> Value {
        let defaults = |name: &str, initiator: &str, start: f64, duration: f64| {
            json!({
                "name": name,
                "initiatorType": initiator,
                "startTime": js_number_value(start),
                "domainLookupStart": 0,
                "domainLookupEnd": 0,
                "connectStart": 0,
                "connectEnd": 0,
                "secureConnectionStart": 0,
                "requestStart": 0,
                "responseStart": 0,
                "responseEnd": 0,
                "duration": js_number_value(duration),
                "transferSize": 0,
                "encodedBodySize": 0,
                "decodedBodySize": 0,
            })
        };
        let mut first = defaults("https://demo.test/static/app.js?v=3", "script", 0.0, 118.5);
        for (key, value) in [
            ("domainLookupStart", 0.4),
            ("domainLookupEnd", 3.2),
            ("connectStart", 3.2),
            ("connectEnd", 14.6),
            ("secureConnectionStart", 6.1),
            ("requestStart", 15.0),
            ("responseStart", 42.75),
            ("responseEnd", 118.5),
            ("transferSize", 20480.0),
            ("encodedBodySize", 19000.0),
            ("decodedBodySize", 51000.0),
        ] {
            first[key] = js_number_value(value);
        }
        let mut second = defaults(
            "https://cdn.other.test/lib/vendor.css",
            "link",
            12.25,
            77.75,
        );
        for (key, value) in [
            ("connectStart", 12.25),
            ("connectEnd", 30.0),
            ("requestStart", 31.0),
            ("responseStart", 55.5),
            ("responseEnd", 90.0),
            ("decodedBodySize", 1200.0),
        ] {
            second[key] = js_number_value(value);
        }
        let mut third = defaults("https://demo.test/api/session", "fetch", 40.0, 220.0);
        for (key, value) in [
            ("requestStart", 41.0),
            ("responseStart", 180.25),
            ("responseEnd", 260.0),
            ("transferSize", 512.0),
            ("encodedBodySize", 512.0),
            ("decodedBodySize", 900.0),
        ] {
            third[key] = js_number_value(value);
        }
        let mut fourth = defaults("https://demo.test/img/logo.png", "img", 300.0, 640.5);
        for (key, value) in [
            ("requestStart", 301.0),
            ("responseStart", 305.0),
            ("responseEnd", 940.5),
            ("transferSize", 8192.0),
            ("encodedBodySize", 8192.0),
            ("decodedBodySize", 8192.0),
        ] {
            fourth[key] = js_number_value(value);
        }
        let fifth = defaults("https://demo.test/beacon", "other", 950.0, 12.0);
        Value::Array(vec![first, second, third, fourth, fifth])
    }

    /// The waterfall page stamps the current time; the oracle captured its
    /// own, so both sides are normalized before comparison.
    fn strip_timestamps(text: &str) -> String {
        static STAMP: std::sync::LazyLock<regex::Regex> = std::sync::LazyLock::new(|| {
            regex::Regex::new(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z").unwrap()
        });
        STAMP.replace_all(text, "<timestamp>").to_string()
    }

    /// Reports the first diverging byte instead of dumping two long documents.
    fn assert_same_document(got: &str, want: &str, label: &str) {
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
    }

    #[test]
    fn waterfall_and_table_match_oracle() {
        let fx = fixture();
        let exp = &fx["expected"];
        let timings = timing_case();
        let list = timings.as_array().unwrap();

        assert_same_document(
            &strip_timestamps(&generate_waterfall_html(list)),
            &strip_timestamps(exp["generateWaterfallHTML"].as_str().unwrap()),
            "waterfall",
        );
        assert_eq!(
            generate_waterfall_html(&[]),
            exp["generateWaterfallHTMLEmpty"].as_str().unwrap(),
            "waterfall empty"
        );

        let mut sorted = list.clone();
        sorted.sort_by(|a, b| {
            field_number(a, "startTime")
                .partial_cmp(&field_number(b, "startTime"))
                .unwrap()
        });
        assert_same_document(
            &generate_table(&sorted),
            exp["generateTable"].as_str().unwrap(),
            "table",
        );
    }

    #[test]
    fn capture_reason_matches_oracle() {
        let fx = fixture();
        let exp = &fx["expected"];
        let want = exp["describeCaptureReason"].as_array().unwrap();
        let status = json!({"reasonText": "Custom reason."});
        let ready = json!({"ready": true});
        let profile = json!({"strategy": {"profile": "balanced", "reasons": ["steady traffic"]}});
        let not_ready = json!({"ready": false});
        let empty_reasons = json!({"strategy": {"reasons": []}});
        let cases = [
            (Some(&status), None),
            (Some(&ready), None),
            (None, Some(&profile)),
            (Some(&not_ready), Some(&empty_reasons)),
            (None, None),
        ];
        for (index, (status, profile)) in cases.iter().enumerate() {
            assert_eq!(
                describe_capture_reason(*status, *profile),
                want[index].as_str().unwrap(),
                "describeCaptureReason {index}"
            );
        }
    }

    #[test]
    fn framework_artifact_export_matches_oracle() {
        let fx = fixture();
        let exp = &fx["expected"];
        let state = json!({
            "summary": {"roots": 2, "stores": 1},
            "router": {},
            "roots": [{"id": "app"}, {"id": "root"}],
            "stores": [],
            "queries": [{"key": "user"}],
            "hydration": [],
            "auth": [{"token": "x"}],
        });
        let mut files: Vec<Value> = Vec::new();
        export_framework_artifacts(
            &mut |path, content| {
                files.push(json!([path, content]));
            },
            Some(&state),
        );
        assert_eq!(
            Value::Array(files),
            exp["exportFrameworkArtifacts"],
            "exportFrameworkArtifacts"
        );
        let mut empty: Vec<Value> = Vec::new();
        export_framework_artifacts(
            &mut |path, content| {
                empty.push(json!([path, content]));
            },
            None,
        );
        assert_eq!(
            Value::Array(empty),
            exp["exportFrameworkArtifactsNull"],
            "exportFrameworkArtifacts(null)"
        );
    }

    #[test]
    fn runtime_artifact_export_matches_oracle() {
        let fx = fixture();
        let exp = &fx["expected"];
        let entries = json!([
            {"index": 0, "id": "r1", "kind": "eval", "url": "https://x/a.js", "text": "var a = 1",
             "hasText": true, "hasBase64": false, "size": 9},
            {"index": 1, "id": "r2", "kind": "wasm", "url": "",
             "base64": "AGFzbQ==", "hasText": false, "hasBase64": true},
            {"index": 2, "id": "r3", "kind": "blob", "hasText": false, "hasBase64": false,
             "note": "not captured"},
        ]);
        let entries = entries.as_array().unwrap();
        let mut written: Vec<(String, Vec<u8>)> = Vec::new();
        let manifest = export_runtime_artifacts(
            &mut |path, bytes| {
                written.push((path.to_string(), bytes.to_vec()));
            },
            entries,
        );
        let want = exp["exportRuntimeArtifacts"].as_array().unwrap();
        assert_eq!(written.len(), want.len(), "runtime file count");
        for (index, (path, bytes)) in written.iter().enumerate() {
            let row = want[index].as_array().unwrap();
            assert_eq!(path, row[0].as_str().unwrap(), "runtime path {index}");
            let expected = row[2].as_str().unwrap();
            if row[1].as_str().unwrap() == "base64" {
                let decoded = crate::decoders::decode_base64_to_bytes(expected).unwrap();
                assert_eq!(bytes, &decoded, "runtime payload {index}");
            } else {
                assert_eq!(
                    std::str::from_utf8(bytes).unwrap(),
                    expected,
                    "runtime text {index}"
                );
            }
        }
        assert_eq!(
            Value::Array(manifest),
            exp["exportRuntimeManifest"],
            "runtime manifest"
        );
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
