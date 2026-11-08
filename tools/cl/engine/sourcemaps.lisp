;;;; sourcemaps.lisp — sourceMappingURL discovery, source-map payload decoding
;;;; and map-URL resolution, ported from sourcemaps.rs.
;;;;
;;;; Three jobs, all of them about the one artefact a minified bundle leaves
;;;; behind: its source map.
;;;;
;;;;   1. `find-source-map-ref`   find the LAST `sourceMappingURL` in a text and
;;;;                              say whether it is a file reference or an
;;;;                              inline `data:` URI.
;;;;   2. `parse-source-map`      read the JSON map and keep only the pairs that
;;;;                              carry both a path and recoverable source text.
;;;;   3. `decode-inline-source-map` / `resolve-map-url`  turn what (1) found
;;;;                              into something (2) can read.
;;;;
;;;; The Rust's answer shapes are the specification:
;;;;   `SourceMapRef` serialises as `{"kind":"inline"|"external","value":...}`
;;;;   (wasm_api.rs `source_map_ref_json`), so the port answers
;;;;   `(:kind "external" :value "app.js.map")` — a plist with the same field
;;;;   names, because the oracle records those exact strings.
;;;;
;;;; Deliberate borrowings. Three helpers already exist and are correct in
;;;; `text.lisp`: the strict `decodeURIComponent`, the WHATWG-shaped authority
;;;; parse, and the scheme-prefix scan. Re-implementing any of them here would
;;;; create a second definition of the same rule, which is the failure mode the
;;;; repo's util.lisp exists to prevent ("widening the set for one producer used
;;;; to leave the other four writing names it would reject"). They are reached
;;;; with `::` because text.lisp does not export them and this module must not
;;;; edit package.lisp. The two narrowings that brings are named in
;;;; `resolve-map-url`'s docstring rather than papered over.

