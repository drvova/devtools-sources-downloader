// Ported one-per-case from test/unpack.test.mjs
// (67 cases). Names, inputs and expectations are 1:1; the JS-runtime-only
// halves (real eval, WebAssembly oracles, onProgress UI callback) are
// documented in PORTING.md.

mod jsfuck_encoder;

use base64::Engine;
use devtools_unpack::beautify::{beautify_js, looks_minified};
use devtools_unpack::bundler::{extract_bundle_modules, module_file_name};
use devtools_unpack::decoders::{
    bytes_to_text, decode_base64_to_bytes, decode_escapes, printable_ratio,
};
use devtools_unpack::detectors::detect_layers;
use devtools_unpack::digest::{sha256_hex, sha256_hex_bytes};
use devtools_unpack::jscbytecode::{
    analyze_jsc_module, detect_jsc_bytecode, find_jsc_shared_table, parse_jsc_header,
    read_jsc_shared_table, recover_jsc_strings, wtf_string_hash,
};
use devtools_unpack::jsfuck::{decode_jsfuck, detect_jsfuck};
use devtools_unpack::packers::{
    detect_packer, detect_string_array, transform_string_array, unpack_packer,
};
use devtools_unpack::pipeline::{
    asset_slug, looks_binary_script, unpack_asset, unpack_assets, unpack_assets_into, Asset,
    UnpackOptions,
};
use devtools_unpack::scanner::{collect_string_literals, find_balanced};
use devtools_unpack::sourcemaps::{
    decode_inline_source_map, find_source_map_ref, parse_source_map, resolve_map_url, SourceMapRef,
};
use devtools_unpack::transforms::{peel_text, Stage};
use devtools_unpack::v8codecache::{
    detect_v8_code_cache, extract_v8_strings, parse_sealed_v8, parse_v8_code_cache,
};
use devtools_unpack::wasm::{detect_wasm_module, parse_wasm_module};
use devtools_unpack::LIMITS;

fn fixture(name: &str) -> Vec<u8> {
    let path = format!("{}/test/fixtures/{name}", env!("CARGO_MANIFEST_DIR"));
    std::fs::read(path).unwrap_or_else(|e| panic!("fixture {name}: {e}"))
}

fn fixture_json(name: &str) -> serde_json::Value {
    let text = String::from_utf8(fixture(name)).unwrap();
    serde_json::from_str(&text).unwrap()
}

fn base64_of(text: &str) -> String {
    base64::engine::general_purpose::STANDARD.encode(text.as_bytes())
}

fn text_asset(url: &str, content: &str) -> Asset {
    Asset::Text {
        url: url.to_string(),
        content: content.to_string(),
        zip_path: None,
    }
}

fn bytes_asset(url: &str, bytes: Vec<u8>) -> Asset {
    Asset::Bytes {
        url: url.to_string(),
        bytes,
        zip_path: None,
    }
}

fn stage_tools(stages: &[Stage]) -> Vec<String> {
    stages
        .iter()
        .map(|s| match s {
            Stage::Binary(b) => b.tool.clone(),
            Stage::Text(t) => t.tool.clone(),
        })
        .collect()
}

fn stage_details(stages: &[Stage]) -> Vec<String> {
    stages
        .iter()
        .filter_map(|s| match s {
            Stage::Binary(b) => Some(b.detail.clone()),
            Stage::Text(_) => None,
        })
        .collect()
}

fn stats_value(stats: &devtools_unpack::jscbytecode::JscStats) -> serde_json::Value {
    serde_json::to_value(stats).unwrap()
}

// ------------------------------------------- scanner, decoders, peel loop

#[test]
fn scanner_balanced_region_ignores_braces_inside_strings_and_comments() {
    let code = r#"function x() { var s = "} not a brace {"; /* } */ return { a: 1 }; } tail"#;
    let start = code.find('{').unwrap();
    let end = find_balanced(code, start).unwrap();
    let full = r#"function x() { var s = "} not a brace {"; /* } */ return { a: 1 }; }"#;
    assert_eq!(&code[start..end], &full[13..]);
}

