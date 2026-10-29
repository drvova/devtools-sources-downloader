// SHA-256 digests over text and bytes. The JS original falls back to FNV-1a
// when crypto.subtle is unavailable (non-secure browser contexts); Rust has
// no such constraint, so the real digest is always used.

use sha2::{Digest, Sha256};

pub fn sha256_hex(text: &str) -> String {
    hex(&Sha256::digest(text.as_bytes()))
}

pub fn sha256_hex_bytes(bytes: &[u8]) -> Option<String> {
    if bytes.is_empty() {
        return None;
    }
    Some(hex(&Sha256::digest(bytes)))
}

fn hex(digest: &[u8]) -> String {
    let mut out = String::with_capacity(digest.len() * 2);
    for b in digest {
        out.push_str(&format!("{b:02x}"));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stable_and_input_sensitive() {
        assert_eq!(sha256_hex("payload"), sha256_hex("payload"));
        assert_ne!(sha256_hex("payload"), sha256_hex("payload "));
        assert_eq!(sha256_hex("payload").len(), 64);
    }

    #[test]
    fn bytes_digest() {
        let a = [1u8, 2, 3, 255];
        assert_ne!(sha256_hex_bytes(&a), sha256_hex_bytes(&[1, 2, 3, 254]));
        assert_eq!(sha256_hex_bytes(&a), sha256_hex_bytes(&a));
        assert_eq!(sha256_hex_bytes(&[]), None);
    }
}
