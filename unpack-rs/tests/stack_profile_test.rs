//! Pins `panel::stackprofile::analyze` against the page-world module it
//! replaces.
//!
//! `tests/fixtures/stack-profile.json` was captured by running `analyze` out of
//! the shipped `src/js/stack-profile.js` under node with a pinned `Date.now`,
//! over 28 snapshots chosen to reach every detector, both sides of every
//! evidence ternary, every trait and every strategy rule - all 19 technologies,
//! all 9 traits and all 6 capture profiles. Each entry carries the snapshot, the
//! profile the JavaScript produced, and that profile's compact serialization, so
//! the Rust analyzer is held to the same values *and* the same key order.

use devtools_unpack::panel::stackprofile;
use serde_json::{json, Map, Value};

fn oracle() -> Value {
    let path = format!(
        "{}/tests/fixtures/stack-profile.json",
        env!("CARGO_MANIFEST_DIR")
    );
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("oracle {path}: {e}"));
    serde_json::from_str(&text).expect("oracle json")
}

/// `generatedAt` is the only clock-dependent field, so both sides get a fixed
/// value and everything else is compared exactly.
fn blank_clock(mut profile: Value) -> Value {
    if let Some(object) = profile.as_object_mut() {
        object.insert("generatedAt".to_string(), json!(0));
    }
    profile
}

/// The same normalization for the serialized form, which also gates key order
/// (both sides preserve insertion order).
fn strip_clock(text: &str) -> String {
    const KEY: &str = "\"generatedAt\":";
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(at) = rest.find(KEY) {
        out.push_str(&rest[..at + KEY.len()]);
        let tail = &rest[at + KEY.len()..];
        let digits = tail
            .find(|c: char| !c.is_ascii_digit())
            .unwrap_or(tail.len());
        out.push('0');
        rest = &tail[digits..];
    }
    out.push_str(rest);
    out
}

#[test]
fn every_captured_snapshot_matches_the_page_world_analyzer() {
    let oracle = oracle();
    let entries = oracle.as_object().expect("oracle is an object");
    assert_eq!(entries.len(), 28, "the oracle lost snapshots");

    for (name, entry) in entries {
        let snapshot = entry.get("snapshot").expect("snapshot");
        let expected = blank_clock(entry.get("profile").expect("profile").clone());
        let actual = stackprofile::analyze(snapshot);
        assert_eq!(
            blank_clock(actual.clone()),
            expected,
            "{name}: the profile differs from the page-world analyzer"
        );

        let want_text = strip_clock(
            entry
                .get("profileText")
                .and_then(|value| value.as_str())
                .expect("profileText"),
        );
        let got_text = strip_clock(&serde_json::to_string(&actual).expect("serialize"));
        assert_eq!(got_text, want_text, "{name}: the serialized form differs");
    }
}

#[test]
fn the_oracle_covers_every_detector_trait_and_strategy() {
    let oracle = oracle();
    let entries = oracle.as_object().expect("oracle is an object");
    let mut technologies = std::collections::BTreeSet::new();
    let mut traits = std::collections::BTreeSet::new();
    let mut strategies = std::collections::BTreeSet::new();
    for entry in entries.values() {
        let profile = entry.get("profile").expect("profile");
        for tech in profile["technologies"].as_array().expect("technologies") {
            technologies.insert(tech["name"].as_str().expect("name").to_string());
        }
        for item in profile["traits"].as_array().expect("traits") {
            traits.insert(item.as_str().expect("trait").to_string());
        }
        strategies.insert(
            profile["strategy"]["profile"]
                .as_str()
                .expect("profile")
                .to_string(),
        );
    }
    assert_eq!(technologies.len(), 19, "every technology: {technologies:?}");
    assert_eq!(traits.len(), 9, "every trait: {traits:?}");
    assert_eq!(strategies.len(), 6, "every strategy: {strategies:?}");
}

