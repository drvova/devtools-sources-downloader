;;;; gate-wasm.lisp — does the wasm layer answer what the Rust module answers?
;;;;
;;;; The oracle is `unpack-rs/tests/unpack_test.rs`, and the node mirror
;;;; `unpack-rs/test/unpack.test.mjs` covers the same three cases against a real
;;;; `WebAssembly.Module` — in that file the export surface is genuinely
;;;; third-party truth (`WebAssembly.Module.exports`) rather than the Rust's own
;;;; reading, which is the strongest check available for it. Every assertion in
;;;; both files appears below:
;;;;
;;;;   wasm_exports_match_the_platform_oracle_on_the_crafted_fixture
;;;;   wasm_name_section_recovered_from_the_real_corpus_fixture
;;;;   wasm_detector_rejects_noise_and_truncated_bytes
;;;;
;;;; The node file adds three things the Rust file does not: `null` as detector
;;;; input (asserted here), the export COUNT taken from WebAssembly itself
;;;; (asserted here), and `WebAssembly.validate(bytes)` on the crafted fixture —
;;;; which this port cannot answer, because it does not re-implement a validator
;;;; and no Lisp in this repo can. That one is named as unproven rather than
;;;; faked. What it would catch is a crafted fixture that is not a legal module;
;;;; the fixture is the Rust crate's own and every field this parser reads out of
;;;; it agrees with the platform capture, so the risk is that the fixture is
;;;; illegal in a way this layer never touches.
;;;;
;;;; Two fixture directories exist in this repo and they are NOT the same:
;;;; `unpack-rs/tests/fixtures/` holds the wasm-oracle JSON, while the BINARY
;;;; fixtures the Rust test reads live in `unpack-rs/test/fixtures/` (`fixture()`
;;;; in the test file builds `<manifest>/test/fixtures/<name>`). `fixture-path`
;;;; in gate.lisp points at the first one, so this file carries its own
;;;; `wasm-fixture-path` rather than editing the shared harness.
;;;;
;;;; WHERE THE `answer` EXPORT COMES FROM. `parse_wasm_module` reports an export
;;;; named `answer`, kind `func`, index 0 — and no fixture in the repo contains
;;;; it: neither wasm fixture declares that export, and `rg answer
;;;; unpack-rs/tests/unpack_test.rs` matches nothing. The module that carries it
;;;; is built by hand in this file ("crafted-answer" below), because it is also
;;;; the module that needs a multi-byte section-size LEB, and one hand-built
;;;; module serves both purposes. Its expected values come from the Rust source,
;;;; not from a capture.
;;;;
;;;; WHAT THE FIXTURES DO NOT COVER, and is therefore pinned structurally:
;;;;   - the import section (neither fixture imports anything),
;;;;   - the type-name subsection (both have empty typeNames),
;;;;   - SLEB128 (the walkers never read a signed value),
;;;;   - a multi-byte section-size LEB (the largest section here is 46 bytes,
;;;;     one LEB byte),
;;;;   - the LEB continuation ceiling and the f64-to-u32 saturation.
;;;; Each of those is built by hand below and its expected answer is derived
;;;; from the Rust source, not from a capture - so the assertions are
;;;; structural, and this file says so at each one instead of implying an oracle
;;;; that does not exist.
;;;;
;;;; The last section is a set of PLAUSIBLE WRONG implementations, written the
;;;; way a careful person writes them on the first pass. A gate that only
;;;; agreed with the fixtures would let one of those through unnoticed.

(in-package :vovas.engine.gate)

;;; ---------------------------------------------------------------------------
;;; Fixtures
;;; ---------------------------------------------------------------------------

(defun wasm-fixture-path (name)
  "Absolute path to a BINARY fixture under `tools/cl/fixtures/oracles/`.

The Rust tree's `test/fixtures/` and `tests/fixtures/` split is gone - the
port owns its fixtures now, all in one directory."
  (merge-pathnames (format nil "tools/cl/fixtures/oracles/~a" name) (repo-root)))

