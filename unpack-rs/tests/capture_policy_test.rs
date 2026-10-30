//! Pins the capture policy against the page world it was extracted from.
//!
//! `tests/fixtures/panel/capture-policy.json` was captured by pulling
//! `shouldRedactKey` and `isTextMime` out of the shipped page-world modules and
//! running them over a corpus, and by reading the seven limits out of their
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
        let want = want.as_bool().unwrap_or_else(|| panic!("{subject:?}: not a bool"));
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
}

#[test]
fn the_injected_object_is_the_shape_the_page_world_reads() {
    let injected = policy::capture_policy();
    let keys: Vec<&String> = injected
        .as_object()
        .expect("policy object")
        .keys()
        .collect();
    assert_eq!(keys, ["redactKey", "textMime", "graphqlUrl", "limits"]);
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
            "runtimeBinary"
        ]
    );
}

/// The point of the move is one source of truth, so a page-world copy coming
/// back is the defect this guards - the same way the mirrored default strategy
/// is guarded.
#[test]
fn the_page_world_keeps_no_local_copy_of_the_policy() {
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
    }
}
