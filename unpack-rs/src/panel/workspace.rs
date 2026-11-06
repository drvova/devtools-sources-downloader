//! The investigation workspace and journey views, ported from `page.js`
//! (buildInvestigationWorkspace and its neighbours).
//!
//! Everything here reads the analysis object the pipeline produced, so the
//! whole module works on JSON values exactly like the JavaScript does.

use serde_json::{json, Value};

use crate::panel::assets::{field_number, field_str, js_truthy};
use crate::panel::boundary::{
    array_contains_any, chain_touches_boundary, flow_touches_any_boundary, flow_touches_boundary,
    BoundaryLabel,
    matches_any_boundary, matches_boundary_entry,
};
use crate::panel::text::js_number_value;
use crate::util::iso8601_now;

/// `arrayTouchesAny`.
fn array_touches_any(values: &[Value], candidates: &[String]) -> bool {
    for value in values {
        if !js_truthy(value) {
            continue;
        }
        if candidates
            .iter()
            .any(|candidate| value.as_str() == Some(candidate.as_str()))
        {
            return true;
        }
    }
    false
}

fn string_path(value: &Value) -> Vec<Value> {
    value
        .get("path")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default()
}

/// `chainPathTouchesAny`.
fn chain_path_touches_any(chain: &Value, boundaries: &[String]) -> bool {
    if !js_truthy(chain) || chain.get("path").is_none() {
        return false;
    }
    array_touches_any(&string_path(chain), boundaries)
}

/// `chainTouchesAnyBoundary`.
fn chain_touches_any_boundary(chain: &Value, boundaries: &[String]) -> bool {
    if !js_truthy(chain) {
        return false;
    }
    boundaries
        .iter()
        .any(|boundary| crate::panel::boundary::chain_touches_boundary(chain, boundary))
}

/// Everything the workspace views say about one boundary.
///
/// Held as one table because these were three separate matches on the same key -
/// a title arm, a description arm and a questions arm - so adding a boundary
/// meant finding all three, and missing one silently fell back to the generic
/// text while the other two looked correct.
struct BoundaryProfile {
    label: BoundaryLabel,
    title: &'static str,
    description: &'static str,
    questions: &'static [&'static str],
}

const PROFILES: [BoundaryProfile; 8] = [
    BoundaryProfile {
        label: BoundaryLabel::Bootstrap,
        title: "Bootstrap workspace",
        description: "Focus on initial loaders, hydration code, runtime bootstraps, and early execution pivots.",
        questions: &[
            "What actually starts the application?",
            "Which chunks materialize runtime artifacts first?",
            "Where does bootstrap hand off to router, state, or data code?",
        ],
    },
    BoundaryProfile {
        label: BoundaryLabel::Router,
        title: "Router workspace",
        description: "Focus on navigation, route loaders, route-linked chunks, and follow-on route activity.",
        questions: &[
            "Which chunks own navigation?",
            "What route-linked requests or runtime artifacts follow router activity?",
            "Which entrypoints look route-specific?",
        ],
    },
    BoundaryProfile {
        label: BoundaryLabel::State,
        title: "State workspace",
        description: "Focus on stores, persistence, rehydration, and state-driven transitions into other subsystems.",
        questions: &[
            "Which stores or persistence seams are present?",
            "Does state drive data fetches or router changes?",
            "Which runtime artifacts look state-derived?",
        ],
    },
    BoundaryProfile {
        label: BoundaryLabel::Data,
        title: "Data workspace",
        description: "Focus on API clients, GraphQL, fetch/XHR activity, and data-triggered runtime behavior.",
        questions: &[
            "Which requests look like the primary API layer?",
            "Which chunks and runtimes trigger requests?",
            "Are GraphQL or other data clients obvious?",
        ],
    },
    BoundaryProfile {
        label: BoundaryLabel::Auth,
        title: "Auth workspace",
        description: "Focus on session setup, token handling, login/logout paths, and downstream auth-driven requests.",
        questions: &[
            "Where is session or token handling initialized?",
            "Which requests belong to login/session refresh?",
            "What does auth trigger next: data, router, or analytics?",
        ],
    },
    BoundaryProfile {
        label: BoundaryLabel::Analytics,
        title: "Analytics workspace",
        description: "Focus on telemetry, tracking beacons, pageview/reporting paths, and analytics fan-out.",
        questions: &[
            "Which beacons or SDK seams are present?",
            "What subsystem activity feeds analytics?",
            "Which chunks likely own telemetry wiring?",
        ],
    },
    BoundaryProfile {
        label: BoundaryLabel::Editor,
        title: "Editor workspace",
        description: "Focus on rich-text/editor runtimes, content workflows, and document mutation paths.",
        questions: &[
            "Which assets or runtimes look content- or editor-related?",
            "What runtime materialization follows editor activity?",
            "Does editor activity lead into state or data flows?",
        ],
    },
    BoundaryProfile {
        label: BoundaryLabel::Vendor,
        title: "Vendor workspace",
        description: "Focus on third-party/framework code that spawns runtime artifacts or crosses into business logic.",
        questions: &[
            "Which third-party bundles are most influential?",
            "Which runtime artifacts come from vendor/framework code?",
            "Where does vendor code cross into app subsystems?",
        ],
    },
];

