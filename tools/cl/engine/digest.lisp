;;;; digest.lisp — SHA-256 digests, ported from digest.rs.
;;;;
;;;; The original JavaScript fell back to FNV-1a when `crypto.subtle` was
;;;; unavailable (a non-secure browser context). Neither Rust nor this port has
;;;; that constraint, so the real digest is always used - the FNV fallback is
;;;; deliberately absent, as PORTING.md records.

(in-package :vovas.engine.digest)

(defun octets-of (string)
  "The UTF-8 bytes of STRING as an octet vector. ironclad's digest functions
take octet input, so every string digest goes through here rather than
depending on how the implementation treats characters internally."
  (sb-ext:string-to-octets string :external-format :utf-8))

(defun hex-of (octets)
  "Lowercase hex, two digits per byte.

`(format nil \"~2,'0x\" b)` looks right and is not: SBCL's `~x` honours
`*print-case*` behaviour via the `:X`-less directive differently than expected
and emits UPPERCASE, so the digest compared unequal to the oracle purely on
case. Building each byte from a lowercase digit table is unambiguous."
  (with-output-to-string (s)
    (loop with digits = "0123456789abcdef"
          for b across octets
          do (write-char (char digits (ash b -4)) s)
             (write-char (char digits (logand b #x0F)) s))))

(defun sha256-hex (text)
  "`sha256Hex(text)`: the hex digest of TEXT's UTF-8 bytes."
  (hex-of (ironclad:digest-sequence :sha256 (octets-of text))))

(defun sha256-hex-bytes (bytes)
  "`sha256HexBytes(bytes)`: the hex digest of BYTES, or NIL for empty input.

The empty case is not a shortcut - it is the original's early return, and the
oracle pins it: an empty asset has no digest rather than the digest of nothing."
  (when (or (null bytes) (zerop (length bytes)))
    (return-from sha256-hex-bytes nil))
  (hex-of (ironclad:digest-sequence :sha256
                                    (if (vectorp bytes)
                                        bytes
                                        (coerce bytes '(vector (unsigned-byte 8)))))))
