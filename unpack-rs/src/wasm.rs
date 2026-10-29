// WebAssembly module layer: detect a binary wasm module by its magic,
// walk its sections, and recover what an investigator actually wants —
// imports, exports, function names from the name section, and string
// constants from data segments. Unknown or truncated structure is
// reported as a note, never a crash.

use std::collections::BTreeMap;

const WASM_MAGIC: [u8; 4] = [0x00, 0x61, 0x73, 0x6d];
const WASM_MIN_STRING: usize = 4;

fn section_name(id: u8) -> String {
    match id {
        0 => "custom".to_string(),
        1 => "type".to_string(),
        2 => "import".to_string(),
        3 => "function".to_string(),
        4 => "table".to_string(),
        5 => "memory".to_string(),
        6 => "global".to_string(),
        7 => "export".to_string(),
        8 => "start".to_string(),
        9 => "element".to_string(),
        10 => "code".to_string(),
        11 => "data".to_string(),
        12 => "dataCount".to_string(),
        other => format!("unknown-{other}"),
    }
}

fn kind_name(kind: u8) -> String {
    match kind {
        0 => "func".to_string(),
        1 => "table".to_string(),
        2 => "memory".to_string(),
        3 => "global".to_string(),
        other => other.to_string(),
    }
}

pub fn detect_wasm_module(bytes: &[u8]) -> bool {
    bytes.len() >= 8 && bytes[..4] == WASM_MAGIC
}

fn leb(bytes: &[u8], at: usize) -> Option<(f64, usize)> {
    let mut value = 0f64;
    let mut shift = 0u32;
    let mut at = at;
    loop {
        if at >= bytes.len() || shift > 35 {
            return None;
        }
        let b = bytes[at];
        at += 1;
        value += (b & 0x7F) as f64 * 2f64.powi(shift as i32);
        if b & 0x80 == 0 {
            return Some((value, at));
        }
        shift += 7;
    }
}

/// A wasm name: LEB length + UTF-8 bytes.
fn wasm_name(bytes: &[u8], at: usize) -> Option<(String, usize)> {
    let (length, mut at) = leb(bytes, at)?;
    let length = length as usize;
    if at + length > bytes.len() {
        return None;
    }
    let mut text = String::new();
    for i in 0..length {
        let b = bytes[at + i];
        if b == 0x09 || b == 0x0a || b == 0x0d || (0x20..0x7f).contains(&b) {
            text.push(b as char);
        } else {
            return None; // names are valid UTF-8; refuse garbage
        }
    }
    at += length;
    Some((text, at))
}

fn limits(bytes: &[u8], at: usize) -> Option<usize> {
    let flag = *bytes.get(at)?;
    let (_, at) = leb(bytes, at + 1)?;
    if flag & 1 != 0 {
        let (_, at) = leb(bytes, at)?;
        Some(at)
    } else {
        Some(at)
    }
}

