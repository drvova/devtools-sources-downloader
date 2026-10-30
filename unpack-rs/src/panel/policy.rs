//! The capture policy the page world applies: what to redact, what counts as
//! text, and how much of each thing to keep.
//!
//! These rules used to be constants inside `framework-introspect.js` and
//! `injected.js`. They are policy, not mechanism - the page world still has to
//! enumerate live objects and read the page, but *what it keeps and what it
//! hides* is a decision, and a decision belongs where it can be typed, tested
//! and reviewed. The redaction rule in particular decides whether a captured
//! token can reach the exported archive, and it had no test at all while it
//! lived in a page-world bundle.
//!
//! The panel injects [`capture_policy`] into the page ahead of its first line
//! (see `page.js::injectAndReload`), so the page world reads one source of
//! truth and pays nothing per key.

use serde_json::{json, Value};

/// Keys whose name matches this are replaced with `[redacted]`. Written in the
/// JavaScript form because the page world compiles it there.
pub const REDACT_KEY_PATTERN: &str =
    "token|secret|password|passwd|cookie|authorization|bearer|jwt|session";

/// A payload whose MIME type matches this is decoded as text rather than kept
/// as bytes.
pub const TEXT_MIME_PATTERN: &str = "(?:javascript|ecmascript|typescript|json|text|xml|svg|html|css)";

/// A request URL containing this is treated as a GraphQL endpoint. The body
/// half of that predicate is structural and stays in the page world, where it
/// mirrors `panel::graph::looks_like_graphql_body`.
pub const GRAPHQL_URL_MARKER: &str = "graphql";

/// How much of each thing a capture keeps.
pub struct Limits {
    pub items: u32,
    pub keys: u32,
    pub string: u32,
    pub mutations: u32,
    pub runtime_items: u32,
    pub runtime_text: u32,
    pub runtime_binary: u32,
}

/// The budgets the page world enforces while capturing.
pub const LIMITS: Limits = Limits {
    items: 12,
    keys: 24,
    string: 240,
    mutations: 500,
    runtime_items: 200,
    runtime_text: 262_144,
    runtime_binary: 1_048_576,
};

/// The object the panel injects as `window.__CAPTURE_POLICY__`. The page world
/// reads these names directly, so they are part of the boundary contract:
/// `tests/capture_policy_test.rs` pins the shape.
pub fn capture_policy() -> Value {
    json!({
        "redactKey": REDACT_KEY_PATTERN,
        "textMime": TEXT_MIME_PATTERN,
        "graphqlUrl": GRAPHQL_URL_MARKER,
        "limits": {
            "items": LIMITS.items,
            "keys": LIMITS.keys,
            "string": LIMITS.string,
            "mutations": LIMITS.mutations,
            "runtimeItems": LIMITS.runtime_items,
            "runtimeText": LIMITS.runtime_text,
            "runtimeBinary": LIMITS.runtime_binary,
        },
    })
}
