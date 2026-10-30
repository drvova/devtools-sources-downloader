// V8 code-cache reader for the export pipeline. A cached-data blob
// (vm.Script#createCachedData, node's compile cache, or a JSCeal-sealed .jsc
// once inflated) opens with the magic 0xC0DE0000 | N where the low half is
// the external-reference-table size of the build that wrote it. Behind the
// header sits a serialized V11/V12 payload: bytecode plus one-byte string
// frames (0x52 tag, a map byte, the StringImpl hash, the length, the

use std::io::Read;

const V8_MAGIC_FAMILY: u32 = 0xC0DE_0000;
const V8_MIN_EXT_REFS: u32 = 1;
const V8_MAX_EXT_REFS: u32 = 0x4000;

const V11_HEADER_SIZE: usize = 24;
const V12_HEADER_SIZE: usize = 32;
const V8_MAX_PAYLOAD: u32 = 256 * 1024 * 1024;
const V8_STRING_MIN: u32 = 2;
const V8_STRING_MAX: u32 = 1 << 24;
const BROTLI_WINDOW_MAX_BYTES: usize = 64 * 1024 * 1024;

fn v8_known_runtime(magic: u32) -> Option<&'static str> {
    match magic {
        0xC0DE_0563 => Some("node18"),
        0xC0DE_05CC => Some("node20"),
        0xC0DE_0628 => Some("node22"),
        0xC0DE_0688 => Some("node24"),
        _ => None,
    }
}

fn u32(bytes: &[u8], at: usize) -> u32 {
    u32::from_le_bytes([
        bytes[at],
        bytes[at + 1],
        bytes[at + 2],
        bytes[at + 3],
    ])
}

pub fn detect_v8_code_cache(bytes: &[u8]) -> bool {
    if bytes.len() < V12_HEADER_SIZE {
        return false;
    }
    let magic = u32(bytes, 0);
    if (magic >> 16) != (V8_MAGIC_FAMILY >> 16) {
        return false;
    }
    let ext_refs = magic & 0xFFFF;
    (V8_MIN_EXT_REFS..=V8_MAX_EXT_REFS).contains(&ext_refs)
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct V8CodeCache {
    pub magic: u32,
    pub magic_hex: String,
    pub runtime: String,
    pub format: &'static str,
    pub version_hash: u32,
    pub source_hash: u32,
    pub flag_hash: u32,
    pub payload_offset: usize,
    pub payload_length: u32,
    pub strings: Vec<String>,
}

pub fn parse_v8_code_cache(bytes: &[u8]) -> Option<V8CodeCache> {
    if !detect_v8_code_cache(bytes) {
        return None;
    }
    let magic = u32(bytes, 0);
    let known = v8_known_runtime(magic);
    // The header layout switched at node22: V11 keeps payload_length at +16,
    // V12 inserts the read-only snapshot checksum there. The payload always
    // ends exactly at the blob end, so the layout whose length fits wins.
    let v11_payload = u32(bytes, 16);
    let v12_payload = u32(bytes, 20);
    let (format, payload_length, payload_offset): (&'static str, u32, usize) =
        if v12_payload as usize + V12_HEADER_SIZE == bytes.len() {
            ("v12", v12_payload, V12_HEADER_SIZE)
        } else if v11_payload as usize + V11_HEADER_SIZE == bytes.len() {
            ("v11", v11_payload, V11_HEADER_SIZE)
        } else {
            return None;
        };
    if payload_length > V8_MAX_PAYLOAD || payload_offset + payload_length as usize > bytes.len() {
        return None;
    }
    let runtime = known.map(str::to_string).unwrap_or_else(|| {
        format!(
            "unknown build ({:x} family, {} external refs)",
            V8_MAGIC_FAMILY,
            magic & 0xFFFF
        )
    });
    Some(V8CodeCache {
        magic,
        magic_hex: format!("0x{magic:x}"),
        runtime,
        format,
        version_hash: u32(bytes, 4),
        source_hash: u32(bytes, 8),
        flag_hash: u32(bytes, 12),
        payload_offset,
        payload_length,
        strings: extract_v8_strings(bytes, payload_offset, Some(payload_offset + payload_length as usize)),
    })
}

/// One-byte string frames inside the serialized payload.
pub fn extract_v8_strings(bytes: &[u8], from: usize, to: Option<usize>) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
    let end = to.unwrap_or(bytes.len()).min(bytes.len());
    let mut i = from;
    while i + 10 <= end {
        if bytes[i] != 0x52 {
            i += 1;
            continue;
        }
        let map = bytes[i + 1];
        if map != 0x61 && map != 0x62 && map != 0x63 {
            i += 1;
            continue;
        }
        let length = u32(bytes, i + 6);
        if !(V8_STRING_MIN..V8_STRING_MAX).contains(&length) {
            i += 1;
            continue;
        }
        let char_at = i + 10;
        if char_at + length as usize > end {
            i += 1;
            continue;
        }
        let chars = &bytes[char_at..char_at + length as usize];
        if !chars.iter().all(|&b| (0x20..0x7f).contains(&b)) {
            i += 1;
            continue;
        }
        let text = chars.iter().map(|&b| b as char).collect::<String>();
        if seen.insert(text.clone()) {
            out.push(text);
        }
        i = char_at + length as usize - 1;
    }
    out
}

/// The brotli inflator seam: the browser route is DecompressionStream('br');
/// node's undici rejects 'br', so callers outside the browser inject their
/// own. Rust has no platform variance, so the default is the brotli crate and
/// the injected form exists for parity and failure injection.
pub type InflateImpl<'a> = dyn Fn(&[u8]) -> std::io::Result<Vec<u8>> + 'a;

pub fn inflate_brotli_with(
    bytes: &[u8],
    injected: Option<&InflateImpl>,
) -> Option<Vec<u8>> {
    if let Some(impl_fn) = injected {
        return impl_fn(bytes).ok();
    }
    inflate_brotli_default(bytes)
}

fn inflate_brotli_default(bytes: &[u8]) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    brotli::Decompressor::new(bytes, 4096)
        .read_to_end(&mut out)
        .ok()?;
    if out.is_empty() {
        return None;
    }
    Some(out)
}

pub struct SealedV8 {
    pub inflated_bytes: usize,
    pub cache: V8CodeCache,
}

/// JSCeal-sealed .jsc: brotli around a V8 code cache. Returns None when the
/// bytes are not that shape, so the JSC-bytecode detector gets its turn.
pub fn parse_sealed_v8(bytes: &[u8], injected: Option<&InflateImpl>) -> Option<SealedV8> {
    if bytes.is_empty() || detect_v8_code_cache(bytes) {
        return None;
    }
    if bytes.len() > BROTLI_WINDOW_MAX_BYTES {
        return None;
    }
    let inflated = inflate_brotli_with(bytes, injected)?;
    if !detect_v8_code_cache(&inflated) {
        return None;
    }
    let parsed = parse_v8_code_cache(&inflated)?;
    Some(SealedV8 {
        inflated_bytes: inflated.len(),
        cache: parsed,
    })
}

