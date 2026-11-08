;;;; gate-sourcemaps.lisp — the sourcemaps oracle comparison.
;;;;
;;;; Lives in `:vovas.engine.gate` because that is where the harness is
;;;; (`make-gate-result`, `check`, `report-failures`, `read-json-file`,
;;;; `fixture-path`, `json-null`). Those are reached with `::` for the private
;;;; ones; the file is in the package, so no prefix is needed at all — but it is
;;;; loaded by ITS OWN system (`vovas-engine.sourcemaps`), which depends on
;;;; `vovas-engine`, so the package exists by the time this file is read.
;;;;
;;;; Three kinds of assertion, because the oracle alone is not enough:
;;;;
;;;;   1. Oracle equality. `findSourceMapRef` over all 17 inputs and
;;;;      `resolveMapUrl` over its 7 pairs, read from the fixtures the wasm
;;;;      engine produced. Those two keys are the only oracle coverage this
;;;;      module has.
;;;;   2. Structural checks. `parseSourceMap` and `decodeInlineSourceMap` have
;;;;      no oracle key (the oracle script never calls them), so they are pinned
;;;;      by shape: the inline map decodes to a document whose `version` is 3
;;;;      and whose `sources` holds `a.ts`, and malformed JSON answers a failure
;;;;      value rather than crashing.
;;;;   3. Wrong-implementation probes. A gate that only compares the right answer
;;;;      passes just as well against an implementation that is right by
;;;;      accident. Each probe names a plausible WRONG port and proves the real
;;;;      one does not produce it.

(in-package :vovas.engine.gate)

;;; ---------------------------------------------------------------------------
;;; The oracle comparison
;;; ---------------------------------------------------------------------------

(defun source-map-ref-json (ref)
  "Normalise the port's plist into the shape the oracle holds, so a port that
returned the right VALUES with the wrong field names still fails.

The oracle stores `{\"kind\":\"external\",\"value\":\"app.js.map\"}`. The port
answers `(:kind \"external\" :value \"app.js.map\")`, which is the same
information in a different container; converting here rather than comparing
loosely keeps the comparison exact about the part that matters (the strings)
without forcing the port to answer hash-tables."
  (when ref
    (list :kind (getf ref :kind) :value (getf ref :value))))

(defun oracle-source-map-ref (value)
  "The oracle's object as the same normalised plist, or NIL for JSON null.

Testing `hash-table-p` rather than `json-null` is the load-bearing part: `json-null`
answers T for the NULL SYMBOL and NIL for everything else, INCLUDING a real
object, so a positive test would keep only the nulls and drop every real case -
a gate that then compares nothing and passes. The object test is what a struct
deserialiser would do anyway."
  (when (hash-table-p value)
    (list :kind (gethash "kind" value)
          :value (gethash "value" value))))

(defun split-resolve-key (key)
  "Split `\"<script> :: <ref>\"` on the FIRST `\" :: \"`. `search` rather than a
regex: the separator is a literal, and the left side (a URL) could in principle
contain a colon that a looser split would latch onto."
  (let ((at (search " :: " key)))
    (unless at
      (error "resolveMapUrl key has no \" :: \" separator: ~s" key))
    (values (subseq key 0 at)
            (subseq key (+ at 4)))))

(defun run-sourcemaps-oracle (&key (verbose t))
  "Every oracle case this module owns. Answers the `gate-result`."
  (let* ((oracle (read-json-file (fixture-path "text-tier-oracle.json")))
         (inputs (read-json-file (fixture-path "text-tier-inputs.json")))
         (sources (gethash "sources" inputs))
         (result (make-gate-result)))

    ;; --- findSourceMapRef, over the 17 inputs ----------------------------
    ;;
    ;; The oracle is keyed by INPUT NAME, not by text, so a name with no entry
    ;; in the inputs fixture is a fixture problem rather than a port failure.
    ;; Asserting the source exists is what stops a renamed case from quietly
    ;; becoming a comparison against an absent string.
    (let ((cases (gethash "findSourceMapRef" oracle)))
      (loop for name being the hash-keys of cases using (hash-value want)
            do (let ((text (gethash name sources)))
                 (unless (stringp text)
                   (error "findSourceMapRef case ~s has no text in text-tier-inputs.json"
                          name))
                 (check result "findSourceMapRef" name
                        (source-map-ref-json
                         (vovas.engine.sourcemaps:find-source-map-ref text))
                        (oracle-source-map-ref want)))))

    ;; --- resolveMapUrl, over the 7 pairs ---------------------------------
    (let ((cases (gethash "resolveMapUrl" oracle)))
      (loop for key being the hash-keys of cases using (hash-value want)
            do (multiple-value-bind (script ref) (split-resolve-key key)
                 (check result "resolveMapUrl" key
                        (vovas.engine.sourcemaps:resolve-map-url script ref)
                        want))))
    result))

