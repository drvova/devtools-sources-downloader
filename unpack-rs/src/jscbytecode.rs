// JavaScriptCore cached-bytecode string recovery and the cached-function
// tree walk (the unbuned oracle, ported). A Bun --bytecode chunk opens with a
// five-word header; every compiler string is a 12-byte record whose
// StringImpl::hash() proves it. Structure recovery binds code blocks whose
// instruction stream opens on `enter`, walks exactly its declared length
// under the opcode table, and ends on a transfer of control.

use std::collections::HashSet;
use std::sync::LazyLock;

const JSC_HEADER_SIZE: usize = 32;
const JSC_FORMAT_WORD: u32 = 1;
const JSC_LENGTH_MASK: u32 = 0x07FF_FFFF;
const JSC_IS_8_BIT: u32 = 0x0800_0000;
const JSC_RECORD_HEADER: usize = 12;
const JSC_STRING_LIMIT: u32 = 4096;
const JSC_HASH_MASK: u64 = 0x00FF_FFFF;

// RapidHash secret from WTF's rapidhash.h — constant, not build specific.
const WTF_SECRET: [u64; 3] = [0x2d35_8dcc_aa6c_78a5, 0x8bb8_4b93_962e_acc9, 0x4b33_a62e_d433_d4a3];

const JSC_OPCODE_SOURCE: &str = include_str!("jsc_opcodes.txt");

const JSC_WIDE16: u8 = 0x83;
const JSC_WIDE32: u8 = 0x85;
const JSC_ENTER_OPCODE: u8 = 134;
const JSC_ARRAY_ORDER: [&str; 7] = ["steps", "instr", "consts", "cscr", "idents", "fdecls", "fexprs"];
const JSC_BLOCK_GAPS: [usize; 4] = [4, 0x38, 0x28, 16];

fn u32(bytes: &[u8], at: usize) -> u32 {
    u32::from_le_bytes([bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]])
}

fn i32(bytes: &[u8], at: usize) -> i32 {
    i32::from_le_bytes([bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]])
}

fn rapid_mix(first: u64, second: u64) -> u64 {
    // The full 128-bit product must survive: masking before the shift would
    // fold zero into the high half and mirror every value.
    let product = (first as u128).wrapping_mul(second as u128);
    (product & u64::MAX as u128) as u64 ^ (product >> 64) as u64
}

fn read64(bytes: &[u8], at: usize) -> u64 {
    u64::from_le_bytes(bytes[at..at + 8].try_into().expect("8-byte slice"))
}

fn read32_big(bytes: &[u8], at: usize) -> u64 {
    // Same misleading name as the JS: the loop builds LITTLE-endian words.
    u32::from_le_bytes(bytes[at..at + 4].try_into().expect("4-byte slice")) as u64
}

/// WTF::StringImpl::hash(): RapidHash over the raw character bytes, low 24
/// bits, zero replaced by 0x800000.
pub fn wtf_string_hash(bytes: &[u8]) -> u32 {
    let length = bytes.len();
    let secret = WTF_SECRET;
    let mut seed = rapid_mix(secret[0], secret[1]) ^ length as u64;
    let (first, second): (u64, u64);
    if length <= 16 {
        if length >= 4 {
            let delta: usize = if length >= 8 { 4 } else { 0 };
            first = (read32_big(bytes, 0) << 32) | read32_big(bytes, length - 4);
            second = (read32_big(bytes, delta) << 32) | read32_big(bytes, length - 4 - delta);
        } else if length > 0 {
            first = ((bytes[0] as u64) << 56)
                | ((bytes[length >> 1] as u64) << 32)
                | bytes[length - 1] as u64;
            second = 0;
        } else {
            first = 0;
            second = 0;
        }
    } else {
        let mut remaining = length;
        let mut at = 0usize;
        if remaining > 48 {
            let mut see1 = seed;
            let mut see2 = seed;
            loop {
                seed = rapid_mix(read64(bytes, at) ^ secret[0], read64(bytes, at + 8) ^ seed);
                see1 = rapid_mix(read64(bytes, at + 16) ^ secret[1], read64(bytes, at + 24) ^ see1);
                see2 = rapid_mix(read64(bytes, at + 32) ^ secret[2], read64(bytes, at + 40) ^ see2);
                at += 48;
                remaining -= 48;
                if remaining < 48 {
                    break;
                }
            }
            seed ^= see1 ^ see2;
        }
        if remaining > 16 {
            seed = rapid_mix(read64(bytes, at) ^ secret[2], read64(bytes, at + 8) ^ seed ^ secret[1]);
            if remaining > 32 {
                seed = rapid_mix(read64(bytes, at + 16) ^ secret[2], read64(bytes, at + 24) ^ seed);
            }
        }
        first = read64(bytes, at + remaining - 16);
        second = read64(bytes, at + remaining - 8);
    }
    let first = first ^ secret[1];
    let second = second ^ seed;
    let product = (first as u128).wrapping_mul(second as u128);
    let value = rapid_mix(
        ((product & u64::MAX as u128) as u64) ^ secret[0] ^ length as u64,
        ((product >> 64) as u64) ^ secret[1],
    ) & JSC_HASH_MASK;
    if value == 0 {
        0x80_0000
    } else {
        value as u32
    }
}

