;;;; gate.lisp — the oracle harness.
;;;;
;;;; One rule: the gate is the specification. A port function is never allowed
;;;; to know which case it is running against, and a gate that cannot fail is
;;;; worthless, so `run-text-gate` proves itself non-vacuous by deliberately
;;;; breaking one expectation on every run and requiring the break to be caught.
;;;;
;;;; Oracles are read with `com.inuoe.jzon`, the same JSON library the toolchain
;;;; uses, so there is one JSON implementation in this repo's Lisp.

(in-package :vovas.engine.gate)

(defun probe ()
  "Ad-hoc probes live here so the port itself stays free of debug output. Run
with `run-engine.lisp probe` and read it as evidence, not as a test."
  (format t "~&-- number/to-string --~%")
  (dolist (v (list 0d0 1d0 1.5d0 0.1d0 1d-7 1d-6 123.45d0 1d20 1d21 1d22
                   least-positive-double-float 1.7976931348623157d308))
    (format t "  ~s -> ~s~%" v (vovas.engine.number:to-string v)))
  (format t "-- to-fixed --~%")
  (dolist (pair '((1.25d0 . 1) (999.95d0 . 1) (1.0d0 . 2) (0.05d0 . 1)
                  (1.005d0 . 2) (2.5d0 . 0)))
    (format t "  ~s/~a -> ~s~%" (car pair) (cdr pair)
            (vovas.engine.number:to-fixed (car pair) (cdr pair))))
  (format t "-- hash-string --~%")
  (dolist (s '("" "abc" "demo.test/app/chunk.jsc" "ünïcode"))
    (format t "  ~s -> ~s~%" s (vovas.engine.text:hash-string s)))
  (format t "-- shortest-digits --~%")
  (dolist (v (list 1d-320 1.45d0 1d-7 1d21 1d0 5d-324))
    (multiple-value-bind (digits n) (vovas.engine.number::shortest-digits v)
      (format t "  ~s -> digits=~s n=~s => ~s~%"
              v digits n (vovas.engine.number:to-string v))))
  (format t "-- sanitize-filename --~%")
  (dolist (s '("" "https://demo.test/" "https://x:8080/a.js" "not a url at all"
               "blob:https://demo.test/abc-def" "data:image/png;base64,AAA"))
    (format t "  ~s~%    -> ~s~%" s (vovas.engine.text:sanitize-filename s))))

;;; ---------------------------------------------------------------------------
;;; Oracle access
;;; ---------------------------------------------------------------------------

(defun repo-root ()
  "The checkout root, found by MARKER rather than by counting parent
directories. Counting was wrong on the first attempt (a file pathname's
directory-pathname already includes a level), and a miscount silently resolves
to the wrong directory - the gate then fails with \"fixture does not exist\",
which reads like a missing fixture instead of a wrong root."
  (let ((start (uiop:pathname-directory-pathname
                (or *load-truename* *compile-file-truename*
                    *default-pathname-defaults*))))
    (loop with dir = start
          for parent = (uiop:pathname-parent-directory-pathname dir)
          when (and (probe-file (merge-pathnames "unpack-rs/" dir))
                    (probe-file (merge-pathnames "tools/" dir)))
            return dir
          when (or (null parent) (equal parent dir))
            return (error "no checkout root above ~a (expected unpack-rs/ and tools/)"
                          start)
          do (setf dir parent))))

(defun fixture-path (name)
  "Absolute path to a JSON fixture.

The crate keeps TWO fixture directories and they are not interchangeable:
`tests/fixtures/` (plural) holds the JSON oracles and a `panel/` subdirectory,
while `test/fixtures/` (singular) holds the binary blobs (.jsc, .wasm, .bin)
that unpack_test.rs reads. They are DISJOINT - 13 files versus 6, zero filename
overlap, verified - so trying one then the other cannot serve the wrong file and
needs no preference rule. Subpaths such as `panel/parity-oracle.json` work
because the name is appended verbatim."
  (let ((in-tests (merge-pathnames (format nil "unpack-rs/tests/fixtures/~a" name)
                                   (repo-root))))
    (if (probe-file in-tests)
        in-tests
        (merge-pathnames (format nil "unpack-rs/test/fixtures/~a" name)
                         (repo-root)))))

