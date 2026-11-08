;;;; zip.lisp — the download archive, ported from zip.rs.
;;;;
;;;; The panel used to assemble the archive in JavaScript (JSZip). The engine
;;;; already owns the file names, the report and the unpack output, so it writes
;;;; the archive itself and the panel only collects the files.
;;;;
;;;; WHAT THIS PORT DOES NOT EMIT, because the Rust does not either: no zip64,
;;;; no data descriptors, no encryption, no comments, no directory entries. A
;;;; limit that cannot be represented is REFUSED with an error rather than
;;;; truncated, because a silently truncated archive downloads fine and is
;;;; simply missing files - the failure that costs a user their day.
;;;;
;;;; DEFLATE IS RAW. `flate2::write::DeflateEncoder` writes a raw deflate
;;;; stream (RFC 1951) with no zlib wrapper (RFC 1950), and that is not a style
;;;; choice: a zip member's compressed bytes ARE the raw stream, so a zlib
;;;; header inside the member makes the member unreadable. salza2's
;;;; `deflate-compressor` is the raw one (`zlib-compressor` adds the wrapper),
;;;; and the gate asserts the distinction rather than trusting it.
;;;;
;;;; DEFLATE IS ALSO NOT ALWAYS A WIN. `compress` keeps whichever of the two
;;;; bodies is SHORTER, and the gate pins that a repetitive payload really is
;;;; deflated while an incompressible one is stored - a port that always stored
;;;; would produce a valid archive that is merely enormous, and only a size
;;;; assertion can see the difference.
;;;;
;;;; TIMESTAMPS. DOS dates start at 1980 and end at 2107; outside that range the
;;;; entry is stamped with the epoch instead of an overflowing bitfield. The
;;;; epoch stamp is also what makes output for identical input byte-identical,
;;;; which the Rust pins with a test and this port pins with one too.
;;;;
;;;; WHY `civil-from-unix-secs` LIVES HERE. It is `util.rs`'s function, but
;;;; `util.lisp` does not carry it yet and this module is its only caller on
;;;; this tier. It is duplicated here rather than edited into another module's
;;;; file - the integrator merges it into `vovas.engine.util` when the date
;;;; formatters that also need it land, and this definition is then deleted.
;;;;
;;;; NO BYTE-IDENTICAL-TO-RUST ORACLE EXISTS for this module and none can be
;;;; written: flate2 and salza2 are different compressors and emit different
;;;; (equally valid) deflate streams for the same input. The gate is therefore a
;;;; ROUND-TRIP gate plus a FOREIGN-ARCHIVE gate: the archive is read back by
;;;; this module's own reader, and additionally a 443-byte archive produced by
;;;; CPython's `zipfile` - a third implementation - is read and its contents
;;;; compared. The format is self-checking (signatures, offsets, a CRC per
;;;; entry), so reading a foreign archive back correctly is a stronger statement
;;;; than byte equality with one particular encoder would be.