#[derive(Debug, Clone, serde::Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct JscHeader {
    pub stamp: u32,
    pub format: u32,
    pub version: u32,
    pub declared_length: u32,
    pub body_offset: u32,
}

pub fn parse_jsc_header(bytes: &[u8]) -> Option<JscHeader> {
    if bytes.len() < JSC_HEADER_SIZE {
        return None;
    }
    let format_word = u32(bytes, 4);
    let declared_length = u32(bytes, 12);
    if format_word != JSC_FORMAT_WORD && declared_length as usize != bytes.len() {
        return None;
    }
    Some(JscHeader {
        stamp: u32(bytes, 0),
        format: format_word,
        version: u32(bytes, 8),
        declared_length,
        body_offset: u32(bytes, 16),
    })
}

pub fn detect_jsc_bytecode(bytes: &[u8]) -> bool {
    parse_jsc_header(bytes).is_some()
}

/// Scan candidates with the proven extractor's prefilter, then prove each by
/// hashing its characters. Distinct strings in order of appearance.
pub fn recover_jsc_strings(bytes: &[u8]) -> Vec<String> {
    if bytes.is_empty() {
        return Vec::new();
    }
    let mut strings: Vec<String> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    let len = bytes.len();
    let mut at = 0usize;
    while at + JSC_RECORD_HEADER <= len {
        // prefilter: bits 24-26 of the flag word clear (top byte & 0x07 == 0)
        // and a zero top byte on the stored hash (24-bit hash, little endian)
        if (bytes[at + 3] & 0x07) != 0 || bytes[at + 7] != 0x00 {
            at += 1;
            continue;
        }
        let flags = u32(bytes, at);
        let stored = u32(bytes, at + 4);
        let length = flags & JSC_LENGTH_MASK;
        // bit 27 is the IS-8-BIT flag: set means one-byte characters
        let width: u32 = if flags & JSC_IS_8_BIT != 0 { 1 } else { 2 };
        let byte_length = (length * width) as usize;
        if length == 0 || length > JSC_STRING_LIMIT || at + JSC_RECORD_HEADER + byte_length > len {
            at += 1;
            continue;
        }
        let char_at = at + JSC_RECORD_HEADER;
        let raw = &bytes[char_at..char_at + byte_length];
        if wtf_string_hash(raw) == stored {
            let mut text = String::new();
            let mut ok = true;
            if width == 1 {
                for &b in raw {
                    if !(0x20..0x7f).contains(&b) {
                        ok = false;
                        break;
                    }
                    text.push(b as char);
                }
            } else {
                for unit in raw.as_chunks::<2>().0 {
                    let code = unit[0] as u32 | ((unit[1] as u32) << 8);
                    if !(0x20..0x7f).contains(&code) {
                        ok = false;
                        break;
                    }
                    text.push(char::from_u32(code).unwrap_or('\u{FFFD}'));
                }
            }
            if ok && seen.insert(text.clone()) {
                strings.push(text);
            }
            at = char_at + byte_length;
        } else {
            at += 1;
        }
    }
    strings
}

// ------------------------------------------------------- opcode table

pub struct JscOpcodeInfo {
    pub name: String,
    pub operand_bytes: usize,
    pub has_metadata: bool,
}

