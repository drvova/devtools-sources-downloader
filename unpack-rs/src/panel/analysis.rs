//! The panel's whole-pipeline assembly, ported from `buildSemanticAnalysis`.
//!
//! This is the integration seam: it runs the asset analysis, module graph,
//! startup chain, boundary labels, cross-boundary flows, entrypoints,
//! framework state and the investigation workspaces in the same order the
//! JavaScript does, and hands back the analysis object every report is
//! rendered from.
//!
//! Object key order is insertion order: the crate enables `serde_json`'s
//! `preserve_order` feature, so a serialized analysis has the same keys in the
//! same textual order as the JavaScript one, and the report pages that embed
//! it are byte-identical.

use serde_json::{json, Value};

use crate::panel::assets::{
    build_chunk_summary, build_runtime_origins, build_runtime_summary, prepare_script_assets,
    strip_chunk_asset, strip_runtime_entry, ScriptInput,
};
use crate::panel::boundary::{
    build_boundary_labels, build_cross_boundary_flows, build_framework_runtime_summary,
    build_framework_state_summary, collect_interesting_entrypoints,
};
use crate::panel::graph::{build_module_graph, build_startup_chain};
use crate::panel::workspace::build_investigation_workspace;
use crate::util::iso8601_now;

/// `buildSemanticAnalysis`.
pub fn build_semantic_analysis(
    js_assets: &[ScriptInput],
    recon_data: Option<&Value>,
    runtime_entries: &[Value],
    runtime_manifest: &[Value],
) -> Value {
    let mut assets = prepare_script_assets(js_assets, recon_data);
    let mut origins = build_runtime_origins(runtime_entries, runtime_manifest, &assets);
    let boundary_labels = build_boundary_labels(&mut assets, &mut origins);
    let cross_boundary_flows = build_cross_boundary_flows(recon_data, &assets, &origins);
    let interesting_entrypoints = collect_interesting_entrypoints(&assets, &origins);
    let framework_state = build_framework_state_summary(
        recon_data
            .and_then(|r| r.get("frameworkState"))
            .filter(|v| !v.is_null()),
    );

    let mut analysis = json!({
        "assets": assets,
        "runtimeRecords": origins,
        "chunkMap": {
            "generatedAt": iso8601_now(),
            "summary": build_chunk_summary(&assets),
            "items": assets.iter().map(strip_chunk_asset).collect::<Vec<Value>>(),
        },
        "moduleGraph": build_module_graph(recon_data, &assets, &origins),
        "startupChain": build_startup_chain(recon_data, &assets, &origins),
        "runtimeOrigins": {
            "generatedAt": iso8601_now(),
            "summary": build_runtime_summary(&origins),
            "items": origins.iter().map(strip_runtime_entry).collect::<Vec<Value>>(),
        },
        "boundaryLabels": boundary_labels,
        "crossBoundaryFlows": cross_boundary_flows,
        "frameworkState": framework_state,
        "frameworkRuntime": build_framework_runtime_summary(
            recon_data,
            &assets,
            &origins,
            &interesting_entrypoints,
            Some(&boundary_labels),
            Some(&cross_boundary_flows),
        ),
        "interestingEntrypoints": interesting_entrypoints,
    });

    let investigation = build_investigation_workspace(&analysis);
    let workspaces = investigation
        .get("workspaces")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    let journeys = investigation
        .get("journeys")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    let available_workspaces: Vec<Value> = workspaces
        .iter()
        .map(|workspace| {
            json!({
                "id": workspace.get("id").cloned().unwrap_or(Value::Null),
                "title": workspace.get("title").cloned().unwrap_or(Value::Null),
                "itemCount": workspace
                    .get("summary")
                    .and_then(|s| s.get("totalItems"))
                    .cloned()
                    .unwrap_or(Value::Null),
                "transitionCount": workspace
                    .get("summary")
                    .and_then(|s| s.get("transitionCount"))
                    .cloned()
                    .unwrap_or(Value::Null),
            })
        })
        .collect();
    let available_journeys: Vec<Value> = journeys
        .iter()
        .map(|journey| {
            json!({
                "id": journey.get("id").cloned().unwrap_or(Value::Null),
                "title": journey.get("title").cloned().unwrap_or(Value::Null),
                "eventCount": journey
                    .get("summary")
                    .and_then(|s| s.get("eventCount"))
                    .cloned()
                    .unwrap_or(Value::Null),
                "transitionCount": journey
                    .get("summary")
                    .and_then(|s| s.get("transitionCount"))
                    .cloned()
                    .unwrap_or(Value::Null),
            })
        })
        .collect();
    if let Some(framework_runtime) = analysis
        .get_mut("frameworkRuntime")
        .and_then(|v| v.as_object_mut())
    {
        framework_runtime.insert(
            "availableWorkspaces".to_string(),
            Value::Array(available_workspaces),
        );
        framework_runtime.insert(
            "availableJourneys".to_string(),
            Value::Array(available_journeys),
        );
    }
    analysis["investigation"] = investigation;
    analysis
}
