;;;; gate-zip.lisp — is the archive this port writes readable, and is it the
;;;; archive zip.rs describes?
;;;;
;;;; THE ORACLE QUESTION, FIRST, because this module is the odd one out.
;;;; Every other module in this port is checked against
;;;; `text-tier-oracle.json`, captured from the engine that actually ships. There
;;;; is no such capture here and there cannot be one: `build_zip` emits a
;;;; deflate stream, flate2 and salza2 are different compressors, and two
;;;; conforming compressors emit different bytes for the same input. A
;;;; byte-identical-to-Rust gate would be asserting which zlib implementation is
;;;; installed, not whether the archive is correct.
;;;;
;;;; So this gate is a ROUND-TRIP gate plus a FOREIGN-ARCHIVE gate, and the
;;;; second half is what keeps it honest:
;;;;
;;;;   ROUND TRIP. An archive with an empty entry, a large deflatable one, an
;;;;   incompressible binary one and a non-ASCII-named one is built and read
;;;;   back with this module's own reader. Names, methods, bodies and CRCs must
;;;;   survive, and the reader is deliberately the Rust TEST's parser - it walks
;;;;   the central directory for names/offsets/sizes and then each LOCAL header
;;;;   independently - so a wrong offset, a wrong size or a wrong CRC cannot
;;;;   pass by being consistent with itself.
;;;;
;;;;   FOREIGN ARCHIVE. A 443-byte archive built by CPython's `zipfile` is
;;;;   embedded below as hex and read by that same reader: three entries, one
;;;;   stored, two deflated, one with a non-ASCII name and the UTF-8 flag set.
;;;;   That is a third implementation's bytes, so the reader is proven against
;;;;   the format rather than against this writer. It is the strongest evidence
;;;;   available here, and it is why the round trip above is not circular: the
;;;;   reader has already been shown to consume bytes it did not produce.
;;;;
;;;; WHAT THIS GATE CANNOT SEE. There is no fixture and no oracle for the exact
;;;; compressed bytes, so "this deflate stream is the one flate2 would have
;;;; produced" is NOT asserted anywhere and no claim is made about it. What is
;;;; asserted is that deflate is used when it helps, is raw rather than
;;;; zlib-framed, and round-trips - which is the whole of the behaviour the
;;;; archive format and its consumers depend on.
;;;;
;;;; WHICH `zip.rs` TEST EACH ASSERTION COMES FROM. The Rust crate pins its own
;;;; behaviour in `mod tests`; those tests are the specification, so every one of
;;;; them has a counterpart here, named so a reader can check the mapping:
;;;;
;;;;   crc32_matches_the_standard_check_value  -> section 1 (both check values)
;;;;   dos_stamp_encodes_a_known_date          -> section 2 (2026-01-01, and the
;;;;                                              pre-1980 clamp)
;;;;   round_trips_text_and_binary_entries     -> section 5 (the same three
;;;;                                              entries: index.json, the
;;;;                                              repeated bundle line and the
;;;;                                              xorshift noise, plus the same
;;;;                                              method expectations)
;;;;   writes_no_directory_entries             -> section 7
;;;;   identical_input_produces_identical_bytes -> section 6
;;;;   refuses_more_entries_than_the_format_holds -> section 9 (the 65535-entry
;;;;                                              case, verbatim)
;;;;
;;;; Everything else here covers what those tests leave open: the foreign
;;;; archive, the zlib-framing distinction, the reader's refusals, `build-zip`'s
;;;; base64 handling, and the two dates in 2024 and 2107 the Rust test never
;;;; reaches.
;;;;
;;;; WRONG-IMPLEMENTATION PROBES. Eight plausible mistakes are checked by
;;;; showing that a NUMBER, a METHOD or an ERROR is not what the mistake would
;;;; produce: the CRC without its final complement, the CRC of the compressed
;;;; body instead of the content, the DOS time/date words swapped, the seconds
;;;; field not halved, a zlib-wrapped stream posing as raw deflate, a writer
;;;; that always deflates (or always stores), a name length counted in
;;;; characters, and an EOCD search that runs forwards into a decoy signature
;;;; inside a stored entry. A mutation sweep proved the whole gate is
;;;; non-vacuous by breaking the port thirteen ways and requiring a failure for
;;;; each; all thirteen were caught. The sweep earned its keep by finding SIX
;;;; gaps in an earlier draft of this file, each now closed by the assertion
;;;; that names it:
;;;;
;;;;   transposed DOS words        -> the header's time/date words, read from
;;;;                                 the bytes (sections 5), not just `dos-stamp`
;;;;   local compressed size       -> the local header's own size fields
;;;;   name counted in characters  -> the local name length, on the non-ASCII entry
;;;;   ceiling off by one          -> the 65535-then-refuse case (section 9)
;;;;   no length check             -> a directory that lies about the size
;;;;   forwards EOCD search        -> the decoy entry, now asserted STORED, since
;;;;                                 a deflated decoy has no signature to trip

(in-package :vovas.engine.gate)

;;; ---------------------------------------------------------------------------
;;; Local helpers
;;;
;;; `check` from gate.lisp compares with `equal`, which is right for octet
;;; vectors but cannot express "signals". `zip-probe` is the same bookkeeping for
;;; a boolean claim, and `zip-signals` runs a thunk and answers the condition
;;; so a `zip-error` expectation can be compared, not merely detected.
;;; ---------------------------------------------------------------------------

(defun zip-probe (result label ok input)
  (record result (and ok t) label input ok t))

(defun zip-signals (thunk)
  "THUNK's `zip-error-message`, or a marker naming what actually happened.

A non-zip condition is reported by TYPE rather than by being swallowed: a gate
that accepted any error would pass a port that crashed on the wrong line."
  (handler-case (progn (funcall thunk) :no-error)
    (vovas.engine.zip:zip-error (cause)
      (vovas.engine.zip:zip-error-message cause))
    (error (cause) (list :unexpected (type-of cause)))))

(defun zip-signals-containing-p (thunk fragment)
  "True when THUNK signals a zip-error whose message contains FRAGMENT."
  (let ((message (zip-signals thunk)))
    (and (stringp message) (search fragment message) t)))

(defun zip-octets (&rest bytes)
  (make-array (length bytes) :element-type '(unsigned-byte 8)
                             :initial-contents bytes))

(defun zip-octet-equal (a b)
  "Element-wise equality for two octet sequences.

`equal` cannot do this job: CL's `equal` is EQL on general vectors, so two
distinct octet vectors holding the same bytes compare unequal. Nearly every
assertion in this gate is about bytes, and without this helper they would all
fail against a correct port - which is exactly what happened on the first run."
  (and (= (length a) (length b))
       (loop for i below (length a) always (= (aref a i) (aref b i)))))

(defun zip-octet-check (result label input got want)
  "A `check` whose comparison is `zip-octet-equal`."
  (record result (zip-octet-equal got want) label input got want))

(defun zip-utf8 (text)
  (sb-ext:string-to-octets text :external-format :utf-8))