/// The boundary names arrive as data, so an unknown one falls back to generic
/// text rather than panicking.
fn profile(boundary: &str) -> Option<&'static BoundaryProfile> {
    PROFILES.iter().find(|profile| profile.label == boundary)
}

/// `getBoundaryTitle`.
fn get_boundary_title(boundary: &str) -> String {
    profile(boundary)
        .map(|profile| profile.title.to_string())
        .unwrap_or_else(|| format!("{boundary} workspace"))
}

/// `getBoundaryDescription`.
fn get_boundary_description(boundary: &str) -> String {
    profile(boundary)
        .map(|profile| profile.description.to_string())
        .unwrap_or_else(|| "Focus on artifacts labeled for this subsystem.".to_string())
}

/// `getBoundaryQuestions`.
fn get_boundary_questions(boundary: &str) -> Vec<String> {
    let questions = profile(boundary)
        .map(|profile| profile.questions)
        .unwrap_or(&[
            "Which artifacts belong here?",
            "Which flows enter or leave this boundary?",
        ]);
    questions.iter().map(|q| q.to_string()).collect()
}

/// `getJourneyQuestions`.
fn get_journey_questions(id: &str) -> Vec<String> {
    let questions: &[&str] = match id {
        "initial-load" => &[
            "Which chunk booted first?",
            "What runtime artifacts were materialized during startup?",
            "Which early transitions led into data or router activity?",
        ],
        "auth-handshake" => &[
            "Which assets and requests carry auth signals?",
            "Does auth lead into data, router, or analytics behavior?",
            "Which runtime artifacts appear around session setup?",
        ],
        "route-change" => &[
            "Which chunks and requests cluster around navigation?",
            "Does route activity trigger data fetches or analytics?",
            "Which runtime artifacts appear after router activity?",
        ],
        "runtime-materialization" => &[
            "Which chunks created runtime artifacts?",
            "Which runtime artifacts spawn other runtimes?",
            "What requests or boundary transitions follow runtime generation?",
        ],
        _ => &[
            "What does this slice show first?",
            "Which transitions deserve inspection?",
        ],
    };
    questions.iter().map(|q| q.to_string()).collect()
}

