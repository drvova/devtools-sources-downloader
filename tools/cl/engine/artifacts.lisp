;;;; artifacts.lisp — the readable-artifact builders, from panel/artifacts.rs.
;;;;
;;;; This is the module that turns captured data into FILES a person reads: the
;;;; runtime payload paths inside the archive, the inline JSON embedded in the
;;;; generated HTML, the escaped attribute and text values, the stats strip, and
;;;; the "semantic reconstruction" header stapled onto a readable script.
;;;;
;;;; The whole file is string assembly, which makes it the place where an
;;;; off-by-one in escaping is invisible: `escapeXml` and `escapeAttr` differ by
;;;; exactly one character (`'`), and the oracle carries a case for each so the
;;;; difference cannot drift.
;;;;
;;;; ORDERING IS LOAD-BEARING in three spots, each commented where it happens:
;;;;   - `runtimeExtension` consults the WASM test, then the mime table IN ORDER,
;;;;     then the kind table, then base64. A `text/javascript` payload is `js`
;;;;     from the mime table, never from the kind table.
;;;;   - `computeReconStats` emits its `type_markup` in FIRST-SEEN order of
;;;;     `initiatorType`, not sorted.
;;;;   - `parseCookies` keeps first-seen key order, and a LATER duplicate key
;;;;     overwrites in place rather than moving to the end.

(in-package :vovas.engine.panel.artifacts)

;;; ---------------------------------------------------------------------------
;;; js-number-value
;;;
;;; `js_number_value`: an integral double becomes an INTEGER in the JSON output,
;;; so 12.5 stays 12.5 while 12.0 renders as "12". The 2^53 bound is the point
;;; at which a double can no longer represent every integer, and past it JS
;;; prints the float form - so the check is not cosmetic.
;;; ---------------------------------------------------------------------------

(defconstant +max-safe-integer+ 9007199254740992d0)

(defun finite-float-p (value)
  "Whether VALUE is finite. An INTEGER is always finite, so it answers T rather
than calling `float-nan-p` on it - SBCL's float predicates require a FLOAT
argument and signal a TYPE-ERROR on 0, which is how this surfaced.

`(= nan 0d0)` and `(/= nan 0d0)` both SIGNAL on SBCL, so finiteness has to be
asked before any comparison of a value that might be NaN."
  (cond
    ((integerp value) t)
    ((rationalp value) t)
    ((floatp value) (and (not (sb-ext:float-nan-p value))
                         (not (sb-ext:float-infinity-p value))))
    (t nil)))

(defun js-number-value (value)
  "`js_number_value`: VALUE as the JSON number it should print as.

A non-finite value becomes NIL, which the writer renders as `null`; an integral
value inside the safe range becomes an integer; anything else stays a double.

The order of the tests matters: the finiteness check must come FIRST, because
`(= nan 0d0)` and `(/= nan 0d0)` both SIGNAL on SBCL rather than answering, so a
NaN reaching `zerop` would raise instead of falling through to `null`."
  (cond
    ((not (realp value)) nil)
    ((and (floatp value) (not (finite-float-p value))) nil)
    ((integerp value) value)
    ((and (zerop (nth-value 1 (truncate value)))
          (< (abs value) +max-safe-integer+))
     (truncate value))
    (t value)))

;;; ---------------------------------------------------------------------------
;;; runtimeFolderName / runtimeExtension / buildRuntimePath
;;; ---------------------------------------------------------------------------

(defun runtime-folder-name (kind)
  "`runtimeFolderName`: the archive folder for a runtime payload kind.

An unrecognised kind - including the empty string - lands in `misc`, which is
why the match is exhaustive over the KNOWN kinds rather than a prefix test."
  (cond
    ((string= kind "eval") "eval")
    ((string= kind "function") "function")
    ((string= kind "blob") "blob")
    ((string= kind "worker") "workers")
    ((string= kind "shared-worker") "shared-workers")
    ((string= kind "service-worker") "service-workers")
    ((string= kind "script-injection") "script-injections")
    ((string= kind "wasm") "wasm")
    (t "misc")))