/// id -> (name, operand bytes including metadata, has metadata)
pub fn jsc_opcode_table() -> &'static Vec<Option<JscOpcodeInfo>> {
    static TABLE: LazyLock<Vec<Option<JscOpcodeInfo>>> = LazyLock::new(|| {
        let mut table: Vec<Option<JscOpcodeInfo>> = (0..256).map(|_| None).collect();
        for row in JSC_OPCODE_SOURCE.split('\n') {
            let mut parts = row.split_whitespace();
            let (Some(id), Some(name), Some(operand), Some(pad)) =
                (parts.next(), parts.next(), parts.next(), parts.next())
            else {
                continue;
            };
            let (Ok(id_num), Ok(operand_num), Ok(pad_num)) =
                (id.parse::<usize>(), operand.parse::<usize>(), pad.parse::<usize>())
            else {
                continue;
            };
            if id_num < 256 {
                table[id_num] = Some(JscOpcodeInfo {
                    name: name.to_string(),
                    operand_bytes: operand_num + pad_num,
                    has_metadata: pad_num == 1,
                });
            }
        }
        table
    });
    &TABLE
}

fn jsc_array_span(name: &str) -> Option<usize> {
    match name {
        "steps" => Some(4),
        "instr" => Some(1),
        "idents" => Some(4),
        "fdecls" => Some(4),
        "fexprs" => Some(4),
        _ => None,
    }
}

fn is_terminal_op(name: &str) -> bool {
    matches!(
        name,
        "ret"
            | "jmp"
            | "ret_undefined"
            | "checkpoint_osr_exit_from_in_call"
            | "throw"
            | "rethrow"
            | "unreachable"
            | "tail_call_varargs"
            | "call_varargs"
            | "call"
            | "tail_call"
            | "call_direct"
            | "tail_call_direct"
            | "call_eval"
            | "call_ignore_result"
            | "construct"
            | "construct_varargs"
            | "jneq_ptr"
            | "direct_tail_call"
    )
}

fn varint(bytes: &[u8], at: usize) -> Option<(f64, usize)> {
    let mut value = 0f64;
    let mut shift = 0u32;
    let mut cursor = at;
    loop {
        if cursor >= bytes.len() || shift > 35 {
            return None;
        }
        let b = bytes[cursor];
        cursor += 1;
        value += (b & 0x7F) as f64 * 2f64.powi(shift as i32);
        if b & 0x80 == 0 {
            return Some((value, cursor));
        }
        shift += 7;
    }
}

fn svarint(bytes: &[u8], at: usize) -> Option<(f64, usize)> {
    let (value, next) = varint(bytes, at)?;
    let signed = ((value as i64) >> 1) ^ -((value as i64) & 1);
    Some((signed as f64, next))
}

pub struct JscTail {
    pub flags: u8,
    pub record_offset: f64,
    pub arrays: Vec<(&'static str, f64, f64)>, // (name, count, start)
    pub extras: f64,
    pub scalars_at: usize,
}

pub fn parse_jsc_tail(bytes: &[u8], at: usize) -> Option<JscTail> {
    if at < 8 || at + 8 > bytes.len() {
        return None;
    }
    let flags = bytes[at];
    if flags & !0x05 != 0 {
        return None;
    }
    let mut cursor = at + 1;
    let (record_offset, next) = varint(bytes, cursor)?;
    if record_offset >= 0x2000_0000u32 as f64 {
        return None;
    }
    cursor = next;
    if flags & 1 != 0 {
        let (extra, next) = varint(bytes, cursor)?;
        if extra > (1u64 << 24) as f64 {
            return None;
        }
        cursor = next;
    }
    let mut arrays = Vec::with_capacity(7);
    for &name in &JSC_ARRAY_ORDER {
        let (count, next) = varint(bytes, cursor)?;
        if count > 0x2000_0000u32 as f64 {
            return None;
        }
        cursor = next;
        let mut start = 0f64;
        if count != 0.0 {
            let (s, next) = svarint(bytes, cursor)?;
            if s.abs() > 0x2000_0000u32 as f64 {
                return None;
            }
            start = s;
            cursor = next;
        }
        arrays.push((name, count, start));
    }
    let mut extras = 0f64;
    if flags & 4 != 0 {
        let (e, next) = svarint(bytes, cursor)?;
        extras = e;
        cursor = next;
    }
    Some(JscTail {
        flags,
        record_offset,
        arrays,
        extras,
        scalars_at: cursor,
    })
}

pub struct JscOp {
    pub name: &'static str,
}

fn walk_jsc_ops(bytes: &[u8], start: usize, length: f64, table: &'static [Option<JscOpcodeInfo>]) -> Option<Vec<JscOp>> {
    let mut offset = start;
    let end = start + length as usize;
    let mut ops: Vec<JscOp> = Vec::new();
    while offset < end {
        if offset >= bytes.len() {
            return None;
        }
        let first = bytes[offset];
        // The table lives in a LazyLock static, so the name slice is 'static.
        let op: &'static JscOpcodeInfo = if first == JSC_WIDE16 || first == JSC_WIDE32 {
            if offset + 2 > bytes.len() {
                return None;
            }
            let op = table.get(bytes[offset + 1] as usize)?.as_ref()?;
            offset += 2 + op.operand_bytes * (if first == JSC_WIDE16 { 2 } else { 4 });
            op
        } else {
            let op = table.get(first as usize)?.as_ref()?;
            offset += 1 + op.operand_bytes;
            op
        };
        if offset > end {
            return None;
        }
        ops.push(JscOp { name: op.name.as_str() });
    }
    if ops.is_empty() {
        None
    } else {
        Some(ops)
    }
}