/// `pushFrameworkCollectionEvents`.
fn push_framework_collection_events(
    target: &mut Vec<Value>,
    items: Option<&Value>,
    kind: &str,
    boundary: &str,
    fallback_label: &str,
) {
    let items = items
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    for (index, item) in items.iter().enumerate() {
        if target.len() >= 24 {
            break;
        }
        let item = if js_truthy(item) { item } else { &Value::Null };
        let label = {
            let candidate = field_str(item, "id");
            if !candidate.is_empty() {
                candidate
            } else {
                let candidate = field_str(item, "kind");
                if !candidate.is_empty() {
                    candidate
                } else {
                    let candidate = field_str(item, "tag");
                    if !candidate.is_empty() {
                        candidate
                    } else {
                        fallback_label.to_string()
                    }
                }
            }
        };
        let detail = {
            let candidate = field_str(item, "source");
            if !candidate.is_empty() {
                candidate
            } else {
                let candidate = field_str(item, "route");
                if !candidate.is_empty() {
                    candidate
                } else {
                    field_str(item, "status")
                }
            }
        };
        let score = {
            let candidate = field_number(item, "keyCount");
            if candidate != 0.0 {
                candidate
            } else {
                let candidate = field_number(item, "queryCount");
                if candidate != 0.0 {
                    candidate
                } else {
                    field_number(item, "childCount")
                }
            }
        };
        target.push(json!({
            "id": format!("{kind}-{}", index + 1),
            "kind": kind,
            "boundary": boundary,
            "label": label,
            "detail": detail,
            "score": js_number_value(score),
        }));
    }
}

/// `buildFrameworkStateEvents`.
fn build_framework_state_events(framework_state: &Value) -> Vec<Value> {
    if !js_truthy(framework_state) {
        return Vec::new();
    }
    let mut events: Vec<Value> = Vec::new();
    let route = field_str(framework_state, "route");
    let router_framework = field_str(framework_state, "routerFramework");
    if !route.is_empty() || !router_framework.is_empty() {
        events.push(json!({
            "id": "framework-router",
            "kind": "router-state",
            "boundary": "router",
            "label": format!("{} router", if router_framework.is_empty() { "generic".to_string() } else { router_framework }),
            "detail": route,
            "score": js_number_value(field_number(framework_state, "queryKeyCount")),
        }));
    }
    for (key, kind, boundary, fallback) in [
        ("roots", "framework-root", "bootstrap", "root"),
        ("stores", "store-snapshot", "state", "store"),
        ("queries", "query-cache", "data", "query"),
        ("hydration", "hydration-payload", "bootstrap", "hydration"),
        ("auth", "auth-state", "auth", "auth"),
    ] {
        push_framework_collection_events(
            &mut events,
            framework_state.get(key),
            kind,
            boundary,
            fallback,
        );
    }
    events.into_iter().take(24).collect()
}

fn items_of(analysis: &Value, key: &str) -> Vec<Value> {
    analysis
        .get(key)
        .and_then(|v| v.get("items"))
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default()
}

fn flows_of(analysis: &Value, key: &str) -> Vec<Value> {
    analysis
        .get("crossBoundaryFlows")
        .and_then(|v| v.get(key))
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default()
}