#[test]
fn scanner_string_literals_decoded_with_escapes() {
    let literals = collect_string_literals(r#"var a = "h\x69"; var b = '\u0041';"#, 0);
    let values: Vec<&str> = literals.iter().map(|l| l.value.as_str()).collect();
    assert_eq!(values, ["hi", "A"]);
}

#[test]
fn decoder_mixed_escapes() {
    assert_eq!(decode_escapes(r"a\tb\nc\\d\x41\u0042"), "a\tb\nc\\dAB");
}

/// `detect_layers` returns findings sorted by score, highest first, and a long
/// base64 literal outscores a single eval payload. This test was named "eval
/// packer wins over base64 when both present" and asserted
/// `eval-unwrap || base64`, which passed on base64 alone - the precedence in its
/// name was never real. It now pins the ordering rule it was reaching for.
#[test]
fn detector_orders_findings_by_score_base64_outranks_one_eval_payload() {
    let payload = "function hello(){return 42;}".repeat(40);
    let code = format!(r#"eval(atob("{}"))"#, base64_of(&payload));
    let findings = detect_layers(&code);
    assert!(
        findings.iter().any(|f| f.tool == "eval-unwrap")
            && findings.iter().any(|f| f.tool == "base64"),
        "both layers are present"
    );
    // base64: 0.5 + min(len/4000, 0.3) = 0.8 for this literal.
    // eval-unwrap: 0.7 + min(1/20, 0.3) = 0.75 for one payload.
    assert_eq!(findings[0].tool, "base64", "higher score wins the stage");
    assert!(
        findings.windows(2).all(|w| w[0].score >= w[1].score),
        "findings must be ordered by descending score"
    );
}

#[test]
fn peel_base64_payload_is_recovered_and_reported_as_a_layer() {
    let payload = "function hello(){return 42;}\nvar window_x = document.title;";
    let result = peel_text(&format!(r#"atob("{}")"#, base64_of(payload)), None);
    assert_eq!(result.stages.len(), 1);
    match &result.stages[0] {
        Stage::Text(s) => {
            assert_eq!(s.tool, "base64");
            assert!(s.input_bytes > s.output_bytes);
        }
        Stage::Binary(_) => panic!("expected text stage"),
    }
    assert!(result.final_text.contains("function hello(){return 42;}"));
}

#[test]
fn peel_gzip_layer_inflates_to_source() {
    let source = format!(
        "function gzipped(){{return \"inflated\";}}\n{}",
        "var pad = 1;\n".repeat(20)
    );
    let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    std::io::Write::write_all(&mut gz, source.as_bytes()).unwrap();
    let gz = gz.finish().unwrap();
    assert_eq!(gz[0], 0x1f);
    let result = peel_text(
        &format!(
            r#"var s = atob("{}");"#,
            base64::engine::general_purpose::STANDARD.encode(&gz)
        ),
        None,
    );
    assert!(result.final_text.contains("function gzipped()"));
    match &result.stages[0] {
        Stage::Text(s) => assert_eq!(s.tool, "base64"),
        Stage::Binary(_) => panic!("expected text stage"),
    }
}

#[test]
fn peel_hex_escape_layer_decodes() {
    let source = "function hexed(){return 7;}";
    let escaped: String = source
        .chars()
        .map(|c| format!("\\x{:02x}", c as u32))
        .collect();
    let result = peel_text(&format!(r#"var t = "{escaped}";"#), None);
    match &result.stages[0] {
        Stage::Text(s) => assert_eq!(s.tool, "hex-escape"),
        Stage::Binary(_) => panic!("expected text stage"),
    }
    assert!(result.final_text.contains("function hexed(){return 7;}"));
}

#[test]
fn peel_charcode_layer_decodes() {
    let source = "function charcoded(){return 9;}";
    let codes: Vec<String> = source.chars().map(|c| (c as u32).to_string()).collect();
    let result = peel_text(
        &format!("var t = String.fromCharCode({});", codes.join(",")),
        None,
    );
    match &result.stages[0] {
        Stage::Text(s) => assert_eq!(s.tool, "charcode"),
        Stage::Binary(_) => panic!("expected text stage"),
    }
    assert!(result
        .final_text
        .contains("function charcoded(){return 9;}"));
}

#[test]
fn peel_reversed_source_is_detected_and_flipped() {
    let source = "function reversed(){ return document.title; }";
    let result = peel_text(&source.chars().rev().collect::<String>(), None);
    match &result.stages[0] {
        Stage::Text(s) => assert_eq!(s.tool, "reverse"),
        Stage::Binary(_) => panic!("expected text stage"),
    }
    assert_eq!(result.final_text, source);
}

#[test]
fn peel_rot13_source_is_detected_and_decoded() {
    let source = "function rot(){ return window.location; }";
    let rotated: String = source
        .chars()
        .map(|c| match c {
            'a'..='z' => {
                char::from_u32(((c as u32 - b'a' as u32 + 13) % 26) + b'a' as u32).unwrap()
            }
            'A'..='Z' => {
                char::from_u32(((c as u32 - b'A' as u32 + 13) % 26) + b'A' as u32).unwrap()
            }
            other => other,
        })
        .collect();
    let result = peel_text(&rotated, None);
    match &result.stages[0] {
        Stage::Text(s) => assert_eq!(s.tool, "rot13"),
        Stage::Binary(_) => panic!("expected text stage"),
    }
    assert_eq!(result.final_text, source);
}

#[test]
fn peel_nested_eval_base64_produces_two_ordered_layers() {
    let inner = "function deep(){return \"deep\";}";
    let outer = format!(r#"eval(atob("{}"))"#, base64_of(inner));
    let result = peel_text(&outer, None);
    assert!(result.stages.len() >= 2);
    match (&result.stages[0], &result.stages[1]) {
        (Stage::Text(a), Stage::Text(b)) => {
            assert_eq!(a.tool, "eval-unwrap");
            assert_eq!(b.tool, "base64");
        }
        _ => panic!("expected text stages"),
    }
    assert!(result.final_text.contains("function deep()"));
}

#[test]
fn peel_plain_source_yields_no_layers() {
    let result = peel_text(
        &"function nothing(){ return 1; }\nmodule.exports = nothing;\n".repeat(3),
        None,
    );
    assert!(result.stages.is_empty());
}

#[test]
fn beautify_minified_detected_beautified_output_is_multiline() {
    let minified = "function a(){return 1}function b(){return 2}var c=a()+b();";
    assert!(looks_minified(minified));
    let pretty = beautify_js(minified, None);
    assert!(pretty.split('\n').count() > 3);
    assert!(pretty.contains("function a() {"));
    let already = "function a() {\n  return 1;\n}\n";
    assert!(!looks_minified(already));
}

// ------------------------------------------------------ webpack modules

#[test]
fn modules_webpack_module_map_is_split_with_sourceurl_names() {
    let bundle = concat!(
        "var __webpack_modules__ = {",
        "10: function (module, exports) { module.exports = \"ten\"; /* } */ },",
        "20: function (module, exports) { //# sourceURL=webpack://app/src/twenty.js\nmodule.exports = 20; }",
        "};",
    );
    let modules = extract_bundle_modules(bundle, None);
    assert_eq!(modules.len(), 2);
    assert_eq!(modules[0].id, "10");
    let ids: Vec<&str> = modules.iter().map(|m| m.id.as_str()).collect();
    assert_eq!(ids, ["10", "20"]);
    assert!(modules[1].code.contains("sourceURL"));
    assert_eq!(module_file_name(&modules[1]), "app/src/twenty.js");
}

#[test]
fn modules_webpackjsonp_chunk_push_array_is_split() {
    let chunk = concat!(
        "(self.webpackChunkapp = self.webpackChunkapp || []).push([[\"chunk-1\"], {",
        "31: function (m) { m.exports = 31; },",
        "32: function (m) { m.exports = 32; }",
        "}]);",
    );
    let modules = extract_bundle_modules(chunk, None);
    let ids: Vec<&str> = modules.iter().map(|m| m.id.as_str()).collect();
    assert_eq!(ids, ["31", "32"]);
}

// ---------------------------------------------------------- source maps

#[test]
fn source_maps_inline_base64_data_uri_is_decoded() {
    let map = r#"{"version":3,"sources":["webpack://app/src/index.js"],"sourcesContent":["export default 1;"]}"#;
    let inline = format!("data:application/json;base64,{}", base64_of(map));
    let json = decode_inline_source_map(&inline).unwrap();
    let parsed = parse_source_map(&json).unwrap();
    assert_eq!(parsed.files.len(), 1);
    assert_eq!(parsed.files[0].path, "app/src/index.js");
    assert_eq!(parsed.files[0].content, "export default 1;");
}

#[test]
fn source_maps_ref_detection_and_url_resolution() {
    assert_eq!(
        find_source_map_ref("var a=1;\n//# sourceMappingURL=main.js.map\n"),
        Some(SourceMapRef::External {
            value: "main.js.map".to_string()
        })
    );
    let ref_hit = find_source_map_ref("x\n//@ sourceMappingURL=data:application/json;base64,AAAA");
    assert!(matches!(ref_hit, Some(SourceMapRef::Inline { .. })));
    assert_eq!(
        resolve_map_url("https://a.test/static/js/main.js", "../maps/main.js.map"),
        "https://a.test/static/maps/main.js.map"
    );
}

// ------------------------------------------------------- asset pipeline

#[test]
fn asset_pipeline_files_layers_and_sources_are_produced() {
    let payload = "function packed(){return document.title;}";
    let map = r#"{"version":3,"sources":["webpack://src/original.ts"],"sourcesContent":["const original = true;"]}"#;
    let content = format!(
        "eval(atob(\"{}\"))\n//# sourceMappingURL=data:application/json;base64,{}",
        base64_of(payload),
        base64_of(map)
    );
    let asset = text_asset("https://a.test/static/main.js?cb=1", &content);
    let result = unpack_asset(
        &asset,
        &UnpackOptions {
            index: Some(0),
            ..Default::default()
        },
    );
    assert!(result.entry.stages.len() >= 2);
    assert_eq!(result.entry.sources, 1);
    let paths: Vec<&str> = result.files.iter().map(|f| f.path.as_str()).collect();
    assert!(paths
        .iter()
        .any(|p| p.starts_with("_unpack/0000-a.test__static__main.js/layers/01-eval-unwrap.js")));
    assert!(paths.iter().any(|p| p.contains("/source-map.json")));
    assert!(paths.iter().any(|p| p.contains("/sources/src/original.ts")));
    let slug = asset_slug("https://a.test/static/main.js?cb=1", 0);
    assert!(regex::Regex::new(r"^0000-a\.test__static__main\.js$")
        .unwrap()
        .is_match(&slug));
    // Each layer artifact carries THAT stage's output, not the final text.
    let layer1 = result
        .files
        .iter()
        .find(|f| f.path.ends_with("/layers/01-eval-unwrap.js"))
        .unwrap();
    let layer2 = result
        .files
        .iter()
        .find(|f| f.path.ends_with("/layers/02-base64.js"))
        .unwrap();
    assert!(layer1.content.starts_with("atob("));
    assert_eq!(layer2.content, payload);
    assert_ne!(layer1.content, layer2.content);
}

#[test]
fn asset_pipeline_external_map_fetched_through_the_injected_fetcher() {
    let map =
        r#"{"version":3,"sources":["src/only.js"],"sourcesContent":["let only = 1;"]}"#.to_string();
    let requested: std::cell::RefCell<Vec<String>> = std::cell::RefCell::new(Vec::new());
    let fetch = |url: &str| -> Option<String> {
        requested.borrow_mut().push(url.to_string());
        Some(map.clone())
    };
    let result = unpack_asset(
        &text_asset(
            "https://a.test/app.js",
            "var a = 1;\n//# sourceMappingURL=app.js.map",
        ),
        &UnpackOptions {
            index: Some(1),
            fetch_text: Some(&fetch),
            ..Default::default()
        },
    );
    assert_eq!(requested.borrow().len(), 1);
    assert_eq!(requested.borrow()[0], "https://a.test/app.js.map");
    assert_eq!(result.entry.sources, 1);
    assert!(result
        .files
        .iter()
        .any(|f| f.path.ends_with("/sources/src/only.js")));
}

#[test]
fn asset_pipeline_budget_refusal_is_reported_not_silently_dropped() {
    let oversized = "x".repeat(64);
    let result = unpack_asset(
        &text_asset("https://a.test/big.js", &oversized),
        &UnpackOptions {
            index: Some(2),
            ..Default::default()
        },
    );
    assert_eq!(result.entry.stages.len(), 0);
    assert_eq!(
        result.entry.notes,
        vec!["no obfuscation layer, bundle structure, or source map content found".to_string()]
    );
    let huge = unpack_asset(
        &text_asset(
            "https://a.test/huge.js",
            &"x".repeat(LIMITS.max_asset_bytes + 1),
        ),
        &UnpackOptions {
            index: Some(3),
            ..Default::default()
        },
    );
    assert_eq!(
        huge.entry.notes,
        vec!["asset exceeds unpack budget".to_string()]
    );
    assert_eq!(huge.files.len(), 0);
}

/// Determinism cannot catch a wrong-but-consistent hash, so the published
/// FIPS 180-4 vectors pin the function itself. Without these, a `sha256_hex`
/// that returned its input reversed would pass every other digest test.
#[test]
fn digest_sha256_matches_the_published_vectors() {
    assert_eq!(
        sha256_hex(""),
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    );
    assert_eq!(
        sha256_hex("abc"),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );
    assert_eq!(
        sha256_hex_bytes(b"abc").as_deref(),
        Some("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        "the byte and text forms must agree on the same input"
    );
}
#[test]
fn digest_sha256_of_identical_text_is_stable_and_input_sensitive() {
    let a = sha256_hex("payload");
    assert_eq!(a, sha256_hex("payload"));
    assert_ne!(a, sha256_hex("payload "));
    assert_eq!(a.len(), 64);
}

#[test]
fn helpers_base64_decode_and_printable_ratio() {
    let bytes = decode_base64_to_bytes("aGVsbG8=").unwrap();
    assert_eq!(bytes_to_text(&bytes), "hello");
    assert_eq!(printable_ratio("hello\nworld"), 1.0);
    assert!(printable_ratio("\u{0}\u{1}") < 0.1);
}

#[test]
fn zip_seam_writes_artifacts_and_a_report_at_the_requested_root() {
    let written: std::cell::RefCell<std::collections::BTreeMap<String, String>> =
        std::cell::RefCell::new(std::collections::BTreeMap::new());
    let payload = "function runtime(){return \"eval\";}";
    let assets = vec![text_asset(
        "eval-payload",
        &format!(r#"eval(atob("{}"))"#, base64_of(payload)),
    )];
    let opts = UnpackOptions {
        path_prefix: "_unpack-runtime".to_string(),
        ..Default::default()
    };
    let report = {
        let mut sink = written.borrow_mut();
        let mut writer = |path: &str, content: &str| {
            sink.insert(path.to_string(), content.to_string());
        };
        unpack_assets_into(&mut writer, &assets, &opts, None)
    };
    assert_eq!(report.root.as_deref(), Some("_unpack-runtime"));
    assert_eq!(report.totals.assets, 1);
    assert_eq!(report.totals.unpacked, 1);
    assert!(!report.unpacked_at.as_deref().unwrap_or("").is_empty());
    let map = written.borrow();
    assert!(map.contains_key("_unpack-runtime/index.json"));
    assert!(map.keys().any(|p| regex::Regex::new(
        r"^_unpack-runtime/0000-eval-payload\.js/layers/01-eval-unwrap\.js$"
    )
    .unwrap()
    .is_match(p)));
    let parsed: serde_json::Value =
        serde_json::from_str(map.get("_unpack-runtime/index.json").unwrap()).unwrap();
    assert_eq!(parsed["totals"]["unpacked"], 1);
    assert_eq!(parsed["assets"][0]["url"], "eval-payload");
}

// ---------------------------------------------- jsfuck (JSFuck 0.5.0 oracle)

#[test]
fn jsfuck_bare_recipe_value_matches_the_vendored_oracle() {
    let jsfucked = jsfuck_encoder::encode("Number", false, false);
    let decoded = decode_jsfuck(&jsfucked);
    assert_eq!(decoded.value.as_deref(), Some("Number"));
    assert!(
        !decoded.captured,
        "bare recipe must yield a plain value, not a capture"
    );
}

#[test]
fn jsfuck_function_wrapper_captures_the_payload_body() {
    let jsfucked = jsfuck_encoder::encode("Number", true, false);
    let decoded = decode_jsfuck(&jsfucked);
    assert!(decoded.captured);
    assert_eq!(decoded.value.as_deref(), Some("Number"));
}

#[test]
fn jsfuck_real_engine_executes_what_the_interpreter_captures() {
    // JS-runtime-only in the original (real eval); the Rust port asserts the
    // interpreter half: the parent-scope wrapper still captures the payload.
    let jsfucked = jsfuck_encoder::encode("Number", true, true);
    let decoded = decode_jsfuck(&jsfucked);
    assert_eq!(decoded.value.as_deref(), Some("Number"));
}

#[test]
fn jsfuck_detector_is_positive_on_encoded_payloads_and_negative_on_source() {
    let pos = detect_jsfuck(&jsfuck_encoder::encode("Number", false, false));
    assert!(pos.detected, "encoded payload must be detected");
    assert!(pos.purity > 0.9, "purity above 0.9, got {}", pos.purity);
    let neg = detect_jsfuck("console.log('a' + 'b');");
    assert!(!neg.detected);
}

#[test]
fn jsfuck_peeltext_routes_and_decodes_as_one_layer() {
    let res = peel_text(&jsfuck_encoder::encode("Number", false, false), None);
    assert_eq!(res.stages.len(), 1);
    match &res.stages[0] {
        Stage::Text(s) => assert_eq!(s.tool, "jsfuck"),
        Stage::Binary(_) => panic!("expected text stage"),
    }
    assert_eq!(res.final_text, "Number");
}

// ---------------------------------------------------------- Dean Edwards packer

const PACKER_CALL: &str = r#"eval(function(p,a,c,k,e,d){e=function(c){return c.toString(36)};if(!''.replace(/^/,String)){while(c--){d[c.toString(a)]=k[c]||c.toString(a)}k=[function(e){return d[e]}];e=function(){return'\w+'};c=1};while(c--){if(k[c]){p=p.replace(new RegExp('\b'+e(c)+'\b','g'),k[c])}}return p}("0.1('2 3 4');",36,5,"console|log|unpacked|from|layer".split('|'),0,{}))"#;

#[test]
fn packer_detector_matches_a_real_packer_call_and_rejects_prose() {
    let hit = detect_packer(PACKER_CALL);
    assert!(hit.is_some(), "real packer call must be detected");
    let hit = hit.unwrap();
    assert_eq!(hit.base, 36);
    assert_eq!(hit.words.len(), 5);
    assert!(detect_packer("console.log('split by pipe words here');").is_none());
}

#[test]
fn packer_unpackpacker_substitutes_base36_words_into_the_template() {
    assert_eq!(
        unpack_packer(PACKER_CALL).as_deref(),
        Some("console.log('unpacked from layer');")
    );
}

#[test]
fn packer_nested_layers_peel_in_order_through_peeltext() {
    let packed = r#"eval(function(p,a,c,k,e,d){e=function(c){return c.toString(36)};if(!''.replace(/^/,String)){while(c--){d[c.toString(a)]=k[c]||c.toString(a)}k=[function(e){return d[e]}];e=function(){return'\w+'};c=1};while(c--){if(k[c]){p=p.replace(new RegExp('\b'+e(c)+'\b','g'),k[c])}}return p}("0 1=['2','3'];4.5(1[9]);",36,6,"var|_0xabc|hello|world|console|log".split('|'),0,{}))"#;
    let res = peel_text(packed, None);
    match &res.stages[0] {
        Stage::Text(s) => assert_eq!(s.tool, "packer"),
        Stage::Binary(_) => panic!("expected text stage"),
    }
    assert_eq!(
        res.final_text,
        "var _0xabc=['hello','world'];console.log(_0xabc[9]);"
    );
}

// -------------------------------------------------------------- string arrays

const STRING_ARRAY_SRC: &str = r#"var _0xabc=['a','1','hello','world'];(function(_0x1,_0x2){while(!![]){try{var _0x4=parseInt(_0x1[0])*1+1;if(_0x4===_0x2)break;else _0x1.push(_0x1.shift())}catch(e){_0x1.push(_0x1.shift())}}}(_0xabc,0x1));var _0xdec=function(i){return _0xabc[i];};console.log(_0xdec(0x2),_0xdec(0x3));"#;

#[test]
fn string_array_detector_requires_rotation_pivot_and_inline_calls() {
    let hit = detect_string_array(STRING_ARRAY_SRC);
    assert!(hit.is_some(), "string array layout must be detected");
    let hit = hit.unwrap();
    assert_eq!(hit.array_id, "_0xabc");
    assert_eq!(hit.literals, 4);
    assert!(
        detect_string_array("var plain=['a','b'];console.log(plain[0]);").is_none(),
        "no rotation/pivot: not the pattern"
    );
}

#[test]
fn string_array_transform_rotates_the_array_and_inlines_decoder_calls() {
    assert_eq!(
        transform_string_array(STRING_ARRAY_SRC).as_deref(),
        Some("var _0xabc = ['1', 'hello', 'world', 'a'];console.log('world','a');")
    );
}

#[test]
fn string_array_peeltext_peels_it_as_one_layer() {
    let res = peel_text(STRING_ARRAY_SRC, None);
    assert_eq!(res.stages.len(), 1);
    match &res.stages[0] {
        Stage::Text(s) => assert_eq!(s.tool, "string-array"),
        Stage::Binary(_) => panic!("expected text stage"),
    }
    assert_eq!(
        res.final_text,
        "var _0xabc = ['1', 'hello', 'world', 'a'];console.log('world','a');"
    );
}

// -------------------------------------------------------------- shell refusals

#[test]
fn refusals_aaencode_shell_is_reported_never_transformed() {
    let shell = "ﾟωﾉ= /´ｍｓ)ﾉ ~┻━┻   //*\\´∇`＊/ ['_']; ".to_string() + &"ﾟΘﾟ".repeat(20);
    let res = peel_text(&shell, None);
    assert!(
        res.stages.is_empty(),
        "no static transform may run on a runtime shell"
    );
    assert_eq!(res.refusals.len(), 1);
    assert_eq!(res.refusals[0].tool, "aaencode");
    assert!(!res.refusals[0].detail.is_empty());
}

#[test]
fn refusals_jjencode_shell_is_reported() {
    let shell = r#"$=~[];$={___:++$,$___:(![]+"")[$],____:++$};$.___=($.__=$[""])[$.___+$.___];console.log($.___);"#;
    let res = peel_text(shell, None);
    assert!(
        res.refusals.iter().any(|r| r.tool == "jjencode"),
        "jjencode must be refused"
    );
}

#[test]
fn refusals_plain_source_carries_none() {
    let res = peel_text("console.log('plain');", None);
    assert!(res.refusals.is_empty());
}

#[test]
fn refusals_unpackasset_surfaces_refusal_notes_on_the_entry() {
    let shell = "ﾟωﾉ= /´ｍｓ)ﾉ ~┻━┻   //*\\´∇`＊/ ['_']; ".to_string() + &"ﾟΘﾟ".repeat(20);
    let res = unpack_asset(
        &text_asset("https://x/aa.js", &shell),
        &UnpackOptions {
            index: Some(3),
            ..Default::default()
        },
    );
    assert_eq!(res.entry.refusals.as_ref().map(|v| v.len()), Some(1));
    assert!(res
        .entry
        .notes
        .iter()
        .any(|n| n.starts_with("refused: aaencode")));
}

// ------------------------------------------------ binary cached-bytecode layers

#[test]
fn v8_header_and_framed_strings_on_a_real_node24_cache() {
    let bytes = fixture("v8-codecache.jsc");
    assert!(detect_v8_code_cache(&bytes));
    let cache = parse_v8_code_cache(&bytes);
    assert!(cache.is_some(), "cache must parse");
    let cache = cache.unwrap();
    assert_eq!(cache.format, "v12");
    assert_eq!(cache.payload_length as usize + 32, bytes.len());
    assert_eq!(cache.strings, ["hi from cache", "evalmachine.<anonymous>"]);
}

#[test]
fn v8_detector_rejects_jsc_bytecode_and_truncated_blobs() {
    assert!(!detect_v8_code_cache(&fixture("jsc-chunk.jsc")));
    assert!(!detect_v8_code_cache(&[0u8; 20]));
    assert!(
        !detect_v8_code_cache(&[0u8; 64]),
        "zero magic must not match the 0xC0DE family"
    );
}

#[test]
fn v8_framed_strings_are_bounded_and_printable() {
    let bytes = fixture("v8-codecache.jsc");
    let strings = extract_v8_strings(&bytes, 32, None);
    assert_eq!(strings, ["hi from cache", "evalmachine.<anonymous>"]);
    let partial = extract_v8_strings(&bytes, 32, Some(140));
    assert_eq!(partial, ["hi from cache"]);
}

#[test]
fn jsc_header_accepts_the_real_chunk_and_rejects_noise() {
    let bytes = fixture("jsc-chunk.jsc");
    let header = parse_jsc_header(&bytes);
    assert!(header.is_some());
    let header = header.unwrap();
    assert_eq!(header.format, 1);
    assert_eq!(header.declared_length as usize, bytes.len());
    assert_eq!(header.body_offset, 32);
    let noise = vec![0x41u8; 4096];
    assert!(
        !detect_jsc_bytecode(&noise),
        "uniform noise must fail the format-or-length guard"
    );
    assert!(!detect_jsc_bytecode(&[0u8; 20]));
}

#[test]
fn jsc_recovered_strings_match_the_unbuned_ground_truth() {
    let bytes = fixture("jsc-chunk.jsc");
    let truth = fixture_json("jsc-chunk-strings.json");
    assert_eq!(
        serde_json::to_value(recover_jsc_strings(&bytes)).unwrap(),
        truth
    );
}

#[test]
fn jsc_wtfstringhash_reproduces_every_ledger_ground_truth() {
    let truths: [(&str, u32); 4] = [
        ("moduleLoader", 0x27d79d),
        ("homeObject", 0xc376d0),
        ("starNamespace", 0x72858b),
        ("iterator", 0x336a9c),
    ];
    for (text, hash) in truths {
        assert_eq!(wtf_string_hash(text.as_bytes()), hash, "{text}");
    }
}

#[test]
fn sealed_brotli_sealed_v8_cache_peels_through_two_stages() {
    let bytes = fixture("v8-codecache-sealed.jsc");
    assert!(
        !detect_v8_code_cache(&bytes),
        "sealed blob must not read as a plain cache"
    );
    let inflator = |b: &[u8]| -> std::io::Result<Vec<u8>> {
        let mut out = Vec::new();
        std::io::Read::read_to_end(&mut brotli::Decompressor::new(b, 4096), &mut out)?;
        Ok(out)
    };
    let sealed = parse_sealed_v8(&bytes, Some(&inflator));
    assert!(
        sealed.is_some(),
        "sealed route must parse with an injected inflator"
    );
    let sealed = sealed.unwrap();
    assert_eq!(
        sealed.cache.strings,
        ["hi from cache", "evalmachine.<anonymous>"]
    );
}

#[test]
fn sealed_a_throwing_inflator_degrades_to_a_refusal_not_a_crash() {
    let bytes = fixture("v8-codecache-sealed.jsc");
    let failing = |_b: &[u8]| -> std::io::Result<Vec<u8>> {
        Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "not brotli",
        ))
    };
    assert!(parse_sealed_v8(&bytes, Some(&failing)).is_none());
}

#[test]
fn routing_looksbinaryscript_matches_caches_by_magic_and_extension_only() {
    assert!(looks_binary_script("https://x/app.jsc", None));
    assert!(looks_binary_script("https://x/chunk.bc?v=2", None));
    assert!(looks_binary_script(
        "https://x/blob",
        Some(&fixture("v8-codecache.jsc"))
    ));
    assert!(looks_binary_script(
        "https://x/blob",
        Some(&fixture("jsc-chunk.jsc"))
    ));
    assert!(!looks_binary_script(
        "https://x/app.js",
        Some(b"console.log(1)")
    ));
    assert!(!looks_binary_script("https://x/b", Some(&[0u8; 8])));
}

#[test]
fn binary_pass_unrecognized_blobs_report_a_refusal_note() {
    let noise = vec![0x41u8; 4096];
    let res = unpack_asset(
        &bytes_asset("https://x/unknown.bin", noise),
        &UnpackOptions {
            index: Some(0),
            ..Default::default()
        },
    );
    assert_eq!(res.entry.kind, "binary");
    assert_eq!(res.entry.stages.len(), 0);
    assert!(
        res.entry
            .notes
            .iter()
            .any(|n| n
                .contains("no V8 code-cache, JSC bytecode, wasm module, or brotli-sealed shape"))
    );
}

#[test]
fn binary_pass_zip_artifacts_are_scoped_to_their_own_asset_root() {
    let written: std::cell::RefCell<std::collections::BTreeMap<String, String>> =
        std::cell::RefCell::new(std::collections::BTreeMap::new());
    let assets = vec![
        bytes_asset("https://x/v8.jsc", fixture("v8-codecache.jsc")),
        bytes_asset("https://x/jsc.jsc", fixture("jsc-chunk.jsc")),
    ];
    let report = {
        let mut sink = written.borrow_mut();
        let mut writer = |path: &str, content: &str| {
            sink.insert(path.to_string(), content.to_string());
        };
        unpack_assets_into(&mut writer, &assets, &UnpackOptions::default(), None)
    };
    let mut roots = std::collections::BTreeSet::new();
    for p in written.borrow().keys() {
        if p.ends_with("/index.json") {
            continue;
        }
        // `root` is a segment of `p`, so asserting p.contains(root) was true by
        // construction. The real claim is that there are exactly two roots.
        let root = p.split('/').nth(1).unwrap().to_string();
        roots.insert(root.clone());
    }
    assert_eq!(roots.len(), 2);
    let v8_root = roots.iter().find(|r| r.contains("v8.jsc")).unwrap();
    let jsc_root = roots.iter().find(|r| r.contains("jsc.jsc")).unwrap();
    let map = written.borrow();
    let v8_strings: serde_json::Value =
        serde_json::from_str(map.get(&format!("_unpack/{v8_root}/strings.json")).unwrap()).unwrap();
    assert_eq!(
        v8_strings,
        serde_json::json!(["hi from cache", "evalmachine.<anonymous>"])
    );
    let jsc_strings: serde_json::Value = serde_json::from_str(
        map.get(&format!("_unpack/{jsc_root}/strings.json"))
            .unwrap(),
    )
    .unwrap();
    assert_eq!(
        jsc_strings,
        serde_json::json!(["moduleLoader", "starNamespace"])
    );
    assert_eq!(report.totals.unpacked, 2);
}

#[test]
fn binary_digest_sha256hexbytes_is_stable_and_input_sensitive() {
    let a = [1u8, 2, 3, 255];
    let b = [1u8, 2, 3, 254];
    assert!(sha256_hex_bytes(&a).is_some());
    assert_eq!(sha256_hex_bytes(&a), sha256_hex_bytes(&[1u8, 2, 3, 255]));
    assert_ne!(sha256_hex_bytes(&a), sha256_hex_bytes(&b));
    assert!(sha256_hex_bytes(&[]).is_none());
}

// ------------------------------------------- cached-function tree + wasm layer

#[test]
fn jsc_cached_function_tree_matches_the_unbuned_oracle() {
    let bytes = fixture("jsc-chunk.jsc");
    let stats = analyze_jsc_module(&bytes, None);
    assert!(stats.valid);
    assert_eq!(stats.nodes, 7);
    assert_eq!(stats.blocks, 7);
    assert_eq!(stats.ops, 103);
    assert_eq!(stats.bind_failed, 0);
    assert_eq!(stats.root_name.as_deref(), Some("<ordinal 204781>"));
    assert_eq!(stats.root_parse_mode, Some(0));
    assert_eq!(stats.functions.len(), 7);
    let truth = fixture_json("jsc-chunk-functions.json");
    assert_eq!(
        stats_value(&stats),
        truth,
        "full tree must stay stable against the oracle-captured ground truth"
    );
}

#[test]
fn jsc_structural_walk_fails_closed_on_non_bytecode_bytes() {
    let noise = vec![0x41u8; 4096];
    let stats = analyze_jsc_module(&noise, None);
    assert_eq!(stats.blocks, 0);
    assert!(!stats.valid);
    assert_eq!(
        stats.functions.len(),
        1,
        "root record alone, no blocks bound"
    );
}

#[test]
fn wasm_exports_match_the_platform_oracle_on_the_crafted_fixture() {
    let bytes = fixture("wasm-data.wasm");
    assert!(detect_wasm_module(&bytes));
    let info = parse_wasm_module(&bytes).unwrap();
    // Oracle captured from WebAssembly.Module.exports on node: the export
    // surface (name, kind) sorted by name.
    let oracle = serde_json::json!([
        {"name": "compute", "kind": "func"},
        {"name": "mem", "kind": "memory"}
    ]);
    let mut mine: Vec<serde_json::Value> = info
        .exports
        .iter()
        .map(|e| serde_json::json!({"name": e.name, "kind": e.kind}))
        .collect();
    mine.sort_by(|a, b| a["name"].as_str().cmp(&b["name"].as_str()));
    assert_eq!(serde_json::Value::Array(mine), oracle);
    assert_eq!(
        info.exports
            .iter()
            .find(|e| e.name == "compute")
            .unwrap()
            .index,
        0
    );
    assert_eq!(info.module_name.as_deref(), Some("handcrafted_module"));
    let names: Vec<&str> = info.function_names.values().map(|s| s.as_str()).collect();
    assert_eq!(names, ["compute"]);
    assert_eq!(
        info.data_strings,
        ["hello from wasm data", "second string here"]
    );
    assert_eq!(info.notes.len(), 0);
}

#[test]
fn wasm_name_section_recovered_from_the_real_corpus_fixture() {
    let bytes = fixture("wasm-named.wasm");
    assert!(detect_wasm_module(&bytes));
    let info = parse_wasm_module(&bytes).unwrap();
    let names: Vec<&str> = info.function_names.values().map(|s| s.as_str()).collect();
    let mut names = names;
    names.sort();
    assert_eq!(names, ["eval0", "eval1", "hash", "mix"]);
    assert_eq!(
        info.exports.len(),
        5,
        "oracle-captured export count from WebAssembly"
    );
    assert_eq!(
        info.notes.len(),
        0,
        "the section walk must consume the module exactly"
    );
}

#[test]
fn wasm_detector_rejects_noise_and_truncated_bytes() {
    assert!(!detect_wasm_module(&[0x41u8; 4096]));
    assert!(!detect_wasm_module(&[0u8; 4]));
    assert!(!detect_wasm_module(&[]));
}

#[test]
fn routing_wasm_extension_and_wasm_magic_reach_the_binary_pass() {
    assert!(looks_binary_script("https://x/mod.wasm", None));
    assert!(looks_binary_script(
        "https://x/blob?v=1",
        Some(&fixture("wasm-named.wasm"))
    ));
    assert!(!looks_binary_script(
        "https://x/app.js",
        Some(b"console.log(1)")
    ));
}

#[test]
fn binary_pass_wasm_asset_lands_the_wasm_module_stage_and_artifact() {
    let res = unpack_asset(
        &bytes_asset("https://x/mod.wasm", fixture("wasm-data.wasm")),
        &UnpackOptions {
            index: Some(0),
            ..Default::default()
        },
    );
    assert_eq!(res.entry.kind, "binary");
    assert!(stage_tools(&res.entry.stages)
        .iter()
        .any(|d| d == "wasm-module"));
    let artifact = res
        .files
        .iter()
        .find(|f| f.path.ends_with("/wasm-info.json"))
        .unwrap();
    let info: serde_json::Value = serde_json::from_str(&artifact.content).unwrap();
    assert_eq!(info["moduleName"], "handcrafted_module");
    assert_eq!(
        info["dataStrings"],
        serde_json::json!(["hello from wasm data", "second string here"])
    );
}

#[test]
fn binary_pass_jsc_asset_lands_functions_json_with_the_oracle_tree() {
    let res = unpack_asset(
        &bytes_asset("https://x/chunk.jsc", fixture("jsc-chunk.jsc")),
        &UnpackOptions {
            index: Some(0),
            ..Default::default()
        },
    );
    let tools = stage_tools(&res.entry.stages);
    assert!(tools.iter().any(|d| d.contains("jsc-bytecode")));
    let stage_detail_lines = stage_details(&res.entry.stages);
    // Delimited, not bare: `"17 functions".contains("7 functions")` is true, so
    // the undelimited form could pass on the wrong count.
    assert!(
        stage_detail_lines[0].contains(", 7 functions,"),
        "stage detail must name the function count, got: {}",
        stage_detail_lines[0]
    );
    assert_eq!(res.entry.functions, Some(7));
    let artifact = res
        .files
        .iter()
        .find(|f| f.path.ends_with("/functions.json"))
        .unwrap();
    let tree: serde_json::Value = serde_json::from_str(&artifact.content).unwrap();
    assert_eq!(tree["valid"], true);
    assert_eq!(tree["functions"].as_array().unwrap().len(), 7);
}

// ------------------------------------------------- shared EncoderStringTable

// Minimal shared EncoderStringTable from real claude.exe records: count,
// offset per ordinal, records laid out in ordinal order (the writer's own
// layout); unneeded ordinals point at a zero-length marker both readers skip.
//
// This is a round trip, so on its own it cannot catch a layout misreading shared
// by the writer and the reader. The layout is validated against real bytes
// elsewhere: `jsc_cached_function_tree_matches_the_unbuned_oracle` walks the
// captured `jsc-chunk.jsc`, which reaches `read_jsc_shared_table` through the
// real walker, and compares the whole tree against a captured oracle. What this
// test adds is the record VALUES and the hole handling, which the real chunk
// exercises only where its own records happen to land.
fn build_shared_table(corrupt_ordinal: Option<u32>) -> Vec<u8> {
    let records_json = fixture_json("jsc-shared-records.json");
    let count = records_json["count"].as_u64().unwrap() as u32;
    let ordinals: Vec<u32> = records_json["records"]
        .as_object()
        .unwrap()
        .keys()
        .filter_map(|k| k.parse::<u32>().ok())
        .collect();
    let mut sorted = ordinals.clone();
    sorted.sort_unstable();
    let offsets_len = 4 + count as usize * 4;
    let mut total = offsets_len + 8;
    let rec_bytes: Vec<Vec<u8>> = sorted
        .iter()
        .map(|o| {
            let hex = records_json["records"][o.to_string()]["hex"]
                .as_str()
                .unwrap();
            hex_to_bytes(hex)
        })
        .collect();
    for b in &rec_bytes {
        total += b.len().div_ceil(4) * 4;
    }
    let mut out = vec![0u8; total];
    out[0..4].copy_from_slice(&count.to_le_bytes());
    let mut cursor = offsets_len + 8;
    let mut pos: std::collections::HashMap<u32, usize> = std::collections::HashMap::new();
    for (i, ordinal) in sorted.iter().enumerate() {
        let mut b = rec_bytes[i].clone();
        if Some(*ordinal) == corrupt_ordinal {
            let last = b.len() - 1;
            b[last] ^= 0xff; // break the stored hash
        }
        out[cursor..cursor + b.len()].copy_from_slice(&b);
        pos.insert(*ordinal, cursor);
        cursor += b.len().div_ceil(4) * 4;
    }
    for o in 0..count {
        let at = 4 + o as usize * 4;
        let value = pos.get(&o).copied().unwrap_or(offsets_len) as u32;
        out[at..at + 4].copy_from_slice(&value.to_le_bytes());
    }
    out
}

fn hex_to_bytes(hex: &str) -> Vec<u8> {
    (0..hex.len() / 2)
        .map(|i| u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).unwrap())
        .collect()
}

#[test]
fn jsc_shared_reader_resolves_real_records_and_leaves_holes() {
    let table = build_shared_table(None);
    let read = read_jsc_shared_table(&table, 0, table.len());
    assert_eq!(read.count, 204782);
    assert_eq!(read.resolved, 9);
    assert_eq!(
        read.strings[0].as_deref(),
        Some("B:/~BUN/root/chunk-6xptctz4.js")
    );
    assert_eq!(read.strings[10609].as_deref(), Some("W"));
    assert_eq!(read.strings[10759].as_deref(), Some("o"));
    assert_eq!(read.strings[22490].as_deref(), Some("S_t"));
    assert_eq!(read.strings[129467].as_deref(), Some("njo"));
    assert_eq!(read.strings[184967].as_deref(), Some("SGs"));
    assert_eq!(
        read.strings[204781].as_deref(),
        Some("file:///B:/%7EBUN/root/chunk-nqhgex2p.js")
    );
    assert!(
        read.strings[100].is_none(),
        "gap ordinals stay holes, never shifted names"
    );
    assert_eq!(
        read_jsc_shared_table(&table, 0, 12).resolved,
        0,
        "a window too small for the offsets array refuses"
    );
}

#[test]
fn jsc_scanner_finds_an_embedded_shared_table_and_rejects_noise() {
    let table = build_shared_table(None);
    let mut padded = vec![0x41u8; 512 + table.len()];
    padded[512..].copy_from_slice(&table);
    let found = find_jsc_shared_table(&padded);
    assert!(
        found.is_some(),
        "scanner must find the table inside an arbitrary blob"
    );
    let found = found.unwrap();
    assert_eq!(found.offset, 512);
    assert_eq!(found.resolved, 9);
    assert_eq!(
        found.strings[204781].as_deref(),
        Some("file:///B:/%7EBUN/root/chunk-nqhgex2p.js")
    );
    assert!(find_jsc_shared_table(&[0x41u8; 4096]).is_none());
    assert!(
        find_jsc_shared_table(&table[..100]).is_none(),
        "a truncated head cannot hold the offsets array"
    );
    assert!(find_jsc_shared_table(&[]).is_none());
}

#[test]
fn jsc_ordinal_name_slots_resolve_against_the_shared_table_oracle_parity() {
    let chunk = fixture("jsc-chunk.jsc");
    let table = build_shared_table(None);
    let read = read_jsc_shared_table(&table, 0, table.len());
    let resolved = analyze_jsc_module(&chunk, Some(&read.strings));
    assert_eq!(
        resolved.root_name.as_deref(),
        Some("file:///B:/%7EBUN/root/chunk-nqhgex2p.js")
    );
    assert_eq!(resolved.bind_failed, 0);
    let truth = fixture_json("jsc-chunk-functions-resolved.json");
    assert_eq!(
        stats_value(&resolved),
        truth,
        "resolved tree must stay stable against the oracle-captured names"
    );
    // the unresolved walk stays byte-identical when no table is passed
    let plain = analyze_jsc_module(&chunk, None);
    assert_eq!(plain.root_name.as_deref(), Some("<ordinal 204781>"));
    let truth_functions = truth["functions"].as_array().unwrap();
    for (i, tf) in truth_functions.iter().enumerate() {
        let p = plain.functions[i].name.as_deref();
        let t = tf["name"].as_str();
        match t {
            None => assert_eq!(p, None),
            Some(_) => assert!(
                p.map(|n| n.starts_with("<ordinal ")).unwrap_or(false),
                "resolved slots degrade to placeholders, got: {p:?}"
            ),
        }
    }
}

#[test]
fn jsc_a_corrupt_record_leaves_a_hole_never_a_shifted_name() {
    let table = build_shared_table(Some(129467));
    let read = read_jsc_shared_table(&table, 0, table.len());
    assert_eq!(read.resolved, 8);
    assert!(
        read.strings[129467].is_none(),
        "the broken ordinal is an unresolvable placeholder"
    );
    assert_eq!(
        read.strings[10609].as_deref(),
        Some("W"),
        "earlier ordinals keep their own strings"
    );
    assert_eq!(
        read.strings[184967].as_deref(),
        Some("SGs"),
        "later ordinals keep their own strings (no dense-list shift)"
    );
    assert_eq!(
        read.strings[204781].as_deref(),
        Some("file:///B:/%7EBUN/root/chunk-nqhgex2p.js")
    );
    let chunk = fixture("jsc-chunk.jsc");
    let resolved = analyze_jsc_module(&chunk, Some(&read.strings));
    assert_eq!(
        resolved
            .functions
            .iter()
            .find(|f| f.record == 0x230)
            .unwrap()
            .name
            .as_deref(),
        Some("<ordinal 129467>")
    );
}

#[test]
fn binary_pass_batch_discovers_the_shared_table_and_resolves_functions_json() {
    let chunk_bytes = fixture("jsc-chunk.jsc");
    let container_bytes = build_shared_table(None);
    let result = unpack_assets(
        &[
            bytes_asset("https://x/assets/chunk-nqhgex2p.jsc", chunk_bytes),
            bytes_asset("https://x/assets/section.bin", container_bytes),
        ],
        &UnpackOptions {
            path_prefix: "_unpack".to_string(),
            ..Default::default()
        },
    );
    let chunk_entry = &result.report.assets[0];
    let tools = stage_tools(&chunk_entry.stages);
    assert!(tools.iter().any(|d| d.contains("jsc-bytecode")));
    let details = stage_details(&chunk_entry.stages);
    assert!(
        details.iter().any(|d| d.contains("names via shared table")),
        "stage detail must name the shared-table resolution, got: {}",
        details.join(" | ")
    );
    let artifact = result
        .files
        .iter()
        .find(|f| f.path.ends_with("chunk-nqhgex2p.jsc.js/functions.json"))
        .unwrap_or_else(|| {
            panic!(
                "functions.json missing: {}",
                result
                    .files
                    .iter()
                    .map(|f| f.path.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        });
    let tree: serde_json::Value = serde_json::from_str(&artifact.content).unwrap();
    assert_eq!(tree["rootName"], "file:///B:/%7EBUN/root/chunk-nqhgex2p.js");
    assert_eq!(
        tree["sharedTable"]["source"],
        "https://x/assets/section.bin"
    );
    assert_eq!(tree["sharedTable"]["resolvedNames"], 6);
    let names = tree["functions"].as_array().unwrap();
    assert!(names.iter().any(|f| f["name"] == "o"));
    assert!(names.iter().any(|f| f["name"] == "SGs"));
}

// Program payloads (formatWord 0): bun --bytecode's cjs default. The
// tree roots at the CacheEntry's m_codeBlock record, and the shared
// table ships in the same .rdata window the scanner walks.

#[test]
fn jsc_program_tag_0_chunk_binds_the_real_function_tree() {
    let chunk = fixture("jsc-cjs-chunk.bin");
    let section = fixture("jsc-cjs-sec.bin");
    let table = find_jsc_shared_table(&section);
    assert!(
        table.is_some(),
        "scanner must find the 53-string table inside the cjs section"
    );
    let table = table.unwrap();
    let resolved = analyze_jsc_module(&chunk, Some(&table.strings));
    let truth = fixture_json("jsc-cjs-functions-resolved.json");
    assert_eq!(
        stats_value(&resolved),
        truth,
        "resolved tree must stay stable against the pinned walk"
    );
    assert!(resolved.valid);
    assert_eq!(resolved.blocks, 17);
    assert_eq!(resolved.bind_failed, 0);
    let names: Vec<Option<&str>> = resolved
        .functions
        .iter()
        .map(|f| f.name.as_deref())
        .collect();
    for real in [
        "calculateInvoiceTotal",
        "validateCustomerRecord",
        "internalAuditLogger",
        "resolvePreferredGateway",
        "InvoiceWorkflow",
        "computeTotal",
        "__export",
    ] {
        assert!(
            names.iter().any(|n| n == &Some(real)),
            "missing real function name: {real}"
        );
    }
    // every named slot resolved through the shared table, no placeholders
    assert!(
        names
            .iter()
            .all(|n| n.map(|n| !n.starts_with("<ordinal ")).unwrap_or(true)),
        "names must resolve, got: {:?}",
        names
            .iter()
            .filter(|n| n.map(|n| n.starts_with("<ordinal ")).unwrap_or(false))
            .collect::<Vec<_>>()
    );
}

#[test]
fn jsc_program_chunk_without_a_table_degrades_to_ordinals_but_still_binds() {
    let chunk = fixture("jsc-cjs-chunk.bin");
    let plain = analyze_jsc_module(&chunk, None);
    assert!(plain.valid);
    assert_eq!(plain.blocks, 17);
    assert_eq!(
        plain.root_name, None,
        "the entry name slot is the empty sentinel in this payload"
    );
    let placeholder = plain
        .functions
        .iter()
        .filter(|f| {
            f.name
                .as_deref()
                .map(|n| n.starts_with("<ordinal "))
                .unwrap_or(false)
        })
        .count();
    assert!(
        placeholder >= 6,
        "expected ordinal placeholders without a table, got {placeholder}"
    );
}

#[test]
fn jsc_program_shaped_noise_must_not_bind() {
    let mut noise = vec![0u8; 4528];
    let put32 = |noise: &mut Vec<u8>, v: u32, at: usize| {
        for i in 0..4 {
            noise[at + i] = ((v >> (8 * i)) & 0xff) as u8;
        }
    };
    put32(&mut noise, 0x64ed8b42, 0); // stamp
    put32(&mut noise, 0, 4); // tag 0 (Program)
    put32(&mut noise, 4, 8); // reserved callee locals
    put32(&mut noise, 4528, 12); // payload size == blob length
    put32(&mut noise, 0x100, 0x2c); // in-bounds code block slot
    let stats = analyze_jsc_module(&noise, None);
    assert!(!stats.valid);
    assert_eq!(stats.blocks, 0);
}

#[test]
fn binary_pass_cjs_asset_lands_functions_json_with_real_names() {
    let chunk_bytes = fixture("jsc-cjs-chunk.bin");
    let section_bytes = fixture("jsc-cjs-sec.bin");
    let result = unpack_assets(
        &[
            bytes_asset("https://x/assets/pair-cjs.jsc", chunk_bytes),
            bytes_asset("https://x/assets/pair-cjs.sec", section_bytes),
        ],
        &UnpackOptions {
            path_prefix: "_unpack".to_string(),
            ..Default::default()
        },
    );
    let chunk_entry = &result.report.assets[0];
    let tools = stage_tools(&chunk_entry.stages);
    assert!(tools.iter().any(|d| d.contains("jsc-bytecode")));
    let details = stage_details(&chunk_entry.stages);
    assert!(
        details[0].contains(", 17 functions,"),
        "stage detail must name the count, got: {}",
        details[0]
    );
    assert!(
        details.iter().any(|d| d.contains("names via shared table")),
        "detail must name the shared-table resolution"
    );
    let artifact = result
        .files
        .iter()
        .find(|f| f.path.ends_with("pair-cjs.jsc.js/functions.json"))
        .unwrap_or_else(|| {
            panic!(
                "functions.json missing: {}",
                result
                    .files
                    .iter()
                    .map(|f| f.path.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        });
    let tree: serde_json::Value = serde_json::from_str(&artifact.content).unwrap();
    assert_eq!(tree["rootName"], serde_json::Value::Null);
    assert_eq!(tree["valid"], true);
    let names: Vec<&serde_json::Value> = tree["functions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|f| &f["name"])
        .collect();
    assert!(
        names.iter().any(|n| *n == "InvoiceWorkflow") && names.iter().any(|n| *n == "computeTotal"),
        "real names must land in the artifact"
    );
}
