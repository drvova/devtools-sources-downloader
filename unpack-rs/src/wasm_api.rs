// Browser engine seam: compiles only for wasm32 and exposes the Rust engine
// to unpack-bridge.js through a small C ABI.
//
// One generic dispatcher (xu_call) carries every pure function the JS test
// suite and page.js consume; dedicated exports exist where the payload is
// binary or large (xu_b64decode, xu_looks_binary_script). Return shapes are
// the JavaScript shapes the tests assert - files are {path, content} objects,
// source-map refs are {kind, value}, reports are the camelCase serde shapes
// the port already mirrors - so this module is the adaptation layer between
// internal Rust types and the JS contract. Remote source maps are fetched
// through the xu_host_fetch import (a synchronous XHR on the JS side),
// keeping the engine's sync fetch_text seam intact.
#[cfg(target_arch = "wasm32")]
use crate::pipeline::{self, Asset, UnpackOptions};
#[cfg(target_arch = "wasm32")]
use crate::{beautify, bundler, decoders, digest, detectors, jscbytecode, jsfuck, packers, panel, scanner, sourcemaps, transforms, v8codecache, wasm as wasm_mod};

#[cfg(target_arch = "wasm32")]
#[link(wasm_import_module = "env")]
extern "C" {
    // Provided by unpack-bridge.js: synchronous fetch, returns an allocated
    // UTF-8 pointer (null = fetch failed). Owned by the engine.
    fn xu_host_fetch(url_ptr: *const u8, url_len: usize, out_len: *mut usize) -> *const u8;
}

#[cfg(target_arch = "wasm32")]
/// Allocate `len` bytes for the host to write into; returns the pointer.
#[no_mangle]
pub extern "C" fn xu_alloc(len: usize) -> *mut u8 {
    let mut buf = Vec::<u8>::with_capacity(len);
    let ptr = buf.as_mut_ptr();
    std::mem::forget(buf);
    ptr
}

#[cfg(target_arch = "wasm32")]
/// Release a block handed out by xu_alloc or by any engine export.
#[no_mangle]
pub extern "C" fn xu_free(ptr: *mut u8, len: usize) {
    if ptr.is_null() {
        return;
    }
    drop(unsafe { Vec::from_raw_parts(ptr, len, len) });
}

#[cfg(target_arch = "wasm32")]
fn write_out(bytes: Vec<u8>, out_len: *mut usize) -> *const u8 {
    let len = bytes.len();
    let buf = bytes.into_boxed_slice();
    let ptr = buf.as_ptr();
    std::mem::forget(buf);
    if !out_len.is_null() {
        unsafe {
            *out_len = len;
        }
    }
    ptr
}

#[cfg(target_arch = "wasm32")]
fn read_json(ptr: *const u8, len: usize) -> serde_json::Value {
    let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
    serde_json::from_slice(bytes).unwrap_or(serde_json::Value::Null)
}

#[cfg(target_arch = "wasm32")]
thread_local! {
    // Static maps supplied by the caller for this dispatch: a JS fetch
    // closure cannot cross the wasm boundary, so callers that need to
    // control fetched text pass { fetchMap: { url: text } } instead and the
    // seam consults it before falling back to the host import.
    static FETCH_MAP: std::cell::RefCell<std::collections::HashMap<String, String>> =
        std::cell::RefCell::new(std::collections::HashMap::new());
}

#[cfg(target_arch = "wasm32")]
fn wasm_fetch_text(url: &str) -> Option<String> {
    if let Some(text) = FETCH_MAP.with(|m| m.borrow().get(url).cloned()) {
        return Some(text);
    }
    let mut out_len: usize = 0;
    let ptr = unsafe { xu_host_fetch(url.as_ptr(), url.len(), &mut out_len) };
    if ptr.is_null() {
        return None;
    }
    if out_len == 0 {
        return Some(String::new());
    }
    let bytes = unsafe { std::slice::from_raw_parts(ptr, out_len) };
    let text = String::from_utf8_lossy(bytes).into_owned();
    xu_free(ptr as *mut u8, out_len);
    Some(text)
}