/// `buildBoundaryWorkspace`.
fn build_boundary_workspace(boundary: &str, analysis: &Value) -> Value {
    let chunks: Vec<Value> = items_of(analysis, "chunkMap")
        .into_iter()
        .filter(|item| matches_boundary_entry(item, boundary))
        .take(18)
        .collect();
    let runtime: Vec<Value> = items_of(analysis, "runtimeOrigins")
        .into_iter()
        .filter(|item| matches_boundary_entry(item, boundary))
        .take(18)
        .collect();
    let entrypoints: Vec<Value> = analysis
        .get("interestingEntrypoints")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .filter(|item| matches_boundary_entry(item, boundary))
        .take(10)
        .collect();
    let events: Vec<Value> = flows_of(analysis, "events")
        .into_iter()
        .filter(|item| matches_boundary_entry(item, boundary))
        .take(24)
        .collect();
    let transitions: Vec<Value> = flows_of(analysis, "transitions")
        .into_iter()
        .filter(|item| flow_touches_boundary(item, boundary))
        .take(24)
        .collect();
    let top_transitions: Vec<Value> = flows_of(analysis, "topTransitions")
        .into_iter()
        .filter(|item| {
            field_str(item, "fromBoundary") == boundary || field_str(item, "toBoundary") == boundary
        })
        .take(10)
        .collect();
    let chains: Vec<Value> = flows_of(analysis, "chains")
        .into_iter()
        .filter(|item| chain_touches_boundary(item, boundary))
        .take(10)
        .collect();
    json!({
        "id": boundary,
        "title": get_boundary_title(boundary),
        "description": get_boundary_description(boundary),
        "questions": get_boundary_questions(boundary),
        "summary": {
            "chunkCount": chunks.len(),
            "runtimeCount": runtime.len(),
            "entrypointCount": entrypoints.len(),
            "eventCount": events.len(),
            "transitionCount": transitions.len(),
            "chainCount": chains.len(),
            "totalItems": chunks.len() + runtime.len() + entrypoints.len(),
        },
        "entrypoints": entrypoints,
        "chunks": chunks,
        "runtime": runtime,
        "events": events,
        "transitions": transitions,
        "topTransitions": top_transitions,
        "chains": chains,
        "relatedArtifacts": [
            crate::panel::paths::ANALYSIS_BOUNDARY_LABELS,
            crate::panel::paths::ANALYSIS_CROSS_BOUNDARY_FLOWS,
            crate::panel::paths::ANALYSIS_INTERESTING_ENTRYPOINTS,
        ],
    })
}

/// `buildFrameworkStateWorkspace`.
fn build_framework_state_workspace(analysis: &Value, existing_workspaces: &[Value]) -> Value {
    let framework_state = analysis
        .get("frameworkState")
        .filter(|v| js_truthy(v))
        .cloned()
        .unwrap_or_else(|| json!({}));
    let boundaries: Vec<String> = [
        BoundaryLabel::Bootstrap,
        BoundaryLabel::Router,
        BoundaryLabel::State,
        BoundaryLabel::Data,
        BoundaryLabel::Auth,
    ]
    .iter()
    .map(|label| label.as_str().to_string())
    .collect();
    let chunks: Vec<Value> = items_of(analysis, "chunkMap")
        .into_iter()
        .filter(|item| matches_any_boundary(item, &boundaries))
        .take(18)
        .collect();
    let runtime: Vec<Value> = items_of(analysis, "runtimeOrigins")
        .into_iter()
        .filter(|item| matches_any_boundary(item, &boundaries))
        .take(18)
        .collect();
    let entrypoints: Vec<Value> = analysis
        .get("interestingEntrypoints")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .filter(|item| matches_any_boundary(item, &boundaries))
        .take(12)
        .collect();
    let transitions: Vec<Value> = flows_of(analysis, "transitions")
        .into_iter()
        .filter(|item| flow_touches_any_boundary(item, &boundaries))
        .take(24)
        .collect();
    let chains: Vec<Value> = flows_of(analysis, "chains")
        .into_iter()
        .filter(|item| chain_touches_any_boundary(item, &boundaries))
        .take(10)
        .collect();
    let events = build_framework_state_events(&framework_state);
    let supporting: Vec<Value> = existing_workspaces
        .iter()
        .filter(|workspace| {
            array_contains_any(
                &boundaries,
                std::slice::from_ref(&field_str(workspace, "id")),
            )
        })
        .cloned()
        .collect();
    let top_transitions: Vec<Value> = flows_of(analysis, "topTransitions")
        .into_iter()
        .filter(|item| {
            array_contains_any(
                &[
                    field_str(item, "fromBoundary"),
                    field_str(item, "toBoundary"),
                ],
                &boundaries,
            )
        })
        .take(10)
        .collect();
    let number_or_zero = |key: &str| js_number_value(field_number(&framework_state, key));
    let router_framework = {
        let value = field_str(&framework_state, "routerFramework");
        if value.is_empty() {
            "generic".to_string()
        } else {
            value
        }
    };
    json!({
        "id": "framework-state",
        "title": "Framework State workspace",
        "description": "Summarize the inspected framework state across router, stores, query caches, hydration payloads, auth state, and detected framework roots.",
        "focusBoundaries": boundaries,
        "questions": [
            "Which router state is active and where did it come from?",
            "Which stores, caches, and hydration payloads are present?",
            "What auth/session state is exposed?",
            "Which supporting workspaces explain the observed framework state?",
        ],
        "summary": {
            "chunkCount": chunks.len(),
            "runtimeCount": runtime.len(),
            "entrypointCount": entrypoints.len(),
            "eventCount": events.len(),
            "transitionCount": transitions.len(),
            "chainCount": chains.len(),
            "totalItems": chunks.len() + runtime.len() + entrypoints.len(),
            "rootCount": number_or_zero("rootCount"),
            "storeCount": number_or_zero("storeCount"),
            "queryCount": number_or_zero("queryCount"),
            "hydrationCount": number_or_zero("hydrationCount"),
            "authCount": number_or_zero("authCount"),
            "routerFramework": router_framework,
            "route": field_str(&framework_state, "route"),
        },
        "entrypoints": entrypoints,
        "chunks": chunks,
        "runtime": runtime,
        "events": events,
        "transitions": transitions,
        "topTransitions": top_transitions,
        "chains": chains,
        "supportingWorkspaces": supporting,
        "relatedArtifacts": framework_state
            .get("relatedArtifacts")
            .cloned()
            .unwrap_or_else(|| json!([])),
    })
}