fn scan_printable_strings(bytes: &[u8], at: usize, end: usize, min: usize) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut run = String::new();
    for &b in &bytes[at..end] {
        if (0x20..0x7f).contains(&b) {
            run.push(b as char);
        } else {
            if run.chars().count() >= min && seen.insert(run.clone()) {
                out.push(run.clone());
            }
            run.clear();
        }
    }
    if run.chars().count() >= min && !seen.contains(&run) {
        out.push(run);
    }
    out
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WasmSection {
    pub id: u8,
    pub name: String,
    pub offset: usize,
    pub size: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub custom_name: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WasmImport {
    pub module: String,
    pub field: String,
    pub kind: String,
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WasmExport {
    pub name: String,
    pub kind: String,
    pub index: u32,
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WasmModuleInfo {
    pub version: u32,
    pub sections: Vec<WasmSection>,
    pub imports: Vec<WasmImport>,
    pub exports: Vec<WasmExport>,
    pub function_names: BTreeMap<u32, String>,
    pub type_names: BTreeMap<u32, String>,
    pub module_name: Option<String>,
    pub function_count: u32,
    pub data_strings: Vec<String>,
    pub notes: Vec<String>,
}

fn parse_name_subsection(payload: &[u8], info: &mut WasmModuleInfo) {
    let mut at = 0usize;
    while at < payload.len() {
        let id = payload[at];
        at += 1;
        let Some((size, next)) = leb(payload, at) else {
            return;
        };
        at = next;
        // u64 bound math: a huge LEB size saturating on 32-bit targets must
        // reject, not wrap into a passing check.
        let size64 = size as u64;
        if size64 > (payload.len() - at) as u64 {
            return;
        }
        let size = size64 as usize;
        let body = &payload[at..at + size];
        let mut cursor = 0usize;
        if id == 0 {
            if let Some((name, _)) = wasm_name(body, 0) {
                info.module_name = Some(name);
            }
        } else if id == 1 || id == 2 || id == 4 {
            let Some((count, next)) = leb(body, cursor) else {
                at += size;
                continue;
            };
            cursor = next;
            let mut i = 0f64;
            while i < count && cursor < body.len() {
                let Some((index, next)) = leb(body, cursor) else {
                    break;
                };
                cursor = next;
                let Some((name, next)) = wasm_name(body, cursor) else {
                    break;
                };
                cursor = next;
                if id == 1 {
                    info.function_names.insert(index as u32, name);
                } else if id == 4 {
                    info.type_names.insert(index as u32, name);
                }
                // id 2 = locals: (funcidx, count, pairs) — not recovered
                if id == 2 {
                    break;
                }
                i += 1.0;
            }
        }
        at += size;
    }
}

pub fn parse_wasm_module(bytes: &[u8]) -> Option<WasmModuleInfo> {
    if !detect_wasm_module(bytes) {
        return None;
    }
    let mut info = WasmModuleInfo {
        version: u32::from_le_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]),
        sections: Vec::new(),
        imports: Vec::new(),
        exports: Vec::new(),
        function_names: BTreeMap::new(),
        type_names: BTreeMap::new(),
        module_name: None,
        function_count: 0,
        data_strings: Vec::new(),
        notes: Vec::new(),
    };
    let mut at = 8usize;
    while at < bytes.len() {
        let id = bytes[at];
        at += 1;
        let Some((size, next)) = leb(bytes, at) else {
            info.notes.push(format!("truncated section header at {at}"));
            break;
        };
        at = next;
        // u64 bound math - see the name walker above.
        let size64 = size as u64;
        if size64 > (bytes.len() - at) as u64 {
            info.notes
                .push(format!("section {} overruns the module", section_name(id)));
            break;
        }
        let size = size64 as usize;
        let end = at + size;
        let mut section = WasmSection {
            id,
            name: section_name(id),
            offset: at,
            size,
            custom_name: None,
        };
        let mut cursor = at;
        // Bounds failures mirror the JS exception catch: the section is
        // reported as partially decoded instead of aborting the walk.
        let decode = (|info: &mut WasmModuleInfo, section: &mut WasmSection| -> bool {
            match id {
                0 => {
                    if let Some((name, name_end)) = wasm_name(bytes, cursor) {
                        section.custom_name = Some(name.clone());
                        if name == "name" {
                            parse_name_subsection(&bytes[name_end..end], info);
                        }
                    }
                }
                2 => {
                    if let Some((count, next)) = leb(bytes, cursor) {
                        cursor = next;
                        let mut i = 0f64;
                        while i < count && cursor < end {
                            let Some((module, next)) = wasm_name(bytes, cursor) else {
                                return false;
                            };
                            cursor = next;
                            let Some((field, next)) = wasm_name(bytes, cursor) else {
                                return false;
                            };
                            cursor = next;
                            let Some(&kind) = bytes.get(cursor) else {
                                return false;
                            };
                            cursor += 1;
                            match kind {
                                0 => {
                                    let Some((_, next)) = leb(bytes, cursor) else {
                                        return false;
                                    };
                                    cursor = next;
                                }
                                1 => {
                                    cursor += 1;
                                    let Some(l) = limits(bytes, cursor) else {
                                        return false;
                                    };
                                    cursor = l;
                                }
                                2 => {
                                    let Some(l) = limits(bytes, cursor) else {
                                        return false;
                                    };
                                    cursor = l;
                                }
                                3 => cursor += 2,
                                _ => {}
                            }
                            info.imports.push(WasmImport {
                                module,
                                field,
                                kind: kind_name(kind),
                            });
                            i += 1.0;
                        }
                    }
                }
                3 => {
                    if let Some((count, _)) = leb(bytes, cursor) {
                        info.function_count = count as u32;
                    }
                }
                7 => {
                    if let Some((count, next)) = leb(bytes, cursor) {
                        cursor = next;
                        let mut e = 0f64;
                        while e < count && cursor < end {
                            let Some((name, next)) = wasm_name(bytes, cursor) else {
                                return false;
                            };
                            cursor = next;
                            let Some(&kind_byte) = bytes.get(cursor) else {
                                return false;
                            };
                            cursor += 1;
                            let Some((index, next)) = leb(bytes, cursor) else {
                                return false;
                            };
                            cursor = next;
                            info.exports.push(WasmExport {
                                name,
                                kind: kind_name(kind_byte),
                                index: index as u32,
                            });
                            e += 1.0;
                        }
                    }
                }
                11 => {
                    if let Some((count, next)) = leb(bytes, cursor) {
                        cursor = next;
                        let mut s = 0f64;
                        while s < count && cursor < end {
                            let Some((flag, next)) = leb(bytes, cursor) else {
                                return false;
                            };
                            cursor = next;
                            if flag == 0.0 || flag == 2.0 {
                                if flag == 2.0 {
                                    let Some((_, next)) = leb(bytes, cursor) else {
                                        return false;
                                    };
                                    cursor = next;
                                }
                                // active segment: skip the init-expr
                                // (ends at the 0x0b end byte)
                                while cursor < end {
                                    let op = bytes[cursor];
                                    cursor += 1;
                                    if op == 0x0b {
                                        break;
                                    }
                                    if matches!(op, 0x23 | 0x24 | 0x41 | 0x42) {
                                        match leb(bytes, cursor) {
                                            Some((_, next)) => cursor = next,
                                            None => {
                                                cursor = end;
                                                break;
                                            }
                                        }
                                    }
                                }
                            }
                            let Some((seg_size, next)) = leb(bytes, cursor) else {
                                return false;
                            };
                            cursor = next;
                            // u64 bound math - see the name walker above.
                            let seg64 = seg_size as u64;
                            if seg64 > (end - cursor) as u64 {
                                return false;
                            }
                            let seg_size = seg64 as usize;
                            for found in scan_printable_strings(bytes, cursor, cursor + seg_size, WASM_MIN_STRING) {
                                if !info.data_strings.contains(&found) {
                                    info.data_strings.push(found);
                                }
                            }
                            cursor += seg_size;
                            s += 1.0;
                        }
                    }
                }
                _ => {}
            }
            true
        })(&mut info, &mut section);
        if !decode {
            info.notes
                .push(format!("section {} partially decoded", section.name));
        }
        info.sections.push(section);
        at = end;
    }
    // named exports are richer than the name section alone
    let exports = info.exports.clone();
    for exp in &exports {
        if exp.kind == "func" && !info.function_names.contains_key(&exp.index) {
            info.function_names.insert(exp.index, exp.name.clone());
        }
    }
    Some(info)
}
