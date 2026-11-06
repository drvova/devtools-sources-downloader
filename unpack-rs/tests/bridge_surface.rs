//! The bridge's export surface, measured against its consumers.
//!
//! `unpack-bridge.js` is the engine's wasm binding: one export per `xu_call`
//! arm. Two kinds of consumer read it - the panel (`page.js`) needs the handful
//! of panel-facing calls, and the node baseline (`test/unpack.test.mjs`) needs
//! the transform surface, because the port's verification strategy is "the same
//! 67 cases as the JS baseline". Both are first-class, so there is no
//! product/test split to make here.
//!
//! What there can be is an export nothing reads, which is a defect in a binding
//! layer: it means the engine exposes a call no consumer wants. That is what
//! this measures, and it is measured rather than asserted because the earlier
//! audit claimed "the other 40 exist only for the test file" - a claim about
//! which exports are wanted, which only a reference count can settle.

use std::collections::BTreeSet;

fn source(name: &str) -> String {
    let path = format!("{}/{}", env!("CARGO_MANIFEST_DIR"), name);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}"))
}

/// Every `export const|function|let NAME` in the bridge.
fn bridge_exports() -> Vec<String> {
    let bridge = source("src/js/unpack-bridge.js");
    let mut names = Vec::new();
    for line in bridge.lines() {
        let Some(rest) = line.strip_prefix("export ") else {
            continue;
        };
        let Some(rest) = rest
            .strip_prefix("const ")
            .or_else(|| rest.strip_prefix("function "))
            .or_else(|| rest.strip_prefix("let "))
        else {
            continue;
        };
        let name: String = rest
            .chars()
            .take_while(|c| c.is_alphanumeric() || *c == '_' || *c == '$')
            .collect();
        if !name.is_empty() {
            names.push(name);
        }
    }
    names
}

/// Whether `name` appears as a whole word in `text`.
fn mentions(text: &str, name: &str) -> bool {
    let bytes = text.as_bytes();
    let needle = name.as_bytes();
    let mut from = 0usize;
    while let Some(at) = text[from..].find(name).map(|i| from + i) {
        let before_ok = at == 0 || !is_word(bytes[at - 1]);
        let after = at + needle.len();
        let after_ok = after >= bytes.len() || !is_word(bytes[after]);
        if before_ok && after_ok {
            return true;
        }
        from = at + 1;
    }
    false
}

fn is_word(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'$'
}

/// The JS files that may consume the bridge.
fn consumers() -> Vec<(String, String)> {
    let mut out = Vec::new();
    for dir in ["src/js", "test"] {
        let path = format!("{}/{dir}", env!("CARGO_MANIFEST_DIR"));
        let Ok(entries) = std::fs::read_dir(&path) else {
            continue;
        };
        for entry in entries.flatten() {
            let file = entry.path();
            let name = file.file_name().and_then(|n| n.to_str()).unwrap_or("");
            if !(name.ends_with(".js") || name.ends_with(".mjs")) {
                continue;
            }
            if name == "unpack-bridge.js" {
                continue;
            }
            let text = std::fs::read_to_string(&file).unwrap_or_default();
            out.push((format!("{dir}/{name}"), text));
        }
    }
    out
}

#[test]
fn every_bridge_export_is_referenced_by_a_consumer() {
    let exports = bridge_exports();
    assert!(
        exports.len() > 40,
        "the export scan found only {} names - it has stopped matching the file",
        exports.len()
    );
    let consumers = consumers();
    assert!(!consumers.is_empty(), "no consumer files were read");

    let mut unreferenced: Vec<&String> = Vec::new();
    for name in &exports {
        if !consumers.iter().any(|(_, text)| mentions(text, name)) {
            unreferenced.push(name);
        }
    }
    assert!(
        unreferenced.is_empty(),
        "bridge exports nothing reads: {unreferenced:?}"
    );
}

/// The panel is one consumer among several, so its imports must be a subset of
/// the bridge's exports rather than the whole surface. This is the half of the
/// audit's claim that is true: the panel does not import everything.
#[test]
fn the_panels_imports_are_a_strict_subset_of_the_bridge() {
    let exports: BTreeSet<String> = bridge_exports().into_iter().collect();
    let page = source("src/js/page.js");

    let start = page.find("from './unpack-bridge.js'").expect("the import block");
    let open = page[..start].rfind("import {").expect("the import opener");
    let block = &page[open + "import {".len()..start];
    let imported: BTreeSet<String> = block
        .split(',')
        // the block ends with the `}` that closes the import
        .map(|s| s.trim().trim_end_matches('}').trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    assert!(!imported.is_empty(), "the import block parsed as empty");
    let missing: Vec<&String> = imported.difference(&exports).collect();
    assert!(
        missing.is_empty(),
        "page.js imports names the bridge does not export: {missing:?}"
    );
    assert!(
        imported.len() < exports.len(),
        "page.js imports the whole bridge ({} of {}) - then there is no subset to speak of",
        imported.len(),
        exports.len()
    );
}

#[test]
fn the_two_consumers_together_cover_the_whole_surface() {
    let exports = bridge_exports();
    let page = source("src/js/page.js");
    let baseline = source("test/unpack.test.mjs");
    let uncovered: Vec<&String> = exports
        .iter()
        .filter(|name| !mentions(&page, name) && !mentions(&baseline, name))
        .collect();
    assert!(
        uncovered.is_empty(),
        "exports neither the panel nor the node baseline reads: {uncovered:?}"
    );
}