#[derive(Clone)]
pub struct JscBlockCandidate {
    pub record: usize,
    pub gap: usize,
    pub region: i64,
    pub instr_at: usize,
    pub instr_length: f64,
    pub op_count: usize,
    pub tail: std::rc::Rc<JscTail>,
    pub tight: bool,
}

/// Bind a code block whose record sits at `record`. Candidates are tried at
/// each fixed record-size gap; a candidate survives only when every positive
/// array packs before the record, the stream opens on `enter`, walks
/// exactly, and ends on a transfer of control.
pub fn bind_jsc_block(bytes: &[u8], record: usize, table: &'static [Option<JscOpcodeInfo>]) -> Vec<JscBlockCandidate> {
    let mut candidates = Vec::new();
    for &gap in &JSC_BLOCK_GAPS {
        let tail = match parse_jsc_tail(bytes, record + gap) {
            Some(t) => t,
            None => continue,
        };
        let instr = match tail.arrays.iter().find(|(name, ..)| *name == "instr") {
            Some((_, count, start)) => (*count, *start),
            None => continue,
        };
        if instr.0 == 0.0 {
            continue;
        }
        let mut packed_end = 0f64;
        let mut has_positive = false;
        let mut rejected = false;
        for &(name, count, start) in &tail.arrays {
            if count == 0.0 || start < 0.0 {
                continue;
            }
            let span = jsc_array_span(name).unwrap_or(1) as f64;
            let end = start + count * span;
            if end > tail.record_offset {
                rejected = true;
                break;
            }
            if jsc_array_span(name).is_some() {
                has_positive = true;
                if end > packed_end {
                    packed_end = end;
                }
            }
        }
        if rejected {
            continue;
        }
        let region = record as f64 - tail.record_offset;
        if !(32.0..=record as f64).contains(&region) {
            continue;
        }
        let region = region as i64;
        let stream_at = region + instr.1 as i64;
        if stream_at < 0 || stream_at as usize >= bytes.len() {
            continue;
        }
        let stream_at = stream_at as usize;
        if bytes[stream_at] != JSC_ENTER_OPCODE {
            continue;
        }
        let ops = match walk_jsc_ops(bytes, stream_at, instr.0, table) {
            Some(ops) => ops,
            None => continue,
        };
        if !ops.last().map(|op| is_terminal_op(op.name)).unwrap_or(false) {
            continue;
        }
        let tail_record_offset = tail.record_offset;
        candidates.push(JscBlockCandidate {
            record,
            gap,
            region,
            instr_at: stream_at,
            instr_length: instr.0,
            op_count: ops.len(),
            tail: std::rc::Rc::new(tail),
            tight: !has_positive || packed_end == tail_record_offset,
        });
    }
    // tight first, then smallest gap; JS sort is stable.
    candidates.sort_by(|a, b| b.tight.cmp(&a.tight).then(a.gap.cmp(&b.gap)));
    candidates
}

/// Names stored inline in a module (a shared-table ordinal does not resolve
/// inside a lone chunk, so it reports as `<ordinal N>`).
fn read_jsc_inline_string(bytes: &[u8], at: i64) -> Option<String> {
    if at < 0 || at as usize + 12 > bytes.len() {
        return None;
    }
    let at = at as usize;
    let length = u32(bytes, at) & 0xFF_FFFF;
    if length == 0 || length > 4096 {
        return None;
    }
    if at + 12 + length as usize > bytes.len() {
        return None;
    }
    let mut text = String::new();
    for i in 0..length as usize {
        let b = bytes[at + 12 + i];
        if !(0x20..0x7f).contains(&b) {
            return None;
        }
        text.push(b as char);
    }
    Some(text)
}

