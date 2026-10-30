//! Zip writer for the download archive.
//!
//! The panel used to assemble the archive in JavaScript (JSZip). The engine
//! already owns the file names, the report and the unpack output, so the
//! archive is written here instead: the panel collects the files it wants and
//! gets the finished bytes back.
//!
//! Deliberately small - entries are deflated (method 8) when that helps and
//! stored (method 0) when it does not, names are flagged UTF-8, and nothing
//! beyond the original format is emitted: no zip64, no data descriptors, no
//! encryption, no comments. Limits are refused rather than truncated, because
//! a silently truncated archive is worse than a failed one.
//!
//! Panics would trap the wasm module (`panic = "abort"`), so every failure
//! path returns `Err`.

use std::io::Write;
use std::sync::LazyLock;

use crate::util::civil_from_unix_secs;

const LOCAL_SIG: u32 = 0x0403_4b50;
const CENTRAL_SIG: u32 = 0x0201_4b50;
const EOCD_SIG: u32 = 0x0605_4b50;

const METHOD_STORE: u16 = 0;
const METHOD_DEFLATE: u16 = 8;

/// Bit 11: the name is UTF-8. The archive holds URLs and page titles.
const FLAG_UTF8: u16 = 0x0800;

/// 2.0 - the version that introduced deflate.
const VERSION: u16 = 20;

/// Original zip: 16-bit entry counts and 32-bit offsets.
const MAX_ENTRIES: usize = 0xFFFF;
const MAX_FIELD: u32 = u32::MAX;

/// DOS dates start at 1980; anything earlier is clamped to it.
const DOS_EPOCH_YEAR: i64 = 1980;
/// 2107 is the last year a DOS date can express.
const DOS_LAST_YEAR: i64 = 2107;

static CRC_TABLE: LazyLock<[u32; 256]> = LazyLock::new(|| {
    let mut table = [0u32; 256];
    for (index, slot) in table.iter_mut().enumerate() {
        let mut value = index as u32;
        for _ in 0..8 {
            value = if value & 1 == 1 {
                (value >> 1) ^ 0xEDB8_8320
            } else {
                value >> 1
            };
        }
        *slot = value;
    }
    table
});

/// CRC-32/ISO-HDLC, the checksum zip entries carry.
fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = 0xFFFF_FFFFu32;
    for byte in bytes {
        let index = ((crc ^ u32::from(*byte)) & 0xFF) as usize;
        crc = (crc >> 8) ^ CRC_TABLE[index];
    }
    !crc
}

/// DOS date and time words for a Unix millisecond stamp.
fn dos_stamp(ms: i64) -> (u16, u16) {
    let secs = (ms.max(0) / 1000) as u64;
    let (year, month, day, hour, minute, second) = civil_from_unix_secs(secs);
    if !(DOS_EPOCH_YEAR..=DOS_LAST_YEAR).contains(&year) {
        return (0, (1 << 5) | 1);
    }
    let date = (((year - DOS_EPOCH_YEAR) as u16) << 9) | ((month as u16) << 5) | day as u16;
    let time = ((hour as u16) << 11) | ((minute as u16) << 5) | (second as u16 / 2);
    (time, date)
}

/// Raw deflate (zip method 8), falling back to store when it does not help.
fn compress(raw: &[u8]) -> (u16, Vec<u8>) {
    let mut encoder =
        flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::default());
    if encoder.write_all(raw).is_err() {
        return (METHOD_STORE, raw.to_vec());
    }
    match encoder.finish() {
        Ok(deflated) if deflated.len() < raw.len() => (METHOD_DEFLATE, deflated),
        _ => (METHOD_STORE, raw.to_vec()),
    }
}

#[derive(Debug, Clone)]
struct Entry {
    name: String,
    method: u16,
    crc: u32,
    compressed: u32,
    uncompressed: u32,
    offset: u32,
}

/// Assembles one archive. Entries keep the order they were added in, which is
/// the order the panel lists them.
#[derive(Debug, Clone)]
pub struct ZipWriter {
    out: Vec<u8>,
    entries: Vec<Entry>,
    time: u16,
    date: u16,
}

impl Default for ZipWriter {
    fn default() -> Self {
        Self::new()
    }
}

impl ZipWriter {
    /// A writer whose entries are stamped with the DOS epoch (1980-01-01),
    /// which makes output for identical input byte-identical.
    pub fn new() -> Self {
        Self::with_ms(0)
    }