(defpackage :vovas.engine.zip
  (:use :cl)
  ;; No `:import-from`: `vovas.engine.decoders` exports only `decode-escapes` -
  ;; `decode-base64-to-bytes` was appended to that file for the source-map slice
  ;; and is not on its export list yet. Reaching it with `::` is deliberate: the
  ;; alternative is a second base64 implementation here, and the decoders'
  ;; normalisation (whitespace stripped, URL-safe alphabet folded, padding
  ;; appended) is exactly the behaviour the panel depends on.
  (:export
   ;; the writer
   #:make-zip-writer
   #:zip-writer-add
   #:zip-writer-add-text
   #:zip-writer-finish
   #:zip-writer-count
   #:zip-writer-empty-p
   #:zip-writer
   ;; the reader
   #:read-archive
   #:find-end-record
   #:read-u16
   #:read-u32
   #:zip-read-entry
   #:zip-read-entry-name
   #:zip-read-entry-method
   #:zip-read-entry-body
   #:zip-read-entry-crc
   #:zip-read-entry-compressed
   #:zip-read-entry-uncompressed
   #:zip-read-entry-offset
   #:zip-end-record
   #:zip-end-record-count
   #:zip-end-record-at
   #:zip-end-record-disk-count
   #:zip-end-record-directory-size
   #:zip-end-record-directory-offset
   ;; checksums, stamps, codecs
   #:crc32
   #:dos-stamp
   #:civil-from-unix-secs
   #:deflate-raw
   #:inflate-raw
   #:compress-entry
   ;; the pipeline entry point
   #:build-zip
   ;; failures and the format's fixed values
   #:zip-error
   #:zip-error-message
   #:+local-sig+ #:+central-sig+ #:+eocd-sig+
   #:+method-store+ #:+method-deflate+ #:+flag-utf8+ #:+version+
   #:*max-entries* #:*max-field*
   #:+dos-epoch-year+ #:+dos-last-year+
   #:*inflate-slack*))

(in-package :vovas.engine.zip)

;;; ---------------------------------------------------------------------------
;;; The format's fixed values
;;;
;;; `defparameter` rather than `defconstant` throughout: reloading a file that
;;; re-evaluates a `defconstant` is a nuisance, and three of these
;;; (`*max-entries*`, `*max-field*`, `*inflate-slack*`) are rebound by the gate
;;; to reach the refusal paths without allocating four gigabytes.
;;; ---------------------------------------------------------------------------

(defparameter +local-sig+ #x04034B50
  "Local file header signature, `PK\\x03\\x04` read little-endian.")

(defparameter +central-sig+ #x02014B50
  "Central directory header signature, `PK\\x01\\x02`.")

(defparameter +eocd-sig+ #x06054B50
  "End of central directory signature, `PK\\x05\\x06`.")

(defparameter +method-store+ 0
  "Store: the body is the content, byte for byte.")

(defparameter +method-deflate+ 8
  "Deflate: the body is a RAW deflate stream (RFC 1951), no zlib wrapper.")

(defparameter +flag-utf8+ #x0800
  "General-purpose bit 11: the entry name is UTF-8. Always set here - the
archive holds URLs and page titles, and a name that is not ASCII would otherwise
be ambiguous between code pages.")

(defparameter +version+ 20
  "2.0, the version that introduced deflate.")

(defparameter *max-entries* #xFFFF
  "16-bit entry counts: the original format's ceiling. `zip-writer-add` refuses
the entry AFTER this many instead of letting the EOCD count wrap.")

(defparameter *max-field* #xFFFFFFFF
  "Every 32-bit field's ceiling: sizes, offsets, name lengths.")

(defparameter +dos-epoch-year+ 1980
  "DOS dates start at 1980; anything earlier is clamped to it.")

(defparameter +dos-last-year+ 2107
  "2107 is the last year a DOS date can express (1980 + 127).")

;;; ---------------------------------------------------------------------------
;;; Conditions
;;; ---------------------------------------------------------------------------

(define-condition zip-error (error)
  ((message :initarg :message :reader zip-error-message))
  (:report (lambda (condition stream)
             (write-string (zip-error-message condition) stream)))
  (:documentation
   "Every refusal this module raises. The Rust returns `Err(String)`; a Lisp
port signals, and one condition class means `build-zip` has one thing to
propagate and the gate has one thing to catch."))

;;; ---------------------------------------------------------------------------
;;; Byte sequences
;;; ---------------------------------------------------------------------------

(defun octets-of (value)
  "VALUE as an octet vector: strings become their UTF-8 bytes.

This module hashes and measures BYTES everywhere, never characters, because
every field in the format counts bytes and `(length \"ünïcode\")` is not the
number that goes in the header. A string argument is therefore a convenience,
not a different mode."
  (cond
    ((stringp value)
     (sb-ext:string-to-octets value :external-format :utf-8))
    ;; A `(typep ... '(vector (unsigned-byte 8)))` test is NOT enough here: an
    ;; adjustable vector with a fill pointer - which is exactly what
    ;; `decode-base64-to-bytes` answers - satisfies the type but not salza2's
    ;; `(simple-array (unsigned-byte 8) (*))` declaration, and `coerce` on such a
    ;; vector can hand the adjustable object straight back. Copying into a fresh
    ;; simple array is the only form both libraries accept.
    ((typep value '(simple-array (unsigned-byte 8) (*))) value)
    ((and (vectorp value)
          (every (lambda (byte) (typep byte '(unsigned-byte 8))) value))
     (let ((copy (make-array (length value) :element-type '(unsigned-byte 8))))
       (replace copy value)
       copy))
    (t (error 'zip-error
              :message (format nil "expected an octet sequence, got a ~s"
                               (type-of value))))))

;;; ---------------------------------------------------------------------------
;;; CRC-32/ISO-HDLC — the checksum zip entries carry
;;; ---------------------------------------------------------------------------

(defparameter *crc32-table*
  (let ((table (make-array 256 :element-type '(unsigned-byte 32))))
    (dotimes (index 256 table)
      (let ((value index))
        (dotimes (bit 8)
          (declare (ignore bit))
          (setf value (if (oddp value)
                          (logxor (ash value -1) #xEDB88320)
                          (ash value -1))))
        (setf (aref table index) (logand #xFFFFFFFF value))))))

(defun crc32 (bytes)
  "CRC-32/ISO-HDLC of BYTES.

The final complement is not decoration: without the `logxor #xFFFFFFFF` before
returning, every value is wrong by a bitwise-not, which still looks like a
plausible checksum and passes any test that only compares two of this port's own
outputs. The gate pins the standard check value for exactly this reason."
  (let ((crc #xFFFFFFFF)
        (data (octets-of bytes)))
    (dotimes (i (length data) (logxor crc #xFFFFFFFF))
      (setf crc (logxor (ash crc -8)
                        (aref *crc32-table*
                              (logand #xFF (logxor crc (aref data i)))))))))

;;; ---------------------------------------------------------------------------
;;; Civil dates — Howard Hinnant's days-to-civil algorithm
;;; ---------------------------------------------------------------------------

(defun civil-from-unix-secs (secs)
  "SECS since the Unix epoch as (values year month day hour minute second).

`util.rs`'s `civil_from_unix_secs`, transcribed. The constants are not magic:
719468 days is the offset from 0000-03-01 to 1970-01-01 in the proleptic
Gregorian calendar, and 146097 days is one 400-year era. Shifting the year to
start in March puts the leap day at the END of the year, which is what makes the
`(153*mp+2)/5` month computation a single expression instead of a table.

Every division here is on a non-negative operand, so CL's `floor` and Rust's `/`
agree; the year is never negative because SECS is clamped before this is called.
"
  (multiple-value-bind (days rem) (floor (max secs 0) 86400)
    (let* ((z (+ days 719468))
           (era (floor z 146097))
           (doe (- z (* era 146097)))                                  ; [0, 146096]
           (yoe (floor (- doe
                           (floor doe 1460)
                           (- (floor doe 36524))
                           (floor doe 146096))
                       365))                                           ; [0, 399]
           (y (+ yoe (* era 400)))
           (doy (- doe (+ (* 365 yoe) (floor yoe 4) (- (floor yoe 100))))) ; [0, 365]
           (mp (floor (+ (* 5 doy) 2) 153))                            ; [0, 11]
           (d (+ (- doy (floor (+ (* 153 mp) 2) 5)) 1))                ; [1, 31]
           (m (if (< mp 10) (+ mp 3) (- mp 9))))                       ; [1, 12]
      (values (if (<= m 2) (1+ y) y)
              m
              d
              (floor rem 3600)
              (floor (mod rem 3600) 60)
              (mod rem 60)))))

(defun dos-stamp (ms)
  "The DOS (values time date) words for a Unix millisecond stamp.

Two details the format forces:

  - Milliseconds are truncated to seconds (the field has 2-second resolution
    anyway), and a negative stamp is clamped to zero, so an unset clock produces
    the epoch rather than a pre-1980 date.
  - A year outside 1980..2107 returns the epoch stamp rather than shifting a
    negative or overflowing year into the 7-bit field, where it would decode as
    some unrelated but perfectly plausible date.

The RETURN ORDER is (time, date), which is the Rust's order and the reverse of
how the two words appear in the header. Swapping them yields an archive every
extractor shows with a nonsense date and nothing else notices.
"
  (multiple-value-bind (year month day hour minute second)
      (civil-from-unix-secs (floor (max ms 0) 1000))
    (if (or (< year +dos-epoch-year+) (> year +dos-last-year+))
        ;; 1980-01-01 00:00:00, assembled with the same shifts as the general
        ;; case so the sentinel cannot drift away from the encoding below.
        (values 0 (logior (ash 1 5) 1))
        (values (logior (ash hour 11) (ash minute 5) (floor second 2))
                (logior (ash (- year +dos-epoch-year+) 9)
                        (ash month 5)
                        day)))))

;;; ---------------------------------------------------------------------------
;;; Raw deflate / inflate
;;; ---------------------------------------------------------------------------

(defparameter *inflate-slack* 4
  "Zero bytes appended to a member before handing it to chipz.

chipz's inflate reaches the final block's end-of-block symbol and then wants one
more READ before it will call the stream finished - with the member's exact
bytes it can signal `premature-end-of-stream` from its own `finish-dstate` even
though every byte decoded. A conforming inflater ignores bytes after the final
block, so the slack changes nothing about the decoded content.

It does, however, hide truncation: a stream cut three bytes short decodes to a
SHORTER body without complaint. That is why `read-archive` verifies the
uncompressed size AND the CRC of every member it inflates instead of trusting
the inflate call to have failed.")

(defparameter *inflate-slack-bytes*
  (make-array *inflate-slack* :element-type '(unsigned-byte 8) :initial-element 0)
  "The slack, allocated once per load. Never written through.")

(defun deflate-raw (bytes)
  "BYTES compressed as a raw deflate stream: no zlib header, no Adler-32 tail.

salza2's `deflate-compressor` is the raw one; `zlib-compressor` is the same
compressor wrapped in RFC 1950 framing. Using the wrapper here would put a
two-byte header inside every zip member, which every extractor rejects because
the member's bytes are supposed to be the stream itself.

EMPTY INPUT IS ENCODED DIRECTLY, and this is not a shortcut around a limit - it
is salza2 being wrong for that one case. Its compressor starts a fixed-Huffman
final block and then emits an end-of-block symbol per input octet with no source
to copy from, so zero input produces 210 bytes that inflate to 32 KiB of zeros.
RFC 1951 §3.2.6 spells the correct empty stream out exactly: one BFINAL=1,
BTYPE=01 block whose body is only the end-of-block code, which is the two octets
#x03 #x00. Both the round-trip assertion in the gate and CPython's zlib read that
as the empty sequence. `compress-entry` never chooses deflate for an empty body
(210 bytes loses to 0), so this branch exists for `deflate-raw` as a primitive -
and because a primitive that lies about its input domain is a trap for the next
caller."
  (let ((data (octets-of bytes)))
    (if (zerop (length data))
        (octets-of (vector #x03 #x00))
        (salza2:compress-data data 'salza2:deflate-compressor))))

(defun inflate-raw (bytes)
  "The content of a raw deflate stream.

Signals `zip-error` for input that is not a deflate stream at all (a zlib
member, garbage, a reserved block type) instead of letting a chipz condition
escape, so callers see one failure vocabulary."
  (let* ((data (octets-of bytes))
         (padded (concatenate '(vector (unsigned-byte 8))
                              data *inflate-slack-bytes*)))
    (handler-case (chipz:decompress nil 'chipz:deflate padded)
      (chipz:chipz-error (cause)
        (error 'zip-error :message (format nil "inflate failed: ~a" cause))))))

(defun compress-entry (raw)
  "The (values method body) a zip entry uses for RAW.

Deflate only when it actually helps: `deflated.len() < raw.len()`, strictly.
The strict `<` matters twice - content that does not shrink would otherwise be
stored with method 8 and a same-size body (legal and pointless), and an EMPTY
entry compresses to a 210-byte buffer in salza2, which is longer than nothing at
all.

The Rust also falls back to store when its encoder reports a write error;
salza2 writes to memory and has no such failure, so the size comparison is the
only fallback left. A compressor error is NOT swallowed: it would mean the zlib
implementation itself is broken, which must be loud."
  (let ((deflated (deflate-raw raw)))
    (if (< (length deflated) (length raw))
        (values +method-deflate+ deflated)
        (values +method-store+ (octets-of raw)))))

;;; ---------------------------------------------------------------------------
;;; Entry records
;;; ---------------------------------------------------------------------------

(defstruct (zip-entry (:constructor %make-zip-entry))
  "One writer bookkeeping record: what the local header and the central record
both need. Kept as a struct rather than a plist so a typo in a field name is a
compile-time-ish error instead of a silently NIL offset."
  (name "" :type string :read-only t)
  (method +method-store+ :type (unsigned-byte 16) :read-only t)
  (crc 0 :type (unsigned-byte 32) :read-only t)
  (compressed 0 :type (unsigned-byte 32) :read-only t)
  (uncompressed 0 :type (unsigned-byte 32) :read-only t)
  (offset 0 :type (unsigned-byte 32) :read-only t))

(defstruct (zip-read-entry (:constructor %make-zip-read-entry))
  "One entry as READ BACK: the decoded body plus what the directory claimed
about it. The claimed sizes are kept because a gate that only compared bodies
could not tell a correct `compressed` field from a wrong one."
  (name "" :type string :read-only t)
  (method +method-store+ :type (unsigned-byte 16) :read-only t)
  (body #() :read-only t)
  (crc 0 :type (unsigned-byte 32) :read-only t)
  (compressed 0 :type (unsigned-byte 32) :read-only t)
  (uncompressed 0 :type (unsigned-byte 32) :read-only t)
  (offset 0 :type (unsigned-byte 32) :read-only t))

(defstruct (zip-end-record (:constructor %make-zip-end-record))
  "The end-of-central-directory record, as found."
  (count 0 :type (unsigned-byte 16) :read-only t)
  (disk-count 0 :type (unsigned-byte 16) :read-only t)
  (directory-size 0 :type (unsigned-byte 32) :read-only t)
  (directory-offset 0 :type (unsigned-byte 32) :read-only t)
  (at 0 :type fixnum :read-only t))

;;; ---------------------------------------------------------------------------
;;; Little-endian output
;;;
;;; Rust appends to a `Vec<u8>`; here the archive lives in one adjustable octet
;;; vector with a fill pointer, so appending is `vector-push-extend` and
;;; reading it back is a `subseq` of the live region. Nothing is allocated per
;;; entry, which matters because the entry ceiling is 65535.
;;; ---------------------------------------------------------------------------

(defun make-octet-buffer (&optional (capacity 1024))
  "An adjustable octet vector with a fill pointer, initially empty."
  (make-array capacity :element-type '(unsigned-byte 8)
                       :adjustable t :fill-pointer 0))

(defun buffer-append (buffer octets)
  "Append OCTETS to BUFFER's live region, growing as needed."
  (loop for byte across octets do (vector-push-extend byte buffer))
  buffer)

(defun buffer-contents (buffer)
  "BUFFER's live region as a fresh simple octet vector.

A copy, not a displaced view: the writer keeps its buffer inside the
`zip-writer` object, and answering a view would let a caller's finished archive
change if the writer were touched afterwards."
  (subseq buffer 0 (fill-pointer buffer)))

(defun put-u16 (buffer value)
  "Append VALUE as 2 little-endian octets."
  (vector-push-extend (logand #xFF value) buffer)
  (vector-push-extend (logand #xFF (ash value -8)) buffer))

(defun put-u32 (buffer value)
  "Append VALUE as 4 little-endian octets."
  (vector-push-extend (logand #xFF value) buffer)
  (vector-push-extend (logand #xFF (ash value -8)) buffer)
  (vector-push-extend (logand #xFF (ash value -16)) buffer)
  (vector-push-extend (logand #xFF (ash value -24)) buffer))

(defun read-u16 (bytes at)
  "The 2-octet little-endian word at AT. Mirrors the Rust test's helper."
  (logior (aref bytes at) (ash (aref bytes (1+ at)) 8)))

(defun read-u32 (bytes at)
  "The 4-octet little-endian word at AT. Mirrors the Rust test's helper."
  (logior (aref bytes at)
          (ash (aref bytes (+ at 1)) 8)
          (ash (aref bytes (+ at 2)) 16)
          (ash (aref bytes (+ at 3)) 24)))

;;; ---------------------------------------------------------------------------
;;; The writer
;;; ---------------------------------------------------------------------------

(defstruct (zip-writer (:constructor %make-zip-writer (time date)))
  (out (make-octet-buffer 4096))
  (entries '())                 ; reversed while adding; nreversed by finish
  (time 0 :type (unsigned-byte 16))
  (date 0 :type (unsigned-byte 16))
  (finished-p nil))

(defun make-zip-writer (&key (ms 0))
  "A writer whose entries are stamped with the DOS date for MS.

`ms = 0` is the Rust's `ZipWriter::new()`: every entry stamped 1980-01-01
00:00:00, which is what makes two builds of the same input byte-identical."
  (multiple-value-bind (time date) (dos-stamp ms)
    (%make-zip-writer time date)))

(defun zip-writer-count (writer)
  "How many entries have been added."
  (length (zip-writer-entries writer)))

(defun zip-writer-empty-p (writer)
  "True when nothing has been added yet."
  (null (zip-writer-entries writer)))

(defun zip-writer-add (writer path content)
  "Add one file. PATH is stored verbatim; CONTENT is a string or octets.

Every refusal here has the same reason: the format has 16-bit entry counts and
32-bit sizes/offsets, and writing a value that does not fit would truncate it
into a plausible-looking archive rather than an obviously broken one. The Rust
refuses; so does this, with the same wording so a caller matching on the message
sees no difference.

Answers T. Signals `zip-error` when a limit is reached or the writer is spent."
  (when (zip-writer-finished-p writer)
    (error 'zip-error
           :message "zip writer already finished; the central directory has been written"))
  (when (>= (zip-writer-count writer) *max-entries*)
    (error 'zip-error
           :message (format nil
                            "zip entry limit reached (~a); refusing to write a truncated archive"
                            *max-entries*)))
  (let* ((name (octets-of path))
         (body (octets-of content))
         (name-length (length name))
         (out (zip-writer-out writer))
         (offset (fill-pointer out)))
    (when (> name-length *max-field*)
      (error 'zip-error
             :message (format nil "zip entry name too long: ~a bytes" name-length)))
    (when (> (length body) *max-field*)
      (error 'zip-error
             :message (format nil
                              "zip entry ~a is ~a bytes; the original format caps entries at 4 GiB"
                              path (length body))))
    (when (> offset *max-field*)
      (error 'zip-error :message "zip archive exceeds 4 GiB; refusing to write"))
    (multiple-value-bind (method stored) (compress-entry body)
      (let ((crc (crc32 body)))
        (put-u32 out +local-sig+)
        (put-u16 out +version+)
        (put-u16 out +flag-utf8+)
        (put-u16 out method)
        (put-u16 out (zip-writer-time writer))
        (put-u16 out (zip-writer-date writer))
        (put-u32 out crc)
        (put-u32 out (length stored))
        (put-u32 out (length body))
        ;; The Rust writes `name.len() as u16`, a CAST rather than a checked
        ;; conversion. This keeps the cast (`logand #xFFFF`) instead of adding a
        ;; check the original lacks: the reader decodes the same truncated
        ;; length, so both sides agree, and inventing an extra refusal would be
        ;; a divergence dressed up as a safety improvement. The 4 GiB bound
        ;; above is the only length check the original enforces.
        (put-u16 out (logand #xFFFF name-length))
        (put-u16 out 0)                              ; extra field length
        (buffer-append out name)
        (buffer-append out stored)
        (push (%make-zip-entry :name path
                               :method method
                               :crc crc
                               :compressed (length stored)
                               :uncompressed (length body)
                               :offset offset)
              (zip-writer-entries writer))))
    t))

(defun zip-writer-add-text (writer path text)
  "Add one text file: its UTF-8 bytes are the content."
  (zip-writer-add writer path text))

(defun zip-writer-finish (writer)
  "Write the central directory and the end record; answer the archive octets.

The Rust takes `self` by value, so finishing twice is impossible there; here the
writer is marked finished and a second call signals, because CL has no move
semantics and appending a second directory to a live writer would produce an
archive whose last EOCD points at the FIRST directory."
  (when (zip-writer-finished-p writer)
    (error 'zip-error :message "zip writer already finished"))
  (let* ((out (zip-writer-out writer))
         (entries (nreverse (zip-writer-entries writer)))
         (directory-offset (fill-pointer out)))
    (setf (zip-writer-entries writer) entries)
    (when (> directory-offset *max-field*)
      (error 'zip-error :message "zip archive exceeds 4 GiB"))
    (let ((directory (make-octet-buffer 1024)))
      (dolist (entry entries)
        (let ((name (octets-of (zip-entry-name entry))))
          (put-u32 directory +central-sig+)
          (put-u16 directory +version+)     ; version made by
          (put-u16 directory +version+)     ; version needed to extract
          (put-u16 directory +flag-utf8+)
          (put-u16 directory (zip-entry-method entry))
          (put-u16 directory (zip-writer-time writer))
          (put-u16 directory (zip-writer-date writer))
          (put-u32 directory (zip-entry-crc entry))
          (put-u32 directory (zip-entry-compressed entry))
          (put-u32 directory (zip-entry-uncompressed entry))
          (put-u16 directory (logand #xFFFF (length name)))
          (put-u16 directory 0)             ; extra field length
          (put-u16 directory 0)             ; file comment length
          (put-u16 directory 0)             ; disk number start
          (put-u16 directory 0)             ; internal attributes
          (put-u32 directory #o644)         ; external attributes: -rw-r--r--
          (put-u32 directory (zip-entry-offset entry))
          (buffer-append directory name)))
      (let ((directory-size (fill-pointer directory)))
        (when (> directory-size *max-field*)
          (error 'zip-error :message "zip central directory exceeds 4 GiB"))
        (buffer-append out (buffer-contents directory))
        (let ((count (mod (length entries) #x10000)))
          (put-u32 out +eocd-sig+)
          (put-u16 out 0)                   ; number of this disk
          (put-u16 out 0)                   ; disk with the directory
          (put-u16 out count)               ; entries on this disk
          (put-u16 out count)               ; entries in total
          (put-u32 out directory-size)
          (put-u32 out directory-offset)
          (put-u16 out 0))))                ; archive comment length
    (setf (zip-writer-finished-p writer) t)
    (buffer-contents out)))

;;; ---------------------------------------------------------------------------
;;; The reader
;;;
;;; zip.rs has no production reader - this is its TEST's independent parser,
;;; promoted here because the gate needs one and because the property that made
;;; it worth writing in the test is worth keeping: it walks the CENTRAL directory
;;; for names, offsets, sizes and CRCs, then walks each LOCAL header
;;; independently, so an entry written at a wrong offset or with a wrong size
;;; cannot pass. A reader that replayed the writer's own bookkeeping would prove
;;; nothing about the bytes.
;;;
;;; It is stricter than the Rust parser in one place, on purpose: it verifies
;;; the CRC and the uncompressed length of every body it inflates. `inflate-raw`
;;; appends slack so chipz will finish, and slack makes a truncated stream decode
;;; SHORT instead of failing; the length and CRC checks turn that silence back
;;; into an error.
;;; ---------------------------------------------------------------------------

(defun signature-at-p (bytes at signature)
  "True when the 4 octets at AT are SIGNATURE read little-endian."
  (and (<= (+ at 4) (length bytes))
       (= (read-u32 bytes at) signature)))

(defun find-end-record (archive)
  "The `zip-end-record` at the end of ARCHIVE.

Searched BACKWARDS: the EOCD is the last thing in the archive, and a four-byte
`PK\\x05\\x06` can occur inside a stored entry's content. Backwards from the end
wins that collision; forwards would stop at the decoy."
  (let ((bytes (octets-of archive)))
    (loop for at downfrom (- (length bytes) 22) to 0
          when (signature-at-p bytes at +eocd-sig+)
            return (%make-zip-end-record
                    :count (read-u16 bytes (+ at 10))
                    :disk-count (read-u16 bytes (+ at 8))
                    :directory-size (read-u32 bytes (+ at 12))
                    :directory-offset (read-u32 bytes (+ at 16))
                    :at at)
          finally (error 'zip-error
                         :message "no end of central directory record"))))

(defun decode-name (bytes start end)
  "The UTF-8 name in BYTES between START and END.

Signals rather than substituting replacement characters: a name that is not
UTF-8 means flag bit 11 - which this writer always sets - is a lie, and a
mangled name writes the file to a path nobody asked for."
  (handler-case (sb-ext:octets-to-string bytes :start start :end end
                                               :external-format :utf-8)
    ;; `sb-int:character-decoding-error`, not `sb-impl::octet-decoding-error`:
    ;; the latter is the internal name of the class SBCL signals for an invalid
    ;; UTF-8 starter byte, and the exported supertype is the one that a port can
    ;; name without reaching into `sb-impl`. Handlers on the internal name would
    ;; silently never match, which is worse than not catching at all.
    (sb-int:character-decoding-error ()
      (error 'zip-error
             :message (format nil "entry name at ~a..~a is not valid UTF-8"
                              start end)))))

(defun read-archive (archive)
  "Every entry in ARCHIVE as a list of `zip-read-entry`, in directory order.

Signals `zip-error` on a signature mismatch, a local header that disagrees with
the central one, a missing EOCD, an inflated body whose CRC or length disagrees
with what the directory claims, or a name that is not valid UTF-8."
  (let* ((bytes (octets-of archive))
         (end (find-end-record bytes))
         (count (zip-end-record-count end)))
    (loop with at = (zip-end-record-directory-offset end)
          for index below count
          collect
          (progn
            (unless (signature-at-p bytes at +central-sig+)
              (error 'zip-error
                     :message (format nil "central header signature at ~a (entry ~a)"
                                      at index)))
            (let* ((method (read-u16 bytes (+ at 10)))
                   (crc (read-u32 bytes (+ at 16)))
                   (compressed (read-u32 bytes (+ at 20)))
                   (uncompressed (read-u32 bytes (+ at 24)))
                   (name-length (read-u16 bytes (+ at 28)))
                   (local (read-u32 bytes (+ at 42)))
                   (name-start (+ at 46))
                   (name (decode-name bytes name-start (+ name-start name-length))))
              (unless (signature-at-p bytes local +local-sig+)
                (error 'zip-error
                       :message (format nil "local header signature for ~a at ~a"
                                        name local)))
              (let ((local-crc (read-u32 bytes (+ local 14))))
                ;; Both header copies carry the CRC of the UNCOMPRESSED content,
                ;; so they must agree; a writer that hashed the deflated body
                ;; would produce a mismatch here and nowhere else.
                (unless (= local-crc crc)
                  (error 'zip-error
                         :message (format nil
                                          "local header CRC ~8,'0x disagrees with central ~8,'0x for ~a"
                                          local-crc crc name))))
              (let* ((local-name-length (read-u16 bytes (+ local 26)))
                     (local-extra (read-u16 bytes (+ local 28)))
                     (start (+ local 30 local-name-length local-extra))
                     (raw (subseq bytes start (+ start compressed)))
                     (body (if (= method +method-deflate+)
                               (inflate-raw raw)
                               raw)))
                (unless (= (length body) uncompressed)
                  (error 'zip-error
                         :message (format nil
                                          "~a inflates to ~a bytes, directory says ~a"
                                          name (length body) uncompressed)))
                (let ((actual (crc32 body)))
                  (unless (= actual crc)
                    (error 'zip-error
                           :message (format nil
                                            "~a CRC ~8,'0x does not match the recorded ~8,'0x"
                                            name actual crc))))
                (incf at (+ 46 name-length))
                (%make-zip-read-entry :name name
                                      :method method
                                      :body body
                                      :crc crc
                                      :compressed compressed
                                      :uncompressed uncompressed
                                      :offset local)))))))

;;; ---------------------------------------------------------------------------
;;; build_zip — the pipeline entry point
;;; ---------------------------------------------------------------------------

(defun base64-payload (text)
  "Decode a base64 payload, or NIL.

Delegated to the decoders module so the repository has ONE base64
implementation: its normalisation (JS whitespace stripped, `-`/`_` folded to
`+`/`/`, `=` padding appended to a multiple of four) is what lets the panel send
an unpadded URL-safe payload, and it is not worth re-deriving here.

`::` rather than `:` because that function is not on the decoders package's
export list yet; the decoders slice appends it for the source-map module. A
missing function here would be a load error, not a silent NIL, because the
package is resolved at load time."
  (vovas.engine.decoders::decode-base64-to-bytes text))

(defun build-zip (files now-ms)
  "The download archive for FILES, stamped with NOW-MS.

FILES is a list of plists in the Rust `ZipFile` shape: `(:path \"...\" :content
\"...\")` for a text entry, `(:path \"...\" :base64 \"...\")` for a binary one.
`:base64` WINS when both are present, which is the Rust's `match &file.base64`
and matters because the panel fills `content` with an empty string for binary
files. A missing `:content` is the empty entry (the Rust's `unwrap_or_default`),
but a `:base64` that does not decode is an error: writing the entry empty would
silently drop the payload."
  (let ((writer (make-zip-writer :ms now-ms)))
    (dolist (file files)
      (let ((path (getf file :path))
            (encoded (getf file :base64)))
        (if encoded
            (let ((bytes (base64-payload encoded)))
              (unless bytes
                (error 'zip-error
                       :message (format nil "zip entry ~a: invalid base64 payload" path)))
              (zip-writer-add writer path bytes))
            (zip-writer-add-text writer path (or (getf file :content) "")))))
    (zip-writer-finish writer)))