#[cfg(target_arch = "wasm32")]
#[no_mangle]
pub extern "C" fn xu_b64decode(in_ptr: *const u8, in_len: usize, out_len: *mut usize) -> *const u8 {
    let bytes = unsafe { std::slice::from_raw_parts(in_ptr, in_len) };
    let text = String::from_utf8_lossy(bytes);
    match decoders::decode_base64_to_bytes(&text) {
        Some(decoded) => write_out(decoded, out_len),
        None => std::ptr::null(),
    }
}

#[cfg(target_arch = "wasm32")]
#[no_mangle]
pub extern "C" fn xu_looks_binary_script(
    url_ptr: *const u8,
    url_len: usize,
    bytes_ptr: *const u8,
    bytes_len: usize,
) -> u8 {
    let url_bytes = unsafe { std::slice::from_raw_parts(url_ptr, url_len) };
    let url = String::from_utf8_lossy(url_bytes);
    let bytes = if bytes_ptr.is_null() {
        None
    } else {
        Some(unsafe { std::slice::from_raw_parts(bytes_ptr, bytes_len) })
    };
    u8::from(pipeline::looks_binary_script(&url, bytes))
}

/// `{"report": ..., "files": [{"path": ..., "content": ...}]}` for the host;
/// mirrors JS unpackAssets.
#[cfg(target_arch = "wasm32")]
#[no_mangle]
pub extern "C" fn xu_run(
    assets_ptr: *const u8,
    assets_len: usize,
    opts_ptr: *const u8,
    opts_len: usize,
    out_len: *mut usize,
) -> *const u8 {
    let assets_json = read_json(assets_ptr, assets_len);
    let opts_json = read_json(opts_ptr, opts_len);
    let result = std::panic::catch_unwind(|| {
        let assets: Vec<HostAsset> =
            serde_json::from_value(assets_json).map_err(|e| format!("assets json: {e}"))?;
        let opts: HostOptions =
            serde_json::from_value(opts_json).map_err(|e| format!("options json: {e}"))?;
        let native_assets: Vec<Asset> = assets.into_iter().map(|a| a.into_native()).collect();
        let batch = pipeline::unpack_assets(&native_assets, &opts.into_native());
        Ok::<serde_json::Value, String>(serde_json::json!({
            "report": batch.report,
            "files": batch
                .files
                .into_iter()
                .map(|f| serde_json::json!({ "path": f.path, "content": f.content }))
                .collect::<Vec<_>>(),
        }))
    });
    let payload = match result {
        Ok(Ok(value)) => serde_json::to_vec(&value).unwrap_or_default(),
        Ok(Err(msg)) => serde_json::json!({ "__error": msg }).to_string().into_bytes(),
        Err(_) => "{\"__error\":\"engine panic in unpack_assets\"}".to_string().into_bytes(),
    };
    write_out(payload, out_len)
}

/// Generic dispatcher: `xu_call(name, argsJson)` runs one engine function and
/// returns its JavaScript-shaped result. Unknown names reply {"__error": ...}.
#[cfg(target_arch = "wasm32")]
#[no_mangle]
pub extern "C" fn xu_call(
    name_ptr: *const u8,
    name_len: usize,
    args_ptr: *const u8,
    args_len: usize,
    out_len: *mut usize,
) -> *const u8 {
    let name_bytes = unsafe { std::slice::from_raw_parts(name_ptr, name_len) };
    let name = String::from_utf8_lossy(name_bytes).into_owned();
    let args = read_json(args_ptr, args_len);
    let array = match args {
        serde_json::Value::Array(a) => a,
        _ => Vec::new(),
    };
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| dispatch(&name, &array)));
    let value = match result {
        Ok(Ok(v)) => v,
        Ok(Err(msg)) => serde_json::json!({ "__error": msg }),
        Err(_) => serde_json::json!({ "__error": "engine panic" }),
    };
    write_out(serde_json::to_vec(&value).unwrap_or_default(), out_len)
}