#[test]
fn confidence_ties_break_by_name_the_way_locale_compare_does() {
    // Node's `localeCompare` orders this fixed vocabulary exactly as a code-unit
    // comparison does. The snapshot above pins the outcome; this names the
    // assumption the port relies on.
    let oracle = oracle();
    let names: Vec<String> = oracle["remix-webpack-wasm-tie"]["profile"]["technologies"]
        .as_array()
        .expect("technologies")
        .iter()
        .map(|tech| tech["name"].as_str().expect("name").to_string())
        .collect();
    assert_eq!(names, ["Remix", "WebAssembly", "Webpack"]);
    assert!(
        names.windows(2).all(|pair| pair[0] < pair[1]),
        "tied entries are ordered by name"
    );
}

#[test]
fn a_missing_or_non_object_snapshot_falls_back_to_the_generic_profile() {
    for snapshot in [json!(null), json!([]), json!("not a snapshot"), json!({})] {
        let profile = stackprofile::analyze(&snapshot);
        assert_eq!(profile["technologies"][0]["name"], json!("Generic Web App"));
        assert_eq!(profile["strategy"]["profile"], json!("generic-app"));
        assert_eq!(profile["summary"], json!("generic-app | Generic Web App"));
        assert_eq!(profile["version"], json!(stackprofile::VERSION));
    }
}

#[test]
fn the_default_strategy_survives_when_no_rule_fires() {
    let profile = stackprofile::analyze(&json!({}));
    let strategy = &profile["strategy"];
    assert_eq!(strategy["reasons"], json!(["Generic adaptive profile"]));
    assert_eq!(strategy["bootDelayMs"], json!(1200));
    assert_eq!(strategy["maxCaptureMs"], json!(18000));
    assert_eq!(strategy["preferHydratedDom"], json!(false));
}

/// The page world used to keep its own copy of the default strategy
/// (`injected.js::defaultStrategy`) because it needs usable timings before the
/// engine can answer - PORTING.md recorded that as a deliberate mirror, and this
/// test held it field for field against `stackprofile::default_strategy`.
///
/// The copy is gone: the strategy now rides in the injected capture policy, so
/// there is no mirror left to drift. Two things remain worth guarding. The page
/// world must read the injected value rather than declaring one again, and its
/// fallback must carry no values of its own - only zeros - because a fallback
/// holding real timings is a transcription that can drift exactly as the old
/// copy did.
#[test]
fn the_page_world_reads_the_default_strategy_instead_of_declaring_one() {
    let path = format!("{}/src/js/injected.js", env!("CARGO_MANIFEST_DIR"));
    let source = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}"));
    assert!(
        source.contains("POLICY.defaultStrategy"),
        "injected.js no longer reads the injected default strategy"
    );
    let fallback = js_default_strategy(&source).expect("injected.js keeps a fallback");
    assert!(
        !fallback.is_empty(),
        "the fallback parsed as empty, so this test would be vacuous"
    );
    for (key, value) in &fallback {
        if let Some(number) = value.as_f64() {
            assert_eq!(
                number, 0.0,
                "the fallback hardcodes `{key}` = {number}; the strategy is injected"
            );
        }
    }
}

/// Pulls the object literal out of `function defaultStrategy() { ... }`.
fn js_default_strategy(source: &str) -> Option<Map<String, Value>> {
    let at = source.find("function defaultStrategy()")?;
    let body = &source[at..];
    let open = body.find("return {")? + "return {".len();
    let mut depth = 1usize;
    let mut end = open;
    for (offset, ch) in body[open..].char_indices() {
        match ch {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    end = open + offset;
                    break;
                }
            }
            _ => {}
        }
    }
    let mut out = Map::new();
    for line in body[open..end].lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with("//") {
            continue;
        }
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        let key = key.trim();
        let value = value.trim().trim_end_matches(',').trim();
        let parsed = if value == "true" || value == "false" {
            json!(value == "true")
        } else if let Ok(number) = value.parse::<f64>() {
            // same shape `JSON.stringify` writes, or the comparison trips on
            // 1200.0 vs 1200
            if number.fract() == 0.0 {
                json!(number as i64)
            } else {
                json!(number)
            }
        } else if value.starts_with('[') {
            json!(value
                .trim_start_matches('[')
                .trim_end_matches(']')
                .split(',')
                .map(|item| item.trim().trim_matches('\'').to_string())
                .collect::<Vec<String>>())
        } else {
            json!(value.trim_matches('\''))
        };
        out.insert(key.to_string(), parsed);
    }
    Some(out)
}