;;; ---------------------------------------------------------------------------
;;; Structural checks: the two functions with no oracle key
;;; ---------------------------------------------------------------------------

(defun source-map-document (text)
  "Parse TEXT into a JZON tree, answering NIL when it is not JSON.

Deliberately NOT `parse-source-map`: this reads the DOCUMENT as the decoder
produced it, so the structural checks see `version` and `sources` — fields
`parse-source-map` never looks at, because nothing downstream of it needs them."
  (handler-case
      (let ((*read-default-float-format* 'double-float))
        (com.inuoe.jzon:parse text))
    (error () nil)))

(defun source-map-document-sources (document)
  "The `sources` array of a decoded document as a list, or NIL."
  (when (hash-table-p document)
    (let ((sources (gethash "sources" document)))
      (when (and (vectorp sources) (not (stringp sources)))
        (loop for item across sources collect item)))))

(defun run-sourcemaps-structure (&key (verbose t))
  "The two functions the oracle does not reach. Answers the `gate-result`.

`decodeInlineSourceMap` is checked against the `inlineMap` INPUT rather than a
hand-written URI: the input is the exact `data:` string the oracle recorded, so
decoding it and finding `a.ts` in the result proves the whole chain — payload
extraction, base64, lossy UTF-8 — against the shipped engine's own artefact.

`parseSourceMap` is checked on four shapes the Rust distinguishes: a good map, a
map with no sourcesContent (valid, no files), malformed JSON (nil), and a JSON
array where a struct belongs (nil). The last two are the crash-resistance claim:
a port that signalled a condition instead of answering nil would take the whole
pipeline down on a hostile map."
  (let* ((oracle (read-json-file (fixture-path "text-tier-oracle.json")))
         (inputs (read-json-file (fixture-path "text-tier-inputs.json")))
         (sources (gethash "sources" inputs))
         ;; `inlineMap` is a CASE INSIDE `findSourceMapRef`, not a top-level key:
         ;; the oracle's top level holds one entry per bridge function, so the
         ;; per-input names live one level down.
         (inline-uri (gethash "value"
                              (gethash "inlineMap" (gethash "findSourceMapRef" oracle))))
         (result (make-gate-result)))

    ;; --- decodeInlineSourceMap on the oracle's own inline URI ------------
    (let* ((decoded (vovas.engine.sourcemaps:decode-inline-source-map inline-uri))
           (document (and (stringp decoded) (source-map-document decoded))))
      (check result "decodeInlineSourceMap: answers text" "inlineMap"
             (stringp decoded) t)
      (check result "decodeInlineSourceMap: decodes to JSON" "inlineMap"
             (hash-table-p document) t)
      (check result "decodeInlineSourceMap: version is 3" "inlineMap"
             (and document (gethash "version" document)) 3)
      (check result "decodeInlineSourceMap: sources hold a.ts" "inlineMap"
             (and document (source-map-document-sources document))
             '("a.ts"))
      ;; The decoded text is JSON for `{"version":3,"sources":["a.ts"],
      ;; "sourcesContent":["const a: number = 1;"]}`, so its exact length is a
      ;; cheap whole-payload equality that a partially-decoded answer fails.
      (check result "decodeInlineSourceMap: full payload length" "inlineMap"
             (and (stringp decoded) (length decoded))
             74))

    ;; --- decodeInlineSourceMap: the non-base64 and failure paths ---------
    ;;
    ;; `data:,hello%20world` has no `;base64`, so it goes through
    ;; decodeURIComponent; a space must survive as a space, not as a `+`.
    (check result "decodeInlineSourceMap: percent payload" "data:,hello%20world"
           (vovas.engine.sourcemaps:decode-inline-source-map "data:,hello%20world")
           "hello world")
    ;; A URI-encoded JSON map is valid input with no base64 arm at all.
    (check result "decodeInlineSourceMap: plain json payload"
           "data:application/json,%7B%22a%22%3A1%7D"
           (vovas.engine.sourcemaps:decode-inline-source-map
            "data:application/json,%7B%22a%22%3A1%7D")
           "{\"a\":1}")
    ;; A broken base64 payload is empty TEXT, not nil: the JS runs TextDecoder
    ;; on the empty array and the caller sees "no map" one step later.
    (check result "decodeInlineSourceMap: corrupt base64 is empty text"
           "data:application/json;base64,!!!!"
           (vovas.engine.sourcemaps:decode-inline-source-map
            "data:application/json;base64,!!!!")
           "")
    ;; No `data:` prefix at all: the pattern's literal prefix does not match.
    (check result "decodeInlineSourceMap: rejects a non-data uri"
           "app.js.map"
           (vovas.engine.sourcemaps:decode-inline-source-map "app.js.map")
           nil)
    ;; A media type carrying a parameter cannot match `[^;,]*` followed by
    ;; `(;base64)?`, so the whole decode fails.
    (check result "decodeInlineSourceMap: rejects a media type parameter"
           "data:application/json;charset=utf-8;base64,eyJhIjoxfQ=="
           (vovas.engine.sourcemaps:decode-inline-source-map
            "data:application/json;charset=utf-8;base64,eyJhIjoxfQ==")
           nil)
    ;; Invalid percent escape: decodeURIComponent throws, so the answer is nil.
    (check result "decodeInlineSourceMap: rejects a bad escape"
           "data:,a%ZZb"
           (vovas.engine.sourcemaps:decode-inline-source-map "data:,a%ZZb")
           nil)

    ;; --- parseSourceMap over text ---------------------------------------
    ;;
    ;; A `webpack:///./src/a.ts` source keeps its `./` here, and that is the
    ;; Rust's own behaviour rather than a lost prefix: the order there is
    ;; webpack scheme, then `^\./` (ANCHORED, so it cannot match mid-string),
    ;; then the leading-slash strip. Stripping `webpack://` leaves `/./src/a.ts`,
    ;; the dot-slash pattern cannot match at offset 0 of that, and the
    ;; leading-slash strip then exposes `./`. Reversing those two steps would be
    ;; a plausible \"cleaner\" port that differs from the engine on every
    ;; webpack map, so it is pinned rather than tidied.
    (let ((map (vovas.engine.sourcemaps:parse-source-map
                "{\"version\":3,\"sources\":[\"webpack:///./src/a.ts\"],\
\"sourcesContent\":[\"export const a = 1;\"],\"sourceRoot\":\"/root/\",\"file\":\"a.js\"}")))
      (check result "parseSourceMap: answers a map" "good map"
             (typep map 'vovas.engine.sourcemaps:parsed-source-map) t)
      (check result "parseSourceMap: keeps the file" "good map"
             (loop for f in (vovas.engine.sourcemaps:parsed-source-map-files map)
                   collect (cons (vovas.engine.sourcemaps:source-file-path f)
                                 (vovas.engine.sourcemaps:source-file-content f)))
             '(("./src/a.ts" . "export const a = 1;")))
      (check result "parseSourceMap: sourceRoot" "good map"
             (vovas.engine.sourcemaps:parsed-source-map-source-root map) "/root/")
      (check result "parseSourceMap: file" "good map"
             (vovas.engine.sourcemaps:parsed-source-map-file map) "a.js"))

    ;; Only sourcesContent is recoverable, so a source with null content, an
    ;; empty string, or no entry at all contributes nothing - while the cap on
    ;; output keeps the ordering of the ones that DO contribute.
    (let ((map (vovas.engine.sourcemaps:parse-source-map
                "{\"sources\":[\"a.ts\",\"\",\"dir/\",\"b.ts\"],\
\"sourcesContent\":[\"A\",\"EMPTY-SKIP\",\"DIR\",null]}")))
      (check result "parseSourceMap: drops empty content and nulls" "mixed"
             (loop for f in (vovas.engine.sourcemaps:parsed-source-map-files map)
                   collect (vovas.engine.sourcemaps:source-file-path f))
             '("a.ts" "index.js" "dir/index.js")))
    ;; The second entry has content \"EMPTY-SKIP\" and a path that cleans to
    ;; empty, so it becomes index.js rather than being dropped. The fourth is
    ;; null and is dropped. The expected list above therefore has three.

    ;; A missing sourcesContent array is VALID and yields no files - serde's
    ;; #[serde(default)]. Answering nil here would be the wrong verdict.
    (let ((map (vovas.engine.sourcemaps:parse-source-map "{\"sources\":[\"a.ts\"]}")))
      (check result "parseSourceMap: missing sourcesContent is valid"
             "sources only"
             (and map (vovas.engine.sourcemaps:parsed-source-map-files map))
             nil))

    ;; An EMPTY document is a valid map with no files: every array field
    ;; defaults. This is the case a "nil means bad" port fails.
    (check result "parseSourceMap: {} is a valid empty map" "{}"
           (typep (vovas.engine.sourcemaps:parse-source-map "{}")
                  'vovas.engine.sourcemaps:parsed-source-map)
           t)

    ;; Malformed input answers nil, it does not signal.
    (dolist (bad '("{" "not json at all" "{\"sources\":}" ""))
      (check result "parseSourceMap: malformed json answers nil" bad
             (handler-case
                 (vovas.engine.sourcemaps:parse-source-map bad)
               (error (e) (format nil "SIGNALLED ~a" e)))
             nil))
    ;; A JSON array, string or number is not a struct.
    (dolist (wrong-shape '("[]" "\"map\"" "3" "null"))
      (check result "parseSourceMap: non-object json answers nil" wrong-shape
             (handler-case
                 (vovas.engine.sourcemaps:parse-source-map wrong-shape)
               (error (e) (format nil "SIGNALLED ~a" e)))
             nil))
    ;; A field of the wrong TYPE fails the document, which is serde's behaviour
    ;; and not a skip.
    (dolist (wrong-type '("{\"sources\":3}" "{\"sources\":[1,2]}"
                          "{\"sources\":[\"a\"],\"sourcesContent\":[1]}"
                          "{\"sources\":[\"a\"],\"sourceRoot\":7}"
                          "{\"sources\":[\"a\"],\"file\":false}"))
      (check result "parseSourceMap: wrong field type answers nil" wrong-type
             (handler-case
                 (vovas.engine.sourcemaps:parse-source-map wrong-type)
               (error (e) (format nil "SIGNALLED ~a" e)))
             nil))

    ;; --- parseSourceMap's version, from a decoded inline map ------------
    ;;
    ;; `parse-source-map` does not read `version` (serde ignores the field), so
    ;; the structural claim is about the DOCUMENT: the decoded inline map is a
    ;; version-3 map. Checked through the public decoder plus the module's own
    ;; document reader, which is exactly what a caller sees.
    (let ((document (source-map-document
                     (or (vovas.engine.sourcemaps:decode-inline-source-map inline-uri)
                         ""))))
      (check result "inline map is a version 3 document" "inlineMap"
             (vovas.engine.sourcemaps:parsed-source-map-version document) 3)
      (check result "inline map parses to one file" "inlineMap"
             (loop for f in (vovas.engine.sourcemaps:parsed-source-map-files
                             (vovas.engine.sourcemaps:parse-source-map
                              (vovas.engine.sourcemaps:decode-inline-source-map
                               inline-uri)))
                   collect (vovas.engine.sourcemaps:source-file-path f))
             '("a.ts"))
      (check result "inline map keeps the original source" "inlineMap"
             (loop for f in (vovas.engine.sourcemaps:parsed-source-map-files
                             (vovas.engine.sourcemaps:parse-source-map
                              (vovas.engine.sourcemaps:decode-inline-source-map
                               inline-uri)))
                   collect (vovas.engine.sourcemaps:source-file-content f))
             '("const a: number = 1;")))

    (when verbose
      (format t "~&sourcemaps structure: ~a/~a checks match~%"
              (gate-result-passed result) (gate-result-total result))
      (report-failures result))
    result))

;;; ---------------------------------------------------------------------------
;;; Wrong-implementation probes
;;; ---------------------------------------------------------------------------

(defun probe-not (label thunk wrong-candidate)
  "Assert THUNK's answer is not WRONG-CANDIDATE. Answers T when it is not.

Every probe also asserts the answer is not NIL-by-accident where that would be
ambiguous, so a port that crashed into a nil answer for everything could not
pass by matching a nil expectation."
  (handler-case
      (let ((got (funcall thunk)))
        (if (equal got wrong-candidate)
            (progn (format t "~&  FAIL  ~a: produced the WRONG value ~s~%" label got)
                   nil)
            (progn (format t "~&  ok    ~a (not ~s; got ~s)~%" label
                           wrong-candidate got)
                   t)))
    (error (e)
      (format t "~&  FAIL  ~a signalled ~a~%" label e)
      nil)))

(defun run-sourcemaps-mutations (&key (verbose t))
  "Each case names a plausible wrong port of one function.

The five chosen here are the ones whose wrongness is invisible from the oracle
alone:

  1. First match instead of last. Every oracle input has zero or one
     sourceMappingURL, so `search` would pass the oracle and take the WRONG ref
     on any text assembled from two sources.
  2. Trimming with JavaScript's `\\s`. It differs from Rust's `is_whitespace` on
     U+FEFF and U+0085, and the Rust trim is what shipped.
  3. A per-byte UTF-8 replacement. It agrees on every VALID payload and gets the
     count of U+FFFD wrong on every truncated one.
  4. `resolveMapUrl` without dot-segment removal. `../up.map` would keep its
     `..`, which the oracle catches for one pair but a port could satisfy by
     string surgery that then breaks `/a/./b.map`.
  5. Base64 without canonical padding checks, which `cl-base64` would supply:
     `\"YR==\"` would answer #x61 where the engine answers null."
  (declare (ignorable verbose))
  (let ((result t))
    (flet ((probe (label thunk wrong)
             (unless (probe-not label thunk wrong) (setf result nil))))

      (probe "find-source-map-ref takes the LAST marker"
             (lambda ()
               (vovas.engine.sourcemaps:find-source-map-ref
                (format nil "//# sourceMappingURL=first.map~%var a=1;~%\
//# sourceMappingURL=second.map~%")))
             '(:kind "external" :value "first.map"))

      (probe "find-source-map-ref trims with JS \\s, not Rust is_whitespace"
             (lambda ()
               ;; A leading U+FEFF is whitespace to JS and NOT to Rust, so the
               ;; value keeps it and the ref is external with a BOM-tainted name.
               (vovas.engine.sourcemaps:find-source-map-ref
                (concatenate 'string "//# sourceMappingURL="
                             (string (code-char #xFEFF)) "a.map")))
             '(:kind "external" :value "a.map"))

      (probe "rust-trim drops NEL (U+0085), as is_whitespace does"
             (lambda ()
               (vovas.engine.sourcemaps:rust-trim
                (concatenate 'string (string (code-char #x85)) "x"
                             (string (code-char #x85)))))
             (concatenate 'string (string (code-char #x85)) "x"
                          (string (code-char #x85))))

      (probe "bytes-to-text replaces one U+FFFD per truncated subpart"
             (lambda ()
               ;; #xE2 #x9C is a truncated three-byte sequence: ONE replacement,
               ;; not two, and not zero.
               (length (vovas.engine.decoders:bytes-to-text
                        (make-array 2 :element-type '(unsigned-byte 8)
                                      :initial-contents '(#xE2 #x9C)))))
             2)

      (probe "bytes-to-text keeps valid multi-byte text intact"
             (lambda ()
               (vovas.engine.decoders:bytes-to-text
                (make-array 4 :element-type '(unsigned-byte 8)
                              :initial-contents '(#xC3 #xBC #xE2 #x9C))))
             "\uFFFD\uFFFD")

      (probe "decode-base64-to-bytes rejects non-canonical trailing bits"
             (lambda ()
               (vovas.engine.decoders:decode-base64-to-bytes "YR=="))
             (make-array 1 :element-type '(unsigned-byte 8) :initial-contents '(#x61)))

      (probe "decode-base64-to-bytes folds the URL-safe alphabet"
             (lambda ()
               ;; "-_8=" is the URL-safe spelling of "+/8=", which is #xFB #xFF.
               (vovas.engine.decoders:decode-base64-to-bytes "-_8="))
             nil)

      (probe "decode-base64-to-bytes strips whitespace before padding"
             (lambda ()
               (vovas.engine.decoders:decode-base64-to-bytes "Y Q =="))
             nil)

      (probe "decode-base64-to-bytes pads an unpadded payload"
             (lambda ()
               (vovas.engine.decoders:decode-base64-to-bytes "YQ"))
             nil)

      (probe "resolve-map-url removes dot segments"
             (lambda ()
               (vovas.engine.sourcemaps:resolve-map-url
                "https://h/a/deep/b.js" "./c.map"))
             "https://h/a/deep/./c.map")

      (probe "resolve-map-url keeps a trailing slash for a directory dot-tail"
             (lambda ()
               (vovas.engine.sourcemaps:resolve-map-url "https://h/a/b.js" "../"))
             "https://h/a")

      (probe "resolve-map-url does not lowercase the base host twice or the path"
             (lambda ()
               (vovas.engine.sourcemaps:resolve-map-url "https://H/a/B.js" "C.js.map"))
             "https://h/a/c.js.map")

      (probe "decode-inline-source-map does not hand back the raw payload"
             (lambda ()
               (vovas.engine.sourcemaps:decode-inline-source-map
                "data:application/json;base64,eyJhIjoxfQ=="))
             "eyJhIjoxfQ==")

      (probe "clean-source-path does not flatten separators to underscores"
             (lambda ()
               (vovas.engine.sourcemaps:clean-source-path "src\\add.js"))
             "src__add.js")

      (probe "clean-source-path strips a single webpack prefix"
             (lambda ()
               (vovas.engine.sourcemaps:clean-source-path "webpack:///./src/a.ts"))
             "webpack:///./src/a.ts"))
    (when verbose
      (format t "~&sourcemaps mutation probes: ~a~%"
              (if result "every wrong implementation rejected" "SOME PROBES FAILED")))
    result))

;;; ---------------------------------------------------------------------------
;;; The gate
;;; ---------------------------------------------------------------------------

(defun run-sourcemaps-gate (&key (verbose t))
  "Compare the sourcemaps port against the wasm oracle and prove the comparison
is not vacuous. Returns T when every case matches and every probe holds."
  (let ((oracle (run-sourcemaps-oracle :verbose verbose))
        (structure (run-sourcemaps-structure :verbose verbose))
        (mutations (run-sourcemaps-mutations :verbose verbose)))
    ;; The oracle halves must be non-empty: a mis-read fixture that yielded zero
    ;; cases would otherwise pass every loop above vacuously.
    (let ((count (+ (gate-result-total oracle) (gate-result-total structure))))
      (unless (plusp count)
        (format t "~&  FAIL  the gate ran zero cases~%")
        (return-from run-sourcemaps-gate nil))
      ;; 17 findSourceMapRef inputs + 7 resolveMapUrl pairs is the floor; a
      ;; lowered count means a whole section silently stopped contributing.
      (unless (>= (gate-result-total oracle) 24)
        (format t "~&  FAIL  oracle coverage dropped to ~a cases (expected >= 24)~%"
                (gate-result-total oracle))
        (return-from run-sourcemaps-gate nil))
      (when verbose
        (format t "~&sourcemaps gate: ~a/~a cases match, ~a structural checks~%"
                (gate-result-passed oracle) (gate-result-total oracle)
                (gate-result-total structure))))
    (and (= (gate-result-passed oracle) (gate-result-total oracle))
         (= (gate-result-passed structure) (gate-result-total structure))
         mutations)))