#[cfg(target_arch = "wasm32")]
fn arg_str(array: &[serde_json::Value], i: usize) -> Option<String> {
    array.get(i).and_then(|v| v.as_str()).map(String::from)
}

#[cfg(target_arch = "wasm32")]
fn arg_bytes(array: &[serde_json::Value], i: usize) -> Option<Vec<u8>> {
    array.get(i).and_then(|v| v.as_array()).map(|arr| {
        arr.iter()
            .map(|n| n.as_u64().unwrap_or(0) as u8)
            .collect::<Vec<u8>>()
    })
}

#[cfg(target_arch = "wasm32")]
fn arg_usize(array: &[serde_json::Value], i: usize) -> Option<usize> {
    array.get(i).and_then(|v| v.as_u64()).map(|n| n as usize)
}

#[cfg(target_arch = "wasm32")]
fn opt_usize(array: &[serde_json::Value], i: usize) -> Option<usize> {
    array
        .get(i)
        .and_then(|v| if v.is_null() { None } else { v.as_u64() })
        .map(|n| n as usize)
}

#[cfg(target_arch = "wasm32")]
fn arg_options(array: &[serde_json::Value], i: usize) -> Result<HostOptions, String> {
    serde_json::from_value(array.get(i).cloned().unwrap_or(serde_json::Value::Null))
        .map_err(|e| format!("options json: {e}"))
}

#[cfg(target_arch = "wasm32")]
fn files_json(files: Vec<pipeline::File>) -> serde_json::Value {
    serde_json::Value::Array(
        files
            .into_iter()
            .map(|f| serde_json::json!({ "path": f.path, "content": f.content }))
            .collect(),
    )
}

#[cfg(target_arch = "wasm32")]
fn source_map_ref_json(r: sourcemaps::SourceMapRef) -> serde_json::Value {
    match r {
        sourcemaps::SourceMapRef::Inline { value } => {
            serde_json::json!({ "kind": "inline", "value": value })
        }
        sourcemaps::SourceMapRef::External { value } => {
            serde_json::json!({ "kind": "external", "value": value })
        }
    }
}

#[cfg(target_arch = "wasm32")]
type DispatchResult = Result<serde_json::Value, String>;