(defparameter *mime-table*
  (list (cons (cl-ppcre:create-scanner "javascript|ecmascript|typescript"
                                      :case-insensitive-mode t) "js")
        (cons (cl-ppcre:create-scanner "json" :case-insensitive-mode t) "json")
        (cons (cl-ppcre:create-scanner "html" :case-insensitive-mode t) "html")
        (cons (cl-ppcre:create-scanner "css" :case-insensitive-mode t) "css")
        (cons (cl-ppcre:create-scanner "svg" :case-insensitive-mode t) "svg")
        (cons (cl-ppcre:create-scanner "xml" :case-insensitive-mode t) "xml")
        (cons (cl-ppcre:create-scanner "text" :case-insensitive-mode t) "txt"))
  "The mime table, in the Rust's order. ORDER MATTERS: `text/json` is `json`
because the json row is tested first, and `application/javascript` is `js`
because that row is first of all.")

(defparameter *wasm-mime*
  (cl-ppcre:create-scanner "wasm" :case-insensitive-mode t))

(defun runtime-extension (entry)
  "`runtimeExtension`: the archive extension for a runtime payload.

The kind test and the WASM mime test come BEFORE the table, so a `wasm` kind
with a `text/plain` mime is still `.wasm`. Past the table, a script-ish kind is
`js`; anything else is `bin` when the payload is base64 and `txt` otherwise."
  (let ((kind (field-str entry "kind"))
        (mime (field-str entry "mimeType")))
    (when (or (string= kind "wasm") (cl-ppcre:scan *wasm-mime* mime))
      (return-from runtime-extension "wasm"))
    (dolist (row *mime-table*)
      (when (cl-ppcre:scan (car row) mime)
        (return-from runtime-extension (cdr row))))
    (cond
      ((member kind '("eval" "function" "worker" "shared-worker"
                      "service-worker" "script-injection")
               :test #'string=)
       "js")
      ((let ((b (field entry "base64"))) (and b (js-truthy b))) "bin")
      (t "txt"))))

(defun build-runtime-path (entry counters)
  "`buildRuntimePath`: `_runtime/<folder>/NNNN.<ext>`, counting PER FOLDER.

COUNTERS is a hash table mutated in place - the caller threads one table across
the whole export so the numbering keeps advancing across payloads. A fresh table
per call would restart every file at 0001."
  (let* ((folder (runtime-folder-name (field-str entry "kind")))
         (count (1+ (gethash folder counters 0))))
    (setf (gethash folder counters) count)
    (format nil "_runtime/~a/~4,'0d.~a" folder count (runtime-extension entry))))

;;; ---------------------------------------------------------------------------
;;; buildRuntimeUnpackAssets
;;;
;;; The payloads the unpack ENGINE can read: text bodies only, and only the ones
;;; whose extension resolves to `js`. A wasm payload is deliberately excluded -
;;; the wasm parser has its own path and does not read it as script text.
;;; ---------------------------------------------------------------------------

(defun build-runtime-unpack-assets (payloads manifest)
  "`buildRuntimeUnpackAssets`: text/javascript payloads as assets.

The zip path comes from the MANIFEST's recorded file for the matching id, and
is empty when the manifest has no such entry - not a synthesised path, because
the manifest is the record of where the export actually put the file."
  (let ((assets '()))
    (dolist (entry payloads)
      (let ((text (field entry "text")))
        (when (and (stringp text) (plusp (length text))
                   (string= (runtime-extension entry) "js"))
          (let* ((id (field-str entry "id"))
                 (manifest-item (find-if (lambda (item)
                                           (string= (field-str item "id") id))
                                         manifest))
                 (raw-file (if manifest-item
                               (field-str manifest-item "file")
                               ""))
                 (url (let ((u (field-str entry "url")))
                        (if (plusp (length u))
                            u
                            (let ((label (field-str entry "label")))
                              (if (plusp (length label)) label id))))))
            (push (list :url url :content text :zip-path raw-file) assets)))))
    (nreverse assets)))

;;; ---------------------------------------------------------------------------
;;; mergeUnpackReports
;;;
;;; The script report ABSORBS the runtime report's totals. Five keys, in a fixed
;;; order, each read as a float and written back through `js_number_value` so an
;;; integral total prints without a trailing `.0`.
;;; ---------------------------------------------------------------------------

(defparameter *merge-keys* '("assets" "unpacked" "modules" "sources" "beautified"))

(defun merge-unpack-reports (script-report runtime-report)
  "`mergeUnpackReports`: add the runtime totals into the script totals, in place.

Returns SCRIPT-REPORT. A missing total on either side contributes 0, so a report
with no runtime section is unchanged rather than broken."
  (let ((totals (field script-report "totals")))
    (when (hash-table-p totals)
      (dolist (key *merge-keys*)
        (let* ((runtime-totals (field runtime-report "totals"))
               (runtime-value (and (hash-table-p runtime-totals)
                                   (let ((v (field runtime-totals key)))
                                     (if (numberp v) (coerce v 'double-float) 0d0))))
               (current (let ((v (field totals key)))
                          (if (numberp v) (coerce v 'double-float) 0d0)))
               (sum (+ current (or runtime-value 0d0))))
          (setf (gethash key totals) (js-number-value sum))))))
  script-report)

;;; ---------------------------------------------------------------------------
;;; parseCookies
;;; ---------------------------------------------------------------------------

(defun split-on-char (text separator)
  "`String.prototype.split(separator)` for a single character.

`split-string` lives in jsfuck.lisp, which loads AFTER this file, and borrowing it
would be a forward reference that only fails at call time. This is four lines and
has no such problem.

An empty TEXT yields ONE empty segment, matching `\"\".split(\";\") == [\"\"]`, and a
trailing separator yields a trailing empty segment - both matter because
`parseCookies` relies on the empty segment being SKIPPED by its `=` test rather
than by the splitter dropping it."
  (let ((parts '())
        (start 0))
    (loop for i from 0 below (length text)
          do (when (char= (char text i) separator)
               (push (subseq text start i) parts)
               (setf start (1+ i))))
    (push (subseq text start) parts)
    (nreverse parts)))

(defun parse-cookies (cookie-str)
  "`parseCookies`: a hash table of cookie name to value, FIRST-SEEN key order.

A pair with no `=` is SKIPPED entirely - not stored with an empty value - and a
duplicate name overwrites in place, keeping its original position. `split(';')`
never drops an empty segment, so `\"a=1;\"` yields one cookie plus a segment with
no `=` that is skipped."
  (let ((result (make-hash-table :test #'equal))
        (order '()))
    (dolist (pair (split-on-char cookie-str #\;))
      (let ((at (position #\= pair)))
        (when at
          (let ((name (js-trim (subseq pair 0 at)))
                (value (js-trim (subseq pair (1+ at)))))
            (unless (gethash name result)
              (push name order))
            (setf (gethash name result) value)))))
    (values result (nreverse order))))

;;; ---------------------------------------------------------------------------
;;; serializeInlineJson
;;;
;;; Inline JSON is embedded in a `<script>` element, so `<`, `>` and `&` are
;;; replaced with their `\u003c` style escapes. The replacement is on the
;;; SERIALIZED text, which is why it catches the characters inside string
;;; literals too - that is the attack surface for `</script>`.
;;; ---------------------------------------------------------------------------

(defun serialize-inline-json (value)
  "`serializeInlineJson`: compact JSON, with `<`, `>` and `&` unicode-escaped.

A FALSY value serializes as `{}` - not as the value - so an absent payload never
produces the literal `null` or `undefined` in the generated HTML."
  (let* ((subject (if (js-truthy value) value (make-hash-table :test #'equal)))
         (text (json-serialize-compact subject)))
    (json-escape-html-chars text)))

(defun json-escape-html-chars (text)
  "Replace `<`, `>` and `&` with their `\\u00XX` escapes, in one pass.

A single pass matters: replacing `&` first and then `<` would re-escape the `&`
introduced by an earlier replacement, and the Rust's chained `.replace` calls do
not have that problem because none of the replacements contain a later search
character."
  (with-output-to-string (s)
    (loop for c across text
          do (case c
               (#\< (write-string "\\u003c" s))
               (#\> (write-string "\\u003e" s))
               (#\& (write-string "\\u0026" s))
               (t (write-char c s))))))

;;; ---------------------------------------------------------------------------
;;; escapeXml / escapeAttr
;;;
;;; These differ by EXACTLY one character: `escapeXml` encodes the apostrophe as
;;; `&#39;`, `escapeAttr` leaves it alone. The oracle carries a case for each
;;; with the same input, so a shared implementation would fail one of them.
;;; ---------------------------------------------------------------------------

(defun escape-attr (value)
  "`escapeAttr`: `&`, `\"`, `<` and `>` - but NOT the apostrophe.

The Rust walks the characters rather than calling `escapeHtml` and undoing it,
because the entities it introduces contain `&` and `;` that a second pass would
mangle. Attribute values here are always double-quoted, so a bare `'` is safe."
  (let ((text (value-as-text value)))
    (with-output-to-string (s)
      (loop for c across text
            do (case c
                 (#\& (write-string "&amp;" s))
                 (#\" (write-string "&quot;" s))
                 (#\< (write-string "&lt;" s))
                 (#\> (write-string "&gt;" s))
                 (t (write-char c s)))))))

(defun escape-xml (value)
  "`escapeXml`: the value as text, then `escapeHtml` - apostrophe INCLUDED.

A null renders as empty, not as the string \"null\", which is what makes this
usable in element text where an absent field should vanish."
  (if (null value)
      ""
      (escape-html (value-as-text value))))

(defun value-as-text (value)
  "The text `escapeXml`/`escapeAttr` start from: null empty, strings verbatim,
booleans as `true`/`false`, numbers through the JS formatter, and objects and
arrays as their compact JSON.

The NUMBER test comes before the boolean one, because `(eq 7 t)` is NIL but a
`(null (json-null-p 7))` test - the always-true spelling - would have made every
number render as `false`."
  (cond
    ((json-null-p value) "")
    ((null value) "")
    ((stringp value) value)
    ((numberp value) (vovas.engine.number:to-string value))
    ((eq value t) "true")
    (t (json-serialize-compact value))))

;;; ---------------------------------------------------------------------------
;;; computeReconStats
;;;
;;; SIX stats: requests, total size, domains, slowest, then one tile per
;;; `initiatorType` in FIRST-SEEN order. The order of the tiles is insertion
;;; order of a vector scan, not sorted, so an entry order change in the timings
;;; changes the HTML.
;;; ---------------------------------------------------------------------------

(defparameter *domain-re* (cl-ppcre:create-scanner "^https?://([^/]+)"))

(defun truthy-or (entry key)
  "`truthyOr`: the field as a number when it is JS-truthy, else NIL.

The truthiness test comes FIRST, so a `transferSize` of 0 is absent rather than
zero - which is why the fallback to `encodedBodySize` is reached at all."
  (let ((value (field entry key)))
    (when (js-truthy value)
      (coerce (js-number value) 'double-float))))

(defun compute-recon-stats (timings)
  "`computeReconStats`: the stats strip as HTML."
  ;; BOTH bindings are DOUBLE-FLOATS and nothing narrows them. `format-size` and
  ;; `format-ms` compare against float literals, so an integer 0 signals a
  ;; TYPE-ERROR rather than answering "0 B" / "0 us" - invisible on any non-empty
  ;; input and fatal on the empty one.
  (let ((total-bytes 0d0)
        (slowest 0d0)
        (domains '())
        (types '())
        (n 0))
    (dolist (timing timings)
      (incf n)
      (incf total-bytes (coerce (or (truthy-or timing "transferSize")
                            (truthy-or timing "encodedBodySize")
                            0d0)
                           'double-float))
      ;; A duration is the responseEnd - startTime span when that is non-zero and
      ;; not NaN, and the recorded `duration` otherwise. The NaN guard comes first
      ;; so a NaN span falls through instead of poisoning `slowest`.
      (let* ((response-end (let ((v (field timing "responseEnd")))
                             (if (numberp v) (coerce v 'double-float) 0d0)))
             (start (let ((v (field timing "startTime")))
                      (if (numberp v) (coerce v 'double-float) 0d0)))
             (span (- response-end start))
             (duration (if (and (not (zerop span)) (finite-float-p span))
                           span
                           (or (truthy-or timing "duration") 0d0))))
        (when (> duration slowest) (setf slowest duration)))
      (let ((name (field-str timing "name")))
        (multiple-value-bind (match groups) (cl-ppcre:scan-to-strings *domain-re* name)
          (when match
            (let ((domain (aref groups 0)))
              (unless (member domain domains :test #'string=)
                (push domain domains))))))
      (let* ((initiator (field-str timing "initiatorType"))
             (kind (if (zerop (length initiator)) "other" initiator))
             (cell (assoc kind types :test #'string=)))
        (if cell
            (setf (cdr cell) (1+ (cdr cell)))
            (setf types (append types (list (cons kind 1)))))))
    (let ((type-markup
            (with-output-to-string (s)
              (dolist (cell types)
                (format s "<div class=\"stat\"><div class=\"val\">~a</div><div class=\"lbl\">~a</div></div>"
                        (cdr cell) (escape-html (car cell)))))))
      (format nil "<div class=\"stat\"><div class=\"val\">~a</div><div class=\"lbl\">Requests</div></div><div class=\"stat\"><div class=\"val\">~a</div><div class=\"lbl\">Total Size</div></div><div class=\"stat\"><div class=\"val\">~a</div><div class=\"lbl\">Domains</div></div><div class=\"stat\"><div class=\"val\">~a</div><div class=\"lbl\">Slowest</div></div>~a"
              n
              (vovas.engine.text:format-size total-bytes)
              (length domains)
              ;; `format-ms`/`format-size` compare with float literals, so an
              ;; INTEGER 0 signals a TYPE-ERROR rather than answering "0 us".
              ;; The empty timings list is the case that exposed it.
              (vovas.engine.text:format-ms (coerce slowest 'double-float))
              type-markup))))

;;; ---------------------------------------------------------------------------
;;; Compact JSON
;;;
;;; `JSON.stringify(value)` with no spacing: keys in insertion order, numbers
;;; through the JS formatter, and the same escapes JS produces (`\"`, `\\`,
;;; `\n`, `\r`, `\t`, `\b`, `\f`, and `\u00XX` for the remaining controls).
;;; ---------------------------------------------------------------------------

(defun json-escape-string (text)
  "`JSON.stringify` on a bare string: the two mandatory escapes, the six short
ones, and `\\u00XX` for other controls below 0x20."
  (with-output-to-string (s)
    (write-char #\" s)
    (loop for c across text
          do (case c
               (#\" (write-string "\\\"" s))
               (#\\ (write-string "\\\\" s))
               (#\Newline (write-string "\\n" s))
               (#\Return (write-string "\\r" s))
               (#\Tab (write-string "\\t" s))
               ((#\Backspace) (write-string "\\b" s))
               ((#\Page) (write-string "\\f" s))
               (t (if (< (char-code c) 32)
                      (format s "\\u~4,'0x" (char-code c))
                      (write-char c s)))))
    (write-char #\" s)))

(defun json-serialize-compact (value)
  "`JSON.stringify(value)` with no whitespace.

A LIST is an ARRAY (an empty list included); a hash table is an object; NIL and
JSON null are `null`. That mapping is a deliberate convention inside this port -
plists are used for internal records, so any list reaching here is array-shaped
by construction.

The null test comes FIRST and is `json-null-p` - the PREDICATE. Not
`(null (json-null x))`, which is what shipped here first: `json-null` in the gate
returns its argument for anything that is not null, so that spelling is true for
EVERY value and every string serialized as `null`."
  (cond
    ((json-null-p value) "null")
    ((stringp value) (json-escape-string value))
    ((eq value t) "true")
    ((null value) "false")
    ((numberp value)
     (let ((out (js-number-value value)))
       (if (null out) "null"
           (if (integerp out)
               (format nil "~d" out)
               (vovas.engine.number:to-string (coerce out 'double-float))))))
    ((hash-table-p value)
     (let ((parts '()))
       (maphash (lambda (k v)
                  (push (concatenate 'string (json-escape-string k) ":"
                                     (json-serialize-compact v))
                        parts))
                value)
       (format nil "{~{~a~^,~}}" (nreverse parts))))
    ((listp value)
     (format nil "[~{~a~^,~}]" (mapcar #'json-serialize-compact value)))
    ((vectorp value)
     (format nil "[~{~a~^,~}]"
             (loop for i below (length value)
                   collect (json-serialize-compact (aref value i)))))
    (t "null")))

;;; ---------------------------------------------------------------------------
;;; generateDomSnapshotHtml
;;; ---------------------------------------------------------------------------

(defparameter *dom-snapshot-style*
  (concatenate 'string
    "body{font-family:system-ui,sans-serif;padding:20px;background:#fff;color:#222}"
    "h1{margin:0 0 8px}"
    "p{margin:0 0 16px;color:#555}"
    "pre{white-space:pre-wrap;word-break:break-word;font-family:Consolas,monospace;"
    "font-size:12px;line-height:1.5;background:#f7f7f7;border:1px solid #ddd;"
    "border-radius:6px;padding:16px}")
  "The snapshot page's inline stylesheet, as ONE source string.

Written as a concatenation rather than a format directive because the stylesheet
is full of braces, and `~` handling plus brace escaping is exactly the class of
mistake this project keeps paying for. The page's own `{{`/`}}` are the literal
CSS braces - the format string in the original is double-braced for that reason.")

(defun generate-dom-snapshot-html (dom-html page-meta)
  "`generateDomSnapshotHtml`: a self-contained HTML page showing the raw DOM.

The TITLE in `<title>` is the constant \"DOM Snapshot\" and does NOT follow the
page title - only the `<h1>` does. That asymmetry is in the original and is
reproduced: a reader who fixes it changes exported bytes."
  (let* ((raw-title (field-str page-meta "title"))
         (title (if (zerop (length raw-title)) "DOM Snapshot" raw-title))
         (url (field-str page-meta "url")))
    (format nil
            "<!DOCTYPE html>~%<html>~%<head>~%<meta charset=\"UTF-8\">~%<title>DOM Snapshot</title>~%<style>~a</style>~%</head>~%<body><h1>~a</h1><p>~a</p><pre>~a</pre></body>~%</html>"
            *dom-snapshot-style*
            (escape-html title)
            (escape-html url)
            (escape-html dom-html))))

;;; ---------------------------------------------------------------------------
;;; buildReadableArtifactWith
;;; ---------------------------------------------------------------------------

(defun build-readable-artifact-with (entry record looks-minified-fn beautify-fn)
  "`buildReadableArtifactWith`: a commented reconstruction of one artifact.

The BODY field is `content` for a chunk entry and `text` for everything else -
two spellings for the same slot, chosen by `kind`. An empty or absent body leaves
the readable body empty, and `Beautified:` then reports \"no\" because the two are
equal, which is the honest answer for nothing to beautify.

`looks-minified-fn` and `beautify-fn` are passed in rather than imported so this
stays independent of the beautifier's size; the caller decides whether that module
is loaded at all."
  (let* ((field-name (if (string= (field-str entry "kind") "chunk") "content" "text"))
         (raw (field record field-name))
         (body (if (and (stringp raw) (plusp (length raw))) raw ""))
         (readable (if (funcall looks-minified-fn body)
                       (funcall beautify-fn body)
                       body))
         (labels-list
           (let ((value (field entry "boundaryLabels")))
             (cond
               ((vectorp value)
                (format nil "~{~a~^, ~}"
                        (remove-if-not #'stringp (coerce value 'list))))
               ((listp value)
                (format nil "~{~a~^, ~}" (remove-if-not #'stringp value)))
               (t ""))))
         (label (let ((l (field-str entry "label")))
                  (if (zerop (length l)) (field-str entry "id") l)))
         (score (or (truthy-or entry "score") 0d0))
         (facts (list
                  (format nil "Kind: ~a" (field-str entry "kind"))
                  (format nil "Label: ~a" label)
                  (format nil "URL: ~a" (field-str entry "url"))
                  (format nil "File: ~a" (field-str entry "file"))
                  (format nil "Boundaries: ~a"
                          (if (zerop (length labels-list)) "none" labels-list))
                  (format nil "Why: ~a" (field-str entry "why"))
                  (format nil "Score: ~a"
                          (vovas.engine.number:to-string score))
                  (format nil "Beautified: ~a"
                          (if (string= readable body) "no" "yes")))))
    (with-output-to-string (out)
      (write-string "/*" out)
      (terpri out)
      (write-string " * Semantic reconstruction" out)
      (dolist (fact facts)
        (terpri out)
        (write-string " * " out)
        (write-string fact out))
      (terpri out)
      (write-string " */" out)
      (terpri out)
      (write-string readable out))))