// ------------------------------------------------------- shared string table

#[derive(serde::Serialize)]
pub struct JscSharedTable {
    pub strings: Vec<Option<String>>,
    pub count: usize,
    pub resolved: usize,
    pub offset: usize,
    pub length: usize,
}

/// Sparse read: one slot per ordinal, holes stay None (the unbuned oracle's
/// dense-list shift bug is deliberately NOT ported — this is the documented
/// divergence, kept from the JS original).
pub fn read_jsc_shared_table(bytes: &[u8], offset: usize, length: usize) -> JscSharedTable {
    let empty = || JscSharedTable {
        strings: Vec::new(),
        count: 0,
        resolved: 0,
        offset,
        length,
    };
    if length < 8 || offset + length > bytes.len() {
        return empty();
    }
    let count = u32(bytes, offset) as usize;
    if !(1..=0x400_000).contains(&count) || 4 + count * 4 > length {
        return empty();
    }
    let end = offset + length;
    let mut strings: Vec<Option<String>> = vec![None; count];
    let mut resolved = 0usize;
    for (ordinal, slot) in strings.iter_mut().enumerate() {
        let record_at = u32(bytes, offset + 4 + ordinal * 4) as usize;
        let at = offset + record_at;
        if !record_at.is_multiple_of(4) || record_at < 8 || at + 8 > end {
            continue;
        }
        let flags = u32(bytes, at);
        let stored = u32(bytes, at + 4);
        let text_length = flags & 0x7FFF_FFFF;
        let width: u32 = if (flags >> 31) & 1 == 1 { 1 } else { 2 };
        // The span arithmetic is done in u64: on 32-bit targets (wasm32) the
        // u32 product and offset sum wrap, and a wrapped sum can pass this
        // bounds check before slicing past the buffer - a panic there, a
        // silent reject everywhere else.
        let byte_length = text_length as u64 * width as u64;
        if text_length == 0 || at as u64 + 8 + byte_length > end as u64 {
            continue;
        }
        let chars = &bytes[at + 8..at + 8 + byte_length as usize];
        if wtf_string_hash(chars) != stored {
            continue;
        }
        let mut text = String::with_capacity(text_length as usize);
        if width == 1 {
            for &b in chars {
                text.push(b as char);
            }
        } else {
            for unit in chars.as_chunks::<2>().0 {
                let code = unit[0] as u32 | ((unit[1] as u32) << 8);
                text.push(char::from_u32(code).unwrap_or('\u{FFFD}'));
            }
        }
        *slot = Some(text);
        resolved += 1;
    }
    JscSharedTable {
        strings,
        count,
        resolved,
        offset,
        length,
    }
}

/// Content-addressed table discovery: a zip of loose assets carries no module
/// graph, so the table is located by validating its own structure.
pub fn find_jsc_shared_table(bytes: &[u8]) -> Option<JscSharedTable> {
    if bytes.len() < 24 {
        return None;
    }
    let mut at = 0usize;
    while at + 16 <= bytes.len() {
        let count = u32(bytes, at) as usize;
        if !(8..=0x20_0000).contains(&count) {
            at += 4;
            continue;
        }
        if at + 4 + count * 4 + 8 > bytes.len() {
            at += 4;
            continue;
        }
        let probes = [0, count >> 1, count - 1];
        let mut last_offset: i64 = -1;
        let mut ok = true;
        for &probe in &probes {
            let record_at = u32(bytes, at + 4 + probe * 4) as usize;
            let rec = at + record_at;
            if !record_at.is_multiple_of(4) || record_at < 8 || rec + 8 > bytes.len() || record_at as i64 <= last_offset {
                ok = false;
                break;
            }
            last_offset = record_at as i64;
            let flags = u32(bytes, rec);
            let stored = u32(bytes, rec + 4);
            let text_length = flags & 0x7FFF_FFFF;
            let width: u32 = if (flags >> 31) & 1 == 1 { 1 } else { 2 };
            // u64 span math - see read_jsc_shared_table for the wasm32 wrap
            // this prevents.
            let byte_length = text_length as u64 * width as u64;
            if text_length == 0 || rec as u64 + 8 + byte_length > bytes.len() as u64 {
                ok = false;
                break;
            }
            if wtf_string_hash(&bytes[rec + 8..rec + 8 + byte_length as usize]) != stored {
                ok = false;
                break;
            }
        }
        if ok {
            let read = read_jsc_shared_table(bytes, at, bytes.len() - at);
            if read.resolved >= probes.len() {
                return Some(read);
            }
        }
        at += 4;
    }
    None
}