(defun wasm-read-fixture-bytes (name)
  "The fixture's bytes as an octet vector. Read in `:element-type
(unsigned-byte 8)`: a character stream would decode the payload as UTF-8 and
silently replace every non-ASCII byte, which for a binary format is data loss
that looks like a parser bug."
  (with-open-file (in (wasm-fixture-path name)
                      :direction :input
                      :element-type '(unsigned-byte 8))
    (let* ((size (file-length in))
           (buffer (make-array size :element-type '(unsigned-byte 8))))
      (read-sequence buffer in)
      buffer)))

;;; ---------------------------------------------------------------------------
;;; Hand-built modules
;;;
;;; The binary format's own encoder, in four lines, so the crafted modules below
;;; are readable as what they are. Anything built here is asserted against the
;;; Rust source's behaviour, never against a capture.
;;; ---------------------------------------------------------------------------

(defun wasm-uleb-octets (value)
  "ULEB128 of VALUE as an octet vector."
  (let ((out (make-array 0 :element-type '(unsigned-byte 8)
                           :adjustable t :fill-pointer 0)))
    (loop
      (let ((b (logand value #x7F)))
        (setf value (ash value -7))
        (vector-push-extend (if (plusp value) (logior b #x80) b) out))
      (when (zerop value) (return)))
    (coerce out '(vector (unsigned-byte 8)))))

(defun wasm-concat-octets (&rest parts)
  "Concatenate octet vectors."
  (let ((out (make-array 0 :element-type '(unsigned-byte 8)
                           :adjustable t :fill-pointer 0)))
    (dolist (part parts)
      (loop for b across (if (vectorp part) part (coerce part 'vector))
            do (vector-push-extend b out)))
    (coerce out '(vector (unsigned-byte 8)))))

(defun wasm-utf8-octets (string)
  "STRING's UTF-8 bytes. Hand-built module names are ASCII, but the byte
producer is generic so a non-ASCII case cannot be written by accident."
  (sb-ext:string-to-octets string :external-format :utf-8))

(defun wasm-name-octets (string)
  "A wasm name: length prefix then UTF-8 bytes."
  (let ((body (wasm-utf8-octets string)))
    (wasm-concat-octets (wasm-uleb-octets (length body)) body)))

(defparameter *wasm-header* #(0 97 115 109 1 0 0 0)
  "magic `\\0asm` and version 1. A parameter for the DEFCONSTANT-UNEQL reason
CONTRACT.md gives.")

(defun wasm-section-octets (id payload)
  "One complete section: id byte, ULEB length of PAYLOAD, payload."
  (wasm-concat-octets (vector id) (wasm-uleb-octets (length payload)) payload))

(defun wasm-module-of (&rest sections)
  "A module from SECTIONS, in the order given."
  (apply #'wasm-concat-octets *wasm-header* sections))

(defun wasm-string-table (strings)
  "The bytes of STRINGS joined by NUL — a data segment body, and the shape that
makes the printable-run scanner's boundary behaviour observable.

Joined with an explicit loop rather than `~{~a~^~c~}`: in that format the
separator directive consumes the NEXT argument each time, so a two-element list
leaves `~c` with a string and signals \"is not of type CHARACTER\"."
  (let ((out (make-array 0 :element-type '(unsigned-byte 8)
                           :adjustable t :fill-pointer 0)))
    (loop for (string . more) on strings
          do (loop for b across (wasm-utf8-octets string)
                   do (vector-push-extend b out))
             (when more (vector-push-extend 0 out)))
    (coerce out '(vector (unsigned-byte 8)))))

;;; ---------------------------------------------------------------------------
;;; Small accessors, so an assertion reads as one
;;; ---------------------------------------------------------------------------

(defun wasm-section-triples (info)
  "Sections as `(id name offset size)` — the four fields the JSON artifact
carries for every section, minus the optional custom name."
  (mapcar (lambda (s)
            (list (vovas.engine.wasm:wasm-section-id s)
                  (vovas.engine.wasm:wasm-section-name s)
                  (vovas.engine.wasm:wasm-section-offset s)
                  (vovas.engine.wasm:wasm-section-size s)))
          (vovas.engine.wasm:wasm-module-info-sections info)))

(defun wasm-export-triples (info)
  "Exports as `(name kind index)`, in declaration order."
  (mapcar (lambda (e)
            (list (vovas.engine.wasm:wasm-export-name e)
                  (vovas.engine.wasm:wasm-export-kind e)
                  (vovas.engine.wasm:wasm-export-index e)))
          (vovas.engine.wasm:wasm-module-info-exports info)))

(defun wasm-import-triples (info)
  "Imports as `(module field kind)`, in declaration order."
  (mapcar (lambda (i)
            (list (vovas.engine.wasm:wasm-import-module i)
                  (vovas.engine.wasm:wasm-import-field i)
                  (vovas.engine.wasm:wasm-import-kind i)))
          (vovas.engine.wasm:wasm-module-info-imports info)))

(defun wasm-wire-value (info key)
  "One field out of `module-info-wire`, by its wire key. Used to assert the
artifact's key names rather than only the record fields."
  (cdr (assoc key (vovas.engine.wasm:module-info-wire info) :test #'string=)))

;;; ---------------------------------------------------------------------------
;;; The gate
;;; ---------------------------------------------------------------------------

(defun run-wasm-gate (&key (verbose t))
  "Compare the wasm port against every assertion the Rust test suite makes
about it, then against hand-built modules for the paths those fixtures do not
reach, then against a set of plausible wrong implementations.

Returns T when every case matches and at least one case ran."
  (let ((result (make-gate-result))
        (probes-ok t))

    ;; ---- fixture 1: wasm-data.wasm -----------------------------------
    ;;
    ;; `wasm_exports_match_the_platform_oracle_on_the_crafted_fixture`. The
    ;; oracle there was captured from node's `WebAssembly.Module.exports`, so
    ;; the export surface is third-party truth, not the Rust's own reading.
    (let* ((bytes (wasm-read-fixture-bytes "wasm-data.wasm"))
           (info (vovas.engine.wasm:parse-wasm-module bytes)))
      (check result "wasm-data: detected" "wasm-data.wasm"
             (vovas.engine.wasm:detect-wasm-module bytes) t)
      (record result (not (null info)) "wasm-data: parses" "wasm-data.wasm" info
              "a wasm-module-info")
      (when info
        (check result "wasm-data: version" "header"
               (vovas.engine.wasm:wasm-module-info-version info) 1)
        ;; The Rust test asserts the export surface SORTED by name; declaration
        ;; order here is compute then mem, which is already sorted, so both
        ;; readings agree and the assertion is on the pairs not the order.
        (check result "wasm-data: exports (name kind index)" "export section"
               (wasm-export-triples info)
               '(("compute" "func" 0) ("mem" "memory" 0)))
        ;; The platform-oracle comparison the way both tests write it: the
        ;; (name, kind) pairs SORTED BY NAME, which is what a sorted
        ;; `WebAssembly.Module.exports` gives. Asserted separately from
        ;; declaration order, so a port that reported the right pairs in an
        ;; order the oracle never produces is still caught - and so a port that
        ;; reported the KIND byte as `"function"` (the platform spelling, which
        ;; the node test explicitly maps to `func`) fails here.
        (check result "wasm-data: export (name kind) sorts onto the platform oracle"
               "sorted by name"
               (stable-sort (mapcar (lambda (triple) (subseq triple 0 2))
                                    (wasm-export-triples info))
                            #'string< :key #'car)
               '(("compute" "func") ("mem" "memory")))
        (check result "wasm-data: the `compute` export is function index 0"
               "compute"
               (third (assoc "compute" (wasm-export-triples info) :test #'string=))
               0)
        (check result "wasm-data: module name from the name section"
               "name subsection 0"
               (vovas.engine.wasm:wasm-module-info-module-name info)
               "handcrafted_module")
        (check result "wasm-data: function names (BTreeMap values order)"
               "name subsection 1"
               (vovas.engine.wasm:function-names info)
               '("compute"))
        (check result "wasm-data: data strings" "data section"
               (vovas.engine.wasm:wasm-module-info-data-strings info)
               '("hello from wasm data" "second string here"))
        (check result "wasm-data: notes empty - the walk consumed the module"
               "notes"
               (vovas.engine.wasm:wasm-module-info-notes info)
               nil)
        (check result "wasm-data: section table (id name offset size)"
               "sections"
               (wasm-section-triples info)
               '((1 "type" 10 6) (3 "function" 18 2) (5 "memory" 22 3)
                 (7 "export" 27 17) (10 "code" 46 9) (11 "data" 57 45)
                 (0 "custom" 104 37)))
        (check result "wasm-data: the custom section is named `name`"
               "custom section"
               (vovas.engine.wasm:wasm-section-custom-name
                (car (last (vovas.engine.wasm:wasm-module-info-sections info))))
               "name")
        (check result "wasm-data: non-custom sections carry no custom name"
               "type section"
               (vovas.engine.wasm:wasm-section-custom-name
                (first (vovas.engine.wasm:wasm-module-info-sections info)))
               nil)
        (check result "wasm-data: function count from the function section"
               "function section"
               (vovas.engine.wasm:wasm-module-info-function-count info) 1)
        (check result "wasm-data: no imports" "import section absent"
               (wasm-import-triples info) nil)
        (check result "wasm-data: no type names" "typeName subsection absent"
               (vovas.engine.wasm:type-names info) nil)
        ;; The artifact contract: pipeline.rs reads `moduleName` and
        ;; `dataStrings` BY NAME out of wasm-info.json.
        (check result "wasm-data: wire moduleName" "wasm-info.json"
               (wasm-wire-value info "moduleName") "handcrafted_module")
        (check result "wasm-data: wire dataStrings" "wasm-info.json"
               (wasm-wire-value info "dataStrings")
               '("hello from wasm data" "second string here"))
        (check result "wasm-data: wire functionNames keyed by decimal index"
               "wasm-info.json"
               (wasm-wire-value info "functionNames") '(("0" . "compute")))
        ;; customName is `skip_serializing_if = "Option::is_none"`: absent, not
        ;; present-and-empty, on a non-custom section.
        (check result "wasm-data: wire omits customName on a non-custom section"
               "(assoc \"customName\" (first sections))"
               (assoc "customName"
                      (first (wasm-wire-value info "sections")) :test #'string=)
               nil)
        (check result "wasm-data: wire includes customName on the custom section"
               "(assoc \"customName\" (last sections))"
               (cdr (assoc "customName"
                           (car (last (wasm-wire-value info "sections")))
                           :test #'string=))
               "name")))

    ;; ---- fixture 2: wasm-named.wasm ----------------------------------
    ;;
    ;; `wasm_name_section_recovered_from_the_real_corpus_fixture`.
    (let* ((bytes (wasm-read-fixture-bytes "wasm-named.wasm"))
           (info (vovas.engine.wasm:parse-wasm-module bytes)))
      (check result "wasm-named: detected" "wasm-named.wasm"
             (vovas.engine.wasm:detect-wasm-module bytes) t)
      (record result (not (null info)) "wasm-named: parses" "wasm-named.wasm"
              info "a wasm-module-info")
      (when info
        (check result "wasm-named: function names, sorted" "name section"
               (sort (copy-list (vovas.engine.wasm:function-names info)) #'string<)
               '("eval0" "eval1" "hash" "mix"))
        ;; The node test reads `Object.keys(functionNames).sort((a,b) => a-b)` -
        ;; NUMERIC sort of the index keys, then maps to names. The keys here are
        ;; integers, so the equivalent is the ascending-index order the BTreeMap
        ;; iteration already gives; asserting the keys pins it.
        (check result "wasm-named: functionNames keys are the numeric indices"
               "Object.keys sorted numerically"
               (mapcar #'car (vovas.engine.wasm:function-name-pairs info))
               '(0 1 2 3))
        (check result "wasm-named: export count" "export section"
               (length (vovas.engine.wasm:wasm-module-info-exports info)) 5)
        (check result "wasm-named: notes empty - exact consumption" "notes"
               (vovas.engine.wasm:wasm-module-info-notes info) nil)
        ;; This fixture has NO name section at all (it is seven sections, none
        ;; custom), so every function name comes from the EXPORT backfill. That
        ;; makes it the one place the backfill is oracle-pinned.
        (check result "wasm-named: names come from the export backfill"
               "no custom section present"
               (vovas.engine.wasm:function-name-pairs info)
               '((0 . "eval0") (1 . "eval1") (2 . "mix") (3 . "hash")))
        (check result "wasm-named: no module name" "no name subsection"
               (vovas.engine.wasm:wasm-module-info-module-name info) nil)
        (check result "wasm-named: function count" "function section"
               (vovas.engine.wasm:wasm-module-info-function-count info) 4)
        (check result "wasm-named: exports in declaration order" "export section"
               (wasm-export-triples info)
               '(("memory" "memory" 0) ("eval0" "func" 0)
                 ("eval1" "func" 1) ("mix" "func" 2) ("hash" "func" 3)))
        (check result "wasm-named: a memory export is not backfilled as a name"
               "kind filter"
               (vovas.engine.wasm:type-names info) nil)
        (check result "wasm-named: wire moduleName is present and null"
               "wasm-info.json"
               (assoc "moduleName" (vovas.engine.wasm:module-info-wire info)
                      :test #'string=)
               '("moduleName"))
        (check result "wasm-named: sections (id name offset size)" "sections"
               (wasm-section-triples info)
               '((1 "type" 10 7) (3 "function" 19 5) (4 "table" 26 5)
                 (5 "memory" 33 3) (6 "global" 38 8) (7 "export" 48 39)
                 (10 "code" 89 46)))))

    ;; ---- the detector, on everything that is not a wasm module -------
    ;;
    ;; `wasm_detector_rejects_noise_and_truncated_bytes`, plus the other binary
    ;; fixtures in this crate: a detector that said yes to a JSC chunk or a V8
    ;; code cache would send them down the wasm stage and lose their real
    ;; analysis.
    (flet ((detect-of (bytes) (vovas.engine.wasm:detect-wasm-module bytes)))
      (check result "detector: 4096 bytes of 0x41" "[0x41; 4096]"
             (detect-of (make-array 4096 :element-type '(unsigned-byte 8)
                                         :initial-element #x41))
             nil)
      (check result "detector: four zero bytes" "[0u8; 4]"
             (detect-of (make-array 4 :element-type '(unsigned-byte 8)
                                      :initial-element 0))
             nil)
      (check result "detector: empty" "[]" (detect-of #()) nil)
      (check result "detector: nil" "nil" (detect-of nil) nil)
      ;; The node mirror asserts `detectWasmModule(null) === false`; a NIL
      ;; argument is the Lisp spelling of the same case, and it is the one that
      ;; would blow up in a port that reached straight for `length`.
      (check result "detector: nil is not a module and does not signal"
             "null" (detect-of nil) nil)
      ;; A Lisp STRING is a legitimate way to hand this function ASCII bytes, so
      ;; `octet-view` coerces it; the same magic text therefore detects, and a
      ;; short string does not. The point is that neither signals.
      (check result "detector: a string of the magic octets is coerced and detects"
             "\"\\0asm\\1\\0\\0\\0\""
             (detect-of (concatenate 'string (string (code-char 0)) "asm"
                                     (string (code-char 1))
                                     (string (code-char 0))
                                     (string (code-char 0))
                                     (string (code-char 0))))
             t)
      (check result "detector: a short string does not detect" "\"asm\""
             (detect-of "asm") nil)
      (check result "detector: magic alone is a header fragment" "8 -> 4 bytes"
             (detect-of (wasm-concat-octets #(0 97 115 109))) nil)
      (check result "detector: seven bytes, magic + half a version"
             "#(0 97 115 109 1 0 0)"
             (detect-of (wasm-concat-octets #(0 97 115 109 1 0 0))) nil)
      (check result "detector: exactly eight bytes with the magic"
             "#(0 97 115 109 1 0 0 0)"
             (detect-of *wasm-header*) t)
      (check result "detector: eight bytes, wrong magic" "asm\\0"
             (detect-of (wasm-concat-octets #(97 115 109 0 1 0 0 0))) nil)
      (dolist (name '("jsc-chunk.jsc" "jsc-cjs-chunk.bin" "jsc-cjs-sec.bin"
                      "v8-codecache.jsc" "v8-codecache-sealed.jsc"))
        (check result (format nil "detector: rejects ~a" name) name
               (detect-of (wasm-read-fixture-bytes name)) nil)))

    ;; ---- a section whose size uses a MULTI-BYTE LEB128 ---------------
    ;;
    ;; STRUCTURAL, not oracle-pinned: neither fixture has a section larger than
    ;; 46 bytes, so every section size in them is one LEB byte. This module's
    ;; data section is 146 bytes, which encodes as 0x92 0x01. A reader that
    ;; consumed a single byte would see size 0x12 = 18, treat the next 18 bytes
    ;; as the whole section, and then read the REST of the payload as a new
    ;; section header — six garbage sections and a note, not a clean parse.
    (let* ((payload (wasm-concat-octets (wasm-string-table '("answer-is-42" "four"))
                                   ;; NUL filler, not printable filler: the size
                                   ;; must cross 127 so the length LEB is two
                                   ;; bytes, and printable padding would become
                                   ;; a data string of its own.
                                   (make-array 160 :element-type '(unsigned-byte 8)
                                                   :initial-element 0)))
           (body (wasm-concat-octets
                  (wasm-uleb-octets 1)                      ; one segment
                  #(0)                                 ; flag 0, memory 0
                  #(#x41 #x00 #x0B)                    ; i32.const 0; end
                  (wasm-uleb-octets (length payload))
                  payload))
           (data-section (wasm-section-octets 11 body))
           (bytes (wasm-module-of
                   (wasm-section-octets 1 (wasm-concat-octets (wasm-uleb-octets 1) #(#x60)
                                                    (wasm-uleb-octets 0)
                                                    (wasm-uleb-octets 0)))
                   (wasm-section-octets 3 (wasm-concat-octets (wasm-uleb-octets 1) (wasm-uleb-octets 0)))
                   (wasm-section-octets 7 (wasm-concat-octets
                                      (wasm-uleb-octets 2)
                                      (wasm-name-octets "answer") #(0) (wasm-uleb-octets 0)
                                      (wasm-name-octets "mem") #(2) (wasm-uleb-octets 0)))
                   data-section))
           (info (vovas.engine.wasm:parse-wasm-module bytes)))
      (record result (>= (length body) 128)
              "crafted-answer: the data section really needs a multi-byte size"
              "data section body length" (length body) ">= 128")
      (check result "crafted-answer: the size LEB is two bytes" "body length"
             (length (wasm-uleb-octets (length body))) 2)
      (record result (not (null info)) "crafted-answer: parses" "hand-built"
              info "a wasm-module-info")
      (when info
        (check result "crafted-answer: exactly four sections, not garbage after"
               "sections" (length (vovas.engine.wasm:wasm-module-info-sections info))
               4)
        (check result "crafted-answer: no notes" "notes"
               (vovas.engine.wasm:wasm-module-info-notes info) nil)
        (check result "crafted-answer: the data section's recorded size"
               "section 11"
               (fourth (assoc 11 (wasm-section-triples info)))
               (length body))
        (check result "crafted-answer: export named answer is func 0"
               "export section"
               (wasm-export-triples info) '(("answer" "func" 0) ("mem" "memory" 0)))
        (check result "crafted-answer: the export backfills the function name"
               "function names" (vovas.engine.wasm:function-names info)
               '("answer"))
        (check result "crafted-answer: both data strings found" "data strings"
               (vovas.engine.wasm:wasm-module-info-data-strings info)
               '("answer-is-42" "four"))))

    ;; ---- a TRUNCATED section is rejected, not read past --------------
    ;;
    ;; Cut the real fixture inside its data section: the section declares 45
    ;; bytes and only 33 remain. The Rust pushes
    ;; `section data overruns the module` and STOPS, returning the six sections
    ;; it already read. A port that clamped the size to what was left would
    ;; instead scan 33 bytes of half a segment and report data strings that are
    ;; not in the file.
    (let* ((full (wasm-read-fixture-bytes "wasm-data.wasm"))
           (cut (subseq full 0 90))
           (info (vovas.engine.wasm:parse-wasm-module cut)))
      (record result (not (null info)) "truncated: still returns a module" "90 of 141"
              info "a wasm-module-info")
      (when info
        (check result "truncated: the note names the overrunning section" "90 of 141"
               (vovas.engine.wasm:wasm-module-info-notes info)
               '("section data overruns the module"))
        (check result "truncated: the sections before it are kept" "90 of 141"
               (length (vovas.engine.wasm:wasm-module-info-sections info)) 5)
        (check result "truncated: no data strings invented from the fragment"
               "90 of 141"
               (vovas.engine.wasm:wasm-module-info-data-strings info) nil)))
    ;; A header cut after the id byte: the size LEB has nowhere to come from.
    (let* ((full (wasm-read-fixture-bytes "wasm-data.wasm"))
           (info (vovas.engine.wasm:parse-wasm-module (subseq full 0 9))))
      (record result (not (null info)) "truncated header: returns a module" "9 bytes"
              info "a wasm-module-info")
      (when info
        (check result "truncated header: note names the offset" "9 bytes"
               (vovas.engine.wasm:wasm-module-info-notes info)
               '("truncated section header at 9"))
        (check result "truncated header: no sections" "9 bytes"
               (vovas.engine.wasm:wasm-module-info-sections info) nil)))
    ;; A truncated module is still DETECTED - the magic is intact. Detection
    ;; answers "is this the wasm format", not "is this well-formed".
    (check result "truncated: detection is about the magic, not the body" "9 bytes"
           (vovas.engine.wasm:detect-wasm-module
            (subseq (wasm-read-fixture-bytes "wasm-data.wasm") 0 9))
           t)
    ;; The three ways a caller can hand this layer the same bytes must all parse
    ;; identically: an octet vector (how the pipeline holds it), a list of
    ;; integers, and a Lisp string of latin-1 characters. The Rust takes `&[u8]`
    ;; and never faces the question; here a type-only rejection would look like a
    ;; content verdict, so the equivalence is pinned.
    (let* ((bytes (wasm-read-fixture-bytes "wasm-data.wasm"))
           (as-octets (vovas.engine.wasm:parse-wasm-module bytes))
           (as-list (vovas.engine.wasm:parse-wasm-module (coerce bytes 'list)))
           (as-string (vovas.engine.wasm:parse-wasm-module (map 'string #'code-char bytes))))
      (check result "input shape: a list of integers parses identically"
             "(coerce bytes 'list)"
             (and as-list (vovas.engine.wasm:wasm-module-info-data-strings as-list))
             (and as-octets (vovas.engine.wasm:wasm-module-info-data-strings as-octets)))
      (check result "input shape: an octet STRING parses identically"
             "(map 'string #'code-char bytes)"
             (and as-string (vovas.engine.wasm:wasm-module-info-data-strings as-string))
             (and as-octets (vovas.engine.wasm:wasm-module-info-data-strings as-octets)))
      (check result "input shape: the string form keeps the module name too"
             "(map 'string #'code-char bytes)"
             (and as-string (vovas.engine.wasm:wasm-module-info-module-name as-string))
             "handcrafted_module"))

    ;; ---- an EXPORT section cut mid-entry -----------------------------
    ;;
    ;; STRUCTURAL: the walk stops at the section end and reports a partial
    ;; decode, keeping the exports it did read. A port that let the loop run
    ;; until the count was satisfied would read into the bytes after the section
    ;; and invent an export.
    (let* ((good (wasm-concat-octets (wasm-uleb-octets 2)
                                (wasm-name-octets "keep") #(0) (wasm-uleb-octets 0)
                                (wasm-name-octets "lost") #(0) (wasm-uleb-octets 1)))
           ;; Declare two exports but supply room for one and a half.
           (cut (subseq good 0 (+ 1 1 (length (wasm-name-octets "keep")) 2 4)))
           (info (vovas.engine.wasm:parse-wasm-module
                  (wasm-module-of (wasm-section-octets 7 cut)))))
      (record result (not (null info)) "export cut mid-entry: parses" "hand-built"
              info "a wasm-module-info")
      (when info
        (check result "export cut mid-entry: a partial-decode note" "hand-built"
               (vovas.engine.wasm:wasm-module-info-notes info)
               '("section export partially decoded"))
        (check result "export cut mid-entry: the complete entry survives"
               "hand-built" (wasm-export-triples info) '(("keep" "func" 0)))))

    ;; ---- the import section, all four kinds --------------------------
    ;;
    ;; STRUCTURAL: neither fixture imports anything, so this is the only place
    ;; the import walker runs. Each kind has a different descriptor length, and
    ;; getting one wrong desynchronises every import after it — which is why all
    ;; four appear in one module and all four are asserted.
    (let* ((body (wasm-concat-octets
                  (wasm-uleb-octets 4)
                  (wasm-name-octets "env") (wasm-name-octets "fn0") #(0) (wasm-uleb-octets 0)
                  (wasm-name-octets "env") (wasm-name-octets "tbl")
                  #(1 #x70 #x00) (wasm-uleb-octets 1)              ; table: funcref, min 1
                  (wasm-name-octets "env") (wasm-name-octets "mem")
                  #(2 #x01) (wasm-uleb-octets 1) (wasm-uleb-octets 2)   ; memory: min 1 max 2
                  (wasm-name-octets "wasi") (wasm-name-octets "glob")
                  #(3 #x7F #x01)))                            ; global: i32, mutable
           (info (vovas.engine.wasm:parse-wasm-module
                  (wasm-module-of (wasm-section-octets 2 body)))))
      (record result (not (null info)) "imports: parses" "hand-built"
              info "a wasm-module-info")
      (when info
        (check result "imports: all four kinds, each descriptor skipped correctly"
               "hand-built"
               (wasm-import-triples info)
               '(("env" "fn0" "func") ("env" "tbl" "table")
                 ("env" "mem" "memory") ("wasi" "glob" "global")))
        (check result "imports: no notes" "hand-built"
               (vovas.engine.wasm:wasm-module-info-notes info) nil)))

    ;; ---- the name section's ordering and its precedence --------------
    ;;
    ;; STRUCTURAL for the ordering: `BTreeMap<u32,String>` iterates ASCENDING BY
    ;; INDEX, and the Rust test reads `.values()`. Here the name subsection lists
    ;; index 1 before index 0, so an implementation that returned insertion
    ;; order would answer ("b" "a").
    (let* ((pairs (wasm-concat-octets (wasm-uleb-octets 2)
                                 (wasm-uleb-octets 1) (wasm-name-octets "b")
                                 (wasm-uleb-octets 0) (wasm-name-octets "a")))
           (tpairs (wasm-concat-octets (wasm-uleb-octets 1)
                                  (wasm-uleb-octets 0) (wasm-name-octets "sig")))
           (body (wasm-concat-octets (wasm-name-octets "name")
                                #(1) (wasm-uleb-octets (length pairs)) pairs
                                #(4) (wasm-uleb-octets (length tpairs)) tpairs))
           (info (vovas.engine.wasm:parse-wasm-module
                  (wasm-module-of (wasm-section-octets 0 body)))))
      (record result (not (null info)) "name order: parses" "hand-built"
              info "a wasm-module-info")
      (when info
        (check result "name order: function names come out by ascending index"
               "index 1 listed before index 0"
               (vovas.engine.wasm:function-names info) '("a" "b"))
        (check result "name order: pairs carry the indices" "hand-built"
               (vovas.engine.wasm:function-name-pairs info)
               '((0 . "a") (1 . "b")))
        (check result "name order: the type-name subsection is read" "id 4"
               (vovas.engine.wasm:type-name-pairs info) '((0 . "sig")))
        (check result "name order: the custom section records its own name"
               "hand-built"
               (vovas.engine.wasm:wasm-section-custom-name
                (first (vovas.engine.wasm:wasm-module-info-sections info)))
               "name")))
    ;; Precedence: the name section wins over an export of the same index.
    ;; `if !function_names.contains_key(&exp.index)` is the Rust's guard, and a
    ;; port that backfilled unconditionally would answer "pubfn" here — losing
    ;; the internal name the module author recorded.
    (let* ((pairs (wasm-concat-octets (wasm-uleb-octets 1) (wasm-uleb-octets 0)
                                 (wasm-name-octets "internal")))
           (custom (wasm-concat-octets (wasm-name-octets "name")
                                  #(1) (wasm-uleb-octets (length pairs)) pairs))
           (exports (wasm-concat-octets (wasm-uleb-octets 1)
                                   (wasm-name-octets "pubfn") #(0) (wasm-uleb-octets 0)))
           (info (vovas.engine.wasm:parse-wasm-module
                  (wasm-module-of (wasm-section-octets 7 exports)
                             (wasm-section-octets 0 custom)))))
      (check result "precedence: the name section beats the export backfill"
             "name `internal`, export `pubfn`, same index 0"
             (and info (vovas.engine.wasm:function-names info))
             '("internal")))

    ;; ---- the printable-run scanner's floor, flush and dedupe ---------
    ;;
    ;; STRUCTURAL. Three separate behaviours, all of them one-line mistakes:
    ;; a run shorter than four characters is not reported; a run that ends the
    ;; segment (no trailing NUL) IS reported; and the same string in two
    ;; segments appears once.
    (let* ((payload (wasm-string-table '("abc" "abcd" "wxyz" "dupstr" "dupstr")))
           (body (wasm-concat-octets (wasm-uleb-octets 1) #(0) #(#x41 #x00 #x0B)
                                (wasm-uleb-octets (length payload)) payload))
           (info (vovas.engine.wasm:parse-wasm-module
                  (wasm-module-of (wasm-section-octets 11 body)))))
      (check result "data strings: shorter than four is dropped, the rest kept"
             "\"abc\\0abcd\\0wxyz\\0dupstr\\0dupstr\""
             (and info (vovas.engine.wasm:wasm-module-info-data-strings info))
             '("abcd" "wxyz" "dupstr")))
    ;; The trailing run with no NUL after it - the shape every hand-built
    ;; module has, and the one an `on non-printable` flush loses.
    (let* ((payload (wasm-utf8-octets "trailing-run-no-nul"))
           (body (wasm-concat-octets (wasm-uleb-octets 1) #(0) #(#x41 #x00 #x0B)
                                (wasm-uleb-octets (length payload)) payload))
           (info (vovas.engine.wasm:parse-wasm-module
                  (wasm-module-of (wasm-section-octets 11 body)))))
      (check result "data strings: the final run is flushed at the segment end"
             "no trailing NUL"
             (and info (vovas.engine.wasm:wasm-module-info-data-strings info))
             '("trailing-run-no-nul")))
    ;; A passive segment (flag 1) has no init expression: the byte right after
    ;; the flag is the segment size. Reading an expression anyway would consume
    ;; the size as an opcode and desynchronise.
    (let* ((payload (wasm-utf8-octets "passive segment"))
           (body (wasm-concat-octets (wasm-uleb-octets 1) #(1)
                                (wasm-uleb-octets (length payload)) payload))
           (info (vovas.engine.wasm:parse-wasm-module
                  (wasm-module-of (wasm-section-octets 11 body)))))
      (check result "data strings: a passive segment has no init expression"
             "flag 1"
             (and info (vovas.engine.wasm:wasm-module-info-data-strings info))
             '("passive segment")))

    ;; ---- the integer layer -------------------------------------------
    ;;
    ;; The spec's own LEB128 examples, plus the two ceilings.
    (flet ((uleb-of (&rest octets)
             (multiple-value-list
              (vovas.engine.wasm:read-uleb128
               (coerce octets '(vector (unsigned-byte 8))) 0 (length octets))))
           (sleb-of (&rest octets)
             (multiple-value-list
              (vovas.engine.wasm:read-sleb128
               (coerce octets '(vector (unsigned-byte 8))) 0 (length octets)))))
      (check result "uleb: 0x00 is 0" "#(0)" (uleb-of #x00) '(0 1))
      (check result "uleb: 0x7f is 127" "#(127)" (uleb-of #x7F) '(127 1))
      (check result "uleb: 0xE5 0x8E 0x26 is 624485" "#(229 142 38)"
             (uleb-of #xE5 #x8E #x26) '(624485 3))
      (check result "uleb: 0x80 0x01 is 128" "#(128 1)"
             (uleb-of #x80 #x01) '(128 2))
      ;; Six bytes is the ceiling (shifts 0..35). A seventh is refused, which is
      ;; what stops 0x80 filler from looping forever - the wrong implementation
      ;; here is not a wrong number, it is a HANG.
      (check result "uleb: a continued seventh byte is refused, not looped"
             "seven 0x80 bytes"
             (uleb-of #x80 #x80 #x80 #x80 #x80 #x80 #x80) '(nil nil))
      (check result "uleb: a value that runs past the limit fails"
             "#(0x80) with limit 1" (uleb-of #x80) '(nil nil))
      (check result "uleb: an empty read fails" "limit 0" (uleb-of) '(nil nil))
      ;; SLEB: the same bytes read signed. 0x7f is -1, not 127 - a port that
      ;; reused the unsigned reader here would make every negative constant
      ;; wrong by its full bias.
      (check result "sleb: 0x7f is -1" "#(127)" (sleb-of #x7F) '(-1 1))
      (check result "sleb: 0x3f is 63" "#(63)" (sleb-of #x3F) '(63 1))
      (check result "sleb: 0xC0 0xBB 0x78 is -123456" "#(192 187 120)"
             (sleb-of #xC0 #xBB #x78) '(-123456 3)))
    ;; wasm-name: the length prefix bounds the read, and a non-ASCII byte
    ;; rejects the WHOLE name instead of being dropped.
    (multiple-value-bind (name next)
        (vovas.engine.wasm:wasm-name (wasm-concat-octets (wasm-uleb-octets 5) (wasm-utf8-octets "hello"))
                                     0 6)
      (check result "wasm-name: length prefix + bytes" "\\05hello"
             (list name next) '("hello" 6)))
    (multiple-value-bind (name next)
        (vovas.engine.wasm:wasm-name
         (wasm-concat-octets (wasm-uleb-octets 4) (wasm-utf8-octets "a")
                        (vector 0) (wasm-utf8-octets "bc"))
         0 5)
      (check result "wasm-name: a NUL byte rejects the name" "a, NUL, bc"
             (list name next) '(nil nil)))
    (multiple-value-bind (name next)
        (vovas.engine.wasm:wasm-name (wasm-concat-octets (wasm-uleb-octets 9) (wasm-utf8-octets "short"))
                                     0 6)
      (check result "wasm-name: a length past the limit fails" "len 9, 5 present"
             (list name next) '(nil nil)))

    ;; ---- the vocabulary ----------------------------------------------
    (check result "section-name: 11 is data" "11"
           (vovas.engine.wasm:section-name 11) "data")
    (check result "section-name: 12 is dataCount" "12"
           (vovas.engine.wasm:section-name 12) "dataCount")
    (check result "section-name: an unassigned id keeps its number" "13"
           (vovas.engine.wasm:section-name 13) "unknown-13")
    (check result "kind-name: 3 is global" "3"
           (vovas.engine.wasm:kind-name 3) "global")
    (check result "kind-name: an out-of-range kind keeps its decimal form" "7"
           (vovas.engine.wasm:kind-name 7) "7")
    ;; The u32 saturation: `count as u32` in Rust, so a declared function count
    ;; of 2^32 reads back as 4294967295 and not as 4294967296. No fixture
    ;; reaches this; it is pinned because a bignum here would serialise as a
    ;; longer number than the original ever writes.
    (let ((info (vovas.engine.wasm:parse-wasm-module
                 (wasm-module-of (wasm-section-octets 3 (wasm-uleb-octets #x100000000))))))
      (check result "function count saturates at u32::MAX like `count as u32`"
             "declared 2^32"
             (and info (vovas.engine.wasm:wasm-module-info-function-count info))
             #xFFFFFFFF))
    ;; An unknown section id is consumed, not walked, and its name says so.
    (let ((info (vovas.engine.wasm:parse-wasm-module
                 (wasm-module-of (wasm-section-octets 42 #(1 2 3))))))
      (check result "an unassigned section id is consumed and named" "id 42"
             (and info (wasm-section-triples info))
             '((42 "unknown-42" 10 3))))

    ;; ---- PLAUSIBLE WRONG IMPLEMENTATIONS -----------------------------
    ;;
    ;; Each of these is what a careful person writes first. The gate asserts the
    ;; port does NOT answer that way, so a green run means the port is right for
    ;; the right reason and not merely agreeing with a fixture by luck.
    (flet ((probe (label thunk wrong)
             (unless (probe-mutation label thunk wrong)
               (setf probes-ok nil))))

      ;; (1) `starts_with(magic)` without the eight-byte floor. This is the most
      ;; natural way to write the detector and it accepts four magic bytes.
      (probe "WRONG-IMPL: detection does not stop at the magic"
             (lambda () (vovas.engine.wasm:detect-wasm-module #(0 97 115 109)))
             t)

      ;; (2) `(<= b #x7E)` widened to `#x7F`, i.e. DEL accepted as a name byte.
      ;; Crafted as a custom section whose name is "na" DEL "me": the port must
      ;; refuse the WHOLE name, and the wrong answer is that mangled name.
      (let* ((body (wasm-concat-octets (wasm-uleb-octets 5) (wasm-utf8-octets "na")
                                  (vector #x7F) (wasm-utf8-octets "me")))
             (info (vovas.engine.wasm:parse-wasm-module
                    (wasm-module-of (wasm-section-octets 0 body)))))
        (probe "WRONG-IMPL: 0x7F (DEL) is not a printable name byte"
               (lambda ()
                 (and info (vovas.engine.wasm:wasm-section-custom-name
                            (first (vovas.engine.wasm:wasm-module-info-sections info)))))
               (concatenate 'string "na" (string (code-char #x7F)) "me")))

      ;; (3) the data-string floor as `>= 3` instead of `>= 4`.
      (let* ((payload (wasm-concat-octets (wasm-utf8-octets "abc") (vector 0)
                                     (wasm-utf8-octets "abcd")))
             (body (wasm-concat-octets (wasm-uleb-octets 1) #(0) #(#x41 #x00 #x0B)
                                  (wasm-uleb-octets (length payload)) payload))
             (info (vovas.engine.wasm:parse-wasm-module
                    (wasm-module-of (wasm-section-octets 11 body)))))
        (probe "WRONG-IMPL: a three-character run is below the string floor"
               (lambda ()
                 (and info (vovas.engine.wasm:wasm-module-info-data-strings info)))
               '("abc" "abcd")))

      ;; (4) section `offset` pointing at the id byte instead of the payload.
      ;; The first section of wasm-data.wasm has its id at 8 and its payload at
      ;; 10; an off-by-two is what an `offset: at` written before `at += 1`
      ;; produces.
      (let ((info (vovas.engine.wasm:parse-wasm-module
                   (wasm-read-fixture-bytes "wasm-data.wasm"))))
        (probe "WRONG-IMPL: a section's offset is its PAYLOAD start, not its id"
               (lambda ()
                 (and info (third (first (wasm-section-triples info)))))
               8))

      ;; (5) the flush only on a non-printable byte, losing the trailing run.
      (let* ((payload (wasm-utf8-octets "tail"))
             (body (wasm-concat-octets (wasm-uleb-octets 1) #(0) #(#x41 #x00 #x0B)
                                  (wasm-uleb-octets (length payload)) payload))
             (info (vovas.engine.wasm:parse-wasm-module
                    (wasm-module-of (wasm-section-octets 11 body)))))
        (probe "WRONG-IMPL: the trailing printable run is not dropped"
               (lambda ()
                 (and info (vovas.engine.wasm:wasm-module-info-data-strings info)))
               nil))

      ;; (6) reusing the unsigned LEB reader for a signed value.
      (probe "WRONG-IMPL: SLEB128 is not ULEB128 (0x7f is -1, not 127)"
             (lambda ()
               (multiple-value-bind (v n)
                   (vovas.engine.wasm:read-sleb128 #(127) 0 1)
                 (list v n)))
             '(127 1))

      ;; (7) a truncation handled by CLAMPING the size to what is left instead
      ;; of rejecting it. That port produces data strings out of half a segment.
      (let* ((full (wasm-read-fixture-bytes "wasm-data.wasm"))
             (info (vovas.engine.wasm:parse-wasm-module (subseq full 0 90))))
        (probe "WRONG-IMPL: a truncated section is rejected, not clamped"
               (lambda ()
                 (and info (vovas.engine.wasm:wasm-module-info-notes info)))
               nil)))

    ;; ---- non-vacuity -------------------------------------------------
    (record result (plusp (gate-result-total result))
            "the gate ran at least one case" "case count"
            (gate-result-total result) "> 0")
    (record result (plusp (length (vovas.engine.wasm:wasm-module-info-sections
                                   (vovas.engine.wasm:parse-wasm-module
                                    (wasm-read-fixture-bytes "wasm-named.wasm")))))
            "wasm-named.wasm yielded sections" "section count"
            (length (vovas.engine.wasm:wasm-module-info-sections
                     (vovas.engine.wasm:parse-wasm-module
                      (wasm-read-fixture-bytes "wasm-named.wasm"))))
            "> 0")

    (when verbose
      (format t "~&wasm gate: ~a/~a cases match~%"
              (gate-result-passed result) (gate-result-total result))
      (report-failures result)
      (if probes-ok
          (format t "~&  every wrong implementation rejected~%")
          (format t "~&  SOME WRONG-IMPLEMENTATION PROBES FAILED~%")))
    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp (gate-result-total result))
         probes-ok)))