/// `buildJourneyView`.
#[allow(clippy::too_many_arguments)]
fn build_journey_view(
    id: &str,
    title: &str,
    description: &str,
    analysis: &Value,
    workspace_map: &std::collections::BTreeMap<String, Value>,
    focus_boundaries: &[String],
    transition_filter: &dyn Fn(&Value) -> bool,
) -> Value {
    let transitions: Vec<Value> = flows_of(analysis, "transitions")
        .into_iter()
        .filter(|flow| {
            transition_filter(flow) || {
                let endpoints = if !field_str(flow, "fromBoundary").is_empty() {
                    vec![
                        Value::String(field_str(flow, "fromBoundary")),
                        Value::String(field_str(flow, "toBoundary")),
                    ]
                } else {
                    Vec::new()
                };
                array_touches_any(&endpoints, focus_boundaries)
            }
        })
        .take(26)
        .collect();
    let events: Vec<Value> = flows_of(analysis, "events")
        .into_iter()
        .filter(|event| matches_any_boundary(event, focus_boundaries))
        .take(28)
        .collect();
    let entrypoints: Vec<Value> = analysis
        .get("interestingEntrypoints")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .filter(|entry| matches_any_boundary(entry, focus_boundaries))
        .take(10)
        .collect();
    let chains: Vec<Value> = flows_of(analysis, "chains")
        .into_iter()
        .filter(|chain| chain_path_touches_any(chain, focus_boundaries))
        .take(10)
        .collect();
    let mut supporting: Vec<Value> = Vec::new();
    for boundary in focus_boundaries {
        if let Some(workspace) = workspace_map.get(boundary) {
            supporting.push(json!({
                "id": field_str(workspace, "id"),
                "title": field_str(workspace, "title"),
                "summary": workspace.get("summary").cloned().unwrap_or_else(|| json!({})),
                "entrypoints": workspace
                    .get("entrypoints")
                    .and_then(|v| v.as_array())
                    .cloned()
                    .unwrap_or_default()
                    .into_iter()
                    .take(3)
                    .collect::<Vec<Value>>(),
            }));
        }
    }
    json!({
        "id": id,
        "title": title,
        "description": description,
        "focusBoundaries": focus_boundaries,
        "summary": {
            "eventCount": events.len(),
            "transitionCount": transitions.len(),
            "chainCount": chains.len(),
            "entrypointCount": entrypoints.len(),
        },
        "questions": get_journey_questions(id),
        "entrypoints": entrypoints,
        "events": events,
        "transitions": transitions,
        "chains": chains,
        "supportingWorkspaces": supporting,
        "relatedArtifacts": [
            crate::panel::paths::ANALYSIS_CROSS_BOUNDARY_FLOWS,
            crate::panel::paths::ANALYSIS_STARTUP_CHAIN,
            crate::panel::paths::ANALYSIS_RUNTIME_ORIGINS,
        ],
    })
}