pub fn decode_jsc_slot(
    bytes: &[u8],
    field_at: usize,
    slot: u32,
    shared: Option<&[Option<String>]>,
    depth: usize,
) -> String {
    if slot == 0x7FFF_FFFF || slot == 0xFFFF_FFFF {
        return String::new();
    }
    let tag = slot & 3;
    match tag {
        1 => {
            let length = (slot >> 2) & 3;
            let mut text = String::new();
            for i in 0..length {
                let code = (slot >> (8 * (i + 1))) & 0xFF;
                text.push(char::from_u32(code).unwrap_or('\u{FFFD}'));
            }
            text
        }
        2 => {
            let ordinal = (slot >> 2) as usize;
            if let Some(strings) = shared {
                if ordinal < strings.len() {
                    if let Some(s) = &strings[ordinal] {
                        return s.clone();
                    }
                }
            }
            format!("<ordinal {ordinal}>")
        }
        0 if depth < 3 => {
            // field-relative pointer (signed 32-bit): the target is either
            // another slot (recursed) or an inline string record (fallback)
            let signed = slot as i32;
            let target = field_at as i64 + signed as i64;
            if target > 0 && target + 4 <= bytes.len() as i64 {
                let target = target as usize;
                let inner = u32(bytes, target);
                if inner & 3 <= 2 {
                    let decoded = decode_jsc_slot(bytes, target, inner, shared, depth + 1);
                    if !decoded.starts_with("<offset") {
                        return decoded;
                    }
                }
                if let Some(record) = read_jsc_inline_string(bytes, target as i64) {
                    return record;
                }
            }
            if target > 0 {
                format!("<offset {signed}>")
            } else {
                String::new()
            }
        }
        3 => format!("<slot {:x}>", slot),
        _ => String::new(),
    }
}

#[derive(Default, Debug, Clone, serde::Serialize)]
pub struct JscBlocksPresent {
    pub call: bool,
    pub construct: bool,
    pub name: bool,
    pub tdz: bool,
    pub rare: bool,
    pub metadata: bool,
}

pub struct JscExecutable {
    pub record: usize,
    pub parse_mode: u32,
    pub present: JscBlocksPresent,
    pub call_blocks: Option<Vec<JscBlockCandidate>>,
    pub call_empty: bool,
    pub construct_blocks: Option<Vec<JscBlockCandidate>>,
    pub construct_empty: bool,
    pub name: Option<String>,
    pub end: usize,
}

pub fn instantiate_jsc_exec(
    bytes: &[u8],
    record: usize,
    shared: Option<&[Option<String>]>,
) -> Option<JscExecutable> {
    if record < 0x20 || record + 32 > bytes.len() {
        return None;
    }
    let header = u32(bytes, record);
    let present = JscBlocksPresent {
        call: header & 1 != 0,
        construct: (header >> 1) & 1 != 0,
        name: (header >> 2) & 1 != 0,
        tdz: (header >> 3) & 1 != 0,
        rare: (header >> 4) & 1 != 0,
        metadata: (header >> 5) & 1 != 0,
    };
    let mut cursor = record + 4;
    if present.metadata {
        cursor += 4;
    }
    let table = jsc_opcode_table();
    let mut call_blocks: Option<Vec<JscBlockCandidate>> = None;
    let mut call_empty = false;
    let mut construct_blocks: Option<Vec<JscBlockCandidate>> = None;
    let mut construct_empty = false;
    for kind in 0..2 {
        let is_call = kind == 0;
        if !(if is_call { present.call } else { present.construct }) {
            continue;
        }
        if cursor + 4 > bytes.len() {
            return None;
        }
        let field_at = cursor;
        let value = i32(bytes, cursor);
        cursor += 4;
        if value == -1 {
            if is_call {
                call_empty = true;
            } else {
                construct_empty = true;
            }
            continue;
        }
        let target = field_at as i64 + value as i64;
        if target < 0x20 || target >= bytes.len() as i64 {
            continue;
        }
        let blocks = bind_jsc_block(bytes, target as usize, table);
        if is_call {
            call_blocks = Some(blocks);
        } else {
            construct_blocks = Some(blocks);
        }
    }
    let mut name: Option<String> = None;
    if present.name {
        if cursor + 4 > bytes.len() {
            return None;
        }
        let name_slot = u32(bytes, cursor);
        name = Some(decode_jsc_slot(bytes, cursor, name_slot, shared, 0));
        cursor += 4;
    }
    if present.tdz {
        cursor += 4;
    }
    if present.rare {
        cursor += 4;
    }
    Some(JscExecutable {
        record,
        parse_mode: (header >> 16) & 0xFF,
        present,
        call_blocks,
        call_empty,
        construct_blocks,
        construct_empty,
        name,
        end: cursor,
    })
}

