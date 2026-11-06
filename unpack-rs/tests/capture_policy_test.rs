//! Pins the capture policy against the page world it was extracted from.
//!
//! `tests/fixtures/panel/capture-policy.json` was captured by pulling
//! `shouldRedactKey` and `isTextMime` out of the shipped page-world modules and
//! running them over a corpus, and by reading the limits out of their
//! declarations - so both the vocabulary and its verdicts come from the code
//! being replaced rather than from a hand transcription. The corpus carries the
//! cases a hand-port gets wrong: case-insensitivity, substrings (`tokens`,
//! `jwtoken`, `sessionless`), near-misses (`authorisation`), empty keys and
//! MIME parameters.

use devtools_unpack::panel::policy;
use regex::RegexBuilder;
use serde_json::Value;

fn oracle() -> Value {
    let path = format!(
        "{}/tests/fixtures/panel/capture-policy.json",
        env!("CARGO_MANIFEST_DIR")
    );
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("oracle {path}: {e}"));
    serde_json::from_str(&text).expect("oracle json")
}

fn compiled(pattern: &str) -> regex::Regex {
    RegexBuilder::new(pattern)
        .case_insensitive(true)
        .build()
        .unwrap_or_else(|e| panic!("pattern {pattern:?}: {e}"))
}

/// Every captured verdict, for whichever predicate the fixture holds.
fn assert_verdicts(section: &Value, pattern: &str) {
    let regex = compiled(pattern);
    let cases = section["cases"].as_object().expect("cases");
    assert!(!cases.is_empty(), "the corpus is empty");
    for (subject, want) in cases {
        let want = want
            .as_bool()
            .unwrap_or_else(|| panic!("{subject:?}: not a bool"));
        assert_eq!(
            regex.is_match(subject),
            want,
            "verdict for {subject:?} differs from the page world"
        );
    }
}

#[test]
fn the_redaction_rule_matches_every_captured_verdict() {
    let oracle = oracle();
    let section = &oracle["redactKey"];
    assert_eq!(section["pattern"], policy::REDACT_KEY_PATTERN);
    assert_eq!(section["flags"], "i");
    assert_verdicts(section, policy::REDACT_KEY_PATTERN);
}

#[test]
fn the_text_rule_matches_every_captured_verdict() {
    let oracle = oracle();
    let section = &oracle["textMime"];
    assert_eq!(section["pattern"], policy::TEXT_MIME_PATTERN);
    assert_eq!(section["flags"], "i");
    assert_verdicts(section, policy::TEXT_MIME_PATTERN);
}

#[test]
fn the_vocabulary_and_limits_match_the_page_world() {
    let oracle = oracle();
    assert_eq!(oracle["graphqlUrlMarker"], policy::GRAPHQL_URL_MARKER);

    let limits = &oracle["limits"];
    let want = |key: &str| {
        limits[key]
            .as_u64()
            .unwrap_or_else(|| panic!("limit {key}")) as u32
    };
    assert_eq!(policy::LIMITS.items, want("items"));
    assert_eq!(policy::LIMITS.keys, want("keys"));
    assert_eq!(policy::LIMITS.string, want("string"));
    assert_eq!(policy::LIMITS.mutations, want("mutations"));
    assert_eq!(policy::LIMITS.runtime_items, want("runtimeItems"));
    assert_eq!(policy::LIMITS.runtime_text, want("runtimeText"));
    assert_eq!(policy::LIMITS.runtime_binary, want("runtimeBinary"));
    assert_eq!(policy::LIMITS.resource_urls, want("resourceUrls"));
    assert_eq!(policy::LIMITS.script_urls, want("scriptUrls"));
    assert_eq!(policy::LIMITS.endpoints, want("endpoints"));
    assert_eq!(policy::LIMITS.response_text, want("responseText"));
    assert_eq!(policy::LIMITS.socket_message, want("socketMessage"));
    assert_eq!(policy::LIMITS.mutation_text, want("mutationText"));
    assert_eq!(policy::LIMITS.element_text, want("elementText"));
    assert_eq!(policy::LIMITS.element_label, want("elementLabel"));
    assert_eq!(policy::LIMITS.class_names, want("classNames"));
    assert_eq!(policy::LIMITS.query_items, want("queryItems"));
    assert_eq!(policy::LIMITS.technologies, want("technologies"));
}

