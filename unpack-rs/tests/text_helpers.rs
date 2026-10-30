// Pins the panel's text helpers against the JavaScript that produced the zip
// paths before the port: `tests/fixtures/text-helpers.json` was captured by
// running `sanitizeFilename` and friends out of the shipped `page.js`, so the
// Rust twins in `panel::text` are held to the names the extension used to
// write into the archive.

use devtools_unpack::panel::text as js;

fn oracle() -> serde_json::Value {
    let path = format!("{}/tests/fixtures/text-helpers.json", env!("CARGO_MANIFEST_DIR"));
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("oracle {path}: {e}"));
    serde_json::from_str(&text).expect("oracle json")
}

fn expect_string(value: &serde_json::Value, what: &str) -> String {
    value
        .as_str()
        .unwrap_or_else(|| panic!("{what}: expected a string, got {value}"))
        .to_string()
}

#[test]
fn sanitize_filename_matches_the_javascript() {
    let oracle = oracle();
    let cases = oracle["sanitizeFilename"].as_object().expect("cases");
    assert!(cases.len() > 20, "oracle should cover the branches");
    for (input, expected) in cases {
        assert_eq!(
            js::sanitize_filename(input),
            expect_string(expected, input),
            "sanitizeFilename({input:?})"
        );
    }
}

#[test]
fn sanitize_page_title_matches_the_javascript() {
    let oracle = oracle();
    let cases = oracle["sanitizePageTitle"].as_object().expect("cases");
    for (input, expected) in cases {
        assert_eq!(
            js::sanitize_page_title(input),
            expect_string(expected, input),
            "sanitizePageTitle({input:?})"
        );
    }
}

#[test]
fn helper_chain_matches_the_javascript() {
    let oracle = oracle();
    let cases = oracle["helpers"].as_object().expect("cases");
    for (key, expected) in cases {
        let (name, input) = key.split_once(':').expect("helper key");
        let want = expect_string(expected, key);
        let got = match name {
            "sanitizePathPart" => js::sanitize_path_part(input, "fb"),
            "appendPathSuffix" => js::append_path_suffix(input, "__s"),
            "normalizeUrlCandidate" => js::normalize_url_candidate(input),
            "hashString" => js::hash_string(input),
            other => panic!("unknown helper {other}"),
        };
        assert_eq!(got, want, "{name}({input:?})");
    }
}