(defun zip-repeat-octets (bytes times)
  "BYTES repeated TIMES, as one octet vector."
  (let ((out (make-array (* (length bytes) times)
                         :element-type '(unsigned-byte 8))))
    (dotimes (i times out)
      (replace out bytes :start1 (* i (length bytes))))))

(defun zip-hex-octets (hex)
  "HEX (whitespace ignored, two digits per byte) as an octet vector.

The foreign archive is embedded as hex rather than as a fixture file because
there is no fixture directory for this module - the archive is one 443-byte
literal and a hex string keeps it inside the gate that uses it, where a reader
can see the format it is proving."
  (let* ((digits (remove-if (lambda (c) (find c " \t\r\n")) hex))
         (out (make-array (floor (length digits) 2)
                          :element-type '(unsigned-byte 8))))
    (loop for i from 0 below (length out)
          do (setf (aref out i)
                   (parse-integer digits :start (* 2 i) :end (+ 2 (* 2 i))
                                         :radix 16)))
    out))

(defun zip-entry-by-name (entries name)
  (find name entries :key #'vovas.engine.zip:zip-read-entry-name :test #'string=))

(defun zip-entry-names (entries)
  (mapcar #'vovas.engine.zip:zip-read-entry-name entries))

;;; ---------------------------------------------------------------------------
;;; The test payloads
;;;
;;; Four entries, one per property the writer has to get right:
;;;   - empty content: the strict `deflated < raw` comparison must fall to store
;;;   - highly repetitive text: must deflate, and must shrink a lot
;;;   - xorshift noise: no structure, so deflate must LOSE and store must win
;;;   - a non-ASCII name: the length field is UTF-8 bytes, not characters
;;; ---------------------------------------------------------------------------

(defparameter *zip-bundle-line* (zip-utf8 "function f(){return 1;}")
  "One line of the Rust test's compressible payload.

The trailing newline is appended as an OCTET below rather than written inside
the string literal. A raw newline in a literal is whatever the FILE's line
ending is: this file was saved CRLF once and the payload became 25 bytes a line
instead of 24, which silently changed every CRC and every size in this gate. The
one thing that must not depend on how the file was saved is the byte sequence
under test.")

(defparameter *zip-bundle-js*
  (zip-repeat-octets (concatenate '(vector (unsigned-byte 8))
                              *zip-bundle-line* (zip-octets #x0A))
                 40)
  "The Rust test's compressible payload: 40 lines of 24 bytes, 960 bytes.")

(defparameter *zip-noise*
  (let ((state #x12345678)
        (out (make-array 512 :element-type '(unsigned-byte 8))))
    (dotimes (i 512 out)
      ;; xorshift32, written out because a PRNG call would make the fixture
      ;; depend on the implementation's random state instead of on this text.
      (setf state (logxor state (logand #xFFFFFFFF (ash state 13))))
      (setf state (logand #xFFFFFFFF state))
      (setf state (logxor state (ash state -17)))
      (setf state (logand #xFFFFFFFF (logxor state (logand #xFFFFFFFF (ash state 5)))))
      (setf (aref out i) (ldb (byte 8 24) state))))
  "The Rust test's incompressible payload: 512 xorshift32 bytes, no structure
for deflate to find, so `compress` must choose store.")

(defparameter *zip-unicode-name* "ünïcode-ページ.html"
  "A name that is UTF-8-longer than it is character-long: 16 characters, 24
bytes. The header carries the byte count, so a port that wrote
`(length name)` would put 16 in the field and every extractor would read the last
eight bytes of the name as the entry's first eight content bytes.")

(defparameter *zip-foreign-hex*
  (concatenate 'string
    "504b03041400000000000000215c905fd4a70b0000000b000000120000005f756e7061636b2f696e6465782e6a736f6e"
    "7b226f6b223a747275657d504b03041400000008000000215c90d0d2eb23000000c00300001700000064656d6f2e7465"
    "73742f6170702f62756e646c652e6a734b2bcd4b2ec9cccf5348d3d0ac2e4a2d292dca5330b4aee54a1b151f151f151f"
    "f4e200504b03041400000808000000215c124c96e6170000008800000015000000756e69636f64652dc3bc6ec3af636f"
    "64652e747874cb38bc3227275fa1fcf0b6a29c1485477326670c8c0000504b010214001400000000000000215c905fd4"
    "a70b0000000b000000120000000000000000000000a401000000005f756e7061636b2f696e6465782e6a736f6e504b01"
    "0214001400000008000000215c90d0d2eb23000000c0030000170000000000000000000000a4013b00000064656d6f2e"
    "746573742f6170702f62756e646c652e6a73504b010214001400000808000000215c124c96e617000000880000001500"
    "00000000000000000000a40193000000756e69636f64652dc3bc6ec3af636f64652e747874504b050600000000030003"
    "00c8000000dd0000000000")
  "An archive CPython's `zipfile` wrote, as hex.

Entries, in order: `_unpack/index.json` (stored, 11 bytes), `demo.test/app/
bundle.js` (deflated, 960 -> 35 bytes) and `unicode-ünïcode.txt` (deflated,
136 -> 23 bytes, general-purpose flag 0x0800). Every timestamp is 2026-01-01
00:00:00, and the file mode is 0644 - both matching what this writer emits, so a
disagreement here is about CONTENT, not about a styling difference.")

;;; ---------------------------------------------------------------------------
;;; The gate
;;; ---------------------------------------------------------------------------

(defun zip-decoy-body ()
  "Stored content containing the EOCD signature, to trip a forwards search.

The bytes are the EOCD signature followed by a plausible-looking record body -
count 153, directory offset 32 - followed by incompressible noise so the entry
is STORED rather than deflated. A forwards scan reads those numbers and then
walks into nonsense; a backwards scan from the end never looks at them."
  (concatenate '(vector (unsigned-byte 8))
               (zip-octets #x50 #x4B #x05 #x06 #x00 #x00 #x00 #x00
                           #x99 #x00 #x99 #x00 #x10 #x00 #x00 #x00
                           #x20 #x00 #x00 #x00 #x00 #x00)
               ;; THE NOISE IS THE POINT. With only structured bytes here, salza2
               ;; deflates the decoy and the signature never reaches the archive,
               ;; so a forwards EOCD search finds nothing to stop at and the test
               ;; passed against the wrong implementation. 512 incompressible
               ;; bytes force `compress-entry` to store the entry verbatim.
               *zip-noise*))

(defun run-zip-gate (&key (verbose t))
  "Check the archive port against its own round trip, a foreign archive, and
the Rust crate's own `zip.rs` tests. Returns T when every case holds."
  (let ((result (make-gate-result)))

    ;; -- 1. CRC-32's standard check value ----------------------------------
    ;;
    ;; Straight from `crc32_matches_the_standard_check_value`. The check value
    ;; "123456789" -> 0xCBF43926 is the one every CRC catalogue lists, so it
    ;; pins the polynomial, the table construction, the shift direction and the
    ;; final complement at once.
    (check result "crc32 of the empty sequence is 0" ""
           (vovas.engine.zip:crc32 "") 0)
    (check result "crc32 check value 123456789 -> #xCBF43926" "123456789"
           (vovas.engine.zip:crc32 "123456789") #xCBF43926)
    (check result "crc32 of the 960-byte bundle payload" "bundle.js"
           (vovas.engine.zip:crc32 *zip-bundle-js*) #xEBD2D090)
    (check result "crc32 of the 512-byte noise payload" "noise"
           (vovas.engine.zip:crc32 *zip-noise*) #xD661F8C7)
    ;; ... and the CRC is over BYTES, so a string argument must be its UTF-8.
    (check result "crc32 of a non-ASCII string hashes its UTF-8 bytes"
           "héllo" (vovas.engine.zip:crc32 "héllo")
           (vovas.engine.zip:crc32 (zip-utf8 "héllo")))

    ;; WRONG IMPLEMENTATION 1: the CRC without its final complement. Every
    ;; value would be wrong by a bitwise-not, which still looks like a checksum.
    (zip-probe result "the CRC carries its final complement (not #x340BC6D9)"
           (/= (vovas.engine.zip:crc32 "123456789") #x340BC6D9) "123456789")
    ;; WRONG IMPLEMENTATION 2: hashing the COMPRESSED body. The stored CRC is
    ;; that of the uncompressed content, so the two must differ for a deflated
    ;; entry - otherwise a writer that hashed the wrong buffer passes every
    ;; read-back test that only checks self-consistency.
    (multiple-value-bind (method body) (vovas.engine.zip:compress-entry *zip-bundle-js*)
      (declare (ignore method))
      (zip-probe result "the entry CRC is of the content, not of the deflated body"
             (/= (vovas.engine.zip:crc32 body) #xEBD2D090) "bundle.js"))

    ;; -- 2. DOS timestamps -------------------------------------------------
    ;;
    ;; `dos_stamp_encodes_a_known_date`, plus two dates the Rust test does not
    ;; reach: a leap day (to prove the civil algorithm's March-based year) and
    ;; the last expressible year (to prove the range check's upper bound).
    (multiple-value-bind (time date) (vovas.engine.zip:dos-stamp 1767225600000)
      (check result "2026-01-01T00:00:00Z date word" "2026-01-01"
             date (logior (ash 46 9) (ash 1 5) 1))
      (check result "2026-01-01T00:00:00Z time word" "2026-01-01"
             time 0))
    (multiple-value-bind (time date) (vovas.engine.zip:dos-stamp 0)
      (check result "a pre-1980 stamp clamps to the DOS epoch date" 0
             date (logior (ash 1 5) 1))
      (check result "a pre-1980 stamp clamps to a zero time" 0 time 0))
    (multiple-value-bind (time date) (vovas.engine.zip:dos-stamp 1781531130000)
      (check result "2026-06-15T13:45:30Z date word" "2026-06-15"
             date (logior (ash 46 9) (ash 6 5) 15))
      (check result "2026-06-15T13:45:30Z time word" "2026-06-15"
             time (logior (ash 13 11) (ash 45 5) 15)))
    (multiple-value-bind (time date) (vovas.engine.zip:dos-stamp 1709208001000)
      (check result "a leap day (2024-02-29) encodes as February 29th" "leap"
             date (logior (ash 44 9) (ash 2 5) 29))
      (check result "a leap day's seconds field is halved" "leap"
             time (logior (ash 12 11) (ash 0 5) 0)))
    (multiple-value-bind (time date) (vovas.engine.zip:dos-stamp 4354819198000)
      (check result "2107-12-31 is the last expressible date, not clamped" "2107"
             date (logior (ash 127 9) (ash 12 5) 31))
      (check result "2107-12-31 keeps its time" "2107" time 49021))
    (multiple-value-bind (time date) (vovas.engine.zip:dos-stamp 4354819200000)
      (check result "2108-01-01 is out of range and clamps to the epoch" "2108"
             date (logior (ash 1 5) 1))
      (check result "2108-01-01 clamps its time to zero" "2108" time 0))

    ;; WRONG IMPLEMENTATION 3: the (time, date) pair swapped. The Rust returns
    ;; them in that order and the header writes them in the other, so a port
    ;; that transposed the two produces an archive whose dates read as
    ;; 2045-something and whose times read as a plausible date.
    (multiple-value-bind (time date) (vovas.engine.zip:dos-stamp 1781531130000)
      (zip-probe result "the DOS words are not the (date, time) transposition"
             (not (= time (logior (ash 46 9) (ash 6 5) 15)))
             "2026-06-15")
      (zip-probe result "the date word is not the time word" (/= time date) "2026-06-15"))
    ;; WRONG IMPLEMENTATION 4: seconds not halved. DOS stores seconds/2; a port
    ;; that stored the raw second writes 30 where 15 belongs, and 30 does not fit
    ;; in the 5-bit field, so it also corrupts the minute above it.
    (multiple-value-bind (time date) (vovas.engine.zip:dos-stamp 1781531130000)
      (declare (ignore date))
      (zip-probe result "the seconds field is halved, not raw"
             (/= time (logior (ash 13 11) (ash 45 5) 30)) "2026-06-15"))
    ;; ... and the civil algorithm itself, against dates it must get right:
    ;; the epoch, a leap day, and a day in the far future.
    (check result "civil_from_unix_secs at the epoch" 0
           (multiple-value-list (vovas.engine.zip:civil-from-unix-secs 0))
           '(1970 1 1 0 0 0))
    (check result "civil_from_unix_secs on a leap day" 1709208001
           (multiple-value-list (vovas.engine.zip:civil-from-unix-secs 1709208001))
           '(2024 2 29 12 0 1))
    (check result "civil_from_unix_secs at the end of 2107" 4354819198
           (multiple-value-list (vovas.engine.zip:civil-from-unix-secs 4354819198))
           '(2107 12 31 23 59 58))
    (check result "civil_from_unix_secs late on 1999-12-31" 946684799
           (multiple-value-list (vovas.engine.zip:civil-from-unix-secs 946684799))
           '(1999 12 31 23 59 59))

    ;; -- 3. Raw deflate: round trip and framing ----------------------------
    ;;
    ;; The known-string round trip. It is asserted byte-identically, not by
    ;; length, because a compressor that dropped or reordered a byte and an
    ;; inflater that did the same would otherwise cancel out.
    (dolist (sample (list "" "a" "0123456789" "hello hello hello hello"
                          "{\"ok\":true}" "function f(){return 1;}"))
      (let ((raw (zip-utf8 sample)))
        (zip-octet-check result "deflate-then-inflate is byte-identical" sample
                     (vovas.engine.zip:inflate-raw (vovas.engine.zip:deflate-raw raw))
                     raw)))
    (zip-octet-check result "deflate-then-inflate is byte-identical (960 bytes)"
                 "bundle.js"
                 (vovas.engine.zip:inflate-raw (vovas.engine.zip:deflate-raw *zip-bundle-js*))
                 *zip-bundle-js*)
    (zip-octet-check result "deflate-then-inflate is byte-identical (all byte values)"
                 "0..255 x2"
                 (vovas.engine.zip:inflate-raw
                  (vovas.engine.zip:deflate-raw
                   (make-array 512 :element-type '(unsigned-byte 8)
                                   :initial-contents
                                   (loop for i below 512 collect (mod i 256)))))
                 (make-array 512 :element-type '(unsigned-byte 8)
                                 :initial-contents
                                 (loop for i below 512 collect (mod i 256))))

    ;; WRONG IMPLEMENTATION 5: a ZLIB-WRAPPED deflate stream inside the member.
    ;; This is the mistake the module's header warns about, and it is invisible
    ;; to a round trip - `zlib-compressor` output inflates fine if it is fed back
    ;; to `chipz:zlib`. Two assertions catch it: the member must not carry the
    ;; zlib header, and the raw inflater must refuse the wrapped stream.
    (let ((zlib-body (salza2:compress-data *zip-bundle-js* 'salza2:zlib-compressor)))
      ;; (a) the wrapped stream is SIX bytes longer: a two-byte header and a
      ;; four-byte Adler-32 trailer. That is the framing difference, measured.
      (check result "a zlib-framed body is 6 bytes longer than the raw one"
             "framing" (- (length zlib-body)
                          (length (vovas.engine.zip:deflate-raw *zip-bundle-js*)))
             6)
      ;; (b) the raw path cannot read it, so a port that called the wrapped
      ;; compressor produces members no extractor can open.
      (zip-probe result "the raw inflater refuses a zlib-framed stream"
             (stringp (zip-signals (lambda () (vovas.engine.zip:inflate-raw zlib-body))))
             "zlib-framed body")
      ;; (c) and the emitted stream does not begin with the zlib CMF/FLG pair.
      (let ((raw (vovas.engine.zip:deflate-raw *zip-bundle-js*)))
        (check result "the zlib body begins with the #x78 CMF byte" "CMF"
               (aref zlib-body 0) #x78)
        (zip-probe result "the emitted deflate stream has no #x78 CMF byte"
               (= (aref raw 0) #x4B)          ; the fixed-Huffman literal block
               (aref raw 0))))
    ;; ... and garbage is an error, not an empty body.
    (zip-probe result "a non-deflate byte sequence is refused"
           (stringp (zip-signals (lambda () (vovas.engine.zip:inflate-raw
                                         (zip-octets #xDE #xAD #xBE #xEF #x01 #x02)))))
           "garbage")

    ;; -- 4. compress-entry chooses the smaller body ------------------------
    (multiple-value-bind (method body) (vovas.engine.zip:compress-entry *zip-bundle-js*)
      (check result "a repetitive payload is deflated (method 8)" "bundle.js"
             method vovas.engine.zip:+method-deflate+)
      (zip-probe result "a deflated entry is really compressed (body < content)"
             (< (length body) (length *zip-bundle-js*))
             (list (length body) (length *zip-bundle-js*)))
      (zip-probe result "a 960-byte repetitive payload shrinks by at least 10x"
             (< (* 10 (length body)) (length *zip-bundle-js*))
             (length body)))
    (multiple-value-bind (method body) (vovas.engine.zip:compress-entry *zip-noise*)
      (check result "an incompressible payload is stored (method 0)" "noise"
             method vovas.engine.zip:+method-store+)
      (zip-octet-check result "a stored body is the content itself" "noise" body *zip-noise*))
    (multiple-value-bind (method body) (vovas.engine.zip:compress-entry (zip-octets))
      ;; WRONG IMPLEMENTATION 6: always deflate. salza2 emits a 210-byte buffer
      ;; for empty input, so a writer that ignored the size comparison would
      ;; write method 8 and a 210-byte body for an empty file.
      (check result "an empty entry is stored, not deflated" "empty"
             method vovas.engine.zip:+method-store+)
      (check result "an empty entry's body is empty" "empty" (length body) 0))
    (multiple-value-bind (method body) (vovas.engine.zip:compress-entry (zip-utf8 "0123456789"))
      ;; 10 bytes deflate to 12; the strict `<` must keep the shorter one.
      (check result "content that deflate would grow is stored" "0123456789"
             method vovas.engine.zip:+method-store+)
      (check result "a stored body stays the original ten bytes" "0123456789"
             (length body) 10))

    ;; -- 5. Round trip: build, then read back ------------------------------
    ;;
    ;; `is_empty` first: it is the writer's other accessor and the one a caller
    ;; uses to skip an empty archive, so a writer that answered T for a writer
    ;; with entries would produce a download with nothing in it.
    (let ((fresh (vovas.engine.zip:make-zip-writer)))
      (zip-probe result "a fresh writer reports itself empty"
                 (vovas.engine.zip:zip-writer-empty-p fresh) "fresh")
      (check result "a fresh writer has no entries" "fresh"
             (vovas.engine.zip:zip-writer-count fresh) 0)
      (vovas.engine.zip:zip-writer-add-text fresh "a" "x")
      (zip-probe result "a writer with one entry is not empty"
                 (not (vovas.engine.zip:zip-writer-empty-p fresh)) "one entry"))
    (let* ((writer (vovas.engine.zip:make-zip-writer))
           (_ (progn
                (vovas.engine.zip:zip-writer-add-text writer "_unpack/index.json" "{\"ok\":true}")
                (vovas.engine.zip:zip-writer-add writer "demo.test/app/bundle.js" *zip-bundle-js*)
                (vovas.engine.zip:zip-writer-add writer "demo.test/raw.bin" *zip-noise*)
                (vovas.engine.zip:zip-writer-add-text writer *zip-unicode-name* "")
                (vovas.engine.zip:zip-writer-add-text writer "empty.txt" "")))
           (count (vovas.engine.zip:zip-writer-count writer))
           (archive (vovas.engine.zip:zip-writer-finish writer))
           (entries (vovas.engine.zip:read-archive archive))
           (end (vovas.engine.zip:find-end-record archive)))
      (declare (ignore _))

      (check result "the writer counted every entry" "5 entries" count 5)
      (check result "the reader answers the same number of entries" "read back"
             (length entries) 5)
      ;; ... in the order they were added, which is the order the panel lists
      ;; them. A reader that walked the directory backwards would still answer
      ;; five entries and every name set comparison would still pass.
      (check result "entries keep the order they were added in" "order"
             (zip-entry-names entries)
             (list "_unpack/index.json" "demo.test/app/bundle.js"
                   "demo.test/raw.bin" *zip-unicode-name* "empty.txt"))

      ;; The format's framing, asserted on the raw bytes rather than through the
      ;; reader: a reader that skipped the signatures would happily read an
      ;; archive with none.
      (check result "the archive begins with the local file header PK\\x03\\x04"
             "first 4 bytes" (coerce (subseq archive 0 4) 'list)
             (list #x50 #x4B #x03 #x04))
      (check result "the archive ends with the EOCD terminator PK\\x05\\x06"
             "last 22 bytes" (coerce (subseq archive (- (length archive) 22)
                                                (+ (- (length archive) 22) 4))
                                     'list)
             (list #x50 #x4B #x05 #x06))
      (check result "the EOCD is the final 22 bytes of the archive" "EOCD at"
             (vovas.engine.zip:zip-end-record-at end)
             (- (length archive) 22))
      ;; The entry count is written TWICE (this disk, total) and both must be
      ;; the number of entries; the Rust writes `count` into both and a port
      ;; that wrote 0 into the first disk's field would be accepted by most
      ;; single-disk readers and rejected by strict ones.
      (check result "the terminator's entry count matches the entries written"
             "EOCD count" (vovas.engine.zip:zip-end-record-count end) count)
      (zip-probe result "both EOCD count fields (this disk and total) agree"
             (= (vovas.engine.zip:read-u16 archive (+ (vovas.engine.zip:zip-end-record-at end) 8))
                (vovas.engine.zip:read-u16 archive (+ (vovas.engine.zip:zip-end-record-at end) 10)))
             "EOCD")
      ;; The directory offset really points at the first central record, and its
      ;; size really covers the directory: a wrong offset is the single most
      ;; common way to write an archive that only some tools open.
      (zip-probe result "the EOCD's directory offset points at PK\\x01\\x02"
             (= (vovas.engine.zip:read-u32 archive
                                           (vovas.engine.zip:zip-end-record-directory-offset end))
                vovas.engine.zip:+central-sig+)
             (vovas.engine.zip:zip-end-record-directory-offset end))
      (check result "the directory ends exactly where the EOCD begins"
             "offset + size"
             (+ (vovas.engine.zip:zip-end-record-directory-offset end)
                (vovas.engine.zip:zip-end-record-directory-size end))
             (vovas.engine.zip:zip-end-record-at end))

      ;; Every entry's content, byte for byte.
      (dolist (pair (list (cons "_unpack/index.json" (zip-utf8 "{\"ok\":true}"))
                          (cons "demo.test/app/bundle.js" *zip-bundle-js*)
                          (cons "demo.test/raw.bin" *zip-noise*)
                          (cons *zip-unicode-name* (zip-octets))
                          (cons "empty.txt" (zip-octets))))
        (let ((entry (zip-entry-by-name entries (car pair))))
          (zip-octet-check result "round-tripped content is byte-identical" (car pair)
                       (and entry (vovas.engine.zip:zip-read-entry-body entry))
                       (cdr pair))))
      ;; The non-ASCII name survives as characters, which is the whole point of
      ;; flag bit 11 and of counting the length in bytes.
      (zip-probe result "a non-ASCII entry name survives the round trip"
             (and (zip-entry-by-name entries *zip-unicode-name*) t) *zip-unicode-name*)
      (check result "the non-ASCII name is UTF-8 longer than it is character-long"
             *zip-unicode-name* (list (length *zip-unicode-name*)
                                  (length (zip-utf8 *zip-unicode-name*)))
             (list 16 24))

      ;; Methods: the deflatable entry deflated, the noise stored.
      (check result "the deflatable entry round-trips as method 8" "bundle.js"
             (vovas.engine.zip:zip-read-entry-method
              (zip-entry-by-name entries "demo.test/app/bundle.js"))
             vovas.engine.zip:+method-deflate+)
      (check result "the incompressible entry round-trips as method 0" "raw.bin"
             (vovas.engine.zip:zip-read-entry-method
              (zip-entry-by-name entries "demo.test/raw.bin"))
             vovas.engine.zip:+method-store+)
      (let ((deflated (zip-entry-by-name entries "demo.test/app/bundle.js"))
            (stored (zip-entry-by-name entries "demo.test/raw.bin")))
        (zip-probe result "the deflated entry's recorded size is smaller than its content"
               (< (vovas.engine.zip:zip-read-entry-compressed deflated)
                  (vovas.engine.zip:zip-read-entry-uncompressed deflated))
               (list (vovas.engine.zip:zip-read-entry-compressed deflated)
                     (vovas.engine.zip:zip-read-entry-uncompressed deflated)))
        (check result "the stored entry's recorded size equals its content"
               "raw.bin" (vovas.engine.zip:zip-read-entry-compressed stored) 512)
        (check result "the stored entry's uncompressed size is 512" "raw.bin"
               (vovas.engine.zip:zip-read-entry-uncompressed stored) 512))

      ;; CRCs: each reported CRC must be the CRC of the content, computed here
      ;; by an independent call rather than taken from the record it is checking.
      (dolist (entry entries)
        (check result "the recorded CRC is the CRC of the entry's content"
               (vovas.engine.zip:zip-read-entry-name entry)
               (vovas.engine.zip:zip-read-entry-crc entry)
               (vovas.engine.zip:crc32 (vovas.engine.zip:zip-read-entry-body entry))))

      ;; The central directory carries the SAME CRC as the local header, which
      ;; the reader asserts; this asserts it from outside so a reader that
      ;; stopped checking would still fail.
      (let ((central-crc (vovas.engine.zip:read-u32
                          archive
                          (+ (vovas.engine.zip:zip-end-record-directory-offset end) 16))))
        (check result "the first central record's CRC is the first entry's CRC"
               "_unpack/index.json" central-crc
               (vovas.engine.zip:crc32 (zip-utf8 "{\"ok\":true}"))))

      ;; Flags and versions, read straight out of the local header: bit 11 set,
      ;; version 20, extra and comment lengths zero. The Rust writes these
      ;; unconditionally and no reader depends on them being ABSENT, so a port
      ;; that emitted an extra field or a data descriptor would still round-trip
      ;; - only a byte-level assertion sees it.
      (check result "the local header sets the UTF-8 name flag" "flags"
             (vovas.engine.zip:read-u16 archive 6) #x0800)
      (check result "the local header's version is 2.0" "version"
             (vovas.engine.zip:read-u16 archive 4) 20)
      (check result "the local header's extra field length is zero" "extra"
             (vovas.engine.zip:read-u16 archive 28) 0)
      ;; The DOS words AS WRITTEN. Section 2 checks `dos-stamp` in isolation, and
      ;; a transposed (date, time) pair passes every one of those cases while
      ;; still reaching the header in the wrong order - which is exactly what the
      ;; mutation sweep found. These read the file instead of the function.
      (check result "the local header's time word is the DOS time" "time word"
             (vovas.engine.zip:read-u16 archive 10) 0)
      (check result "the local header's date word is the DOS date" "date word"
             (vovas.engine.zip:read-u16 archive 12) (logior (ash 1 5) 1))
      ;; ... and the same pair in the first central record, because the two
      ;; copies are written by different code paths.
      (check result "the central record's time word is the DOS time" "time word"
             (vovas.engine.zip:read-u16
              archive (+ (vovas.engine.zip:zip-end-record-directory-offset end) 12))
             0)
      (check result "the central record's date word is the DOS date" "date word"
             (vovas.engine.zip:read-u16
              archive (+ (vovas.engine.zip:zip-end-record-directory-offset end) 14))
             (logior (ash 1 5) 1))

      ;; The LOCAL sizes are a second copy of the central ones and nothing in the
      ;; reader compares them, so a writer that put the content size in the
      ;; compressed field survived every assertion above. Read them out.
      (let* ((bundle-entry (zip-entry-by-name entries "demo.test/app/bundle.js"))
             (at (vovas.engine.zip:zip-read-entry-offset bundle-entry))
             (local-compressed (vovas.engine.zip:read-u32 archive (+ at 18)))
             (local-uncompressed (vovas.engine.zip:read-u32 archive (+ at 22))))
        (check result "the local compressed size is the deflated body's"
               "bundle.js" local-compressed
               (vovas.engine.zip:zip-read-entry-compressed bundle-entry))
        (check result "the local uncompressed size is the content's" "bundle.js"
               local-uncompressed 960)
        (zip-probe result "the local compressed size is smaller than the content"
                   (< local-compressed local-uncompressed)
                   (list local-compressed local-uncompressed)))
      ;; The local NAME LENGTH in bytes, for the entry whose name is not ASCII.
      ;; The reader locates the body with it, but an empty body starts and ends
      ;; at the same place whatever the length says - so only reading the field
      ;; catches a character count here.
      (let* ((unicode-entry (zip-entry-by-name entries *zip-unicode-name*))
             (at (vovas.engine.zip:zip-read-entry-offset unicode-entry)))
        (check result "the local name length is the UTF-8 byte count"
               *zip-unicode-name*
               (vovas.engine.zip:read-u16 archive (+ at 26))
               (length (zip-utf8 *zip-unicode-name*)))
        (check result "... which is longer than the character count"
               *zip-unicode-name*
               (list (length (zip-utf8 *zip-unicode-name*))
                     (length *zip-unicode-name*))
               (list 24 16)))
      (check result "the first entry starts at offset 0" "offset"
             (vovas.engine.zip:zip-read-entry-offset
              (zip-entry-by-name entries "_unpack/index.json"))
             0)
      ;; ... and each later entry starts where the previous one ended, which is
      ;; what makes an archive readable by a forward-only extractor.
      (loop for (a b) on entries
            while b
            do (check result "each entry begins where the previous one ended"
                      (vovas.engine.zip:zip-read-entry-name b)
                      (vovas.engine.zip:zip-read-entry-offset b)
                      (+ (vovas.engine.zip:zip-read-entry-offset a)
                         30
                         (length (zip-utf8 (vovas.engine.zip:zip-read-entry-name a)))
                         (vovas.engine.zip:zip-read-entry-compressed a)))))

    ;; -- 6. Determinism -----------------------------------------------------
    ;;
    ;; `identical_input_produces_identical_bytes`. This is what lets a test, a
    ;; cache or a digest compare two builds, and it is only true because
    ;; `make-zip-writer` defaults to the DOS epoch instead of the wall clock.
    (flet ((build ()
             (let ((writer (vovas.engine.zip:make-zip-writer)))
               (vovas.engine.zip:zip-writer-add-text writer "a.txt" "alpha")
               (vovas.engine.zip:zip-writer-add writer "b.bin" (zip-octets 0 1 2 3 255))
               (vovas.engine.zip:zip-writer-finish writer))))
      (zip-octet-check result "identical input produces identical bytes" "two builds"
                   (build) (build)))
    ;; ... and a stamped writer differs from the epoch writer, so the
    ;; determinism above is a property of the default and not of the writer
    ;; ignoring the clock it was given.
    (let ((stamped (let ((writer (vovas.engine.zip:make-zip-writer
                                  :ms 1781531130000)))
                     (vovas.engine.zip:zip-writer-add-text writer "a.txt" "alpha")
                     (vovas.engine.zip:zip-writer-finish writer))))
      (zip-probe result "a stamped writer is not byte-identical to the epoch writer"
             (not (= (vovas.engine.zip:read-u16 stamped 10)
                     (vovas.engine.zip:read-u16
                      (let ((writer (vovas.engine.zip:make-zip-writer)))
                        (vovas.engine.zip:zip-writer-add-text writer "a.txt" "alpha")
                        (vovas.engine.zip:zip-writer-finish writer))
                      10)))
             "time word"))

    ;; -- 7. No directory entries -------------------------------------------
    ;;
    ;; `writes_no_directory_entries`: JSZip emitted an entry per parent folder.
    ;; Extractors do not need them - each file carries its full path - so only
    ;; real files are written. Pinned so the difference stays deliberate, and
    ;; because a port that copied JSZip would produce a round trip that still
    ;; passed (extra empty entries) while the entry count no longer matched.
    (let* ((writer (vovas.engine.zip:make-zip-writer))
           (_ (vovas.engine.zip:zip-writer-add-text writer
                                                    "_unpack/0000-x/a/b/c.js" "x"))
           (entries (vovas.engine.zip:read-archive
                     (vovas.engine.zip:zip-writer-finish writer))))
      (declare (ignore _))
      (check result "a deep path writes exactly one entry" "c.js" (length entries) 1)
      (check result "the deep path's entry keeps its whole path" "c.js"
             (zip-entry-names entries) (list "_unpack/0000-x/a/b/c.js")))

    ;; -- 8. build_zip: the pipeline entry point ----------------------------
    (let* ((archive (vovas.engine.zip:build-zip
                     (list (list :path "_unpack/index.json" :content "{\"ok\":true}")
                           ;; `:base64` must win over `:content` - the panel
                           ;; fills `content` with an empty string for binaries.
                           (list :path "demo.test/blob.bin" :content ""
                                 :base64 "AAEC/w==")
                           ;; a missing :content is the empty entry
                           (list :path "nothing.txt"))
                     0))
           (entries (vovas.engine.zip:read-archive archive)))
      (check result "build-zip writes every file" "3 files" (length entries) 3)
      (zip-octet-check result "build-zip decodes a base64 payload into bytes" "blob.bin"
                   (vovas.engine.zip:zip-read-entry-body
                    (zip-entry-by-name entries "demo.test/blob.bin"))
                   (zip-octets 0 1 2 255))
      (zip-probe result "build-zip prefers :base64 over an empty :content"
             (= (vovas.engine.zip:zip-read-entry-uncompressed
                 (zip-entry-by-name entries "demo.test/blob.bin"))
                4)
             "blob.bin")
      (check result "build-zip treats a missing :content as empty" "nothing.txt"
             (vovas.engine.zip:zip-read-entry-uncompressed
              (zip-entry-by-name entries "nothing.txt"))
             0)
      ;; An invalid base64 payload must be refused, not written empty: the
      ;; `unwrap_or_default` is on `content` alone.
      (check result "build-zip refuses an undecodable base64 payload" "bad base64"
             (zip-signals-containing-p
              (lambda () (vovas.engine.zip:build-zip
                          (list (list :path "bad.bin" :base64 "!!!!")) 0))
              "invalid base64 payload")
             t)
      ;; ... and the refusal is a `zip-error` naming the entry, not a generic
      ;; arity or type failure that a careless check would also accept.
      (check result "the base64 refusal names the offending entry" "bad.bin"
             (zip-signals (lambda () (vovas.engine.zip:build-zip
                                  (list (list :path "bad.bin" :base64 "!!!!")) 0)))
             "zip entry bad.bin: invalid base64 payload"))

    ;; -- 9. Refusals -------------------------------------------------------
    ;;
    ;; The entry ceiling is rebound rather than reached: the real limit is
    ;; 65535 entries and building them costs seconds, while the COMPARISON under
    ;; test (`>=`, refusing the entry AFTER the ceiling) is fully exercised by a
    ;; ceiling of two. The real ceiling is asserted separately, immediately
    ;; below, so the rebinding cannot hide a wrong constant.
    (check result "the entry ceiling is the 16-bit format limit" "max-entries"
           vovas.engine.zip:*max-entries* #xFFFF)
    (let ((vovas.engine.zip:*max-entries* 2))
      (let ((writer (vovas.engine.zip:make-zip-writer)))
        (vovas.engine.zip:zip-writer-add-text writer "a" "x")
        (vovas.engine.zip:zip-writer-add-text writer "b" "x")
        (check result "the ceiling-th entry is accepted" "2 of 2"
               (vovas.engine.zip:zip-writer-count writer) 2)
        (check result "the entry after the ceiling is refused" "3rd"
               (zip-signals-containing-p
                (lambda () (vovas.engine.zip:zip-writer-add-text writer "c" "x"))
                "entry limit")
               t)))
    ;; The Rust test's own case: exactly MAX_ENTRIES entries, then a refusal.
    ;; Slow on purpose - this is the only assertion that reaches the real
    ;; 16-bit boundary, and a bound of 65535 that quietly wrapped to 0 would be
    ;; caught here and nowhere else.
    (let ((writer (vovas.engine.zip:make-zip-writer)))
      (dotimes (index 65535)
        (vovas.engine.zip:zip-writer-add-text writer (format nil "f~a" index) "x"))
      (check result "65535 entries are accepted" "MAX_ENTRIES"
             (vovas.engine.zip:zip-writer-count writer) 65535)
      (check result "the 65536th entry is refused" "one-too-many"
             (zip-signals-containing-p
              (lambda () (vovas.engine.zip:zip-writer-add-text writer "one-too-many" "x"))
              "entry limit")
             t)
      ;; ... and the archive that many entries produce is still readable, with
      ;; an EOCD count of 65535 in a 16-bit field. This is where a count written
      ;; as `(1+ count)` or a wrapped offset would surface.
      (let ((archive (vovas.engine.zip:zip-writer-finish writer)))
        (check result "a 65535-entry archive reports 65535 in its terminator"
               "full archive"
               (vovas.engine.zip:zip-end-record-count
                (vovas.engine.zip:find-end-record archive))
               65535)
        (zip-probe result "a 65535-entry archive is readable end to end"
               (= (length (vovas.engine.zip:read-archive archive)) 65535)
               (length archive))))
    (check result "finishing a writer twice is refused" "finish twice"
           (zip-signals-containing-p
            (lambda ()
              (let ((writer (vovas.engine.zip:make-zip-writer)))
                (vovas.engine.zip:zip-writer-add-text writer "a" "x")
                (vovas.engine.zip:zip-writer-finish writer)
                (vovas.engine.zip:zip-writer-finish writer)))
            "already finished")
           t)
    (check result "adding to a finished writer is refused" "add after finish"
           (zip-signals-containing-p
            (lambda ()
              (let ((writer (vovas.engine.zip:make-zip-writer)))
                (vovas.engine.zip:zip-writer-add-text writer "a" "x")
                (vovas.engine.zip:zip-writer-finish writer)
                (vovas.engine.zip:zip-writer-add-text writer "b" "y")))
            "already finished")
           t)

    ;; -- 10. The reader has teeth ------------------------------------------
    ;;
    ;; A reader that accepted anything would make every round trip above pass
    ;; vacuously. Four corruptions, each of a kind a broken writer could
    ;; produce, must each be refused with a message that names the problem.
    (let* ((writer (vovas.engine.zip:make-zip-writer))
           (_ (progn (vovas.engine.zip:zip-writer-add-text writer "a.txt" "alpha")
                     (vovas.engine.zip:zip-writer-add-text writer "b.txt" "beta")))
           (archive (vovas.engine.zip:zip-writer-finish writer)))
      (declare (ignore _))
      ;; (a) a flipped content byte: the CRC no longer matches.
      ;; "a.txt" is FIVE bytes, and the local header is 30 bytes, so the first
      ;; content byte is at 35 - not 30, which is the first byte of the NAME and
      ;; is not covered by the CRC at all.
      (let ((broken (copy-seq archive)))
        (setf (aref broken 35) (logxor (aref broken 35) #x01))   ; 'a' -> '`'
        (check result "a corrupted stored byte fails the CRC check" "flipped byte"
               (zip-signals-containing-p (lambda () (vovas.engine.zip:read-archive broken))
                                     "CRC")
               t))
      ;; (b) a wrong local-header CRC (bytes 14..17 of the first local header)
      (let ((broken (copy-seq archive)))
        (setf (aref broken 14) (logxor (aref broken 14) #xFF))
        (check result "a local header CRC that disagrees with the central one is refused"
               "broken local CRC"
               (zip-signals-containing-p (lambda () (vovas.engine.zip:read-archive broken))
                                     "local header CRC")
               t))
      ;; (c) a truncated archive: the EOCD is gone
      (check result "an archive with no EOCD is refused" "truncated"
             (zip-signals-containing-p
              (lambda () (vovas.engine.zip:read-archive (subseq archive 0 40)))
              "end of central directory")
             t)
      ;; (d) a damaged local signature
      (let ((broken (copy-seq archive)))
        (setf (aref broken 0) #x00)
        (check result "a damaged local header signature is refused" "bad local sig"
               (zip-signals-containing-p (lambda () (vovas.engine.zip:read-archive broken))
                                     "local header signature")
               t))
      ;; (e) a name that is not UTF-8. The name the reader REPORTS comes from the
      ;; CENTRAL directory, so that is the copy to damage: the first central
      ;; record begins at the directory offset, its name at +46. Corrupting the
      ;; LOCAL name bytes instead is a no-op - this reader takes the name from the
      ;; directory and only the local LENGTH - which is worth knowing and was
      ;; found by this assertion failing first time round.
      (let* ((broken (copy-seq archive))
             (central (+ (vovas.engine.zip:zip-end-record-directory-offset
                          (vovas.engine.zip:find-end-record broken))
                         46)))
        (setf (aref broken central) #xFF)
        (check result "a non-UTF-8 entry name is refused" "bad name"
               (zip-signals-containing-p (lambda () (vovas.engine.zip:read-archive broken))
                                     "UTF-8")
               t))
      ;; (e2) a directory that LIES about the uncompressed size, with every other
      ;; field correct. The body decodes to the right bytes and the CRC matches,
      ;; so ONLY the length check can catch this - which is why the mutation
      ;; sweep found that check unguarded. The field is the central record's
      ;; uncompressed size at +24.
      (let* ((broken (copy-seq archive))
             (central (+ (vovas.engine.zip:zip-end-record-directory-offset
                          (vovas.engine.zip:find-end-record broken))
                         24)))
        (setf (aref broken central) #x2A)   ; low byte -> 42, not 5
        (check result "a directory that misstates the uncompressed size is refused"
               "lying size"
               (zip-signals-containing-p
                (lambda () (vovas.engine.zip:read-archive broken))
                "directory says")
               t))
      ;; (f) garbage is not an archive at all
      (check result "a non-archive is refused" "garbage"
             (zip-signals-containing-p
              (lambda () (vovas.engine.zip:read-archive (zip-octets 1 2 3 4 5 6 7 8)))
              "end of central directory")
             t))

    ;; -- 11. The foreign archive ------------------------------------------
    ;;
    ;; Bytes CPython wrote, read by this module's reader. Nothing here involves
    ;; this writer, so a self-consistent bug in both halves cannot hide.
    (let* ((foreign (zip-hex-octets *zip-foreign-hex*))
           (entries (vovas.engine.zip:read-archive foreign))
           (end (vovas.engine.zip:find-end-record foreign))
           (bundle *zip-bundle-js*)
           (unicode-body (zip-repeat-octets (zip-utf8 "héllo wörld ✓") 8)))
      (check result "the foreign archive is 443 bytes" "hex length"
             (length foreign) 443)
      (check result "the foreign archive begins with PK\\x03\\x04" "first 4 bytes"
             (coerce (subseq foreign 0 4) 'list) (list #x50 #x4B #x03 #x04))
      (check result "the foreign archive holds three entries" "count"
             (vovas.engine.zip:zip-end-record-count end) 3)
      (check result "the foreign archive's names are read exactly" "names"
             (zip-entry-names entries)
             (list "_unpack/index.json" "demo.test/app/bundle.js"
                   "unicode-ünïcode.txt"))
      (check result "a stored foreign entry reads as method 0" "index.json"
             (vovas.engine.zip:zip-read-entry-method
              (zip-entry-by-name entries "_unpack/index.json"))
             vovas.engine.zip:+method-store+)
      (check result "a deflated foreign entry reads as method 8" "bundle.js"
             (vovas.engine.zip:zip-read-entry-method
              (zip-entry-by-name entries "demo.test/app/bundle.js"))
             vovas.engine.zip:+method-deflate+)
      (zip-octet-check result "the stored foreign entry's body is exact" "index.json"
                   (vovas.engine.zip:zip-read-entry-body
                    (zip-entry-by-name entries "_unpack/index.json"))
                   (zip-utf8 "{\"ok\":true}"))
      (zip-octet-check result "the deflated foreign entry inflates to 960 exact bytes"
                   "bundle.js"
                   (vovas.engine.zip:zip-read-entry-body
                    (zip-entry-by-name entries "demo.test/app/bundle.js"))
                   bundle)
      (zip-octet-check result "a non-ASCII foreign name with the UTF-8 flag round-trips"
                   "unicode"
                   (vovas.engine.zip:zip-read-entry-body
                    (zip-entry-by-name entries "unicode-ünïcode.txt"))
                   unicode-body)
      (check result "the foreign archive's recorded CRC is the content's CRC"
             "bundle.js"
             (vovas.engine.zip:zip-read-entry-crc
              (zip-entry-by-name entries "demo.test/app/bundle.js"))
             #xEBD2D090)
      (check result "the foreign UTF-8 entry carries flag bit 11" "flag"
             (logand (vovas.engine.zip:read-u16
                      foreign
                      (+ (vovas.engine.zip:zip-read-entry-offset
                          (zip-entry-by-name entries "unicode-ünïcode.txt"))
                         6))
                     #x0800)
             #x0800)
      ;; WRONG IMPLEMENTATION 7: the name length counted in CHARACTERS. The
      ;; foreign name is 19 characters and 21 bytes, and the directory's name
      ;; length field carries 21; a reader using the character count reads two
      ;; characters out of the next record. Measured from the archive: the third
      ;; central record begins at (directory offset + 46 + 21) + (46 + 23).
      (let* ((unicode-entry (zip-entry-by-name entries "unicode-ünïcode.txt"))
             (third-at (+ (vovas.engine.zip:zip-end-record-directory-offset end)
                          (+ 46 18)                 ; index.json: 18 bytes
                          (+ 46 23)))               ; bundle.js: 23 bytes
             (length-field (vovas.engine.zip:read-u16 foreign (+ third-at 28))))
        (check result "the foreign name's length field is its UTF-8 byte count"
               "unicode entry" length-field 21)
        (zip-probe result "... and not its character count (19)"
               (and (= 19 (length (vovas.engine.zip:zip-read-entry-name unicode-entry)))
                    (/= length-field 19))
               length-field)))

    ;; -- 12. The EOCD search runs backwards --------------------------------
    ;;
    ;; WRONG IMPLEMENTATION 8: a forwards `position` for `PK\x05\x06`. A stored
    ;; entry whose content IS the EOCD signature is the decoy that catches it,
    ;; and it is a legal archive - stored content is arbitrary bytes.
    (let* ((decoy (zip-decoy-body))
           (writer (vovas.engine.zip:make-zip-writer))
           (_ (progn (vovas.engine.zip:zip-writer-add writer "decoy.bin" decoy)
                     (vovas.engine.zip:zip-writer-add-text writer "real.txt" "real")))
           (archive (vovas.engine.zip:zip-writer-finish writer))
           (end (vovas.engine.zip:find-end-record archive)))
      (declare (ignore _))
      (check result "the EOCD search skips a decoy signature inside stored content"
             "decoy archive" (vovas.engine.zip:zip-end-record-count end) 2)
      (check result "the EOCD found is the archive's last 22 bytes" "decoy archive"
             (vovas.engine.zip:zip-end-record-at end) (- (length archive) 22))
      (check result "the decoy archive still reads both entries" "decoy archive"
             (zip-entry-names (vovas.engine.zip:read-archive archive))
             (list "decoy.bin" "real.txt"))
      ;; The decoy only trips a forwards search if its bytes are in the archive
      ;; verbatim; if the writer deflated it, the signature is gone and the case
      ;; above passes vacuously.
      (check result "the decoy entry is stored, so its signature is in the file"
             "decoy.bin"
             (vovas.engine.zip:zip-read-entry-method
              (zip-entry-by-name (vovas.engine.zip:read-archive archive) "decoy.bin"))
             vovas.engine.zip:+method-store+))

    ;; -- 13. The gate is non-vacuous ---------------------------------------
    (zip-probe result "the gate ran a non-empty set of cases"
           (plusp (gate-result-total result)) (gate-result-total result))

    (when verbose
      (format t "~&zip gate: ~a/~a cases match~%"
              (gate-result-passed result) (gate-result-total result))
      (report-failures result))
    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp (gate-result-total result)))))