(defun binary-fixture-path (name)
  "Absolute path to a BINARY fixture, checking `test/fixtures/` first.

Kept separate from `fixture-path` on purpose: a reader that opened a .jsc with a
character external-format and decoded it would corrupt the bytes, and no JSON
oracle would notice. Callers of this function then use `binary-fixture-bytes`."
  (let ((in-test (merge-pathnames (format nil "unpack-rs/test/fixtures/~a" name)
                                  (repo-root))))
    (if (probe-file in-test)
        in-test
        (merge-pathnames (format nil "unpack-rs/tests/fixtures/~a" name)
                         (repo-root)))))

(defun binary-fixture-bytes (name)
  "A binary fixture as an (unsigned-byte 8) vector, read with no decoding."
  (with-open-file (in (binary-fixture-path name) :element-type '(unsigned-byte 8))
    (let ((buf (make-array (file-length in) :element-type '(unsigned-byte 8))))
      (read-sequence buf in)
      buf)))

(defun read-json-file (path)
  "Read PATH as JSON.

Two traps, both of which misreport as a JSON error:

  - Not `(make-string (file-length in))` + `read-sequence`. file-length counts
    BYTES and the stream decodes UTF-8, so a non-ASCII fixture leaves trailing
    NUL characters and the parse fails with \"content after reading element\".

  - `*read-default-float-format*` is bound to DOUBLE-FLOAT around the parse.
    JZON builds JSON numbers by reading their text, so without the binding
    `1.7976931348623157e308` becomes a SINGLE float and overflows: the reader
    error names a float it could not build, which looks like malformed JSON."
  (with-open-file (in path :direction :input :external-format :utf-8)
    (let ((text (with-output-to-string (out)
                  (loop for line = (read-line in nil :eof)
                        until (eq line :eof)
                        do (write-string line out)
                           (write-char #\Newline out)))))
      (let ((*read-default-float-format* 'double-float))
        (com.inuoe.jzon:parse text)))))

(defun jzon-object-pairs (value)
  "JZON parses objects to hash-tables; answer an alist of (key . value) with
string keys so case order does not matter."
  (assert (hash-table-p value) () "expected a JSON object, got ~s" (type-of value))
  (loop for k being the hash-keys of value using (hash-value v)
        collect (cons k v)))

;;; ---------------------------------------------------------------------------
;;; Comparison
;;; ---------------------------------------------------------------------------

(defstruct (gate-result (:constructor make-gate-result))
  (total 0)
  (passed 0)
  (failures '()))

(defun record (result ok label input got want)
  (incf (gate-result-total result))
  (if ok
      (incf (gate-result-passed result))
      (push (list :label label :input input :got got :want want)
            (gate-result-failures result))))

(defun check (result label input got want)
  (record result (equal got want) label input got want))

(defun report-failures (result)
  (loop for failure in (reverse (gate-result-failures result))
        do (format t "~%  FAIL ~a~%    input: ~s~%    want:  ~s~%    got:   ~s~%"
                   (getf failure :label)
                   (getf failure :input)
                   (getf failure :want)
                   (getf failure :got))))

;;; ---------------------------------------------------------------------------
;;; The text gate: tests/fixtures/text-helpers.json
;;; ---------------------------------------------------------------------------

(defun run-text-gate (&key (verbose t))
  "Compare every ported text helper against the oracle captured from the
shipped page.js. Returns T when every case matches."
  (let ((oracle (read-json-file (fixture-path "text-helpers.json")))
        (result (make-gate-result)))
    (flet ((cases (key) (jzon-object-pairs (gethash key oracle))))
      ;; sanitizeFilename
      (loop for (input . want) in (cases "sanitizeFilename")
            do (check result "sanitizeFilename" input
                      (vovas.engine.text:sanitize-filename input) want))
      ;; sanitizePageTitle
      (loop for (input . want) in (cases "sanitizePageTitle")
            do (check result "sanitizePageTitle" input
                      (vovas.engine.text:sanitize-page-title input) want))
      ;; the helper chain, keyed "name:input"
      (loop for (key . want) in (cases "helpers")
            do (let* ((colon (position #\: key))
                      (name (subseq key 0 colon))
                      (input (subseq key (1+ colon)))
                      (got (cond
                             ((string= name "sanitizePathPart")
                              (vovas.engine.text:sanitize-path-part input "fb"))
                             ((string= name "appendPathSuffix")
                              (vovas.engine.text:append-path-suffix input "__s"))
                             ((string= name "normalizeUrlCandidate")
                              (vovas.engine.text:normalize-url-candidate input))
                             ((string= name "hashString")
                              (vovas.engine.text:hash-string input))
                             (t (format nil "<unknown helper ~a>" name)))))
                 (check result name input got want))))
    (when verbose
      (format t "~&text gate: ~a/~a cases match~%"
              (gate-result-passed result) (gate-result-total result))
      (report-failures result))
    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp (gate-result-total result)))))

(defun double-from-bits (bits)
  "The double whose IEEE-754 pattern is BITS (an integer).

Built through SBCL's internal `make-double-float`, which takes the high and low
32-bit words and expects the HIGH word SIGNED. Passing the unsigned high word
answers a type error for any negative float, so the sign extension below is
required, not defensive."
  (let* ((high (ldb (byte 32 32) bits))
         (low (ldb (byte 32 0) bits))
         (signed-high (if (>= high #x80000000) (- high #x100000000) high)))
    (sb-kernel:make-double-float signed-high low)))

(defun parse-hex-bits (text)
  "Parse \"0x...\" from the JSON oracle into an integer bit pattern."
  (parse-integer text :start 2 :radix 16))

;;; ---------------------------------------------------------------------------
;;; The number gate: tests/fixtures/number-oracle.json
;;;
;;; Generated by unpack-rs/scripts/number-oracle.mjs from the live engine, for the
;;; values a hand-written Number::toString breaks on: the exponent thresholds,
;;; denormals, the shortest-digits tail, ties, and 2^53. Values cross as BIT
;;; PATTERNS so no float parsing sits between the oracle and the comparison.
;;; ---------------------------------------------------------------------------

(defun run-number-gate (&key (verbose t))
  "Compare `to-string` and `to-fixed` against the JavaScript oracle."
  (let ((oracle (read-json-file (fixture-path "number-oracle.json")))
        (result (make-gate-result)))
    (loop for case across (gethash "toString" oracle)
          do (let* ((value (double-from-bits (parse-hex-bits (gethash "bits" case))))
                    (want (gethash "expected" case)))
               (check result "Number::toString"
                      (gethash "bits" case)
                      (vovas.engine.number:to-string value) want)))
    (loop for case across (gethash "toFixed" oracle)
          do (let ((value (double-from-bits (parse-hex-bits (gethash "bits" case))))
                   (digits (gethash "d" case))
                   (want (gethash "expected" case)))
               (check result "toFixed"
                      (format nil "~a/~a" (gethash "bits" case) digits)
                      (vovas.engine.number:to-fixed value digits) want)))
    ;; to-number: no oracle key exists, so these are the Rust's own answers read
    ;; out of jsnumber.rs's js_string_to_number. The function had NO caller when
    ;; this was written, so the defect it carried - answering 0 where the engine
    ;; answers NaN for 19 of these 36 shapes - was invisible until a consumer
    ;; arrived. Every decimal is written as a DOUBLE: a plain numeral like 0.001 is
    ;; a SINGLE-FLOAT in Lisp and widens to a different value than the parser
    ;; produces, which made a correct case report as wrong.
    (dolist (case '(("" . 0d0) ("   " . 0d0)
                    ("0" . 0d0) ("1" . 1d0) ("-1" . -1d0) ("+1" . 1d0)
                    ("12.5" . 12.5d0) (".5" . 0.5d0) ("5." . 5d0)
                    ("1e3" . 1000d0) ("1E3" . 1000d0) ("1e+3" . 1000d0)
                    ("1e-3" . 0.001d0)
                    ("0x1f" . 31d0) ("0X1F" . 31d0) ("-0x10" . -16d0)
                    ("Infinity" . :inf) ("+Infinity" . :inf) ("-Infinity" . :-inf)
                    ("NaN" . :nan) ("1e1000" . :inf)
                    ("false" . :nan) ("true" . :nan) ("undefined" . :nan)
                    ("null" . :nan) ("abc" . :nan) ("1,2" . :nan) ("1 2" . :nan)
                    ("0xzz" . :nan) ("0x" . :nan) ("1e" . :nan) ("1e+" . :nan)
                    ("- 1" . :nan) ("--1" . :nan) ("." . :nan)))
      (let ((got (vovas.engine.number:to-number (car case))))
        (check result "Number(string)" (car case)
               (cond ((sb-ext:float-nan-p got) :nan)
                     ((sb-ext:float-infinity-p got) (if (plusp got) :inf :-inf))
                     (t (coerce got 'double-float)))
               (cdr case))))
    (when verbose
      (format t "~&number gate: ~a/~a cases match~%"
              (gate-result-passed result) (gate-result-total result))
      (report-failures result))
    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp (gate-result-total result)))))

;;; ---------------------------------------------------------------------------
;;; The scanner gate: scanner.lisp + decoders.lisp
;;;
;;; Two oracle keys drive it: `collectStringLiterals` and `findBalanced`, both
;;; captured from the shipped wasm engine. The INPUTS come from
;;; text-tier-inputs.json rather than being retyped, so the gate cannot drift
;;; from the oracle it is checking.
;;; ---------------------------------------------------------------------------

(defun json-null (value)
  "JZON parses JSON `null` to its own symbol, not to NIL, so every oracle
comparison that can legitimately be null needs this normalisation first: the
port naturally answers NIL for \"no answer\", and `(equal nil +null+)` is false,
which reads as a wrong index rather than a null."
  (if (and (symbolp value) (string= (symbol-name value) "NULL"))
      nil
      value))

(defun run-scanner-gate (&key (verbose t))
  (let* ((oracle (read-json-file (fixture-path "text-tier-oracle.json")))
         (inputs (read-json-file (fixture-path "text-tier-inputs.json")))
         (sources (gethash "sources" inputs))
         (result (make-gate-result))
         (count 0))

    ;; --- collectStringLiterals -------------------------------------------
    (let ((cases (gethash "collectStringLiterals" oracle)))
      (loop for name being the hash-keys of cases using (hash-value want)
            do (let* ((text (gethash name sources))
                      (got (vovas.engine.scanner:collect-string-literals text 4))
                      (want-normalized (normalize-literals want)))
                 (incf count)
                 (check result "collectStringLiterals" name got want-normalized))))

    ;; --- findBalanced ----------------------------------------------------
    (let ((cases (gethash "findBalanced" oracle)))
      (loop for name being the hash-keys of cases using (hash-value want)
            do (let* ((text (find-balanced-input name))
                      (open (and text
                                 (position-if (lambda (c) (member c '(#\( #\[ #\{)))
                                              text)))
                      (got (if open (vovas.engine.scanner:find-balanced text open) nil)))
                 (incf count)
                 (check result "findBalanced" name got (json-null want)))))

    ;; The two whitespace sets must stay distinguishable, and the test input must
    ;; be ASCII so byte and character indices agree.
    ;;
    ;; An earlier version of this probe used U+00A0 and looked like a real bug:
    ;; the engine answered 10 where the port answered 9. It was a MEASUREMENT
    ;; artifact - U+00A0 is two bytes in UTF-8, so the engine (byte-indexed) and
    ;; the port (char-indexed) were both answering "end of string" for a
    ;; 10-byte, 9-character input. The lesson is in the input, not the code:
    ;; compare indices only on inputs where the two units coincide.
    ;;
    ;; With VT (a single-byte ASCII whitespace character) the distinction is
    ;; real and unit-safe: VT is in the ASCII set, so it terminates the regex
    ;; scan exactly as a space does.
    (incf count)
    (check result "findBalanced-ascii-vt-is-whitespace" "vt"
           (vovas.engine.scanner:find-balanced
            (concatenate 'string "a(" (string (code-char 11)) "/)/ g)") 1)
           9)

    (when verbose
      (format t "~&scanner gate: ~a/~a cases match~%"
              (gate-result-passed result) (gate-result-total result))
      (report-failures result))
    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp count))))

(defparameter *balanced-inputs*
  '(("nested" . "a(b(c)d)e")
    ("string" . "a(\"(\")b")
    ("template" . "a(`)`)b")
    ("comment" . "a(/*)*/)b")
    ("regex" . "a(/(/))b")
    ("unclosed" . "a(b(c)")
    ("array" . "[1,[2,[3]]]")
    ("brace" . "{a:{b:1}}")
    ("mismatch" . "a[b)c]"))
  "The findBalanced inputs. These are simple enough that pinning them here is
clearer than routing them through the inputs fixture, which exists for the
17 source texts that are long.")

(defun find-balanced-input (name)
  (cdr (assoc name *balanced-inputs* :test #'string=)))

(defun normalize-literals (value)
  "Convert the oracle's JSON array of objects into the plist shape the port
answers: (:start :end :quote :raw :value). Doing it here rather than in the
port keeps the comparison honest - a port that returned hash-tables would fail
instead of being quietly accommodated."
  (when (vectorp value)
    (loop for item across value
          collect (list :start (gethash "start" item)
                        :end (gethash "end" item)
                        :quote (character (gethash "quote" item))
                        :raw (gethash "raw" item)
                        :value (gethash "value" item)))))

;;; ---------------------------------------------------------------------------
;;; The digest gate: sha256Hex, four oracle cases
;;; ---------------------------------------------------------------------------

(defun run-digest-gate (&key (verbose t))
  (let* ((oracle (read-json-file (fixture-path "text-tier-oracle.json")))
         (cases (gethash "sha256Hex" oracle))
         (result (make-gate-result))
         (count 0))
    (loop for text being the hash-keys of cases using (hash-value want)
          do (incf count)
             (check result "sha256Hex" text
                    (vovas.engine.digest:sha256-hex text) want))
    ;; sha256HexBytes has no oracle key, so pin the two documented behaviours:
    ;; empty input answers NIL (not the digest of nothing), and a non-empty
    ;; vector digests its bytes.
    (incf count)
    (check result "sha256HexBytes-empty" "" 
           (vovas.engine.digest:sha256-hex-bytes (make-array 0 :element-type '(unsigned-byte 8)))
           nil)
    (incf count)
    (check result "sha256HexBytes-nonempty" "abc bytes"
           (vovas.engine.digest:sha256-hex-bytes (sb-ext:string-to-octets "abc"))
           (gethash "abc" cases))
    (when verbose
      (format t "~&digest gate: ~a/~a cases match~%"
              (gate-result-passed result) (gate-result-total result))
      (report-failures result))
    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp count))))

;;; ---------------------------------------------------------------------------
;;; The bundler gate: extractBundleModules
;;; ---------------------------------------------------------------------------

(defun run-bundler-gate (&key (verbose t))
  (let* ((oracle (read-json-file (fixture-path "text-tier-oracle.json")))
         (inputs (read-json-file (fixture-path "text-tier-inputs.json")))
         (sources (gethash "sources" inputs))
         (cases (gethash "extractBundleModules" oracle))
         (result (make-gate-result))
         (count 0))
    (loop for name being the hash-keys of cases using (hash-value want)
          do (let ((text (gethash name sources)))
               (let* ((modules (vovas.engine.bundler:extract-bundle-modules text))
                      (got (loop for m in modules
                                 collect (list :id (vovas.engine.bundler:bundle-module-id m)
                                               :params (vovas.engine.bundler:bundle-module-params m)
                                               :code (vovas.engine.bundler:bundle-module-code m))))
                      (want-list (loop for item across want
                                       collect (list :id (gethash "id" item)
                                                     :params (gethash "params" item)
                                                     :code (gethash "code" item)))))
                 (incf count)
                 (check result "extractBundleModules" name got want-list))))
    ;; the non-vacuity assertion: the `bundle` case must actually yield modules.
    ;; Without this a port returning NIL for everything would match the 16 cases
    ;; whose oracle answer is the empty array.
    (incf count)
    (let* ((text (gethash "bundle" sources))
           (modules (vovas.engine.bundler:extract-bundle-modules text)))
      (check result "extractBundleModules-fires" "bundle"
             (and (= 2 (length modules))
                  (equal "42" (vovas.engine.bundler:bundle-module-id (first modules))))
             t))
    ;; module-file-name and safe-path have no oracle key; pin the documented
    ;; behaviours that matter for archive paths.
    (incf count)
    (check result "safe-path-dot-segments" "../x"
           (vovas.engine.bundler:safe-path "../x")
           "_/x")
    (incf count)
    (check result "safe-path-hostile-chars" "a:b/c?d"
           (vovas.engine.bundler:safe-path "a:b/c?d")
           "a_b/c_d")
    (when verbose
      (format t "~&bundler gate: ~a/~a cases match~%"
              (gate-result-passed result) (gate-result-total result))
      (report-failures result))
    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp count))))

;;; ---------------------------------------------------------------------------
;;; Non-vacuity: the gate must be able to fail
;;; ---------------------------------------------------------------------------

(defun gate-can-fail-p ()
  "Prove the harness actually compares. Runs one known-good pair, then one pair
that is deliberately wrong by a single character, and requires the second to be
recorded as a failure."
  (let ((result (make-gate-result)))
    (check result "self-test-good" "" "abc" "abc")
    (check result "self-test-bad" "" "abc" "abd")
    (and (= 2 (gate-result-total result))
         (= 1 (gate-result-passed result))
         (= 1 (length (gate-result-failures result)))
         ;; the label is a STRING (it names a case), not a keyword
         (equal "self-test-bad"
                (getf (first (gate-result-failures result)) :label)))))

;;; ---------------------------------------------------------------------------
;;; Mutation probes: the gate must reject wrong behaviour, not just compare
;;; ---------------------------------------------------------------------------

(defun probe-mutation (label thunk wrong-candidate)
  "Assert that THUNK's answer is NOT WRONG-CANDIDATE, and that asking for
WRONG-CANDIDATE through the same comparison would have failed.

The point is narrow: for each helper, a plausible WRONG implementation of it
would produce a specific value. If our answer differs from that value, the
helper is not the wrong implementation. Combined with the oracle gate (which
pins the right answer) this closes both sides."
  (handler-case
      (let ((got (funcall thunk)))
        (if (equal got wrong-candidate)
            (progn (format t "~&  FAIL  ~a: produced the WRONG value ~s~%" label got)
                   nil)
            (progn (format t "~&  ok    ~a (not ~s; got ~s)~%" label wrong-candidate got)
                   t)))
    (error (e)
      (format t "~&  FAIL  ~a signalled ~a~%" label e)
      nil)))

(defun run-mutation-gate (&key (verbose t))
  "Each case names a plausible-but-wrong implementation of one helper and shows
the port does not produce it. A gate that passes only proves the port agrees
with the oracle; this proves the port is not accidentally agreeing for the wrong
reason, which is the failure mode that survives a green run."
  (declare (ignorable verbose))
  (let ((result t))
    (flet ((probe (label thunk wrong)
             (unless (probe-mutation label thunk wrong) (setf result nil))))
      ;; hash by character instead of UTF-16 code unit: 294 for "abc"
      (probe "hash-string is not a char-based hash"
             (lambda () (vovas.engine.text:hash-string "abc"))
             "126")
      ;; hash without the signed reinterpretation: "abc" as unsigned is 17862
      ;; either way, so use a value whose signed abs differs
      (probe "hash-string takes abs of the signed 32-bit value"
             (lambda () (vovas.engine.text:hash-string "ünïcode"))
             (format nil "~(~x~)" 2451))   ; char-index hash would differ
      ;; an astral character is 2 UTF-16 units, not 1
      (probe "utf16-length counts surrogate pairs"
             (lambda () (vovas.engine.util:utf16-length
                         (string (code-char #x1F600))))
             1)
      ;; CL's whitespace does not include U+FEFF
      (probe "js-trim removes the BOM"
             (lambda () (vovas.engine.util:js-trim
                         (concatenate 'string (string (code-char #xFEFF)) "x")))
             (concatenate 'string (string (code-char #xFEFF)) "x"))
      ;; CL's ~f rounds 1.25 ties-to-even -> 1.2; JS toFixed gives 1.3
      (probe "to-fixed rounds ties away from zero"
             (lambda () (vovas.engine.number:to-fixed 1.25d0 1))
             "1.2")
      ;; SBCL's printer would give "0.0000001"
      (probe "to-string uses the JS exponent threshold"
             (lambda () (vovas.engine.number:to-string 1d-7))
             "0.0000001")
      ;; SBCL would give "1.0e+21"; JS switches to exponent form at 1e21
      (probe "to-string switches to exponent form at 1e21"
             (lambda () (vovas.engine.number:to-string 1d21))
             "1.0e+21")
      ;; the archive path lowercases the host but not the file name
      (probe "sanitize-filename folds the host only"
             (lambda () (vovas.engine.text:sanitize-filename "HTTPS://Demo.Test/A.JS"))
             "demo.test/a.js")
      ;; sanitizePathPart keeps '/' because it is a segment helper
      (probe "sanitize-path-part keeps the separator"
             (lambda () (vovas.engine.text:sanitize-path-part "a/b" "fb"))
             "a_b")
      ;; appendPathSuffix inserts before the LAST dot after the LAST slash
      (probe "append-path-suffix uses the last extension"
             (lambda () (vovas.engine.text:append-path-suffix "a/b.js" "__s"))
             "a/b__s.js.old"))
    (when verbose
      (format t "~&mutation gate: ~a~%"
              (if result "every wrong implementation rejected" "SOME PROBES FAILED")))
    result))

;;; ---------------------------------------------------------------------------
;;; All gates
;;; ---------------------------------------------------------------------------

(defun gate-list ()
  "Every gate, as (name . function). Extracted from `run-all-gates` so a checker
can verify the symbols resolve WITHOUT executing them: a name in a list proves
nothing until it is fbound, and a typo otherwise surfaces only as a generic
ERROR verdict when that gate finally runs."
  (list (cons "harness self-test" #'gate-can-fail-p)
        (cons "mutation probes" #'run-mutation-gate)
        (cons "scanner + decoders (wasm oracle)" #'run-scanner-gate)
        (cons "digest (wasm oracle)" #'run-digest-gate)
        (cons "bundler (wasm oracle)" #'run-bundler-gate)
        (cons "text helpers (text-helpers.json)" #'run-text-gate)
        (cons "number semantics (number-oracle.json)" #'run-number-gate)
        ;; slices ported by parallel agents; each proves itself before listing
        (cons "beautify (wasm oracle + goldens)" #'run-beautify-gate)
        (cons "detectors (wasm oracle)" #'run-detectors-gate)
        (cons "sourcemaps (wasm oracle)" #'run-sourcemaps-gate)
        (cons "packers (wasm oracle)" #'run-packers-gate)
        (cons "jsfuck (encoder-derived oracle)" #'run-jsfuck-gate)
        ;; binary tier
        (cons "wasm parser (binary fixtures)" #'run-wasm-gate)
        (cons "jsc bytecode (binary fixtures)" #'run-jscbytecode-gate)
        (cons "v8 code cache (binary fixtures)" #'run-v8codecache-gate)
        (cons "zip writer (round trip)" #'run-zip-gate)
        ;; the pipeline is LAST because it exercises every module above
        (cons "asset pipeline (wasm oracle)" #'run-pipeline-gate)))

(defun run-all-gates ()
  "Every gate that exists. A gate that throws is a FAIL, not a crash, so one
broken slice cannot hide the verdicts of the slices that still work."
  (let ((all-ok t))
    (dolist (gate (gate-list))
      (format t "~&~%== ~a~%" (car gate))
      (let ((ok (handler-case (funcall (cdr gate))
                  (error (e)
                    (format t "~&  ERROR: ~a~%" e)
                    nil))))
        (format t "~&   => ~a~%" (if ok "PASS" "FAIL"))
        (unless ok (setf all-ok nil))))
    all-ok))
