//! The archive's own layout: the paths the export writes and the paths the
//! report and the workspace views refer to.
//!
//! A path written by one module and referenced by another is a contract, so it
//! is spelled once here. Renaming an artifact is then a compile error at every
//! reference instead of a report that links to a file nothing writes.

use serde_json::Value;

/// The framework-state slices the export writes, as (archive path, state key).
pub const FRAMEWORK_ARTIFACTS: [(&str, &str); 7] = [
    ("_framework/summary.json", "summary"),
    ("_framework/router-state.json", "router"),
    ("_framework/framework-roots.json", "roots"),
    ("_framework/store-snapshots.json", "stores"),
    ("_framework/query-caches.json", "queries"),
    ("_framework/hydration-payloads.json", "hydration"),
    ("_framework/auth-state.json", "auth"),
];

/// Whether a framework-state slice is present.
///
/// `keys_len` is the panel's `Object.keys(x).length`, so this is one rule for
/// objects, arrays and strings alike. The writer and the artifact index used to
/// test presence differently - the writer counted keys, the index demanded an
/// object or an array - so a slice holding a non-empty string was written to the
/// archive and left out of the index that points at it.
pub fn framework_slice_present(state: &Value, key: &str) -> bool {
    state
        .get(key)
        .map(crate::panel::assets::keys_len)
        .unwrap_or(0)
        > 0
}

pub const ANALYSIS_CHUNK_MAP: &str = "_analysis/chunk-map.json";
pub const ANALYSIS_CROSS_BOUNDARY_FLOWS: &str = "_analysis/cross-boundary-flows.json";
pub const ANALYSIS_MODULE_GRAPH: &str = "_analysis/module-graph.json";
pub const ANALYSIS_STARTUP_CHAIN: &str = "_analysis/startup-chain.json";
pub const ANALYSIS_RUNTIME_ORIGINS: &str = "_analysis/runtime-origins.json";
pub const ANALYSIS_BOUNDARY_LABELS: &str = "_analysis/boundary-labels.json";
pub const ANALYSIS_FRAMEWORK_RUNTIME: &str = "_analysis/framework-runtime.json";
pub const ANALYSIS_INTERESTING_ENTRYPOINTS: &str = "_analysis/interesting-entrypoints.json";
pub const ANALYSIS_INDEX_HTML: &str = "_analysis/index.html";

/// The analysis artifacts the export writes, as (archive path, analysis key).
pub const ANALYSIS_ARTIFACTS: [(&str, &str); 8] = [
    (ANALYSIS_CHUNK_MAP, "chunkMap"),
    (ANALYSIS_CROSS_BOUNDARY_FLOWS, "crossBoundaryFlows"),
    (ANALYSIS_MODULE_GRAPH, "moduleGraph"),
    (ANALYSIS_STARTUP_CHAIN, "startupChain"),
    (ANALYSIS_RUNTIME_ORIGINS, "runtimeOrigins"),
    (ANALYSIS_BOUNDARY_LABELS, "boundaryLabels"),
    (ANALYSIS_FRAMEWORK_RUNTIME, "frameworkRuntime"),
    (ANALYSIS_INTERESTING_ENTRYPOINTS, "interestingEntrypoints"),
];