fn jsc_block_children(bytes: &[u8], block: &JscBlockCandidate) -> Vec<(&'static str, i64)> {
    let mut children = Vec::new();
    let region = block.region;
    for &kind in &["fdecls", "fexprs"] {
        let Some((_, count, start)) = block.tail.arrays.iter().find(|(name, ..)| *name == kind) else {
            continue;
        };
        if *count == 0.0 {
            continue;
        }
        let base = region as f64 + *start;
        for index in 0..(*count as usize) {
            let slot_at = base + (index * 4) as f64;
            if slot_at + 4.0 > bytes.len() as f64 {
                break;
            }
            // JS reads through a negative index as undefined -> delta 0;
            // the child then fails the target >= 0x20 gate below.
            let delta = if slot_at >= 0.0 {
                i32(bytes, slot_at as usize) as i64
            } else {
                0
            };
            children.push((kind, slot_at as i64 + delta));
        }
    }
    children
}

// CachedTypes GenericCacheEntry (the first 16 bytes of every payload): stamp,
// tag (the format word), reserved callee-locals, payload size (== blob
// length). Tag 0 = Program (bun --bytecode's cjs default), 1 = Module.
fn parse_jsc_cache_entry(bytes: &[u8]) -> Option<(u32, usize)> {
    if bytes.len() < 0x30 {
        return None;
    }
    let tag = u32(bytes, 4);
    if tag != 0 && tag != 1 {
        return None;
    }
    if u32(bytes, 12) as usize != bytes.len() {
        return None;
    }
    let slot = u32(bytes, 0x2c) as i32;
    if slot <= 0 || slot == -1 {
        return None;
    }
    let record = 0x2c + slot as usize;
    if record < 0x30 || record + 0x38 >= bytes.len() {
        return None;
    }
    Some((tag, record))
}

#[derive(Debug, Clone, serde::Serialize, PartialEq, serde::Deserialize)]
pub struct JscBlockInfo {
    pub region: i64,
    #[serde(rename = "instrAt")]
    pub instr_at: usize,
    #[serde(rename = "instrLength")]
    pub instr_length: u64,
    #[serde(rename = "opCount")]
    pub op_count: usize,
    pub gap: u64,
}

#[derive(Debug, Clone, serde::Serialize, PartialEq, serde::Deserialize)]
pub struct JscFunction {
    pub name: Option<String>,
    pub kind: String,
    pub record: u64,
    #[serde(rename = "callBlock")]
    pub call_block: Option<JscBlockInfo>,
    #[serde(rename = "constructBlock")]
    pub construct_block: Option<JscBlockInfo>,
}

#[derive(Debug, Clone, serde::Serialize, PartialEq, serde::Deserialize)]
pub struct JscSharedTableInfo {
    pub source: String,
    pub ordinals: usize,
    #[serde(rename = "resolvedNames")]
    pub resolved_names: usize,
}

#[derive(Debug, Clone, serde::Serialize, PartialEq, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JscStats {
    pub valid: bool,
    pub root_name: Option<String>,
    pub root_parse_mode: Option<u32>,
    pub nodes: usize,
    pub blocks: usize,
    pub ops: usize,
    pub bind_failed: usize,
    pub functions: Vec<JscFunction>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub shared_table: Option<JscSharedTableInfo>,
}

fn block_info(c: &JscBlockCandidate) -> JscBlockInfo {
    JscBlockInfo {
        region: c.region,
        instr_at: c.instr_at,
        instr_length: c.instr_length as u64,
        op_count: c.op_count,
        gap: c.gap as u64,
    }
}