#[cfg(target_arch = "wasm32")]
fn dispatch(name: &str, a: &[serde_json::Value]) -> DispatchResult {
    match name {
        "LIMITS" => {
            let l = &crate::LIMITS;
            Ok(serde_json::json!({
                "maxDepth": l.max_depth,
                "maxAssetBytes": l.max_asset_bytes,
                "maxBeautifyBytes": l.max_beautify_bytes,
                "maxModules": l.max_modules,
                "maxSources": l.max_sources,
                "maxMapBytes": l.max_map_bytes,
                "minPayloadLength": l.min_payload_length,
            }))
        }
        "panelTrackerView" => {
            let tracker = a.get(0).cloned().unwrap_or(serde_json::Value::Null);
            let filters = a
                .get(1)
                .and_then(|v| v.as_object())
                .map(|o| panel::model::ResourceFilters {
                    status: o
                        .get("status")
                        .and_then(|v| v.as_str())
                        .unwrap_or("all")
                        .to_string(),
                    kind: o
                        .get("kind")
                        .and_then(|v| v.as_str())
                        .unwrap_or("all")
                        .to_string(),
                    search: o
                        .get("search")
                        .and_then(|v| v.as_str())
                        .unwrap_or_default()
                        .to_string(),
                    sort: o
                        .get("sort")
                        .and_then(|v| v.as_str())
                        .unwrap_or("newest")
                        .to_string(),
                })
                .unwrap_or_default();
            let view = panel::view::tracker_view(&tracker, &filters);
            serde_json::to_value(view).map_err(|e| e.to_string())
        }
        "sha256Hex" => Ok(serde_json::Value::String(digest::sha256_hex(
            &arg_str(a, 0).ok_or("sha256Hex: text")?,
        ))),
        "sha256HexBytes" => Ok(match arg_bytes(a, 0) {
            Some(bytes) => match digest::sha256_hex_bytes(&bytes) {
                Some(hex) => serde_json::Value::String(hex),
                None => serde_json::Value::Null,
            },
            None => serde_json::Value::Null,
        }),
        "looksBinaryScript" => {
            let bytes = match a.get(1) {
                Some(v) if v.is_array() => Some(arg_bytes(a, 1).unwrap_or_default()),
                _ => None,
            };
            Ok(serde_json::Value::Bool(pipeline::looks_binary_script(
                &arg_str(a, 0).ok_or("looksBinaryScript: url")?,
                bytes.as_deref(),
            )))
        }
        "collectStringLiterals" => {
            let text = arg_str(a, 0).ok_or("collectStringLiterals: text")?;
            let min_length = a
                .get(1)
                .and_then(|v| v.as_object())
                .and_then(|o| o.get("minLength"))
                .and_then(|v| v.as_u64())
                .unwrap_or(0) as usize;
            serde_json::to_value(scanner::collect_string_literals(&text, min_length))
                .map_err(|e| e.to_string())
        }
        "findBalanced" => Ok(match arg_usize(a, 1) {
            Some(idx) => serde_json::to_value(scanner::find_balanced(
                &arg_str(a, 0).ok_or("findBalanced: text")?,
                idx,
            ))
            .map_err(|e| e.to_string())?,
            None => serde_json::Value::Null,
        }),
        "decodeEscapes" => Ok(serde_json::Value::String(decoders::decode_escapes(
            &arg_str(a, 0).ok_or("decodeEscapes: raw")?,
        ))),
        "decodeBase64ToBytes" => Ok(match arg_str(a, 0).as_deref().map(decoders::decode_base64_to_bytes) {
            Some(Some(bytes)) => serde_json::Value::Array(
                bytes.into_iter().map(serde_json::Value::from).collect(),
            ),
            _ => serde_json::Value::Null,
        }),
        "bytesToText" => Ok(serde_json::Value::String(decoders::bytes_to_text(
            &arg_bytes(a, 0).unwrap_or_default(),
        ))),
        "printableRatio" => Ok(serde_json::json!(decoders::printable_ratio(
            &arg_str(a, 0).ok_or("printableRatio: text")?
        ))),
        "detectLayers" => serde_json::to_value(detectors::detect_layers(
            &arg_str(a, 0).ok_or("detectLayers: text")?,
        ))
        .map_err(|e| e.to_string()),
        "peelText" => {
            let text = arg_str(a, 0).ok_or("peelText: text")?;
            let max_depth = a
                .get(1)
                .and_then(|v| v.as_object())
                .and_then(|o| o.get("maxDepth"))
                .and_then(|v| if v.is_null() { None } else { v.as_u64() })
                .map(|n| n as usize);
            serde_json::to_value(transforms::peel_text(&text, max_depth)).map_err(|e| e.to_string())
        }
        "looksMinified" => Ok(serde_json::Value::Bool(beautify::looks_minified(
            &arg_str(a, 0).ok_or("looksMinified: text")?,
        ))),
        "beautifyJs" => Ok(serde_json::Value::String(beautify::beautify_js(
            &arg_str(a, 0).ok_or("beautifyJs: text")?,
            opt_usize(a, 1),
        ))),
        "extractBundleModules" => {
            let modules = bundler::extract_bundle_modules(
                &arg_str(a, 0).ok_or("extractBundleModules: text")?,
                opt_usize(a, 1),
            );
            Ok(serde_json::Value::Array(
                modules
                    .into_iter()
                    .map(|m| serde_json::json!({ "id": m.id, "params": m.params, "code": m.code }))
                    .collect(),
            ))
        }
        "findSourceMapRef" => Ok(match sourcemaps::find_source_map_ref(
            &arg_str(a, 0).ok_or("findSourceMapRef: text")?,
        ) {
            Some(r) => source_map_ref_json(r),
            None => serde_json::Value::Null,
        }),
        "parseSourceMap" => {
            let json_text = arg_str(a, 0).ok_or("parseSourceMap: json")?;
            match sourcemaps::parse_source_map(&json_text) {
                Ok(parsed) => Ok(serde_json::json!({
                    "files": parsed
                        .files
                        .into_iter()
                        .map(|f| serde_json::json!({ "path": f.path, "content": f.content }))
                        .collect::<Vec<_>>(),
                    "sourceRoot": parsed.source_root,
                    "file": parsed.file,
                })),
                Err(_) => Ok(serde_json::Value::Null),
            }
        }
        "decodeInlineSourceMap" => Ok(match sourcemaps::decode_inline_source_map(
            &arg_str(a, 0).ok_or("decodeInlineSourceMap: dataUri")?,
        ) {
            Some(text) => serde_json::Value::String(text),
            None => serde_json::Value::Null,
        }),
        "resolveMapUrl" => Ok(serde_json::Value::String(sourcemaps::resolve_map_url(
            &arg_str(a, 0).ok_or("resolveMapUrl: scriptUrl")?,
            &arg_str(a, 1).ok_or("resolveMapUrl: mapRef")?,
        ))),
        "assetSlug" => Ok(serde_json::Value::String(pipeline::asset_slug(
            &arg_str(a, 0).ok_or("assetSlug: url")?,
            arg_usize(a, 1).ok_or("assetSlug: index")?,
        ))),
        "unpackAsset" => {
            let asset: HostAsset = serde_json::from_value(a.first().cloned().unwrap_or(serde_json::Value::Null))
                .map_err(|e| format!("unpackAsset: asset json: {e}"))?;
            let opts = arg_options(a, 1)?;
            let result = pipeline::unpack_asset(&asset.into_native(), &opts.into_native());
            Ok(serde_json::json!({
                "entry": result.entry,
                "files": files_json(result.files),
            }))
        }
        "unpackAssets" => {
            let assets: Vec<HostAsset> =
                serde_json::from_value(a.first().cloned().unwrap_or(serde_json::Value::Null))
                    .map_err(|e| format!("unpackAssets: assets json: {e}"))?;
            let opts = arg_options(a, 1)?;
            let native_assets: Vec<Asset> = assets.into_iter().map(|a| a.into_native()).collect();
            let batch = pipeline::unpack_assets(&native_assets, &opts.into_native());
            Ok(serde_json::json!({
                "report": batch.report,
                "files": files_json(batch.files),
            }))
        }
        "decodeJsfuck" => serde_json::to_value(jsfuck::decode_jsfuck(&arg_str(a, 0).ok_or("decodeJsfuck: source")?))
            .map_err(|e| e.to_string()),
        "detectJsfuck" => serde_json::to_value(jsfuck::detect_jsfuck(&arg_str(a, 0).ok_or("detectJsfuck: source")?))
            .map_err(|e| e.to_string()),
        "detectPacker" => Ok(match packers::detect_packer(&arg_str(a, 0).ok_or("detectPacker: text")?) {
            Some(found) => serde_json::to_value(found).map_err(|e| e.to_string())?,
            None => serde_json::Value::Null,
        }),
        "unpackPacker" => Ok(match packers::unpack_packer(&arg_str(a, 0).ok_or("unpackPacker: text")?) {
            Some(text) => serde_json::Value::String(text),
            None => serde_json::Value::Null,
        }),
        "transformStringArray" => Ok(match packers::transform_string_array(&arg_str(a, 0).ok_or("transformStringArray: source")?) {
            Some(text) => serde_json::Value::String(text),
            None => serde_json::Value::Null,
        }),
        "detectStringArray" => Ok(match packers::detect_string_array(&arg_str(a, 0).ok_or("detectStringArray: source")?) {
            Some(detected) => serde_json::to_value(detected).map_err(|e| e.to_string())?,
            None => serde_json::Value::Null,
        }),
        "detectV8CodeCache" => Ok(serde_json::Value::Bool(v8codecache::detect_v8_code_cache(
            &arg_bytes(a, 0).unwrap_or_default(),
        ))),
        "parseV8CodeCache" => Ok(match v8codecache::parse_v8_code_cache(&arg_bytes(a, 0).unwrap_or_default()) {
            Some(cache) => serde_json::to_value(cache).map_err(|e| e.to_string())?,
            None => serde_json::Value::Null,
        }),
        "extractV8Strings" => serde_json::to_value(v8codecache::extract_v8_strings(
            &arg_bytes(a, 0).unwrap_or_default(),
            arg_usize(a, 1).unwrap_or(0),
            opt_usize(a, 2),
        ))
        .map_err(|e| e.to_string()),
        "parseSealedV8" => {
            let bytes = arg_bytes(a, 0).unwrap_or_default();
            let mode = a
                .get(1)
                .and_then(|v| v.as_object())
                .and_then(|o| o.get("inflate"))
                .map(|v| {
                    if v.is_string() {
                        v.as_str().unwrap_or_default().to_string()
                    } else {
                        // a JS function means "use the engine's brotli"
                        "brotli".to_string()
                    }
                })
                .unwrap_or_else(|| "brotli".to_string());
            if bytes.is_empty() || v8codecache::detect_v8_code_cache(&bytes) {
                return Ok(serde_json::Value::Null);
            }
            let inflated = match mode.as_str() {
                "throw" => None,
                _ => v8codecache::inflate_brotli_with(&bytes, None),
            };
            let inflated = match inflated {
                Some(text) if v8codecache::detect_v8_code_cache(&text) => text,
                _ => return Ok(serde_json::Value::Null),
            };
            let parsed = match v8codecache::parse_v8_code_cache(&inflated) {
                Some(parsed) => parsed,
                None => return Ok(serde_json::Value::Null),
            };
            Ok(serde_json::json!({
                "tool": "jsc-sealed-v8",
                "detail": "brotli-sealed V8 code cache",
                "inflatedBytes": inflated.len(),
                "cache": parsed,
            }))
        }
        "parseJscHeader" => Ok(match jscbytecode::parse_jsc_header(&arg_bytes(a, 0).unwrap_or_default()) {
            Some(header) => serde_json::to_value(header).map_err(|e| e.to_string())?,
            None => serde_json::Value::Null,
        }),
        "detectJscBytecode" => Ok(serde_json::Value::Bool(jscbytecode::detect_jsc_bytecode(
            &arg_bytes(a, 0).unwrap_or_default(),
        ))),
        "recoverJscStrings" => serde_json::to_value(jscbytecode::recover_jsc_strings(
            &arg_bytes(a, 0).unwrap_or_default(),
        ))
        .map_err(|e| e.to_string()),
        "wtfStringHash" => Ok(serde_json::json!(jscbytecode::wtf_string_hash(
            &arg_bytes(a, 0).unwrap_or_default()
        ))),
        "analyzeJscModule" => {
            let shared: Option<Vec<Option<String>>> = match a.get(1) {
                Some(serde_json::Value::Null) | None => None,
                Some(v) => Some(
                    serde_json::from_value(v.clone())
                        .map_err(|e| format!("analyzeJscModule: shared: {e}"))?,
                ),
            };
            serde_json::to_value(jscbytecode::analyze_jsc_module(
                &arg_bytes(a, 0).unwrap_or_default(),
                shared.as_deref(),
            ))
            .map_err(|e| e.to_string())
        }
        "readJscSharedTable" => serde_json::to_value(jscbytecode::read_jsc_shared_table(
            &arg_bytes(a, 0).unwrap_or_default(),
            arg_usize(a, 1).ok_or("readJscSharedTable: offset")?,
            arg_usize(a, 2).ok_or("readJscSharedTable: length")?,
        ))
        .map_err(|e| e.to_string()),
        "findJscSharedTable" => Ok(match jscbytecode::find_jsc_shared_table(&arg_bytes(a, 0).unwrap_or_default()) {
            Some(table) => serde_json::to_value(table).map_err(|e| e.to_string())?,
            None => serde_json::Value::Null,
        }),
        "detectWasmModule" => Ok(serde_json::Value::Bool(wasm_mod::detect_wasm_module(
            &arg_bytes(a, 0).unwrap_or_default(),
        ))),
        "parseWasmModule" => Ok(match wasm_mod::parse_wasm_module(&arg_bytes(a, 0).unwrap_or_default()) {
            Some(info) => serde_json::to_value(info).map_err(|e| e.to_string())?,
            None => serde_json::Value::Null,
        }),
        _ => Err(format!("xu_call: unknown function {name}")),
    }
}

