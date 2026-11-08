;;;; pipeline.lisp — the asset pipeline, ported from pipeline.rs.
;;;;
;;;; This is the LAST engine module and it is pure orchestration: every rung it
;;;; calls was ported and gated before this file existed. It therefore
;;;; REIMPLEMENTS NOTHING. `peel-text`, the packer rungs, the bundler splitter,
;;;; the beautifier, the source-map reader, the wasm/JSC/V8 parsers, SHA-256 and
;;;; the zip writer are all reached through their own packages.
;;;;
;;;; Two shapes decide the whole file:
;;;;
;;;;   An ASSET is a plist whose `:kind` is `:text` (carries `:content`) or
;;;;   `:bytes` (carries `:bytes`), plus `:url` and `:zip-path`. The Rust enum
;;;;   is `Text{url,content,zip_path} | Bytes{url,bytes,zip_path}`, so the
;;;;   discriminant is data, not a type.
;;;;
;;;;   A REPORT VALUE is a small JSON tree built by `json-object` /
;;;;   `json-array` and rendered by `pretty-json`. Not a plist: the serialised
;;;;   report IS the artifact (`raw/index.json` is compared byte-for-byte
;;;;   against the engine's own output), and JSON objects are ORDERED while
;;;;   plists are not. `serde_json` is built with `preserve_order` for exactly
;;;;   this reason, and the oracle records the engine's key order.
;;;;
;;;; WHY THE JSON WRITER LIVES HERE. `com.inuoe.jzon` cannot serialise a plist
;;;; or an alist (it answers `["A",1]` for `(:a 1)` and a type error for
;;;; `(("a" . 1))`), and `lisp->json` in tools/cl/util.lisp is keyword-keyed and
;;;; unordered. Neither can express "these keys, in this order, with JSON null
;;;; here and false there". So this module carries a writer whose only job is to
;;;; reproduce `serde_json::to_string_pretty` for the shapes a report contains,
;;;; and the gate pins it by byte-comparing four real artifacts.

(in-package :cl-user)

(defpackage :vovas.engine.pipeline
  (:use :cl)
  (:import-from :vovas.engine.util
                #:utf16-length
                #:utf16-prefix
                #:utf16-suffix
                #:bad-path-chars-p
                #:*limits-max-asset-bytes*
                #:*limits-max-map-bytes*)
  (:import-from :vovas.engine.number
                #:to-string)
  (:import-from :vovas.engine.transforms
                #:peel-text
                #:peel-result-stages
                #:peel-result-outputs
                #:peel-result-final
                #:peel-result-refusals
                #:make-binary-stage)
  (:import-from :vovas.engine.digest
                #:sha256-hex
                #:sha256-hex-bytes)
  (:import-from :vovas.engine.bundler
                #:extract-bundle-modules
                #:module-file-name
                #:safe-path
                #:bundle-module-code)
  (:import-from :vovas.engine.beautify
                #:looks-minified-p
                #:beautify-js)
  (:import-from :vovas.engine.sourcemaps
                #:find-source-map-ref
                #:parse-source-map
                #:decode-inline-source-map
                #:resolve-map-url
                #:source-map-ref-value
                #:source-map-ref-inline-p
                #:parsed-source-map-files
                #:source-file-path
                #:source-file-content)
  (:import-from :vovas.engine.wasm
                #:detect-wasm-module
                #:parse-wasm-module
                #:module-info-wire
                #:wasm-module-info-sections
                #:wasm-module-info-imports
                #:wasm-module-info-exports
                #:function-name-pairs
                #:type-name-pairs)
  (:import-from :vovas.engine.jscbytecode
                #:detect-jsc-bytecode
                #:parse-jsc-header
                #:recover-jsc-strings
                #:analyze-jsc-module
                #:find-jsc-shared-table)
  (:import-from :vovas.engine.v8codecache
                #:detect-v8-code-cache
                #:parse-v8-code-cache
                #:parse-sealed-v8
                #:v8-code-cache-magic-hex
                #:v8-code-cache-runtime
                #:v8-code-cache-format
                #:v8-code-cache-version-hash
                #:v8-code-cache-source-hash
                #:v8-code-cache-flag-hash
                #:v8-code-cache-payload-length
                #:v8-code-cache-strings
                #:sealed-v8-inflated-bytes
                #:sealed-v8-cache)
  (:import-from :vovas.engine.zip
                #:civil-from-unix-secs)
  (:export
   ;; the two routing predicates
   #:asset-slug
   #:looks-binary-script
   ;; the JSON writer (the report artifact's format)
   #:pretty-json
   #:json-object
   #:json-array
   #:object-get
   ;; the structs, as constructors + accessors
   #:make-text-asset
   #:make-bytes-asset
   #:asset-url
   #:asset-zip-path
   #:asset-kind
   #:asset-content
   #:asset-bytes
   #:asset-text-p
   #:make-unpack-options
   #:options-index
   #:options-zip-path
   #:options-max-depth
   #:options-max-modules
   #:options-max-beautify-bytes
   #:options-path-prefix
   #:options-fetch-text
   #:options-inflate
   #:options-shared-jsc-strings
   #:options-shared-jsc-source
   ;; the entry points
   #:unpack-binary-asset
   #:unpack-asset
   #:unpack-assets
   #:unpack-assets-into
   #:first-non-empty
   #:build-zip
   ;; report shapes, so a caller never rebuilds a key by hand
   #:entry-json
   #:report-json
   #:make-entry
   #:entry-get
   #:entry-has-key-p
   #:asset-result-entry
   #:asset-result-files
   #:make-asset-result
   #:make-file
   #:file-path
   #:file-content
   #:batch-result-report
   #:batch-result-files
   #:make-batch-result
   #:make-report
   #:report-assets
   #:report-totals
   #:report-root
   #:report-unpacked-at
   #:report-generated-by
   #:totals-assets
   #:totals-unpacked
   #:totals-modules
   #:totals-sources
   #:totals-beautified
   #:make-totals
   ;; the wall clock, overridable so the zip seam's stamp is pinnable
   #:iso8601-now
   #:*clock-seconds*))

(in-package :vovas.engine.pipeline)

;;; ===========================================================================
;;; The JSON writer
;;;
;;; A report value is a tree of two tagged conses plus atoms:
;;;
;;;   (json-object . ((KEY . VALUE) ...))   ordered, KEY a string
;;;   (json-array  . (VALUE ...))
;;;   string                                JSON string
;;;   integer                               JSON number
;;;   double-float                          JSON number
;;;   T                                     JSON true
;;;   :FALSE                                JSON false
;;;   :NULL / NIL                           JSON null
;;;
;;; The distinction that forces this vocabulary is `false` versus `null`. In
;;; Lisp both are `nil`, and the report needs both in the same object: a binary
;;; entry is `{"beautified": false, "sourceMap": null}`. A plist cannot spell
;;; that, which is why the entries here are built rather than derived.
;;; ===========================================================================

(defun json-object (&rest entries)
  "An ordered JSON object from (KEY . VALUE) conses. KEY must be a string."
  (cons :json-object entries))

(defun json-array (&rest items)
  "A JSON array."
  (cons :json-array items))

(defun json-object-p (value)
  (and (consp value) (eq (car value) :json-object)))

(defun json-array-p (value)
  (and (consp value) (eq (car value) :json-array)))

(defun object-get (object key)
  "The value under KEY in an object built by `json-object`, or NIL.
For the gate's own assertions; the port's routing reads the source structs."
  (cdr (assoc key (cdr object) :test #'string=)))

(defun emit-json-string (text stream)
  "TEXT as a JSON string literal, escaped the way `serde_json` escapes.

The five short forms are the ones `serde_json` emits specially; every other
control character below 0x20 becomes `\\u00XX` with LOWERCASE hex. Everything at
or above 0x20 is written as the character itself, including non-ASCII -
`serde_json` does not escape it and neither does the engine (the oracle's notes
carry an em dash verbatim)."
  (write-char #\" stream)
  (loop for c across text
        for code = (char-code c)
        do (case c
             (#\" (write-string "\\\"" stream))
             (#\\ (write-string "\\\\" stream))
             (#\Newline (write-string "\\n" stream))
             (#\Return (write-string "\\r" stream))
             (#\Tab (write-string "\\t" stream))
             (#\Backspace (write-string "\\b" stream))
             (#\Page (write-string "\\f" stream))
             (t (if (< code #x20)
                    (format stream "\\u~4,'0x" code)
                    (write-char c stream)))))
  (write-char #\" stream))

(defun emit-double (value stream)
  "VALUE as a JSON number the way `serde_json` writes an f64.

STRUCTURAL, not oracle-pinned: no captured report contains a float. Only a
refusal's `density`/`purity` can, and every captured case has an empty refusal
list - so this path is unreachable from the fixtures and the gate says so
rather than implying coverage. The two deliberate choices:

  - an integral double keeps a `.0` (`1.0`, not `1`), which is serde's form and
    NOT JavaScript's `Number::toString`;
  - non-integral values go through `vovas.engine.number:to-string`. serde uses
    ryu and agrees on the digits; the two differ only in exponent spelling
    (`1e21` versus `1e+21`).

A non-finite float is an ERROR, mirroring `pretty_json`'s
`expect(\"a report must serialize\")`: silently writing `null` would turn a bug
into a plausible-looking artifact."
  (cond
    ((sb-ext:float-nan-p value)
     (error "a report must serialize: NaN cannot be written to JSON"))
    ((sb-ext:float-infinity-p value)
     (error "a report must serialize: infinity cannot be written to JSON"))
    ((= value (fround value))
     (format stream "~d.0" (truncate value)))
    (t (write-string (to-string value) stream))))

(defun write-indent (stream level)
  (dotimes (i (* 2 level)) (write-char #\Space stream)))

(defun emit-json (value stream level)
  (cond
    ((json-object-p value)
     (let ((entries (cdr value)))
       (if (null entries)
           (write-string "{}" stream)
           (progn
             (write-char #\{ stream)
             (write-char #\Newline stream)
             (loop for (entry . rest) on entries
                   do (write-indent stream (1+ level))
                      (emit-json-string (car entry) stream)
                      (write-string ": " stream)
                      (emit-json (cdr entry) stream (1+ level))
                      (unless (null rest) (write-char #\, stream))
                      (write-char #\Newline stream))
             (write-indent stream level)
             (write-char #\} stream)))))
    ((json-array-p value)
     (let ((items (cdr value)))
       (if (null items)
           (write-string "[]" stream)
           (progn
             (write-char #\[ stream)
             (write-char #\Newline stream)
             (loop for (item . rest) on items
                   do (write-indent stream (1+ level))
                      (emit-json item stream (1+ level))
                      (unless (null rest) (write-char #\, stream))
                      (write-char #\Newline stream))
             (write-indent stream level)
             (write-char #\] stream)))))
    ((stringp value) (emit-json-string value stream))
    ((integerp value) (format stream "~d" value))
    ((floatp value) (emit-double value stream))
    ((eq value t) (write-string "true" stream))
    ((eq value :false) (write-string "false" stream))
    ((null value) (write-string "null" stream))
    ((eq value :null) (write-string "null" stream))
    (t (error "not a JSON report value: ~s" value))))

(defun pretty-json (value)
  "VALUE rendered as JSON with `serde_json::to_string_pretty`'s layout.

No trailing newline: `serde_json::to_string_pretty` does not add one, and the
oracle's own artifacts confirm it (`raw/index.json` ends on `}`)."
  (with-output-to-string (stream)
    (emit-json value stream 0)))

;;; ===========================================================================
;;; The wire converter
;;;
;;; `module-info-wire` (wasm.lisp) answers an ALIST with string keys; the packer
;;; refusals answer plists. Converting is the right seam - re-spelling the wasm
;;; keys here would be a second definition of that artifact's contract, which is
;;; what wasm.lisp's docstring says not to do.
;;;
;;; ONE ambiguity has to be resolved by key name: `nil` is the empty list AND
;;; JSON null, and the wire carries both (`moduleName: null`, `notes: []`). The
;;; array-key set below is the disambiguator, and it is checked by the gate's
;;; byte-comparison of wasm-info.json rather than by inspection.
;;; ===========================================================================

(defparameter *wire-array-keys*
  '("sections" "imports" "exports" "dataStrings" "notes" "functions" "markers")
  "Object keys whose `nil` means the empty ARRAY. Every other `nil` is null.
A parameter, not a constant: a `defconstant` on a list signals
DEFCONSTANT-UNEQL on reload even for identical text.")

(defparameter *wire-object-keys*
  '("functionNames" "typeNames")
  "Object keys whose `nil` means the empty OBJECT, not null.

`functionNames` and `typeNames` are `BTreeMap<u32, String>`, so an empty one
serialises as `{}` and the oracle shows exactly that for `wasm-named.wasm`
(`\"typeNames\": {}` beside `\"functionNames\": {\"0\": \"eval0\", ...}`). Getting
this wrong writes `null` and shifts every downstream byte by two characters -
which is how this was caught, by the 1238-versus-1236 length mismatch rather
than by anything readable.")

(defun wire->json (value &optional key)
  "VALUE as a JSON tree. KEY disambiguates the empty case only, and the THREE
empty answers are all distinct: `[]` for an array field, `{}` for a map field,
`null` for an `Option`."
  (cond
    ((null value) (cond ((and key (member key *wire-array-keys* :test #'string=))
                         (json-array))
                        ((and key (member key *wire-object-keys* :test #'string=))
                         (json-object))
                        (t :null)))
    ((stringp value) value)
    ((integerp value) value)
    ((floatp value) value)
    ((eq value t) t)
    ((eq value :false) :false)
    ((vectorp value)
     (apply #'json-array (loop for item across value collect (wire->json item))))
    ;; an ALIST: every element is (KEY . VALUE) with a string KEY
    ((and (consp (car value)) (stringp (caar value)))
     (cons :json-object
           (mapcar (lambda (pair)
                     (cons (car pair) (wire->json (cdr pair) (car pair))))
                   value)))
    ((consp value) (apply #'json-array (mapcar #'wire->json value)))
    (t (error "not a wire value: ~s" value))))

;;; ===========================================================================
;;; The wall clock
;;;
;;; `iso8601_now` reads a clock, and `unpack_assets_into` stamps the report with
;;; it. A pure function is easier to gate than a clock, so the clock is a
;;; parameter: NIL means "read the system clock", a number pins it. Same seam
;;; shape as `*limits-*` in util.lisp - the value the function actually needs,
;;; not a test hook bolted on.
;;; ===========================================================================

(defparameter *clock-seconds* nil
  "Unix seconds to use instead of the system clock, or NIL for the real clock.")

(defun iso8601-now ()
  "`iso8601_now`: `YYYY-MM-DDTHH:MM:SS.000Z` for the current (or pinned) time."
  (multiple-value-bind (year month day hour minute second)
      (civil-from-unix-secs (or *clock-seconds*
                                (- (get-universal-time) 2208988800)))
    (format nil "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0d.000Z"
            year month day hour minute second)))

;;; ===========================================================================
;;; Asset slug
;;;
;;; Five regexes, and the ANCHORS are where a hand-written port goes wrong:
;;;
;;;   `^[a-z]+://`   case-insensitive, so `HTTP://` is stripped
;;;   `[?#].*$`      `$` is END OF HAYSTACK in Rust - not end-of-line, and not
;;;                  before a trailing newline. The oracle pins the difference:
;;;                  `a?b\n` keeps the `?` (which becomes `_`) AND the newline,
;;;                  because `.*` cannot cross `\n` and `$` is not at the end.
;;;                  cl-ppcre's `$` DOES match before a final newline, so this
;;;                  port uses `\z`. Measured, not assumed.
;;;   `[\\:*?"<>|]`  the single-segment hostile set, defined once in util.lisp
;;;   `/+`           runs of slashes become `__`
;;;   `\.js$`        same `$` story: `a.js\n` is NOT a .js URL
;;; ===========================================================================

(defparameter *scheme-re* nil)
(defparameter *query-re* nil)
(defparameter *slug-slashes-re* nil)
(defparameter *binary-ext-re* nil)
(defparameter *js-ext-re* nil)

(defun pipeline-scanners ()
  (unless *scheme-re*
    (setf *scheme-re* (cl-ppcre:create-scanner "^[a-z]+://"
                                               :case-insensitive-mode t))
    ;; `\z` not `$`: Rust's `$` is end-of-haystack only (see the header note).
    (setf *query-re* (cl-ppcre:create-scanner "[?#].*\\z"))
    (setf *slug-slashes-re* (cl-ppcre:create-scanner "/+"))
    (setf *binary-ext-re* (cl-ppcre:create-scanner "\\.(jsc|bc|wasm)(\\?|\\z)"
                                                   :case-insensitive-mode t))
    (setf *js-ext-re* (cl-ppcre:create-scanner "\\.js\\z"
                                               :case-insensitive-mode t)))
  (values))

(defun replace-bad-path-chars (text)
  "`BAD_PATH_CHARS.replace_all(text, \"_\")`, one character at a time.

A character loop rather than a regex because the set is seven ASCII characters
and `bad-path-chars-p` in util.lisp is already the single definition of it."
  (with-output-to-string (out)
    (loop for c across text
          do (write-char (if (bad-path-chars-p c) #\_ c) out))))

(defun asset-slug (url &optional (index 0))
  "`asset_slug(url, index)`: the archive directory name for one asset.

INDEX is `unwrap_or(0)` in the Rust, so NIL means zero. The four-digit prefix is
`utf16_suffix(\"000\" + index, 4)`, which for a large index keeps its LAST four
digits: 1234 answers `1234`, 12 answers `0012`."
  (pipeline-scanners)
  (let* ((cleaned (cl-ppcre:regex-replace *scheme-re* url ""))
         (cleaned (cl-ppcre:regex-replace *query-re* cleaned ""))
         (cleaned (replace-bad-path-chars cleaned))
         (cleaned (cl-ppcre:regex-replace-all *slug-slashes-re* cleaned "__")))
    (when (> (utf16-length cleaned) 90)
      (setf cleaned (utf16-suffix cleaned 90)))
    (when (zerop (length cleaned))
      (setf cleaned "inline"))
    (unless (cl-ppcre:scan *js-ext-re* cleaned)
      (setf cleaned (concatenate 'string cleaned ".js")))
    (format nil "~a-~a"
            (utf16-suffix (format nil "000~a" (or index 0)) 4)
            cleaned)))

;;; ===========================================================================
;;; looksBinaryScript
;;;
;;; The routing test the panel uses to choose which half of the engine an asset
;;; goes to. Three rungs, and the LENGTH GUARDS are load-bearing: the detectors
;;; below them read fixed offsets, so a 4-byte blob must never reach them.
;;; ===========================================================================

(defun looks-binary-script (url &optional bytes)
  "`looks_binary_script(url, bytes)`. BYTES is NIL for a URL-only probe.

The extension test needs no bytes; the byte tests need 8 octets for wasm (a
4-byte magic plus a version word) and 32 for the two cache shapes, whose
detectors read further into the header."
  (pipeline-scanners)
  (when (cl-ppcre:scan *binary-ext-re* url)
    (return-from looks-binary-script t))
  (when bytes
    (let ((n (length bytes)))
      (when (and (>= n 8) (detect-wasm-module bytes))
        (return-from looks-binary-script t))
      (when (and (>= n 32)
                 (or (detect-v8-code-cache bytes)
                     (detect-jsc-bytecode bytes)))
        (return-from looks-binary-script t))))
  nil)

;;; ===========================================================================
;;; The structs
;;;
;;; Plists, because the Rust structs are plain data with no identity. The
;;; keyword names are the FIELD names, not the wire names - the wire names live
;;; in `entry-json` / `stage-json`, so a rename there cannot silently match a
;;; keyword here.
;;; ===========================================================================

(defun make-text-asset (url content &optional zip-path)
  (list :kind :text :url url :content content :zip-path zip-path))

(defun make-bytes-asset (url bytes &optional zip-path)
  (list :kind :bytes :url url :bytes bytes :zip-path zip-path))

(defun asset-url (asset) (getf asset :url))
(defun asset-zip-path (asset) (getf asset :zip-path))
(defun asset-kind (asset) (getf asset :kind))
(defun asset-content (asset) (getf asset :content))
(defun asset-bytes (asset) (getf asset :bytes))
(defun asset-text-p (asset) (eq (getf asset :kind) :text))

(defun make-unpack-options (&key index zip-path max-depth max-modules
                                 max-beautify-bytes
                                 (path-prefix "_unpack")
                                 fetch-text inflate
                                 shared-jsc-strings shared-jsc-source)
  "`UnpackOptions`, with `impl Default`'s values.

The only non-NIL default is `path_prefix`, and it matters: every artifact path
in every report starts with it, so a port defaulting it to `\"\"` would write
`/0000-...` and the archive would unpack into an absolute path."
  (list :index index
        :zip-path (or zip-path "")
        :max-depth max-depth
        :max-modules max-modules
        :max-beautify-bytes max-beautify-bytes
        :path-prefix (if (null path-prefix) "_unpack" path-prefix)
        :fetch-text fetch-text
        :inflate inflate
        :shared-jsc-strings shared-jsc-strings
        :shared-jsc-source shared-jsc-source))

(defun options-index (opts) (getf opts :index))
(defun options-zip-path (opts) (getf opts :zip-path))
(defun options-max-depth (opts) (getf opts :max-depth))
(defun options-max-modules (opts) (getf opts :max-modules))
(defun options-max-beautify-bytes (opts) (getf opts :max-beautify-bytes))
(defun options-path-prefix (opts) (getf opts :path-prefix))
(defun options-fetch-text (opts) (getf opts :fetch-text))
(defun options-inflate (opts) (getf opts :inflate))
(defun options-shared-jsc-strings (opts) (getf opts :shared-jsc-strings))
(defun options-shared-jsc-source (opts) (getf opts :shared-jsc-source))

(defun make-file (path content) (list :path path :content content))
(defun file-path (file) (getf file :path))
(defun file-content (file) (getf file :content))

(defun make-asset-result (entry files) (list :entry entry :files files))
(defun asset-result-entry (result) (getf result :entry))
(defun (setf asset-result-entry) (value result) (setf (getf result :entry) value))
(defun asset-result-files (result) (getf result :files))
(defun (setf asset-result-files) (value result) (setf (getf result :files) value))

(defun make-totals (&key (assets 0) (unpacked 0) (modules 0) (sources 0) (beautified 0))
  (list :assets assets :unpacked unpacked :modules modules
        :sources sources :beautified beautified))
(defun totals-assets (totals) (getf totals :assets))
(defun totals-unpacked (totals) (getf totals :unpacked))
(defun totals-modules (totals) (getf totals :modules))
(defun totals-sources (totals) (getf totals :sources))
(defun totals-beautified (totals) (getf totals :beautified))

(defun make-report (&key (generated-by "unpack.js") (assets '()) totals root unpacked-at)
  (list :generated-by generated-by :assets assets :totals totals
        :root root :unpacked-at unpacked-at))
(defun report-assets (report) (getf report :assets))
(defun (setf report-assets) (value report)
  "A real SETF expander rather than a `(setf (getf ...))` at every call site:
the batch appends one entry per asset and spelling that as
`(setf (getf report :assets) ...)` in the loop reads as ad-hoc plist surgery."
  (setf (getf report :assets) value))
(defun report-totals (report) (getf report :totals))
(defun (setf report-totals) (value report) (setf (getf report :totals) value))
(defun report-root (report) (getf report :root))
(defun report-unpacked-at (report) (getf report :unpacked-at))
(defun report-generated-by (report) (getf report :generated-by))

(defun make-batch-result (report files) (list :report report :files files))
(defun batch-result-report (batch) (getf batch :report))
(defun batch-result-files (batch) (getf batch :files))

;;; ===========================================================================
;;; The report entry
;;;
;;; `ReportEntry` is a plist and `entry-json` renders it. Two fields are
;;; OPTIONAL and their ABSENCE is the contract:
;;;
;;;   `refusals`   present for every TEXT entry (even as `[]`), never present
;;;                for a binary one. The Rust sets `Some(vec![])` in the text
;;;                branch and leaves `None` elsewhere, and
;;;                `skip_serializing_if = "Option::is_none"` drops it.
;;;   `functions`  present only when a JSC function tree bound.
;;;
;;; `getf` cannot tell "absent" from "present and NIL", so the key-presence test
;;; is `entry-has-key-p` and the callers SET the key explicitly (which prepends
;;; the pair even when the value is NIL). The oracle distinguishes the two:
;;; every text entry carries `refusals`, and the wasm/v8/unrecognised binary
;;; entries do not.
;;; ===========================================================================

(defun make-entry (&key url (zip-path "") (kind "text") (bytes 0) digest
                        (stages '()) (modules 0) (sources 0) (beautified nil)
                        source-map (notes '()))
  (list :url url :zip-path zip-path :kind kind :bytes bytes :digest digest
        :stages stages :modules modules :sources sources :beautified beautified
        :source-map source-map :notes notes))

(defun entry-get (entry key) (getf entry key))

(defun entry-has-key-p (entry key)
  "T when KEY is physically in ENTRY's plist. The whole reason this exists is
that `(getf entry :refusals)` answers NIL for both \"no refusals\" and \"no
field\", and the report needs those to serialise differently."
  (loop for (k ignored) on entry by #'cddr thereis (eq k key)))

(defun stage-json (stage)
  "One `Stage`. The enum is UNTAGGED, so a text stage and a binary stage are
distinguished by their FIELDS alone - a text stage carries `:input-bytes`, a
binary stage carries `:detail`."
  (if (entry-has-key-p stage :detail)
      (json-object (cons "depth" (getf stage :depth))
                   (cons "tool" (getf stage :tool))
                   (cons "detail" (getf stage :detail)))
      (json-object (cons "depth" (getf stage :depth))
                   (cons "tool" (getf stage :tool))
                   (cons "inputBytes" (getf stage :input-bytes))
                   (cons "outputBytes" (getf stage :output-bytes))
                   (cons "digest" (getf stage :digest))
                   (cons "sourceUrl" (getf stage :source-url)))))

(defun refusal-json (refusal)
  "One `Refusal`. All six keys are written even when null: the struct carries no
`skip_serializing_if`, so serde emits them."
  (json-object (cons "tool" (getf refusal :tool))
               (cons "detail" (getf refusal :detail))
               (cons "bannerHits" (getf refusal :banner-hits))
               (cons "density" (getf refusal :density))
               (cons "purity" (getf refusal :purity))
               (cons "markers"
                     (let ((markers (getf refusal :markers)))
                       (if (null markers)
                           :null
                           (apply #'json-array
                                  (mapcar (lambda (marker)
                                            (json-object
                                             (cons "marker" (getf marker :marker))
                                             (cons "count" (getf marker :count))))
                                          markers)))))))

(defun entry-json (entry)
  "`ReportEntry` rendered in serde's FIELD ORDER.

Order is the artifact: `raw/index.json` is compared byte-for-byte, and
`preserve_order` in the crate exists so the Rust matches the old JavaScript
engine's key order rather than sorting."
  (let ((object (list (cons "url" (entry-get entry :url))
                      (cons "zipPath" (entry-get entry :zip-path))
                      (cons "kind" (entry-get entry :kind))
                      (cons "bytes" (entry-get entry :bytes))
                      (cons "digest" (entry-get entry :digest))
                      (cons "stages"
                            (apply #'json-array
                                   (mapcar #'stage-json (entry-get entry :stages))))
                      (cons "modules" (entry-get entry :modules))
                      (cons "sources" (entry-get entry :sources))
                      (cons "beautified" (if (entry-get entry :beautified) t :false))
                      (cons "sourceMap"
                            (let ((summary (entry-get entry :source-map)))
                              (if (null summary)
                                  :null
                                  (json-object (cons "kind" (getf summary :kind))
                                               (cons "ref" (getf summary :ref))))))
                      (cons "notes"
                            (apply #'json-array
                                   (copy-list (entry-get entry :notes)))))))
    ;; the two conditionally-present fields, in the Rust's declaration order
    (when (entry-has-key-p entry :refusals)
      (setf object
            (append object
                    (list (cons "refusals"
                                (apply #'json-array
                                       (mapcar #'refusal-json
                                               (entry-get entry :refusals))))))))
    (when (entry-has-key-p entry :functions)
      (setf object (append object (list (cons "functions"
                                              (entry-get entry :functions))))))
    (cons :json-object object)))

(defun report-json (report)
  "`Report` rendered in serde's field order. `root` and `unpackedAt` are
`skip_serializing_if = \"Option::is_none\"`, so `unpackAssets` (which sets
neither) emits neither, while `unpackAssetsForZip` emits both at the end."
  (let ((object (list (cons "generatedBy" (report-generated-by report))
                      (cons "assets"
                            (apply #'json-array
                                   (mapcar #'entry-json (report-assets report))))
                      (cons "totals"
                            (let ((totals (report-totals report)))
                              (json-object
                               (cons "assets" (totals-assets totals))
                               (cons "unpacked" (totals-unpacked totals))
                               (cons "modules" (totals-modules totals))
                               (cons "sources" (totals-sources totals))
                               (cons "beautified" (totals-beautified totals))))))))
    (when (report-root report)
      (setf object (append object (list (cons "root" (report-root report))))))
    (when (report-unpacked-at report)
      (setf object (append object (list (cons "unpackedAt" (report-unpacked-at report))))))
    (cons :json-object object)))

;;; ===========================================================================
;;; The binary pass
;;;
;;; The ladder is ordered exactly like the peel loop: every rung is a
;;; self-contained detector, the first match routes, and an unrecognised blob is
;;; a REPORTED refusal rather than a silent skip.
;;;
;;; One detail that is easy to "tidy up" and must not be: the wasm and V8 rungs
;;; are NOT guarded by "no stages yet" - only JSC and the sealed-brotli rung
;;; are. A blob that is both wasm and V8 (impossible in practice) would get
;;; both rungs in the Rust, and the ordering of the guards is part of the
;;; behaviour rather than an accident.
;;; ===========================================================================

(defun jsc-block-json (block)
  "`JscBlockInfo`, in the struct's field order."
  (json-object (cons "region" (getf block :region))
               (cons "instrAt" (getf block :instr-at))
               (cons "instrLength" (getf block :instr-length))
               (cons "opCount" (getf block :op-count))
               (cons "gap" (getf block :gap))))

(defun jsc-function-json (function)
  "`JscFunction`. `callBlock`/`constructBlock` are `Option<JscBlockInfo>` with
NO `skip_serializing_if`, so an absent block is an explicit null - and the
sidecar fixtures show `callBlock: null` on repeated records, which is the proof
the field is written rather than omitted."
  (json-object (cons "name" (getf function :name))
               (cons "kind" (getf function :kind))
               (cons "record" (getf function :record))
               (cons "callBlock" (let ((block (getf function :call-block)))
                                   (if block (jsc-block-json block) :null)))
               (cons "constructBlock" (let ((block (getf function :construct-block)))
                                        (if block (jsc-block-json block) :null)))))

(defun jsc-stats-json (stats &optional shared-table)
  "`JscStats` as `functions.json`. Camel-case keys from
`#[serde(rename_all = \"camelCase\")]`; `sharedTable` is
`skip_serializing_if = \"Option::is_none\"`, so it is APPENDED only when the
pipeline filled it."
  (let ((object (list (cons "valid" (if (getf stats :valid) t :false))
                      (cons "rootName" (getf stats :root-name))
                      (cons "rootParseMode" (getf stats :root-parse-mode))
                      (cons "nodes" (getf stats :nodes))
                      (cons "blocks" (getf stats :blocks))
                      (cons "ops" (getf stats :ops))
                      (cons "bindFailed" (getf stats :bind-failed))
                      (cons "functions"
                            (apply #'json-array
                                   (mapcar #'jsc-function-json
                                           (getf stats :functions)))))))
    (when shared-table
      (setf object
            (append object
                    (list (cons "sharedTable"
                                (json-object
                                 (cons "source" (getf shared-table :source))
                                 (cons "ordinals" (getf shared-table :ordinals))
                                 (cons "resolvedNames"
                                       (getf shared-table :resolved-names))))))))
    (cons :json-object object)))

(defun named-function-count (functions)
  "How many functions resolved to a REAL name: non-empty and not the
`<ordinal N>` placeholder. This is the `resolved_names` figure the shared-table
summary reports, and the only evidence that the table helped."
  (count-if (lambda (function)
              (let ((name (getf function :name)))
                (and name
                     (plusp (length name))
                     (not (eql 0 (search "<ordinal " name))))))
            functions))

(defun unpack-binary-asset (url bytes opts)
  "`unpack_binary_asset`: the bytes path, see the ladder note above."
  (let* ((index (or (options-index opts) 0))
         (entry (make-entry :url url
                            :zip-path (or (options-zip-path opts) "")
                            :kind "binary"
                            :bytes (length bytes)
                            :digest (sha256-hex-bytes bytes)))
         (files '())
         (strings nil))
    (when (> (length bytes) *limits-max-asset-bytes*)
      (setf (getf entry :notes) (list "asset exceeds unpack budget"))
      (return-from unpack-binary-asset
        (make-asset-result entry (nreverse files))))
    (let ((base (format nil "~a/~a" (options-path-prefix opts)
                        (asset-slug url index))))
      ;; LABELS, not FLET: `header` calls `add-file`, and a `flet`'s defs are not
      ;; in scope inside its own defs.
      (labels ((note (text) (push text (getf entry :notes)))
             (add-stage (stage) (push stage (getf entry :stages)))
             (add-file (path content) (push (make-file path content) files))
             (detail! (text)
               ;; The stage detail is EXTENDED in place later on, so extend the
               ;; newest stage (which `push` put at the front).
               (let ((stage (car (getf entry :stages))))
                 (setf (getf stage :detail)
                       (format nil "~a, ~a" (getf stage :detail) text))
                 (setf (car (getf entry :stages)) stage)))
             (header (payload)
               ;; an ALIST, because the key ORDER is the artifact
               (add-file (format nil "~a/cache-header.json" base)
                         (pretty-json (wire->json payload)))))

        ;; ---- wasm --------------------------------------------------------
        (when (detect-wasm-module bytes)
          (let ((wasm (parse-wasm-module bytes)))
            (when wasm
              (add-stage
               (make-binary-stage
                :depth 0
                :tool "wasm-module"
                ;; `function_names.len()` is the number of NAMED functions, not
                ;; the function count - `function-name-pairs` is that map, and
                ;; `wasm-named.wasm` answers 4 while `wasm-data.wasm` answers 1.
                :detail (format nil "wasm module, ~a sections, ~a imports, ~a exports, ~a named functions"
                                (length (wasm-module-info-sections wasm))
                                (length (wasm-module-info-imports wasm))
                                (length (wasm-module-info-exports wasm))
                                (length (function-name-pairs wasm)))))
              (add-file (format nil "~a/wasm-info.json" base)
                        (pretty-json (wire->json (module-info-wire wasm)))))))

        ;; ---- V8 code cache ----------------------------------------------
        (when (detect-v8-code-cache bytes)
          (let ((cache (parse-v8-code-cache bytes)))
            (when cache
              (add-stage
               (make-binary-stage
                :depth 0
                :tool "v8-code-cache"
                :detail (format nil "~a ~a, payload ~aB"
                                (v8-code-cache-runtime cache)
                                (v8-code-cache-format cache)
                                (v8-code-cache-payload-length cache))))
              (setf strings (copy-list (v8-code-cache-strings cache)))
              (header (list (cons "shape" "v8-code-cache")
                            (cons "magic" (v8-code-cache-magic-hex cache))
                            (cons "runtime" (v8-code-cache-runtime cache))
                            (cons "format" (v8-code-cache-format cache))
                            (cons "versionHash" (v8-code-cache-version-hash cache))
                            (cons "sourceHash" (v8-code-cache-source-hash cache))
                            (cons "flagHash" (v8-code-cache-flag-hash cache))
                            (cons "payloadLength"
                                  (v8-code-cache-payload-length cache)))))))

        ;; ---- JSC bytecode ------------------------------------------------
        (when (and (null (getf entry :stages)) (detect-jsc-bytecode bytes))
          (let ((parsed (parse-jsc-header bytes)))
            (when parsed
              (add-stage
               (make-binary-stage
                :depth 0
                :tool "jsc-bytecode"
                :detail (format nil "JSC bytecode v~a, ~aB"
                                (getf parsed :version)
                                (getf parsed :declared-length))))
              (setf strings (recover-jsc-strings bytes))
              (header (list (cons "shape" "jsc-bytecode")
                            (cons "stamp" (getf parsed :stamp))
                            (cons "format" (getf parsed :format))
                            (cons "version" (getf parsed :version))
                            (cons "declaredLength" (getf parsed :declared-length))
                            (cons "bodyOffset" (getf parsed :body-offset))))
              (let ((structure (analyze-jsc-module
                                bytes (options-shared-jsc-strings opts)))
                    (shared-table nil))
                (if (plusp (getf structure :blocks))
                    (progn
                      (detail! (format nil "~a functions, ~a blocks, ~a ops"
                                       (length (getf structure :functions))
                                       (getf structure :blocks)
                                       (getf structure :ops)))
                      (setf (getf entry :functions)
                            (length (getf structure :functions)))
                      (when (options-shared-jsc-strings opts)
                        (let ((named (named-function-count
                                      (getf structure :functions))))
                          (setf shared-table
                                (list :source (or (options-shared-jsc-source opts)
                                                  "batch")
                                      :ordinals (length (options-shared-jsc-strings opts))
                                      :resolved-names named))
                          (detail! (format nil "~a names via shared table" named))))
                      (add-file (format nil "~a/functions.json" base)
                                (pretty-json
                                 (jsc-stats-json structure shared-table))))
                    (note "JSC function tree did not bind (build opcode drift)"))))))

        ;; ---- brotli-sealed V8 --------------------------------------------
        (when (null (getf entry :stages))
          (let ((sealed (parse-sealed-v8 bytes (options-inflate opts))))
            (when sealed
              (add-stage (make-binary-stage
                          :depth 0
                          :tool "jsc-sealed-v8"
                          :detail (format nil "brotli-sealed V8 cache, ~aB inflated"
                                          (sealed-v8-inflated-bytes sealed))))
              (let ((cache (sealed-v8-cache sealed)))
                (add-stage (make-binary-stage
                            :depth 1
                            :tool "v8-code-cache"
                            :detail (format nil "~a ~a, payload ~aB"
                                            (v8-code-cache-runtime cache)
                                            (v8-code-cache-format cache)
                                            (v8-code-cache-payload-length cache))))
                (setf strings (copy-list (v8-code-cache-strings cache)))
                (header (list (cons "shape" "jsc-sealed-v8")
                              (cons "inflatedBytes" (sealed-v8-inflated-bytes sealed))
                              (cons "magic" (v8-code-cache-magic-hex cache))
                              (cons "runtime" (v8-code-cache-runtime cache))
                              (cons "format" (v8-code-cache-format cache))))))))

        ;; ---- the recovered strings ---------------------------------------
        (when (and strings (plusp (length strings)))
          (add-file (format nil "~a/strings.json" base)
                    (pretty-json (apply #'json-array (copy-list strings)))))

        (when (null (getf entry :stages))
          (note "binary asset: no V8 code-cache, JSC bytecode, wasm module, or brotli-sealed shape recognized")))

      ;; The Rust pushes onto a Vec, so the order is discovery order, and
      ;; `push` + `nreverse` reproduces it for both stages and notes.
      (setf (getf entry :stages) (nreverse (getf entry :stages)))
      (setf (getf entry :notes) (nreverse (getf entry :notes)))
      (make-asset-result entry (nreverse files)))))

;;; ===========================================================================
;;; The text pass
;;; ===========================================================================

(defun unpack-text-asset (asset opts)
  "The text branch: peel, split bundle modules, beautify, follow the map."
  (let* ((url (asset-url asset))
         (content (or (asset-content asset) ""))
         (index (or (options-index opts) 0))
         (entry (make-entry
                 :url url
                 :zip-path (or (options-zip-path opts) "")
                 :kind "text"
                 ;; `bytes` is the UTF-16 LENGTH, not the octet count: the
                 ;; engine measures assets in JavaScript string units
                 ;; throughout, so `é` counts 1 and an emoji counts 2.
                 :bytes (utf16-length content)
                 ;; an EMPTY asset has NO digest rather than the digest of
                 ;; nothing - the Rust's early `None`.
                 :digest (unless (zerop (length content)) (sha256-hex content))))
         (files '()))
    (flet ((note (text) (push text (getf entry :notes)))
           (add-file (path text) (push (make-file path text) files)))
      (when (or (zerop (length content))
                (> (utf16-length content) *limits-max-asset-bytes*))
        (unless (zerop (length content))
          (note "asset exceeds unpack budget"))
        ;; `refusals` is NOT set here: the Rust returns before assigning it, so
        ;; an over-budget text entry has no `refusals` key at all. Only
        ;; reachable with a >8 MiB asset, which no oracle case carries.
        (return-from unpack-text-asset
          (make-asset-result entry (nreverse files))))
      (let* ((base (format nil "~a/~a" (options-path-prefix opts)
                           (asset-slug url index)))
             (peeled (peel-text content (options-max-depth opts)))
             (stages (peel-result-stages peeled))
             (outputs (peel-result-outputs peeled))
             (refusals (peel-result-refusals peeled))
             (current (peel-result-final peeled)))

        (setf (getf entry :stages) stages)
        ;; ALWAYS present, even when empty: a text entry always carries the key
        ;; and that is how the oracle distinguishes the two branches.
        (setf (getf entry :refusals) refusals)
        (loop for refusal in refusals
              do (note (format nil "refused: ~a — ~a"
                               (getf refusal :tool) (getf refusal :detail))))

        ;; one artifact per peel layer. The name is `0{depth}-{tool}` - a
        ;; literal `0` and the raw depth, NOT zero-padded, so a tenth layer
        ;; would read `010-tool.js`. Preserved as-is.
        (loop for stage in stages
              for output in outputs
              do (unless (entry-has-key-p stage :detail)
                   (add-file (format nil "~a/layers/0~a-~a.js" base
                                     (getf stage :depth) (getf stage :tool))
                             (utf16-prefix output *limits-max-asset-bytes*))))

        (when stages
          (add-file (format nil "~a/00-original.js" base) content))

        (let ((modules (extract-bundle-modules current (options-max-modules opts))))
          (setf (getf entry :modules) (length modules))
          (loop for module in modules
                do (add-file (format nil "~a/modules/~a" base
                                     (safe-path (module-file-name module)))
                             (bundle-module-code module))))

        ;; `looks-minified` is asked TWICE - it gates both the beautified
        ;; artifact and the untouched `10-source.js`, and the two are mutually
        ;; exclusive. Caching the answer would be correct here but is not what
        ;; the Rust does, and the second call sees the same text.
        (when (looks-minified-p current)
          (let ((beautified (beautify-js current (options-max-beautify-bytes opts))))
            (unless (equal beautified current)
              (setf (getf entry :beautified) t)
              (add-file (format nil "~a/10-beautified.js" base) beautified))))
        (unless (looks-minified-p current)
          (add-file (format nil "~a/10-source.js" base) current))

        ;; the map is looked for in the ORIGINAL first, then in the peeled
        ;; output: an obfuscator can strip the comment, and a peel can reveal one
        (let ((map-ref (or (find-source-map-ref content)
                           (find-source-map-ref current))))
          (when map-ref
            (let* ((inline (source-map-ref-inline-p map-ref))
                   (value (source-map-ref-value map-ref)))
              (setf (getf entry :source-map)
                    (list :kind (if inline "inline" "external")
                          :ref (if inline "inline data URI" value)))
              (let ((map-json
                      (if inline
                          (decode-inline-source-map value)
                          ;; an EXTERNAL map needs the injected fetcher; with no
                          ;; fetcher the Rust answers None and notes NOTHING, so
                          ;; a caller that forgot the fetcher gets a silent
                          ;; absence rather than a misleading note.
                          (let ((fetch (options-fetch-text opts)))
                            (when fetch
                              (let ((text (funcall fetch (resolve-map-url url value))))
                                (if (and text (<= (utf16-length text)
                                                  *limits-max-map-bytes*))
                                    text
                                    (progn
                                      (note (format nil "source map fetch failed: ~a" value))
                                      nil))))))))
                (when map-json
                  (let ((parsed (parse-source-map map-json)))
                    (if parsed
                        (progn
                          (setf (getf entry :sources)
                                (length (parsed-source-map-files parsed)))
                          (add-file (format nil "~a/source-map.json" base) map-json)
                          (loop for file in (parsed-source-map-files parsed)
                                do (add-file
                                    (format nil "~a/sources/~a" base
                                            (safe-path (source-file-path file)))
                                    (source-file-content file))))
                        (note "source map parse failed"))))))))

        (when (and (null stages)
                   (zerop (getf entry :modules))
                   (zerop (getf entry :sources)))
          (note "no obfuscation layer, bundle structure, or source map content found"))))

    (setf (getf entry :notes) (nreverse (getf entry :notes)))
    (make-asset-result entry (nreverse files))))

;;; ===========================================================================
;;; Routing, and the batch
;;; ===========================================================================

(defun unpack-asset (asset opts)
  "`unpack_asset`: route by asset kind, then the full pass for that kind."
  (if (eq (asset-kind asset) :bytes)
      (unpack-binary-asset (asset-url asset) (asset-bytes asset) opts)
      (unpack-text-asset asset opts)))

(defun first-non-empty (parts fallback)
  "`first_non_empty`: the first non-empty string in PARTS, else FALLBACK."
  (loop for part in parts
        when (and part (plusp (length part)))
          return part
        finally (return fallback)))

(defun empty-shared-table-p (table)
  "A refusal shape from `read-jsc-shared-table` has `:strings` NIL. A real table
always carries a vector (possibly all holes), so this distinguishes the two
without inspecting the count."
  (null (getf table :strings)))

(defun discover-shared-table (assets)
  "Find the container-wide JSC EncoderStringTable by structure.

Answers `(values strings source)` or `(values nil nil)`. Only called when some
asset is JSC-shaped, because the scan is byte-by-byte over every candidate and
there is nothing to find in a batch of JavaScript. The `resolved >= 8` floor is
the Rust's: a table that resolved fewer than eight names is noise, not a table."
  (loop for asset in assets
        for s from 0
        do (when (eq (asset-kind asset) :bytes)
             (let ((bytes (asset-bytes asset)))
               (unless (or (< (length bytes) 24)
                           (> (length bytes) *limits-max-asset-bytes*))
                 (let ((found (find-jsc-shared-table bytes)))
                   (when (and found
                              (not (empty-shared-table-p found))
                              (>= (getf found :resolved) 8))
                     (return-from discover-shared-table
                       (values (getf found :strings)
                               (first-non-empty
                                (list (asset-url asset)
                                      (or (asset-zip-path asset) ""))
                                (format nil "asset ~a" s))))))))))
  (values nil nil))

(defun any-jsc-asset-p (assets)
  "T when any asset is JSC-shaped, which is the only case where scanning for a
shared table can pay off. No length guard here: `detect-jsc-bytecode` is
`parse-jsc-header`, which already refuses anything shorter than the five-word
header, so adding one would be a second, unmeasured guard over the same rule."
  (some (lambda (asset)
          (and (eq (asset-kind asset) :bytes)
               (detect-jsc-bytecode (asset-bytes asset))))
        assets))

(defun unpack-assets (assets opts)
  "`unpack_assets`: every asset through `unpack-asset`, with the shared JSC
string table discovered ONCE for the container and shared with every chunk.

That table is why this entry point exists separately. A zip of loose assets
carries no module graph, so nothing REFERENCES the EncoderStringTable - it is
found by validating its own structure in any binary asset, and then every
`<ordinal N>` slot in every chunk resolves through it. Doing it per asset would
leave each chunk's names as placeholders, which the batch oracle shows directly:
the same chunk names 15 functions when the table is present and
`<ordinal N>` placeholders when it is not."
  (let ((report (make-report :generated-by "unpack.js"
                             :assets '()
                             :totals (make-totals :assets (length assets))))
        (all-files '())
        (shared (and (options-shared-jsc-strings opts)
                     (coerce (options-shared-jsc-strings opts) 'vector)))
        (shared-source (options-shared-jsc-source opts)))
    (when (and (null shared) (any-jsc-asset-p assets))
      (multiple-value-bind (strings source) (discover-shared-table assets)
        (when strings
          (setf shared strings
                shared-source source))))
    (loop for asset in assets
          for i from 0
          do (let* ((result (unpack-asset
                             asset
                             (make-unpack-options
                              :index i
                              :zip-path (or (asset-zip-path asset) "")
                              :max-depth (options-max-depth opts)
                              :max-modules (options-max-modules opts)
                              :max-beautify-bytes (options-max-beautify-bytes opts)
                              :path-prefix (options-path-prefix opts)
                              :fetch-text (options-fetch-text opts)
                              :inflate (options-inflate opts)
                              :shared-jsc-strings shared
                              :shared-jsc-source shared-source)))
                    (entry (asset-result-entry result))
                    (totals (report-totals report)))
               ;; "unpacked" means a layer was peeled, modules were split, or
               ;; sources were recovered - NOT merely "an entry exists". An
               ;; empty asset produces an entry and counts as NOT unpacked.
               (when (or (getf entry :stages)
                         (plusp (getf entry :sources))
                         (plusp (getf entry :modules)))
                 (setf (getf totals :unpacked) (1+ (getf totals :unpacked))))
               (setf (getf totals :modules)
                     (+ (getf totals :modules) (getf entry :modules)))
               (setf (getf totals :sources)
                     (+ (getf totals :sources) (getf entry :sources)))
               (when (getf entry :beautified)
                 (setf (getf totals :beautified) (1+ (getf totals :beautified))))
               (setf (report-assets report)
                     (append (report-assets report) (list entry)))
               (setf all-files (append all-files (asset-result-files result)))))
    (make-batch-result report all-files)))

;;; ===========================================================================
;;; The zip seam
;;; ===========================================================================

(defun build-zip (files now-ms)
  "`build_zip`: the archive for FILES, stamped NOW-MS.

DELEGATES to `vovas.engine.zip:build-zip`, the port of the same function, which
`gate-zip.lisp` already round-trip gates. Re-exported because pipeline.rs
exposes it through the same module surface the panel and the wasm dispatcher
call; a second implementation would be two definitions of one archive format."
  (vovas.engine.zip:build-zip files now-ms))

(defun unpack-assets-into (writer assets opts &optional report-path)
  "`unpack_assets_into`: write every artifact through WRITER, then the report.

WRITER is a function of (PATH CONTENT). The report lands at REPORT-PATH
(default `{prefix}/index.json`) and is the LAST thing written.

`root` and `unpackedAt` are stamped HERE and not in `unpack-assets`, which is
exactly why `unpackAssets` emits neither: the batch is clock-free, the archive
is not. The prefix is also re-normalised here - an EMPTY `path_prefix` becomes
`_unpack` for the report's root - while the artifact paths used the prefix
verbatim. That asymmetry is the Rust's, and the bridge hides it by sending
`null` rather than `\"\"`; the port keeps the behaviour so a direct caller sees
the same thing."
  (let* ((prefix (let ((p (options-path-prefix opts)))
                   (if (or (null p) (zerop (length p))) "_unpack" p)))
         (result (unpack-assets assets opts)))
    (loop for file in (batch-result-files result)
          do (funcall writer (file-path file) (file-content file)))
    (let* ((batch-report (batch-result-report result))
           (report (make-report :generated-by (report-generated-by batch-report)
                                :assets (report-assets batch-report)
                                :totals (report-totals batch-report)
                                :root prefix
                                :unpacked-at (iso8601-now)))
           (path (or report-path (format nil "~a/index.json" prefix))))
      (funcall writer path (pretty-json (report-json report)))
      report)))
