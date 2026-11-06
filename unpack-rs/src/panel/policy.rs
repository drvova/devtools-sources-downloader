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
pub const TEXT_MIME_PATTERN: &str =
    "(?:javascript|ecmascript|typescript|json|text|xml|svg|html|css)";

/// A request URL containing this is treated as a GraphQL endpoint.
pub const GRAPHQL_URL_MARKER: &str = "graphql";

/// A request body whose text matches this is treated as a GraphQL operation.
///
/// Written in a form both engines accept: the page world compiles it as a
/// `RegExp`, and the engine compiles it with `unicode(false)` so `\b` is an
/// ASCII word boundary there too. The two used to spell this predicate
/// separately - `(?-u:\b)` on one side, `\b` on the other - which is the
/// same rule written two ways and free to drift. `operationName` is part of
/// the alternation because it is a plain substring test, not a word-boundary
/// one.
pub const GRAPHQL_BODY_PATTERN: &str = r"(?:^|\b)(query|mutation|subscription)\b|operationName";

/// Object keys whose presence marks a request body as a GraphQL operation.
pub const GRAPHQL_BODY_KEYS: [&str; 3] = ["query", "operationName", "extensions"];

/// How much of each thing a capture keeps.
pub struct Limits {
    pub items: u32,
    pub keys: u32,
    pub string: u32,
    pub mutations: u32,
    pub runtime_items: u32,
    pub runtime_text: u32,
    pub runtime_binary: u32,
    pub resource_urls: u32,
    pub script_urls: u32,
    pub endpoints: u32,
    pub response_text: u32,
    pub socket_message: u32,
    pub mutation_text: u32,
    pub element_text: u32,
    pub element_label: u32,
    pub class_names: u32,
    pub query_items: u32,
    pub technologies: u32,
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
    resource_urls: 160,
    script_urls: 80,
    endpoints: 20,
    response_text: 10_000,
    socket_message: 2_000,
    mutation_text: 200,
    element_text: 80,
    element_label: 40,
    class_names: 8,
    query_items: 6,
    technologies: 12,
};

/// The object the panel injects as `window.__CAPTURE_POLICY__`. The page world
/// reads these names directly, so they are part of the boundary contract:
/// `tests/capture_policy_test.rs` pins the shape.
pub fn capture_policy() -> Value {
    json!({
        "redactKey": REDACT_KEY_PATTERN,
        "textMime": TEXT_MIME_PATTERN,
        "graphqlUrl": GRAPHQL_URL_MARKER,
        "graphqlBody": GRAPHQL_BODY_PATTERN,
        "graphqlBodyKeys": GRAPHQL_BODY_KEYS,
        // The page world needs usable timings before the panel's analysed
        // profile arrives, and it used to keep its own copy of them. They are
        // engine policy like the budgets below, so they ride here.
        "defaultStrategy": crate::panel::stackprofile::default_strategy(),
        "limits": {
            "items": LIMITS.items,
            "keys": LIMITS.keys,
            "string": LIMITS.string,
            "mutations": LIMITS.mutations,
            "runtimeItems": LIMITS.runtime_items,
            "runtimeText": LIMITS.runtime_text,
            "runtimeBinary": LIMITS.runtime_binary,
            "resourceUrls": LIMITS.resource_urls,
            "scriptUrls": LIMITS.script_urls,
            "endpoints": LIMITS.endpoints,
            "responseText": LIMITS.response_text,
            "socketMessage": LIMITS.socket_message,
            "mutationText": LIMITS.mutation_text,
            "elementText": LIMITS.element_text,
            "elementLabel": LIMITS.element_label,
            "classNames": LIMITS.class_names,
            "queryItems": LIMITS.query_items,
            "technologies": LIMITS.technologies,
        },
    })
}
