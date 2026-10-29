// Rust port of the DevTools sources-downloader unpack engine.
//
// One crate mirrors the six browser modules: the scanner, decoders, jsfuck
// interpreter, packers/string-array, JSC bytecode, V8 code cache and wasm
// walkers, plus the detect/route/transform pipeline that drives them. Every
// public function of the JavaScript engine has a Rust counterpart with the
// same observable behavior; see PORTING.md for the API map, the deliberate
// divergences (sync everywhere, no FNV digest fallback, the simplified
// beautifier, char-based reverse/rot13) and the preserved quirks.

pub mod beautify;
pub mod bundler;
pub mod decoders;
pub mod detectors;
pub mod digest;
pub mod jscbytecode;
pub mod jsfuck;
pub mod jsnumber;
pub mod packers;
pub mod pipeline;
pub mod scanner;
pub mod sourcemaps;
pub mod transforms;
pub mod util;
pub mod v8codecache;
pub mod wasm;

/// JS `LIMITS` from unpack.js.
pub struct Limits {
    pub max_depth: usize,
    pub max_asset_bytes: usize,
    pub max_beautify_bytes: usize,
    pub max_modules: usize,
    pub max_sources: usize,
    pub max_map_bytes: usize,
    pub min_payload_length: usize,
}

pub const LIMITS: Limits = Limits {
    max_depth: 8,
    max_asset_bytes: 8 << 20,
    max_beautify_bytes: 2 << 20,
    max_modules: 400,
    max_sources: 400,
    max_map_bytes: 32 << 20,
    min_payload_length: 24,
};