(defpackage :vovas.engine.sourcemaps
  (:use :cl)
  (:import-from :vovas.engine.util
                #:bad-path-chars-p
                #:*limits-max-sources*)
  (:import-from :vovas.engine.decoders
                #:ascii-js-space-p
                #:decode-base64-to-bytes
                #:bytes-to-text)
  ;; text.lisp does not export these and package.lisp is the integrator's file,
  ;; so the strict `decodeURIComponent`, the scheme scan and the authority
  ;; parser are reached with `::` inside function bodies instead of here. See
  ;; the file header for why re-implementing them would be worse.
  (:export
   #:find-source-map-ref
   #:parse-source-map
   #:parse-source-map-value
   #:decode-inline-source-map
   #:resolve-map-url
   #:source-map-ref-value
   #:source-map-ref-inline-p
   ;; the struct TYPES are exported as well as their accessors: the gate tests
   ;; `(typep map 'parsed-source-map)`, and `:export` of an accessor does not
   ;; export the type name the `defstruct` interned.
   #:parsed-source-map
   #:source-file
   #:parsed-source-map-files
   #:parsed-source-map-source-root
   #:parsed-source-map-file
   #:source-file-path
   #:source-file-content
   #:parsed-source-map-version
   #:clean-source-path
   #:rust-trim
   #:rust-whitespace-p))

(in-package :vovas.engine.sourcemaps)

(defparameter *map-ref-marker* "sourceMappingURL"
  "The literal the engine searches for. A defparameter, not a defconstant: the
contract's rule 2, because a defconstant on a string signals DEFCONSTANT-UNEQL
on reload even when the text is identical.")

;;; ---------------------------------------------------------------------------
;;; Whitespace: which trim the Rust actually performed
;;; ---------------------------------------------------------------------------

(defun rust-whitespace-p (c)
  "Rust's `char::is_whitespace`, i.e. the Unicode White_Space property.

This is NOT `vovas.engine.util:js-whitespace-p`, and the difference is real:
`find_source_map_ref` ends with `str::trim()`, not `String.prototype.trim`.
JavaScript's `\\s` includes U+FEFF (a BOM) and excludes U+0085 (NEL); Rust's
`is_whitespace` does the reverse. A payload starting with a BOM therefore keeps
it here and loses it under a JS trim, and the engine's answer follows the Rust
because the Rust is what shipped."
  (let ((code (char-code c)))
    (or (<= #x09 code #x0D)             ; TAB LF VT FF CR
        (= code #x20)                   ; SPACE
        (= code #x85)                   ; NEL
        (= code #xA0)                   ; NBSP
        (= code #x1680)                 ; OGHAM SPACE MARK
        (<= #x2000 code #x200A)         ; EN QUAD .. HAIR SPACE
        (= code #x2028)                 ; LINE SEPARATOR
        (= code #x2029)                 ; PARAGRAPH SEPARATOR
        (= code #x202F)                 ; NARROW NO-BREAK SPACE
        (= code #x205F)                 ; MEDIUM MATHEMATICAL SPACE
        (= code #x3000))))              ; IDEOGRAPHIC SPACE

(defun rust-trim (text)
  "`str::trim()`: both ends, `rust-whitespace-p`. Always a fresh string, so a
caller cannot end up sharing storage with its input."
  (let* ((n (length text))
         (start (loop for i from 0 below n
                      while (rust-whitespace-p (char text i))
                      finally (return i)))
         (end (loop for i from n downto (1+ start)
                    while (rust-whitespace-p (char text (1- i)))
                    finally (return i))))
    (subseq text start end)))

;;; ---------------------------------------------------------------------------
;;; findSourceMapRef
;;; ---------------------------------------------------------------------------

(defun strip-map-ref-prefix (line)
  "`MAP_REF_PREFIX.replace(line, \"\")` for
`^sourceMappingURL[ \\t\\n\\x0B\\f\\r]*=[ \\t\\n\\x0B\\f\\r]*`.

`Regex::replace` (not `replace_all`) rewrites only the first match, and the `^`
anchor means that match can only start at offset 0 — so this is: the keyword,
optional JS-ASCII whitespace, one `=`, optional whitespace, then the rest.

When the anchored pattern does NOT match the line comes back unchanged. That is
not defensive coding: `sourceMappingURLX=foo` is a text the engine answers with
the whole line as an external ref, and swallowing the failure would have made it
answer \"X=foo\" instead."
  (labels ((space-at (i)
             (and (< i (length line)) (ascii-js-space-p (char line i))))
           (skip (i)
             (loop while (space-at i) do (incf i) finally (return i))))
    ;; LINE always begins with the marker: `find-source-map-ref` starts it at the
    ;; index `rfind` answered. Skipping the marker rather than matching it again
    ;; is what the `^`-anchored replace is doing.
    (let ((i (skip (length *map-ref-marker*))))
      (if (and (< i (length line)) (char= (char line i) #\=))
          (subseq line (skip (1+ i)))
          (copy-seq line)))))

(defun last-index-of (needle text)
  "`str::rfind`, as a character index: the start of the LAST occurrence of
NEEDLE in TEXT, or NIL.

Character index, not byte index. The Rust indexes bytes; every index it computes
is then used to slice the same string, so the two agree as long as the unit is
used consistently — and the marker is ASCII, so a byte index always lands on a
character boundary. Using characters here keeps `(length text)` (the fallback
line end) in the same unit as the search result, which is the trap this note
exists to prevent: mixing the units truncates the line by one character for
every astral character before it."
  (let ((found nil)
        (start 0))
    (loop for at = (search needle text :start2 start)
          while at
          do (setf found at
                   start (1+ at)))
    found))

(defun find-source-map-ref (text)
  "`findSourceMapRef`, answering `(:kind \"inline\"|\"external\" :value STRING)`
or NIL for \"no reference in this text\".

The LAST occurrence wins, not the first, and that is the specification: a text
assembled from several concatenated sources carries several references, and the
one that describes the final output is the trailing comment. `rfind` is what the
engine calls, and the oracle's inputs all have zero or one so no case would have
caught a first-match port.

The ref runs to the end of its LINE, not to the end of the text: a
sourceMappingURL with trailing code after it on the same line would otherwise
swallow that code into the URL.

An inline ref keeps the ENTIRE `data:` URI in `value` rather than just its
payload, because `decode-inline-source-map` re-matches the prefix to learn the
encoding — the decoder has no other way to know whether the payload is base64."
  (let ((index (last-index-of *map-ref-marker* text)))
    (when (null index)
      (return-from find-source-map-ref nil))
    (let* ((line-end (or (position #\Newline text :start index) (length text)))
           (line (subseq text index line-end))
           (value (rust-trim (strip-map-ref-prefix line))))
      (cond
        ((string= value "") nil)
        ;; `starts_with("data:")` is case-sensitive in the Rust, so
        ;; "DATA:..." is an external ref with a very odd name, not an inline one.
        ((and (>= (length value) 5) (string= (subseq value 0 5) "data:"))
         (list :kind "inline" :value value))
        (t (list :kind "external" :value value))))))

;;; ---------------------------------------------------------------------------
;;; parseSourceMap
;;; ---------------------------------------------------------------------------

(defstruct (source-file (:constructor make-source-file (path content)))
  (path "" :type string)
  (content "" :type string))

(defstruct (parsed-source-map (:constructor %make-parsed-source-map))
  (files '() :type list)
  (source-root "" :type string)
  (file "" :type string))

(defun json-null-p (value)
  "JZON parses JSON `null` to the symbol NAMED \"NULL\", which is neither NIL nor
a Lisp null. Every field test that has to tell \"present but null\" from
\"present and false\" needs this, and `sourcesContent` entries are exactly that
case."
  (and (symbolp value)
       (not (null value))
       (string= (symbol-name value) "NULL")))

(defun json-string-p (value)
  (typep value 'string))

(defun clean-source-path (source)
  "`clean_source_path`: strip the prefixes bundlers write, normalise separators,
and replace the characters a path segment may not contain.

Order is load-bearing and preserved exactly:

  1. `^webpack://`   webpack's own scheme
  2. `^webpack//`    the same scheme written without the colon
  3. `^\\./`           a redundant current-directory prefix
  4. `\\\\` -> `/`     Windows separators, ALL of them
  5. `^/+`           leading slashes, so the result stays a RELATIVE path
  6. the shared bad-path-character set -> `_`

Step 4 has to precede step 6: `[\\\\:*?\"<>|]` includes the backslash, so doing
(6) first would turn every separator into an underscore and flatten
`src\\\\add.js` to `src__add.js`. Its presence in the set is not redundant — it
catches a backslash that arrived from a later stage — but it must never be the
thing that sees a separator.

Each `^`-anchored step strips ONE prefix, not every occurrence, which is why a
path like `a/webpack://b` keeps its embedded marker."
  (let* ((path (if (and (>= (length source) 10)
                        (string= (subseq source 0 10) "webpack://"))
                   (subseq source 10)
                   source))
         (path (if (and (>= (length path) 9)
                        (string= (subseq path 0 9) "webpack//"))
                   (subseq path 9)
                   path))
         (path (if (and (>= (length path) 2)
                        (string= (subseq path 0 2) "./"))
                   (subseq path 2)
                   path))
         (path (with-output-to-string (s)
                 (loop for c across path
                       do (write-char (if (char= c #\\) #\/ c) s))))
         (path (string-left-trim "/" path)))
    (with-output-to-string (s)
      (loop for c across path
            do (write-char (if (bad-path-chars-p c) #\_ c) s)))))

(defun string-sequence-p (value)
  "A JSON array, as JZON parses one."
  (and (vectorp value) (not (stringp value))))

(defun read-string-sequence (value)
  "VALUE as a list of strings, as `(values ok-p list)`.

The SECOND value is the answer; the first is what tells the caller whether the
field deserialised at all. They cannot be collapsed into one: a serde `Vec<String>`
that is a JSON array of no elements is a perfectly good EMPTY list, and an empty
list is NIL in Lisp, so a caller testing the list itself would read \"the map has
no sources\" and \"the map is malformed\" as the same answer. Serde's `Vec<String>`
also rejects the whole document on a single non-string element, which is why this
is all-or-nothing rather than a filtering walk."
  (unless (string-sequence-p value)
    (return-from read-string-sequence (values nil nil)))
  (let ((items (loop for item across value collect item)))
    (if (every #'json-string-p items)
        (values t items)
        (values nil nil))))

(defun read-optional-string (value)
  "A serde `Option<String>`: `(values ok-p string)`.

`ok-p` is NIL when the field holds something serde would reject, which makes the
whole document fail to deserialise; a JSON `null` is `(values T NIL)` and a
string is itself. `false` and `0` are rejections, not nulls — JZON parses JSON
`true`/`false` to Lisp booleans, and NIL would otherwise be indistinguishable
from the absent-field default."
  (cond
    ((json-null-p value) (values t nil))
    ((json-string-p value) (values t value))
    (t (values nil nil))))

(defun read-content-sequence (value)
  "`sourcesContent` as `(values ok-p list)`. Each element is a serde
`Option<String>`: a JSON string or a JSON null, and nothing else.

The nulls are KEPT, not filtered out here, because the pairing with `sources`
is by INDEX: dropping a null would shift every later source onto the wrong
content, which is a bug that reads as \"wrong source text\" and not as a parse
problem. `parse-source-map` skips the nulls while walking the pairs."
  (unless (string-sequence-p value)
    (return-from read-content-sequence (values nil nil)))
  (let ((items '()))
    (loop for item across value
          do (multiple-value-bind (ok content) (read-optional-string item)
               (unless ok
                 (return-from read-content-sequence (values nil nil)))
               (push content items)))
    (values t (nreverse items))))

(defun parse-json-text (json)
  "Read JSON text, answering two values: a success flag and the parsed tree.

The flag exists because a legitimate document can parse to something falsy: a
bare `null` parses to JZON's NULL symbol, and a document is never NIL. A caller
that tested the tree would read \"this text is `null`\" as \"this text is
malformed\" and answer the same failure for both.

Two guards, neither of them defensive padding:

  - An EMPTY or whitespace-only text is rejected before JZON sees it. JZON 1.1.4
    signals a bare TYPE-ERROR on empty input (it reads zero characters where its
    reader declared at least one), which is not a JSON condition and would escape
    the two handlers below. `serde_json` answers a clean `EofWhileParsingValue`
    there, and both are \"this is not a map\".
  - `*read-default-float-format*` is bound around the parse for the reason
    gate.lisp records: JZON builds numbers from their text, so without it a
    `1e308` becomes a SINGLE float and overflows into a reader error that reads
    like malformed JSON."
  (when (every (lambda (c) (member c '(#\Space #\Tab #\Newline #\Return #\Page)))
               json)
    (return-from parse-json-text (values nil nil)))
  (handler-case
      (let ((*read-default-float-format* 'double-float))
        (values t (com.inuoe.jzon:parse json)))
    ;; The two JZON condition classes, named rather than caught as `error`: a
    ;; genuinely unexpected reader failure should surface rather than be
    ;; laundered into \"this is not a map\".
    (com.inuoe.jzon:json-parse-error () (values nil nil))
    (com.inuoe.jzon:json-eof-error () (values nil nil))))

(defun parse-source-map (json)
  "JS `parseSourceMap(json)`: parse the text, then map the struct.

A SEPARATE text entry point from `parse-source-map-value` because
`serde_json::from_str` is a text-to-struct conversion: the Rust signature takes
`&str`, not a value, and the caller in pipeline.rs hands it text decoded out of a
`data:` URI. Splitting the two is what lets the gate feed the struct mapper a
tree it built itself, without also having to invent a JSON reader.

A parse error and a shape error answer the same NIL, because that is what the
engine does: wasm_api.rs collapses `Err(_)` from either source into JSON `null`.
The caller cannot tell them apart and does not need to."
  (multiple-value-bind (ok tree) (parse-json-text json)
    (when ok
      (parse-source-map-value tree))))

(defun field-or-default (object name default-reader default)
  "Read NAME from OBJECT with serde's `#[serde(default)]` semantics.

PRESENT is decided by the SECOND value of `gethash`, never by the value: a key
whose value is JSON `null` IS present, and for an `Option<T>` field that means
`None` (valid), while an absent key means the whole `#[serde(default)]` expression
runs — which for these struct fields is the same empty answer but only because
the default happens to be the empty value. Conflating them works by luck for
`sourceRoot` and breaks for anything whose default is not \"absent\"."
  (multiple-value-bind (value present) (gethash name object)
    (if present
        (multiple-value-bind (ok result) (funcall default-reader value)
          (if ok (values t result) (values nil nil)))
        (values t default))))

(defun parse-source-map-value (json)
  "`parse_source_map` over an ALREADY-PARSED JSON value, answering a
`parsed-source-map` or NIL.

Separate from `parse-source-map` so the JSON reader is not welded into the
struct mapper: the gate can feed it trees it built itself, and the one place
that knows which JSON library the repo uses stays in the text entry point
above.

NIL is the failure value. The Rust's `Result` exists because the JS throws and
the caller maps the throw to a note; wasm_api.rs turns `Err(_)` into JSON `null`
and `Ok` into the `{files, sourceRoot, file}` object, so NIL is the shape the
caller actually consumes and the shape the gate asserts for invalid input.

What is kept, and why each skip exists:

  - A source with no `sourcesContent` entry, a `null` entry, or an EMPTY string
    is dropped. Only the sourcesContent slice is the recoverable original, so a
    path with no text behind it would be an archive entry with nothing to write.
  - A path that cleans down to empty, or that still ends in `/` (a directory,
    not a file), becomes `index.js` rather than being dropped.
  - `LIMITS.max_sources` (400) caps the OUTPUT, checked before each push, so a
    hostile map with a million sources cannot allocate a million entries.

Serde's tolerance is reproduced rather than a general JSON reader's: unknown
keys are ignored (the struct has no `deny_unknown_fields`), a MISSING array field
defaults to empty, but a field of the wrong TYPE fails the whole document. The
`sources` length need not match `sourcesContent` — the pairing is by index and a
short `sourcesContent` simply stops contributing."
  (unless (hash-table-p json)
    ;; serde deserialises a struct only from a JSON object. An array, a string
    ;; or a bare number is an error, not an empty map.
    (return-from parse-source-map-value nil))
  (multiple-value-bind (sources-ok sources)
      ;; `#[serde(default)]` on `sources: Vec<String>`: an ABSENT key is an
      ;; empty vector, a present one must be an array of strings.
      (field-or-default json "sources" #'read-string-sequence '())
    (unless sources-ok
      (return-from parse-source-map-value nil))
    (multiple-value-bind (contents-ok contents)
        (field-or-default json "sourcesContent" #'read-content-sequence '())
      (unless contents-ok
        (return-from parse-source-map-value nil))
      (multiple-value-bind (root-ok source-root)
          (field-or-default json "sourceRoot" #'read-optional-string nil)
        (unless root-ok
          (return-from parse-source-map-value nil))
        (multiple-value-bind (file-ok file)
            (field-or-default json "file" #'read-optional-string nil)
          (unless file-ok
            (return-from parse-source-map-value nil))
            (let ((files '())
                  (limit *limits-max-sources*))
              ;; The cap counts FILES, not sources, and is checked before each
              ;; push. A map whose first 400 sources all lack content therefore
              ;; keeps scanning past them rather than stopping at source 400.
              (loop for source in sources
                    for i from 0
                    while (< (length files) limit)
                    do (let ((content (nth i contents)))
                         (when (and content (plusp (length content)))
                           (let ((path (clean-source-path source)))
                             (when (or (string= path "")
                                       (char= (char path (1- (length path))) #\/))
                               (setf path (concatenate 'string path "index.js")))
                             (push (make-source-file path content) files)))))
            (%make-parsed-source-map :files (nreverse files)
                                     :source-root (or source-root "")
                                     :file (or file ""))))))))

(defun parsed-source-map-version (json)
  "The `version` of a decoded map DOCUMENT, for the gate's structural check.

Kept here rather than in the gate because it is the one field `parse-source-map`
does not read (nothing downstream uses it): serde ignores it, so a JSON map
without `version` still parses. Answering it from the same JZON tree the parse
used means the gate checks the document the engine actually decoded."
  (when (hash-table-p json)
    (let ((version (gethash "version" json)))
      (and (integerp version) version))))

;;; ---------------------------------------------------------------------------
;;; decodeInlineSourceMap
;;; ---------------------------------------------------------------------------

(defun decode-inline-source-map (data-uri)
  "`decodeInlineSourceMap`, answering a string or NIL.

`DATA_URI_RE = ^data:([^;,]*)(;base64)?,([\\s\\S]*)$` is written out by hand. The
three groups are the media type (no `;` and no `,`), an optional literal
`;base64`, and the payload up to the end of the string — `[\\s\\S]` rather than
`.` precisely so embedded newlines survive.

Hand-written because the consequences of getting it wrong are subtle and worth
stating: a media type containing any parameter (`application/json;charset=utf-8`)
cannot match, because `[^;,]*` stops at the `;` and `(;base64)?` will not accept
`;charset=...`, and the Rust's regex then fails outright. A general-purpose
`data:` parser would happily decode those and answer text where the engine
answers null. NIL is that null.

Two payload paths:

  - `;base64` present: decode to bytes, then lossy-UTF-8 to text. A payload that
    does not decode answers the text of ZERO bytes — the empty string, not NIL.
    That is the Rust's `unwrap_or_default()` and it is deliberate: the JS
    TextDecoder path runs on whatever came back, so a corrupt map reads as
    \"no map\" one call later rather than here.
  - `;base64` absent: `decodeURIComponent`, strict. An invalid escape answers
    NIL, which is the Rust's `Option` propagating the throw."
  (unless (and (>= (length data-uri) 5) (string= (subseq data-uri 0 5) "data:"))
    (return-from decode-inline-source-map nil))
  (let* ((n (length data-uri))
         (media-end (or (position-if (lambda (c) (member c '(#\; #\,)))
                                     data-uri :start 5)
                        n)))
    (when (= media-end n)
      ;; no `;` and no `,` after the media type: the pattern's mandatory comma
      ;; is missing
      (return-from decode-inline-source-map nil))
    (if (char= (char data-uri media-end) #\,)
        ;; `(;base64)?` matched nothing, so the comma is the payload start
        (vovas.engine.transforms:decode-uri-component
         (subseq data-uri (1+ media-end)))
        ;; a `;` — it must be exactly `;base64`, and then a comma
        (let ((params-start media-end))
          (unless (and (>= (- n params-start) 7)
                       (string= (subseq data-uri params-start (+ params-start 7))
                                ";base64"))
            (return-from decode-inline-source-map nil))
          (let ((comma (+ params-start 7)))
            (unless (and (< comma n) (char= (char data-uri comma) #\,))
              (return-from decode-inline-source-map nil))
            (bytes-to-text
             (or (decode-base64-to-bytes (subseq data-uri (1+ comma)))
                 ;; the empty vector: a failed decode becomes empty TEXT
                 (make-array 0 :element-type '(unsigned-byte 8)))))))))

;;; ---------------------------------------------------------------------------
;;; resolveMapUrl
;;;
;;; `url::Url::parse(script)?.join(ref)?.to_string()`, with the raw ref when
;;; either half does not parse. The join is RFC 3986 section 5, which is what the
;;; `url` crate implements for a hierarchical URL.
;;; ---------------------------------------------------------------------------

(defparameter *scheme-default-ports* '(("http" . 80) ("https" . 443)
                                       ("ws" . 80) ("wss" . 443)
                                       ("ftp" . 21))
  "Ports the `url` crate drops from serialisation because they are implied by
the scheme. A non-default port must be written back, which is why this table
exists instead of always emitting the port.")

(defun split-path-segments (path)
  "The segments of an absolute PATH, leading slash removed.

A trailing slash produces a final empty segment on purpose: rejoining
(\"a\" \"\") over `/` gives back \"a/\" rather than \"a\", and the difference
between a directory and a file is exactly what `resolveMapUrl` must not lose."
  (let ((segments '())
        (start 1)
        (n (length path)))
    (loop
      (let ((slash (position #\/ path :start start)))
        (if slash
            (progn (push (subseq path start slash) segments)
                   (setf start (1+ slash)))
            (progn (when (<= start n)
                     (push (subseq path start n) segments))
                   (return)))))
    (nreverse segments)))

(defun remove-dot-segments (path)
  "RFC 3986 5.2.4 `remove_dot_segments`, over an absolute path.

Three rules, each of which a naive `(remove \"..\")` gets wrong:

  - `..` POPS the previous segment; it does not get deleted with the segment
    before it left in place. `/a/../up.map` answers `/up.map`.
  - A `..` that would escape the root is dropped silently, so `/../../x` answers
    `/x` rather than `/../../x`. The `url` crate cannot produce a path above the
    root, so keeping the dots would be a path no browser can resolve.
  - A path whose last segment is `.` or `..` keeps a TRAILING SLASH: the
    reference named a directory, and `/a/.` answers `/a/`, not `/a`."
  (let ((out '())
        (directory-tail nil))
    (dolist (segment (split-path-segments path))
      (cond
        ((string= segment ".") (setf directory-tail t))
        ((string= segment "..") (setf directory-tail t) (when out (pop out)))
        (t (setf directory-tail nil) (push segment out))))
    (let ((segments (nreverse out)))
      (when directory-tail
        (setf segments (append segments (list ""))))
      (format nil "/~{~a~^/~}" segments))))

(defun split-reference (ref)
  "RFC 3986 5.2.1: split REF into (values path query fragment). The fragment is
everything after the first `#`; the query is everything after the first `?` in
what remains. Both come back as strings, or NIL when the delimiter is absent, so
an EMPTY query (`a?`) stays distinguishable from no query at all."
  (let* ((hash (position #\# ref))
         (before (if hash (subseq ref 0 hash) ref))
         (fragment (and hash (subseq ref (1+ hash))))
         (question (position #\? before))
         (query (and question (subseq before (1+ question))))
         (path (if question (subseq before 0 question) before)))
    (values path query fragment)))

(defun serialize-url (scheme host port path query fragment)
  "`Url::to_string()` for an authority URL: `scheme://host[:port]/path[?q][#f]`.

The host is already lowercased by the parser and the path already defaulted to
`/`. The port is written only when it is not the scheme's default, and an EMPTY
query or fragment keeps its bare delimiter, which is how the crate round-trips
`https://h/a?`."
  (let ((default (cdr (assoc scheme *scheme-default-ports* :test #'string=))))
    (concatenate 'string
                 scheme "://" host
                 (if (and port (/= port default)) (format nil ":~a" port) "")
                 (if (string= path "") "/" path)
                 (if query (concatenate 'string "?" query) "")
                 (if fragment (concatenate 'string "#" fragment) ""))))

(defun join-reference (scheme host port base-path base-query ref)
  "Resolve REF against the already-parsed base (SCHEME HOST PORT BASE-PATH
BASE-QUERY), answering the serialised URL, or NIL when REF is not usable.

The four RFC 3986 5.2.2 cases, in the order the spec checks them: a reference
with its own scheme is absolute; `//` replaces the authority; an empty path is
the same document; anything else is a relative path merged onto the base's
directory."
  (when (vovas.engine.text::scheme-prefix-length ref)
    ;; An absolute reference replaces everything. A reference whose scheme is
    ;; NOT followed by `//` is opaque, and the `url` crate would keep it as
    ;; `scheme:path`; that form cannot be a source-map URL in practice, so it
    ;; is answered as written rather than parsed.
    (let ((parsed (vovas.engine.text::parse-url-for-panel ref)))
      (return-from join-reference
        (if parsed
            (serialize-url (vovas.engine.text::parsed-url-scheme parsed)
                           (vovas.engine.text::parsed-url-host parsed)
                           (vovas.engine.text::parsed-url-port parsed)
                           (vovas.engine.text::parsed-url-path parsed)
                           (vovas.engine.text::parsed-url-query parsed)
                           (vovas.engine.text::parsed-url-fragment parsed))
            (copy-seq ref)))))
    (multiple-value-bind (path query fragment) (split-reference ref)
      (cond
        ;; "//host/path": the authority is replaced, the scheme is inherited
        ((and (>= (length path) 2) (string= (subseq path 0 2) "//"))
         (let ((parsed (vovas.engine.text::parse-url-for-panel
                        (concatenate 'string scheme ":" path))))
           (if parsed
               (serialize-url (vovas.engine.text::parsed-url-scheme parsed)
                              (vovas.engine.text::parsed-url-host parsed)
                              (vovas.engine.text::parsed-url-port parsed)
                              (vovas.engine.text::parsed-url-path parsed)
                              (vovas.engine.text::parsed-url-query parsed)
                              (vovas.engine.text::parsed-url-fragment parsed))
               (copy-seq ref))))
        ;; An empty path means "the same document" (RFC 3986 5.2.2): the base
        ;; path survives and the base QUERY survives unless the reference wrote
        ;; its own. Inheriting the query unconditionally would answer
        ;; `.../b.js?` for a bare "", and dropping it would lose it on `#top`.
        ((string= path "")
         (serialize-url scheme host port base-path
                        (if (null query) base-query query)
                        fragment))
        (t
         (let* ((absolute (char= (char path 0) #\/))
                (merged (if absolute
                            path
                            ;; merge: everything up to the base's last slash,
                            ;; except that an empty base path still means "/"
                            (let ((slash (position #\/ base-path :from-end t)))
                              (concatenate 'string
                                           (if slash (subseq base-path 0 (1+ slash)) "/")
                                           path)))))
           (serialize-url scheme host port
                          (remove-dot-segments merged)
                          query fragment))))))

(defun resolve-map-url (script-url map-ref)
  "JS `new URL(mapRef, scriptUrl).href`, falling back to the raw MAP-REF when
either side is not a parseable absolute URL. `url::Url::parse` and
`base.join` in the Rust; both failures answer `map_ref.to_string()`.

Two narrowings, both reported rather than hidden, and neither reachable from the
oracle's seven pairs:

  - `user:pass@host` in SCRIPT-URL is dropped. `url::Url` keeps userinfo and
    writes it back; `text.lisp`'s panel parser discards it (\"the panel never
    writes credentials into a path\"). A source-map URL never carries
    credentials, so the resolver inherits that decision instead of keeping a
    second copy of it.
  - A base with a scheme but NO `//` — `custom-scheme:/x`, `file:///C:/x.js` —
    is answered as unparseable here, where `url::Url` would treat it as
    hierarchical. `file:///C:/x.js` parses with an empty host, which the panel
    parser rejects. A page served over http(s) always has an authority, so this
    only bites a locally-opened page.

NIL never escapes this function: the fallback is the raw reference."
  (let ((base (vovas.engine.text::parse-url-for-panel script-url)))
    (if (null base)
        (copy-seq map-ref)
        (or (join-reference (vovas.engine.text::parsed-url-scheme base)
                            (vovas.engine.text::parsed-url-host base)
                            (vovas.engine.text::parsed-url-port base)
                            (vovas.engine.text::parsed-url-path base)
                            (vovas.engine.text::parsed-url-query base)
                            map-ref)
            (copy-seq map-ref)))))

;;; ---------------------------------------------------------------------------
;;; The value accessors the pipeline consumes
;;; ---------------------------------------------------------------------------

(defun source-map-ref-value (ref)
  "`SourceMapRef::value()`: the string either variant carries."
  (getf ref :value))

(defun source-map-ref-inline-p (ref)
  "`matches!(ref, SourceMapRef::Inline { .. })`: whether the value is a `data:`
URI that still has to be decoded."
  (equal (getf ref :kind) "inline"))