/// `buildJourneyViews`.
fn build_journey_views(analysis: &Value, workspaces: &[Value]) -> Vec<Value> {
    let workspace_map: std::collections::BTreeMap<String, Value> = workspaces
        .iter()
        .map(|workspace| (field_str(workspace, "id"), workspace.clone()))
        .collect();
    let focus = |items: &[BoundaryLabel]| {
        items.iter().map(|label| label.as_str().to_string()).collect::<Vec<String>>()
    };
    vec![
        build_journey_view(
            "initial-load",
            "Initial load",
            "Trace how bootstrap code, runtime materialization, routing, and data startup fit together during first load.",
            analysis,
            &workspace_map,
            &focus(&[
                BoundaryLabel::Bootstrap,
                BoundaryLabel::Router,
                BoundaryLabel::Data,
                BoundaryLabel::State,
            ]),
            &|flow| {
                field_str(flow, "fromBoundary") == BoundaryLabel::Bootstrap.as_str()
                    || field_str(flow, "toBoundary") == BoundaryLabel::Bootstrap.as_str()
                    || field_str(flow, "relation") == "imports-boundary"
                    || field_str(flow, "relation") == "materializes-runtime"
            },
        ),
        build_journey_view(
            "auth-handshake",
            "Auth handshake",
            "Slice the session/auth path and its downstream transitions into data, router, and analytics.",
            analysis,
            &workspace_map,
            &focus(&[
                BoundaryLabel::Auth,
                BoundaryLabel::Data,
                BoundaryLabel::Router,
                BoundaryLabel::Analytics,
            ]),
            &|flow| flow_touches_boundary(flow, BoundaryLabel::Auth.as_str()),
        ),
        build_journey_view(
            "route-change",
            "Route change",
            "Slice the navigation path through router, data, state, and analytics activity.",
            analysis,
            &workspace_map,
            &focus(&[
                BoundaryLabel::Router,
                BoundaryLabel::Data,
                BoundaryLabel::State,
                BoundaryLabel::Analytics,
            ]),
            &|flow| flow_touches_boundary(flow, BoundaryLabel::Router.as_str()),
        ),
        build_journey_view(
            "runtime-materialization",
            "Runtime materialization",
            "Show which chunks create runtime artifacts and how those artifacts lead into requests or more runtime generation.",
            analysis,
            &workspace_map,
            &focus(&[
                BoundaryLabel::Bootstrap,
                BoundaryLabel::Vendor,
                BoundaryLabel::Data,
            ]),
            &|flow| {
                field_str(flow, "relation") == "materializes-runtime"
                    || field_str(flow, "relation") == "spawns-runtime"
                    || field_str(flow.get("from").unwrap_or(&Value::Null), "kind") == "runtime"
                    || field_str(flow.get("to").unwrap_or(&Value::Null), "kind") == "runtime"
            },
        ),
    ]
}