#[test]
fn the_injected_object_is_the_shape_the_page_world_reads() {
    let injected = policy::capture_policy();
    let keys: Vec<&String> = injected
        .as_object()
        .expect("policy object")
        .keys()
        .collect();
    assert_eq!(
        keys,
        ["redactKey", "textMime", "graphqlUrl", "defaultStrategy", "limits"]
    );
    assert_eq!(injected["redactKey"], policy::REDACT_KEY_PATTERN);
    assert_eq!(injected["textMime"], policy::TEXT_MIME_PATTERN);
    assert_eq!(injected["graphqlUrl"], policy::GRAPHQL_URL_MARKER);

    let limit_keys: Vec<&String> = injected["limits"]
        .as_object()
        .expect("limits object")
        .keys()
        .collect();
    assert_eq!(
        limit_keys,
        [
            "items",
            "keys",
            "string",
            "mutations",
            "runtimeItems",
            "runtimeText",
            "runtimeBinary",
            "resourceUrls",
            "scriptUrls",
            "endpoints",
            "responseText",
            "socketMessage",
            "mutationText",
            "elementText",
            "elementLabel",
            "classNames",
            "queryItems",
            "technologies"
        ]
    );
}

/// The page world used to keep its own copy of the default strategy, thirteen
/// keys transcribed from `stackprofile::default_strategy`. Nothing compared the
/// two, so a timing changed in Rust would have left the page world waiting on
/// the old one. The injected value is now the engine's own map, and this pins
/// that - the assertion is identity, not a transcription.
#[test]
fn the_injected_strategy_is_the_engine_default() {
    let injected = policy::capture_policy();
    let want = serde_json::Value::Object(devtools_unpack::panel::stackprofile::default_strategy());
    assert_eq!(injected["defaultStrategy"], want);
    assert_eq!(
        injected["defaultStrategy"]["profile"], "generic-app",
        "the profile name the page world reports"
    );
}

/// A `limit()` name that no policy key answers reads as 0 - the policy fails
/// closed - so a typo silently captures nothing instead of failing. The reverse
/// is just as invisible: a key nothing reads is a budget that no longer budgets.
/// Neither direction is visible from the Rust side alone, so both are checked
/// against the page world's own call sites.
#[test]
fn every_limit_name_the_page_world_reads_is_answered_and_every_key_is_read() {
    let injected = policy::capture_policy();
    let known: std::collections::BTreeSet<String> = injected["limits"]
        .as_object()
        .expect("limits")
        .keys()
        .cloned()
        .collect();

    let call = regex::Regex::new(r"limit\('([A-Za-z][A-Za-z0-9]*)'\)").expect("limit regex");
    let hardcoded = regex::Regex::new(r"\.substring\(0, *[0-9]+\)").expect("substring regex");
    let mut read: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    for name in ["framework-introspect.js", "injected.js"] {
        let path = format!("{}/src/js/{name}", env!("CARGO_MANIFEST_DIR"));
        let source = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}"));
        for caps in call.captures_iter(&source) {
            let key = caps[1].to_string();
            assert!(
                known.contains(&key),
                "{name} reads limit('{key}'), which capture_policy() does not answer -                  it would read as 0 and capture nothing"
            );
            read.insert(key);
        }
        assert!(
            !hardcoded.is_match(&source),
            "{name} hardcodes a substring budget again; every one belongs in policy.rs"
        );
    }
    assert!(!read.is_empty(), "no limit() call sites found");
    let unused: Vec<&String> = known.difference(&read).collect();
    assert!(unused.is_empty(), "policy keys nothing reads: {unused:?}");
}

/// The point of the move is one source of truth, so a page-world copy coming
/// back is the defect this guards - for the budgets, the redaction rule and the
/// default strategy alike.
#[test]
fn the_page_world_keeps_no_local_copy_of_the_policy() {
    let nonzero_strategy_literal = regex::Regex::new(
        r"(?:bootDelay|networkQuiet|mutationQuiet|runtimeQuiet|socketQuiet|workerGrace|maxCapture)Ms:\s*[1-9]",
    )
    .expect("strategy literal regex");
    for name in ["framework-introspect.js", "injected.js"] {
        let path = format!("{}/src/js/{name}", env!("CARGO_MANIFEST_DIR"));
        let source = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}"));
        assert!(
            !source.contains("var MAX_"),
            "{name} declares a local capture limit again"
        );
        assert!(
            source.contains("__CAPTURE_POLICY__"),
            "{name} does not read the injected capture policy"
        );
        // The strategy fallback may carry zeros, never the engine's timings: a
        // non-zero literal here means the thirteen-key copy has come back.
        assert!(
            !nonzero_strategy_literal.is_match(&source),
            "{name} hardcodes a capture timing again; the strategy is injected"
        );
    }
}