// Host-side JSON shapes for the pipeline seam. Bytes arrive base64-encoded
// (page.js holds Uint8Arrays; JSON arrays of megabytes would be absurd).
#[cfg(target_arch = "wasm32")]
#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct HostAsset {
    url: String,
    #[serde(default)]
    content: Option<String>,
    #[serde(default)]
    bytes_b64: Option<String>,
    #[serde(default)]
    zip_path: Option<String>,
}

#[cfg(target_arch = "wasm32")]
impl HostAsset {
    fn into_native(self) -> Asset {
        match self.bytes_b64 {
            Some(b64) => Asset::Bytes {
                url: self.url,
                bytes: decoders::decode_base64_to_bytes(&b64).unwrap_or_default(),
                zip_path: self.zip_path,
            },
            _ => Asset::Text {
                url: self.url,
                content: self.content.unwrap_or_default(),
                zip_path: self.zip_path,
            },
        }
    }
}

#[cfg(target_arch = "wasm32")]
#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct HostOptions {
    #[serde(default)]
    index: Option<usize>,
    #[serde(default)]
    path_prefix: Option<String>,
    #[serde(default)]
    max_depth: Option<usize>,
    #[serde(default)]
    max_modules: Option<usize>,
    #[serde(default)]
    max_beautify_bytes: Option<usize>,
    #[serde(default, deserialize_with = "deserialize_fetch_map")]
    fetch_map: std::collections::HashMap<String, String>,
}

// Tolerates both an absent key and an explicit null: the bridge omits the
// map when the caller did not supply one, but explicit nulls must not fail
// the whole options parse.
#[cfg(target_arch = "wasm32")]
fn deserialize_fetch_map<'de, D>(
    deserializer: D,
) -> Result<std::collections::HashMap<String, String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value: Option<std::collections::HashMap<String, String>> =
        serde::Deserialize::deserialize(deserializer)?;
    Ok(value.unwrap_or_default())
}

#[cfg(target_arch = "wasm32")]
impl HostOptions {
    fn into_native(self) -> UnpackOptions<'static> {
        FETCH_MAP.with(|m| *m.borrow_mut() = self.fetch_map.clone());
        UnpackOptions {
            index: self.index,
            zip_path: String::new(),
            max_depth: self.max_depth,
            max_modules: self.max_modules,
            max_beautify_bytes: self.max_beautify_bytes,
            path_prefix: self.path_prefix.unwrap_or_else(|| "_unpack".to_string()),
            fetch_text: Some(&wasm_fetch_text),
            inflate: None,
            shared_jsc_strings: None,
            shared_jsc_source: None,
        }
    }
}