/// `buildInvestigationWorkspace`.
pub fn build_investigation_workspace(analysis: &Value) -> Value {
    let categories: Vec<String> = analysis
        .get("boundaryLabels")
        .and_then(|v| v.get("categories"))
        .and_then(|v| v.as_array())
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item.as_str().map(|s| s.to_string()))
                .collect()
        })
        .unwrap_or_else(|| {
            BoundaryLabel::ALL
                .iter()
                .map(|label| label.as_str().to_string())
            .collect()
        });
    let mut workspaces: Vec<Value> = categories
        .iter()
        .map(|category| build_boundary_workspace(category, analysis))
        .collect();
    let framework_workspace = build_framework_state_workspace(analysis, &workspaces);
    workspaces.push(framework_workspace);
    let journeys = build_journey_views(analysis, &workspaces);

    let framework_runtime = analysis
        .get("frameworkRuntime")
        .filter(|v| js_truthy(v))
        .cloned()
        .unwrap_or_else(|| json!({}));
    let profile_name = {
        let name = field_str(&framework_runtime, "profile");
        if name.is_empty() {
            "generic-app".to_string()
        } else {
            name
        }
    };
    json!({
        "generatedAt": iso8601_now(),
        "page": framework_runtime.get("page").cloned().unwrap_or_else(|| json!({})),
        "profile": {
            "name": profile_name,
            "confidence": js_number_value(field_number(&framework_runtime, "confidence")),
            "technologies": framework_runtime.get("technologies").cloned().unwrap_or_else(|| json!([])),
            "traits": framework_runtime.get("traits").cloned().unwrap_or_else(|| json!([])),
            "captureReason": field_str(&framework_runtime, "captureReason"),
        },
        "summary": {
            "workspaceCount": workspaces.len(),
            "journeyCount": journeys.len(),
            "topBoundaryFlows": flows_of(analysis, "topTransitions")
                .into_iter()
                .take(10)
                .collect::<Vec<Value>>(),
            "likelyEntrypoints": analysis
                .get("interestingEntrypoints")
                .and_then(|v| v.as_array())
                .cloned()
                .unwrap_or_default()
                .into_iter()
                .take(8)
                .collect::<Vec<Value>>(),
            "boundaryCounts": analysis
                .get("boundaryLabels")
                .and_then(|v| v.get("summary"))
                .cloned()
                .unwrap_or(Value::Null),
        },
        "workspaces": workspaces,
        "journeys": journeys,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::panel::analysis::build_semantic_analysis;
    use crate::panel::assets::ScriptInput;

    fn fixture() -> Value {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/panel/boundary-oracle.json"
        );
        serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
    }

    fn analysis_inputs() -> (Vec<ScriptInput>, Value, Vec<Value>, Vec<Value>) {
        let fx = fixture();
        let input = &fx["input"];
        let scripts: Vec<ScriptInput> =
            serde_json::from_value(input["scriptFixture"].clone()).unwrap();
        let entries = input["runtimeEntries"].as_array().unwrap().clone();
        let manifest = input["runtimeManifest"].as_array().unwrap().clone();
        let recon_data = json!({
            "timings": input["reconFixture"]["timings"],
            "stackProfile": input["reconFixture"]["stackProfile"],
            "captureStatus": input["reconFixture"]["captureStatus"],
            "page": input["reconFixture"]["page"],
            "recon": input["recon"],
            "frameworkState": input["frameworkState"],
        });
        (scripts, recon_data, entries, manifest)
    }

    /// The reports carry timestamps; everything else must match exactly.
    fn strip_timestamps(value: &Value) -> Value {
        match value {
            Value::Object(map) => Value::Object(
                map.iter()
                    .filter(|(key, _)| *key != "generatedAt")
                    .map(|(key, item)| (key.clone(), strip_timestamps(item)))
                    .collect(),
            ),
            Value::Array(items) => Value::Array(items.iter().map(strip_timestamps).collect()),
            other => other.clone(),
        }
    }

    #[test]
    fn workspace_helpers_match_oracle() {
        let fx = fixture();
        let exp = &fx["expected"];
        let (scripts, recon_data, entries, manifest) = analysis_inputs();
        let analysis = build_semantic_analysis(&scripts, Some(&recon_data), &entries, &manifest);

        let workspace = build_investigation_workspace(&analysis);
        assert_eq!(
            strip_timestamps(&workspace),
            strip_timestamps(&exp["buildInvestigationWorkspace"]),
            "buildInvestigationWorkspace"
        );

        let boundaries = ["bootstrap", "auth", "vendor", "nope"];
        let want = exp["buildBoundaryWorkspace"].as_array().unwrap();
        for (index, boundary) in boundaries.iter().enumerate() {
            assert_eq!(
                strip_timestamps(&build_boundary_workspace(boundary, &analysis)),
                strip_timestamps(&want[index]),
                "buildBoundaryWorkspace {boundary}"
            );
        }

        let workspaces = workspace["workspaces"].as_array().unwrap().clone();
        assert_eq!(
            strip_timestamps(&build_framework_state_workspace(&analysis, &workspaces)),
            strip_timestamps(&exp["buildFrameworkStateWorkspace"]),
            "buildFrameworkStateWorkspace"
        );
        assert_eq!(
            Value::Array(build_framework_state_events(&analysis["frameworkState"])),
            exp["buildFrameworkStateEvents"][0],
            "buildFrameworkStateEvents"
        );
        assert_eq!(
            Value::Array(build_framework_state_events(&Value::Null)),
            exp["buildFrameworkStateEvents"][1],
            "buildFrameworkStateEvents null"
        );
        assert_eq!(
            Value::Array(build_journey_views(&analysis, &workspaces)),
            exp["buildJourneyViews"],
            "buildJourneyViews"
        );
        let titles = ["bootstrap", "vendor", "nope"];
        let want = exp["getBoundaryTitle"].as_array().unwrap();
        for (index, boundary) in titles.iter().enumerate() {
            assert_eq!(get_boundary_title(boundary), want[index].as_str().unwrap());
        }
        let descriptions = ["data", "nope"];
        let want = exp["getBoundaryDescription"].as_array().unwrap();
        for (index, boundary) in descriptions.iter().enumerate() {
            assert_eq!(
                get_boundary_description(boundary),
                want[index].as_str().unwrap()
            );
        }
        let question_boundaries = ["auth", "nope"];
        let want = exp["getBoundaryQuestions"].as_array().unwrap();
        for (index, boundary) in question_boundaries.iter().enumerate() {
            assert_eq!(
                serde_json::to_value(get_boundary_questions(boundary)).unwrap(),
                want[index]
            );
        }
        let journey_ids = ["initial-load", "nope"];
        let want = exp["getJourneyQuestions"].as_array().unwrap();
        for (index, id) in journey_ids.iter().enumerate() {
            assert_eq!(
                serde_json::to_value(get_journey_questions(id)).unwrap(),
                want[index]
            );
        }
        assert_eq!(
            serde_json::to_value(vec![
                matches_boundary_entry(&json!({ "primaryBoundary": "auth" }), "auth"),
                matches_boundary_entry(&json!({ "boundaryLabels": ["data"] }), "data"),
                matches_boundary_entry(&json!({ "boundaryLabels": ["data"] }), "auth"),
                matches_boundary_entry(&Value::Null, "auth"),
            ])
            .unwrap(),
            exp["matchesBoundaryEntry"]
        );
        assert_eq!(
            serde_json::to_value(vec![
                chain_touches_boundary(&json!({ "path": ["a", "b"] }), "b"),
                chain_touches_boundary(&json!({ "path": ["a", "b"] }), "c"),
                chain_touches_boundary(&Value::Null, "c"),
            ])
            .unwrap(),
            exp["chainTouchesBoundary"]
        );
        assert_eq!(
            serde_json::to_value(vec![
                array_touches_any(&[json!("a"), json!(""), json!("b")], &["b".to_string()]),
                array_touches_any(&[json!("a")], &["b".to_string()]),
            ])
            .unwrap(),
            exp["arrayTouchesAny"]
        );
    }

    #[test]
    fn whole_pipeline_matches_oracle() {
        let fx = fixture();
        let exp = &fx["expected"];
        let (scripts, recon_data, entries, manifest) = analysis_inputs();
        let analysis = build_semantic_analysis(&scripts, Some(&recon_data), &entries, &manifest);
        assert_eq!(
            strip_timestamps(&analysis),
            strip_timestamps(&exp["buildSemanticAnalysis"]),
            "buildSemanticAnalysis"
        );
    }
}