/// Decode a module's whole cached-function tree. One bad slot is counted,
/// not raised: a corrupt slot must not discard the rest.
pub fn analyze_jsc_module(bytes: &[u8], shared: Option<&[Option<String>]>) -> JscStats {
    let mut stats = JscStats {
        valid: false,
        root_name: None,
        root_parse_mode: None,
        nodes: 0,
        blocks: 0,
        ops: 0,
        bind_failed: 0,
        functions: Vec::new(),
        shared_table: None,
    };
    let mut pending: Vec<JscBlockCandidate> = Vec::new();
    let mut seen_blocks: HashSet<String> = HashSet::new();
    let mut seen_exec: HashSet<usize> = HashSet::new();

    let entry = parse_jsc_cache_entry(bytes);
    if let Some((0, code_block_record)) = entry {
        let candidates = bind_jsc_block(bytes, code_block_record, jsc_opcode_table());
        let program = candidates.iter().find(|c| c.gap == 0x38).cloned();
        let Some(program) = program else {
            return stats;
        };
        let root_name = decode_jsc_slot(bytes, 0x1c, u32(bytes, 0x1c), shared, 0);
        stats.root_name = if root_name.is_empty() { None } else { Some(root_name) };
        stats.root_parse_mode = Some(0);
        stats.nodes = 1;
        stats.functions.push(JscFunction {
            name: stats.root_name.clone(),
            kind: "root".to_string(),
            record: program.record as u64,
            call_block: Some(block_info(&program)),
            construct_block: None,
        });
        pending.push(program);
    } else {
        let Some(root) = instantiate_jsc_exec(bytes, 0x20, shared) else {
            return stats;
        };
        stats.root_name = root.name.clone();
        stats.root_parse_mode = Some(root.parse_mode);
        stats.nodes = 1;
        stats.functions.push(JscFunction {
            name: root.name.clone(),
            kind: "root".to_string(),
            record: root.record as u64,
            call_block: None,
            construct_block: None,
        });
        seen_exec.insert(root.record);
        for key in 0..2 {
            let (blocks, is_call) = if key == 0 {
                (&root.call_blocks, true)
            } else {
                (&root.construct_blocks, false)
            };
            let (present_kind, empty) = if is_call {
                (root.present.call, root.call_empty)
            } else {
                (root.present.construct, root.construct_empty)
            };
            let Some(blocks) = blocks else {
                if present_kind && !empty {
                    stats.bind_failed += 1;
                }
                continue;
            };
            pending.extend(blocks.iter().cloned());
            if let Some(best) = blocks.first() {
                let entry = &mut stats.functions[0];
                if is_call {
                    entry.call_block = Some(block_info(best));
                } else {
                    entry.construct_block = Some(block_info(best));
                }
            }
        }
    }

    while let Some(block) = pending.pop() {
        let identity = format!("{}:{}", block.record, block.gap);
        if seen_blocks.contains(&identity) {
            continue;
        }
        seen_blocks.insert(identity);
        stats.blocks += 1;
        stats.ops += block.op_count;
        for (kind, target) in jsc_block_children(bytes, &block) {
            if target < 0x20 || target >= bytes.len() as i64 - 32 {
                stats.bind_failed += 1;
                continue;
            }
            let Some(child) = instantiate_jsc_exec(bytes, target as usize, shared) else {
                stats.bind_failed += 1;
                continue;
            };
            let fresh = !seen_exec.contains(&child.record);
            let mut pushed_at: Option<usize> = None;
            if fresh {
                seen_exec.insert(child.record);
                stats.nodes += 1;
                stats.functions.push(JscFunction {
                    name: child.name.clone(),
                    kind: kind.to_string(),
                    record: child.record as u64,
                    call_block: None,
                    construct_block: None,
                });
                pushed_at = Some(stats.functions.len() - 1);
            }
            for key in 0..2 {
                let (blocks, is_call) = if key == 0 {
                    (&child.call_blocks, true)
                } else {
                    (&child.construct_blocks, false)
                };
                let (present_kind, empty) = if is_call {
                    (child.present.call, child.call_empty)
                } else {
                    (child.present.construct, child.construct_empty)
                };
                let Some(blocks) = blocks else {
                    if present_kind && !empty {
                        stats.bind_failed += 1;
                    }
                    continue;
                };
                pending.extend(blocks.iter().cloned());
                // The JS mutates the same `fn` object reference, so a fresh
                // child's pushed entry receives its blocks; a seen child's
                // local entry is discarded and the mutation is invisible.
                if let (Some(idx), Some(best)) = (pushed_at, blocks.first()) {
                    let entry = &mut stats.functions[idx];
                    if is_call {
                        entry.call_block = Some(block_info(best));
                    } else {
                        entry.construct_block = Some(block_info(best));
                    }
                }
            }
        }
    }
    stats.valid = stats.blocks > 0 && stats.bind_failed == 0;
    stats.functions.sort_by_key(|f| f.record);
    stats
}