    /// A writer whose entries are stamped with a Unix millisecond time.
    pub fn with_ms(ms: i64) -> Self {
        let (time, date) = dos_stamp(ms);
        Self {
            out: Vec::new(),
            entries: Vec::new(),
            time,
            date,
        }
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Adds one file. `path` is stored verbatim; callers pass the names the
    /// reports already use.
    pub fn add(&mut self, path: &str, content: &[u8]) -> Result<(), String> {
        if self.entries.len() >= MAX_ENTRIES {
            return Err(format!(
                "zip entry limit reached ({MAX_ENTRIES}); refusing to write a truncated archive"
            ));
        }
        let name = path.as_bytes();
        if name.len() > MAX_FIELD as usize {
            return Err(format!("zip entry name too long: {} bytes", name.len()));
        }
        if content.len() > MAX_FIELD as usize {
            return Err(format!(
                "zip entry {path} is {} bytes; the original format caps entries at 4 GiB",
                content.len()
            ));
        }
        let offset = u32::try_from(self.out.len())
            .map_err(|_| "zip archive exceeds 4 GiB; refusing to write".to_string())?;
        let crc = crc32(content);
        let (method, body) = compress(content);

        let mut header = Vec::with_capacity(30 + name.len());
        header.extend_from_slice(&LOCAL_SIG.to_le_bytes());
        header.extend_from_slice(&VERSION.to_le_bytes());
        header.extend_from_slice(&FLAG_UTF8.to_le_bytes());
        header.extend_from_slice(&method.to_le_bytes());
        header.extend_from_slice(&self.time.to_le_bytes());
        header.extend_from_slice(&self.date.to_le_bytes());
        header.extend_from_slice(&crc.to_le_bytes());
        header.extend_from_slice(&(body.len() as u32).to_le_bytes());
        header.extend_from_slice(&(content.len() as u32).to_le_bytes());
        header.extend_from_slice(&(name.len() as u16).to_le_bytes());
        header.extend_from_slice(&0u16.to_le_bytes());
        header.extend_from_slice(name);

        self.out.extend_from_slice(&header);
        self.out.extend_from_slice(&body);
        self.entries.push(Entry {
            name: path.to_string(),
            method,
            crc,
            compressed: body.len() as u32,
            uncompressed: content.len() as u32,
            offset,
        });
        Ok(())
    }

    pub fn add_text(&mut self, path: &str, text: &str) -> Result<(), String> {
        self.add(path, text.as_bytes())
    }

    /// Writes the central directory and the end record, returning the archive.
    pub fn finish(mut self) -> Result<Vec<u8>, String> {
        let directory_offset =
            u32::try_from(self.out.len()).map_err(|_| "zip archive exceeds 4 GiB".to_string())?;
        let mut directory = Vec::new();
        for entry in &self.entries {
            directory.extend_from_slice(&CENTRAL_SIG.to_le_bytes());
            directory.extend_from_slice(&VERSION.to_le_bytes());
            directory.extend_from_slice(&VERSION.to_le_bytes());
            directory.extend_from_slice(&FLAG_UTF8.to_le_bytes());
            directory.extend_from_slice(&entry.method.to_le_bytes());
            directory.extend_from_slice(&self.time.to_le_bytes());
            directory.extend_from_slice(&self.date.to_le_bytes());
            directory.extend_from_slice(&entry.crc.to_le_bytes());
            directory.extend_from_slice(&entry.compressed.to_le_bytes());
            directory.extend_from_slice(&entry.uncompressed.to_le_bytes());
            directory.extend_from_slice(&(entry.name.len() as u16).to_le_bytes());
            directory.extend_from_slice(&0u16.to_le_bytes()); // extra
            directory.extend_from_slice(&0u16.to_le_bytes()); // comment
            directory.extend_from_slice(&0u16.to_le_bytes()); // disk
            directory.extend_from_slice(&0u16.to_le_bytes()); // internal attributes
            directory.extend_from_slice(&0o644u32.to_le_bytes()); // external: -rw-r--r--
            directory.extend_from_slice(&entry.offset.to_le_bytes());
            directory.extend_from_slice(entry.name.as_bytes());
        }
        let directory_size = u32::try_from(directory.len())
            .map_err(|_| "zip central directory exceeds 4 GiB".to_string())?;

        self.out.extend_from_slice(&directory);
        let count = self.entries.len() as u16;
        self.out.extend_from_slice(&EOCD_SIG.to_le_bytes());
        self.out.extend_from_slice(&0u16.to_le_bytes()); // this disk
        self.out.extend_from_slice(&0u16.to_le_bytes()); // disk with the directory
        self.out.extend_from_slice(&count.to_le_bytes());
        self.out.extend_from_slice(&count.to_le_bytes());
        self.out.extend_from_slice(&directory_size.to_le_bytes());
        self.out.extend_from_slice(&directory_offset.to_le_bytes());
        self.out.extend_from_slice(&0u16.to_le_bytes()); // comment
        Ok(self.out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;

    fn read_u16(bytes: &[u8], at: usize) -> u16 {
        u16::from_le_bytes([bytes[at], bytes[at + 1]])
    }

    fn read_u32(bytes: &[u8], at: usize) -> u32 {
        u32::from_le_bytes([bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]])
    }

    /// Independent parser: walks the central directory, then each local
    /// header, so a wrong offset or size cannot pass.
    fn parse(archive: &[u8]) -> Vec<(String, u16, Vec<u8>)> {
        let eocd = archive
            .windows(4)
            .rposition(|w| w == EOCD_SIG.to_le_bytes())
            .expect("end of central directory");
        let count = read_u16(archive, eocd + 10) as usize;
        let mut at = read_u32(archive, eocd + 16) as usize;
        let mut out = Vec::new();
        for _ in 0..count {
            assert_eq!(read_u32(archive, at), CENTRAL_SIG, "central header signature");
            let method = read_u16(archive, at + 10);
            let crc = read_u32(archive, at + 16);
            let compressed = read_u32(archive, at + 20) as usize;
            let name_len = read_u16(archive, at + 28) as usize;
            let local = read_u32(archive, at + 42) as usize;
            let name = String::from_utf8(archive[at + 46..at + 46 + name_len].to_vec()).unwrap();

            assert_eq!(read_u32(archive, local), LOCAL_SIG, "local header signature");
            let local_name_len = read_u16(archive, local + 26) as usize;
            let local_extra = read_u16(archive, local + 28) as usize;
            let start = local + 30 + local_name_len + local_extra;
            let raw = archive[start..start + compressed].to_vec();
            // both header copies carry the crc of the UNCOMPRESSED content
            assert_eq!(
                read_u32(archive, local + 14),
                crc,
                "local header crc matches the central one"
            );
            let body = if method == METHOD_DEFLATE {
                let mut text = Vec::new();
                flate2::read::DeflateDecoder::new(raw.as_slice())
                    .read_to_end(&mut text)
                    .expect("inflate entry");
                text
            } else {
                raw
            };
            assert_eq!(crc32(&body), crc, "central crc");
            out.push((name, method, body));
            at += 46 + name_len;
        }
        out
    }

    #[test]
    fn crc32_matches_the_standard_check_value() {
        assert_eq!(crc32(b""), 0);
        assert_eq!(crc32(b"123456789"), 0xCBF4_3926);
    }

    #[test]
    fn round_trips_text_and_binary_entries() {
        let mut writer = ZipWriter::new();
        writer.add_text("_unpack/index.json", "{\"ok\":true}").unwrap();
        // compressible: deflate should win
        writer
            .add("demo.test/app/bundle.js", &b"function f(){return 1;}\n".repeat(40))
            .unwrap();
        // incompressible: store should win (xorshift32 bytes, no structure to find)
        let mut state = 0x1234_5678u32;
        let noise: Vec<u8> = (0..512)
            .map(|_| {
                state ^= state << 13;
                state ^= state >> 17;
                state ^= state << 5;
                (state >> 24) as u8
            })
            .collect();
        writer.add("demo.test/raw.bin", &noise).unwrap();
        let archive = writer.finish().unwrap();

        let entries = parse(&archive);
        assert_eq!(entries.len(), 3);
        assert_eq!(entries[0].0, "_unpack/index.json");
        assert_eq!(entries[0].2, b"{\"ok\":true}");
        assert_eq!(entries[1].1, METHOD_DEFLATE);
        assert_eq!(entries[1].2, b"function f(){return 1;}\n".repeat(40));
        assert_eq!(entries[2].0, "demo.test/raw.bin");
        assert_eq!(entries[2].1, METHOD_STORE);
        assert_eq!(entries[2].2, noise);
    }

    #[test]
    fn writes_no_directory_entries() {
        // JSZip added an entry for every parent folder; extractors do not need
        // them (each file carries its full path), so only real files are
        // written. Pinned here so the difference stays deliberate.
        let mut writer = ZipWriter::new();
        writer.add_text("_unpack/0000-x/a/b/c.js", "x").unwrap();
        let entries = parse(&writer.finish().unwrap());
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].0, "_unpack/0000-x/a/b/c.js");
    }

    #[test]
    fn identical_input_produces_identical_bytes() {
        let build = || {
            let mut writer = ZipWriter::new();
            writer.add_text("a.txt", "alpha").unwrap();
            writer.add("b.bin", &[0, 1, 2, 3, 255]).unwrap();
            writer.finish().unwrap()
        };
        assert_eq!(build(), build());
    }

    #[test]
    fn dos_stamp_encodes_a_known_date() {
        // 2026-01-01T00:00:00Z -> year offset 46, January, day 1, midnight
        let (time, date) = dos_stamp(1_767_225_600_000);
        assert_eq!(date, (46 << 9) | (1 << 5) | 1);
        assert_eq!(time, 0);
        // before 1980 clamps to the epoch rather than encoding an invalid date
        assert_eq!(dos_stamp(0), (0, (1 << 5) | 1));
    }

    #[test]
    fn refuses_more_entries_than_the_format_holds() {
        let mut writer = ZipWriter::new();
        for index in 0..MAX_ENTRIES {
            writer.add(&format!("f{index}"), b"x").unwrap();
        }
        assert_eq!(writer.len(), MAX_ENTRIES);
        let error = writer.add("one-too-many", b"x").unwrap_err();
        assert!(error.contains("entry limit"), "{error}");
    }
}
