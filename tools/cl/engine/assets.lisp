;;;; assets.lisp — script-asset analysis, from panel/assets.rs (SLICE 1).
;;;;
;;;; Scope: the HELPER TIER — the pure string/detection functions that the
;;;; pipeline-level functions are built from. Those have 61 real input/output pairs
;;;; in `assets-oracle-paired.json`, transcribed from the Rust test block, so this
;;;; slice is properly oracle-pinned rather than structurally guessed.
;;;;
;;;; NOT ported yet, and deliberately: `prepare-script-assets`, `build-chunk-summary`,
;;;; `strip-chunk-asset`, `build-runtime-origins`, `strip-runtime-entry` and the
;;;; scoring functions. They need `ScriptAsset` / `RuntimeOrigin` records and the
;;;; recon fixture's whole shape, which is a second slice. The gate for this file
;;;; asserts only what exists, so a green run here does not imply the pipeline tier
;;;; works.
;;;;
;;;; Almost everything below is a SUBSTRING test over a lowercased `"url\ncontent"`
;;;; sample, and that shape is load-bearing: a rule that matched against `content`
;;;; alone would miss a signal carried in the URL, and vice versa.

(in-package :vovas.engine.panel.assets)

;;; ---------------------------------------------------------------------------
;;; URL normalisation
;;; ---------------------------------------------------------------------------

(defun normalize-url-key (url)
  "`normalizeUrlKey`: everything before the first `#`.

A fragment never identifies a resource, so two URLs differing only in `#...` are
the same key. The QUERY survives - `?a=1` can genuinely be a different asset."
  (let ((hash (position #\# url)))
    (if hash (subseq url 0 hash) (copy-seq url))))

(defun strip-url-variant (url)
  "`stripUrlVariant`: the fragment AND the query removed, via `normalizeUrlKey`
first so `#` wins over a later `?`."
  (let ((q (position #\? (normalize-url-key url))))
    (if q (subseq (normalize-url-key url) 0 q) (normalize-url-key url))))

(defun get-bare-file-name (value)
  "`getBareFileName`: the last path segment after removing the query/fragment,
with backslashes folded to forward slashes first so a Windows path splits too."
  (let* ((stripped (substitute #\/ #\\ (strip-url-variant value)))
         (slash (position #\/ stripped :from-end t)))
    (if slash (subseq stripped (1+ slash)) stripped)))

;;; ---------------------------------------------------------------------------
;;; Stack references
;;; ---------------------------------------------------------------------------

(defun clean-stack-reference (value)
  "`cleanStackReference`: trim, drop trailing `)`/`,` runs, then a `:line:col` or
`:line` suffix.

The ORDER is the contract. Trailing punctuation must go before the line suffix,
because `foo.js:10:5),` only becomes `foo.js` if the `),` is removed first -
strip the suffix first and the pattern never matches."
  (let ((s (vovas.engine.util:js-trim value)))
    (setf s (cl-ppcre:regex-replace "[),]+$" s ""))
    (setf s (cl-ppcre:regex-replace ":[0-9]+:[0-9]+$" s ""))
    (cl-ppcre:regex-replace ":[0-9]+$" s "")))

(defun extract-stack-refs (stack)
  "`extractStackRefs`: the URL-ish references in a stack trace, in order.

Each match is cleaned, and a `blob:` reference survives cleaning because the
scheme is part of the match rather than something the pattern discards."
  (let ((refs '()))
    (cl-ppcre:do-scans (start end reg-start reg-end
                        "((?:https?|blob:https?):[^\\s)\"',]+)" stack)
      (declare (ignore reg-start reg-end))
      (let ((raw (subseq stack start end))
            (cleaned (clean-stack-reference (subseq stack start end))))
        (declare (ignore raw))
        (unless (string= cleaned "")
          (push cleaned refs))))
    (unique-strings (nreverse refs))))

;;; ---------------------------------------------------------------------------
;;; A small shared helper the Rust uses everywhere
;;; ---------------------------------------------------------------------------

(defun unique-strings (values)
  "`uniqueStrings`: first occurrence wins, order preserved."
  (let ((seen '())
        (out '()))
    (dolist (v values)
      (unless (member v seen :test #'string=)
        (push v seen)
        (push v out)))
    (nreverse out)))

;;; ---------------------------------------------------------------------------
;;; Detection: bundler, framework, startup signals
;;;
;;; All three fold url and content into ONE lowercased sample, so a rule can fire
;;; on either. That is why `url\ncontent` is built identically in each.
;;; ---------------------------------------------------------------------------

(defun asset-sample (url content)
  "`format!(\"{url}\\n{content}\").to_lowercase()`."
  (string-downcase (format nil "~a~%~a" url content)))

(defun detect-bundler-name (url content)
  "`detectBundlerName`. Order matters: webpack is tested before parcel and vite,
so a bundle carrying both markers reports webpack."
  (let ((s (asset-sample url content)))
    (cond
      ((or (search "__webpack_require__" s)
           (search "webpackchunk" s)
           (search "/_next/static/chunks/" s))
       "webpack")
      ((search "parcelrequire" s) "parcel")
      ((or (search "import.meta.hot" s)
           (search "/@vite/" s)
           (search "__vite__" s))
       "vite")
      (t "unknown"))))

(defun detect-framework-hints (url content &optional stack-profile)
  "`detectFrameworkHints`: at most EIGHT hints, deduplicated, in test order.

`stack-profile` is the recon JSON object; its `technologies` array contributes a
hint per entry with a non-empty `name`. Those come AFTER the content-derived
hints, because the Rust pushes them onto the same vector before deduplicating -
so a technology that duplicates an earlier hint does not cost a later distinct
one its slot. The cap is applied after both, on the deduplicated list."
  (let ((s (asset-sample url content))
        (hints '()))
    (flet ((hint (name test)
             (when test (push name hints))))
      (hint "Next.js" (or (search "__next_data__" s) (search "/_next/" s)))
      (hint "React" (or (search "reactdom" s) (search "react" s)))
      (hint "Nuxt" (search "__nuxt" s))
      (hint "Vue" (or (search "__vue" s) (search "createapp(" s)))
      (hint "Angular" (or (search "ng-version" s) (search "zone.js" s)))
      (hint "SvelteKit" (search "svelte" s))
      (hint "Astro" (search "astro" s))
      (hint "Remix" (search "remix" s)))
    ;; built-ins in test order, then the profile's technologies appended
    (let ((ordered (nreverse hints))
          (techs (and (hash-table-p stack-profile)
                      (field stack-profile "technologies"))))
      (when (vectorp techs)
        (loop for tech across techs
              do (let ((name (and (hash-table-p tech) (field tech "name"))))
                   (when (and (stringp name) (plusp (length name)))
                     (setf ordered (append ordered (list name)))))))
      (let ((uniq (unique-strings ordered)))
        (if (> (length uniq) 8) (subseq uniq 0 8) uniq)))))

(defun detect-startup-signals (url content)
  "`detectStartupSignals`: every startup marker present, deduplicated, no cap."
  (let ((s (asset-sample url content))
        (signals '()))
    ;; NOT named `signal`: that is CL:SIGNAL and rebinding it is a package-lock
    ;; violation in a package that uses CL.
    (flet ((add-signal (name test)
             (when test (push name signals))))
      (add-signal "hydration"
              (or (search "hydrateroot" s)
                  (search "reactdom.hydrate" s)
                  (search "__next_data__" s)))
      (add-signal "service-worker-register" (search "serviceworker.register" s))
      (add-signal "worker-bootstrap"
              (or (search "new worker(" s) (search "sharedworker(" s)))
      (add-signal "wasm-bootstrap" (search "webassembly" s))
      (add-signal "graphql-client"
              (or (search "graphql" s) (search "apollo" s) (search "relay" s)))
      (add-signal "dynamic-import" (search "import(" s))
      (add-signal "inline-source-map" (search "sourcemappingurl=data:" s))
      (add-signal "chunk-loader"
              (or (search "webpackchunk" s)
                  (search "__webpack_require__.e" s)
                  (search "parcelrequire" s)
                  (search "__vite__" s)))
      (add-signal "router" (or (search "router" s) (search "history.pushstate" s))))
    (unique-strings (nreverse signals))))

;;; ---------------------------------------------------------------------------
;;; Route hints and imports
;;; ---------------------------------------------------------------------------

(defparameter *route-skip*
  (cl-ppcre:create-scanner "^(static|assets|chunks|build|dist|js|runtime|vendor)$"
                           :case-insensitive-mode t)
  "Directory names that say nothing about a route.")

(defparameter *route-hashy*
  (cl-ppcre:create-scanner "^[0-9a-f_-]{8,}$" :case-insensitive-mode t)
  "Content-hash segments, which are not route names.")

(defparameter *route-ext*
  (cl-ppcre:create-scanner "\\.[A-Za-z0-9]+$")
  "A trailing extension, stripped before the segment is judged.")

(defun extract-route-hints-from-url (url)
  "`extractRouteHintsFromUrl`: meaningful path segments, at most SIX.

A segment shorter than THREE UTF-16 units is dropped, as are the skip-list
directories and content hashes. The extension is removed BEFORE the length test,
so `js` alone is skipped by name rather than surviving as a 2-char segment."
  (let ((parsed (vovas.engine.text:parse-url-for-panel url)))
    (unless parsed
      (return-from extract-route-hints-from-url '()))
    (let ((hints '()))
      (setf hints
            (loop for part in (split-on-slash
                               (vovas.engine.text::parsed-url-path parsed))
                  for decoded = (vovas.engine.text:safe-decode-uri-component part)
                  for stripped = (cl-ppcre:regex-replace *route-ext* decoded "")
                  when (and (plusp (length stripped))
                            (>= (vovas.engine.util:utf16-length stripped) 3)
                            (not (cl-ppcre:scan *route-skip* stripped))
                            (not (cl-ppcre:scan *route-hashy* stripped)))
                    collect stripped))
      (let ((uniq (unique-strings hints)))
        (if (> (length uniq) 6) (subseq uniq 0 6) uniq)))))

(defun split-on-slash (text)
  (let ((out '())
        (start 0))
    (loop for i from 0 below (length text)
          do (when (char= (char text i) #\/)
               (push (subseq text start i) out)
               (setf start (1+ i))))
    (push (subseq text start) out)
    (nreverse out)))

(defparameter *js-s-chars*
  (format nil "~a~a~a~a~a~a"
          #\Space #\Tab #\Newline (code-char 11) (code-char 12) #\Return)
  "util.rs's JS_S as literal characters, for the import patterns.")

(defun extract-import-specifiers (content)
  "`extractImportSpecifiers`: specifiers from `import ... from`, `import(...)` and
`require(...)`, deduplicated, first 40 per pattern.

The Rust writes `(?-u:\b)` to force an ASCII word boundary. cl-ppcre has no
`(?-u:` flag group - it rejects it outright - but it does not need one: its `\\b`
is ASCII-only already. Dropping the flag is therefore a faithful translation, not
a relaxation.

The whitespace class is written with LITERAL characters rather than `\\u{b}`
escapes, because a Lisp string reader does not interpret `\\u` - the escape
survives as text and corrupts the class."
  (let ((ws (format nil "[~a~a~a~a~a~a]"
                     #\Space #\Tab #\Newline (code-char 11) (code-char 12) #\Return))
        (quote-chars (format nil "[\"'~a]" (code-char 96)))
        (not-quote (format nil "[^\"'~a]" (code-char 96)))
        (imports '()))
    (flet ((collect (scanner)
             (cl-ppcre:do-register-groups (spec) (scanner content)
               (when (< (length imports) 40)
                 (push spec imports)))))
      (collect (cl-ppcre:create-scanner
                (format nil "\\bimport~a*(?:[^\"'~a]*?from~a*)?~a(~a+)~a"
                        ws (code-char 96) ws quote-chars not-quote quote-chars)))
      (collect (cl-ppcre:create-scanner
                (format nil "\\bimport~a*\\(~a*~a(~a+)~a~a*\\)"
                        ws ws quote-chars not-quote quote-chars ws)))
      (collect (cl-ppcre:create-scanner
                (format nil "\\brequire~a*\\(~a*~a(~a+)~a~a*\\)"
                        ws ws quote-chars not-quote quote-chars ws))))
    (unique-strings (nreverse imports))))

;;; ---------------------------------------------------------------------------
;;; keys-len
;;;
;;; `Object.keys(value).length`, which the panel's guards use as one presence
;;; rule for three different shapes. It lives here because paths.rs needs it and
;;; assets.rs owns it.
;;; ---------------------------------------------------------------------------

(defun keys-len (value)
  "`Object.keys(value).length`: arrays and strings report their LENGTH, objects
their own-key count, everything else zero.

The string case is the one that matters: a non-empty STRING has non-zero
`keys_len`, so a slice holding `\"x\"` counts as present. The writer and the
artifact index used to test presence differently - the writer counted keys, the
index demanded an object or an array - so a string slice was written to the
archive and left out of the index pointing at it. One rule, here, is the fix."
  (cond
    ((hash-table-p value) (hash-table-count value))
    ((vectorp value) (length value))
    ((stringp value) (length value))
    (t 0)))

;;; ---------------------------------------------------------------------------
;;; Field accessors
;;;
;;; The JS pattern `entry[key]` appears in every panel module, so the coercion
;;; rules live in one place rather than per call site.
;;; ---------------------------------------------------------------------------

(defun field (entry key)
  "`entry[key]`, or NIL when the key is absent OR its value is JS-FALSY.

The Rust is `entry.get(key).filter(|v| js_truthy(v))` - a PRESENCE test that is
really a TRUTHINESS test. So a stored `0`, `\"\"`, `false`, or `null` all read as
absent. This matters wherever a field's presence drives a bonus or a branch: a
runtime with `timestamp: 0` must NOT earn the timestamp bonus, and a `transferSize`
of 0 must fall through to `encodedBodySize`.

Getting this wrong is invisible in the common case, because `field-str` answers
\"\" for both absent and falsy and `field-number` answers 0 for both. It only shows
up where someone writes `(when (field entry key) ...)` - which is precisely the
Rust's `if let Some(...)` pattern."
  (when (hash-table-p entry)
    (multiple-value-bind (value present) (gethash key entry)
      (when (and present (vovas.engine.panel.model:js-truthy value))
        value))))

(defun field-str (entry key)
  "`fieldStr`: a STRING for a string or number field, empty otherwise.

A number renders through the JS number formatting, so `5` becomes \"5\" and not
\"5.0\" - and an object or array becomes EMPTY, not \"[object Object]\", because
this is the accessor used where a reference must be text."
  (let ((value (field entry key)))
    (cond
      ((null value) "")
      ((stringp value) value)
      ((numberp value) (vovas.engine.number:to-string (coerce value 'double-float)))
      (t ""))))

(defun field-number (entry key)
  "`fieldNumber`: the field coerced by `Number(...)`, or 0 when absent."
  (let ((value (field entry key)))
    (if (null value) 0d0 (vovas.engine.panel.model:js-number value))))


;;; ===========================================================================
;;; SLICE 2: the pipeline tier
;;;
;;; `prepare-script-assets` and the runtime-origin builders. These define the
;;; `ScriptAsset` record that boundary, graph, artifacts and report all consume,
;;; which is why this slice had to land before any of them.
;;; ===========================================================================

(defstruct (module-signals (:constructor make-module-signals
                               (&key (import-count 0) (dynamic-imports 0)
                                     (requires 0) (exports 0))))
  (import-count 0 :type integer)
  (dynamic-imports 0 :type integer)
  (requires 0 :type integer)
  (exports 0 :type integer))

(defstruct (script-asset (:constructor %make-script-asset))
  (id "") (url "") (file "")
  (size 0 :type integer)
  (transfer-size 0d0 :type double-float)
  (start-time 0d0 :type double-float)
  (duration 0d0 :type double-float)
  (imports '())
  (module-signals (make-module-signals))
  (bundler "unknown")
  (framework-hints '())
  (route-hints '())
  (startup-signals '())
  (source-map-embedded nil)
  (content "")
  (classification "app")
  (score 0d0 :type double-float)
  ;; the four boundary fields keep the JS assignment order - details first -
  ;; because these records serialize straight into the exported analysis
  (boundary-details '())
  (boundary-labels '())
  (primary-boundary "")
  (boundary-reasons '()))

(defstruct (boundary-detail (:constructor make-boundary-detail (label score reasons)))
  (label "" ) (score 0d0 :type double-float) (reasons '()))

;;; ---------------------------------------------------------------------------
;;; The patterns prepare-script-assets counts
;;; ---------------------------------------------------------------------------

;;; NOTE ON BACKSLASHES: `format` copies `~a` substitutions verbatim and does not
;;; touch backslashes, so a regex escape needs exactly TWO backslashes in the
;;; Lisp source (`\\W` -> the two chars `\W`). Writing four produced `\\W`, a
;;; literal backslash followed by `W`, which is why the require scanner failed to
;;; balance its parens.
;;;
;;; `\\b` stands in for the Rust's `(?-u:\\b)`: cl-ppcre rejects the flag group,
;;; but its own `\\b` is already ASCII-only, so the translation is exact.

(defparameter *dyn-import-re*
  (cl-ppcre:create-scanner
   (format nil "\\bimport[~a]*\\(" *js-s-chars*)))
(defparameter *require-re*
  (cl-ppcre:create-scanner
   (format nil "\\brequire[~a]*\\([~a]*[\"'~a]" *js-s-chars* *js-s-chars* (code-char 96))))
(defparameter *export-re*
  (cl-ppcre:create-scanner
   (format nil "\\bexport[~a]+(?:default|const|function|class|\\{)" *js-s-chars*)))
(defparameter *source-map-re*
  (cl-ppcre:create-scanner
   (format nil "sourceMappingURL[~a]*=[~a]*data:" *js-s-chars* *js-s-chars*)
   :case-insensitive-mode t))

(defun count-matches (text scanner)
  "`countMatches`: how many times SCANNER matches."
  (let ((n 0))
    (cl-ppcre:do-scans (s e rs re scanner text)
      (declare (ignore rs re))
      (when (and s e) (incf n)))
    n))

;;; ---------------------------------------------------------------------------
;;; scoreScriptAsset
;;; ---------------------------------------------------------------------------

(defun score-script-asset (entry)
  "`scoreScriptAsset`. Note the `.min` guards: the module-signal bonus caps at 12
and the transfer-size bonus at 12, so a huge bundle cannot dominate the score."
  (let ((score (cond ((string= (script-asset-classification entry) "app") 48d0)
                     ((string= (script-asset-classification entry) "runtime") 34d0)
                     ((string= (script-asset-classification entry) "framework") 24d0)
                     (t 18d0))))
    (incf score (* (length (script-asset-startup-signals entry)) 7d0))
    (incf score (* (length (script-asset-route-hints entry)) 4d0))
    (incf score (min 12d0
                     (+ (* (module-signals-dynamic-imports
                            (script-asset-module-signals entry)) 2d0)
                        (module-signals-import-count
                         (script-asset-module-signals entry)))))
    (when (script-asset-source-map-embedded entry) (incf score 6d0))
    (let ((ts (script-asset-transfer-size entry)))
      (when (/= ts 0d0)
        (incf score (min 12d0 (round (/ ts 50000d0))))))
    score))

;;; ---------------------------------------------------------------------------
;;; Timing lookup
;;; ---------------------------------------------------------------------------

(defun build-timing-lookup (timings)
  "`buildTimingLookup`: full URL and query-stripped URL, FIRST writer wins.

Two keys per entry because a resource URL and its timing name can differ in the
query string. `first writer wins` is why this cannot be a plain alist push - a
later entry must not overwrite an earlier one for the same key."
  (let ((lookup '()))
    (flet ((put (key item)
             (unless (assoc key lookup :test #'string=)
               (push (cons key item) lookup))))
      (dolist (item timings)
        (let ((name (field-str item "name")))
          (unless (zerop (length name))
            (put (normalize-url-key name) item)
            (put (strip-url-variant name) item)))))
    lookup))

;;; ---------------------------------------------------------------------------
;;; prepareScriptAssets
;;; ---------------------------------------------------------------------------

(defun prepare-script-assets (inputs &optional recon)
  "`prepareScriptAssets`: every raw script input as a `script-asset`.

A missing or empty url becomes `inline/script-N.js`, and NON-STRING content is
treated as empty - byte content reaches the pipeline as a Bytes asset instead, so
a non-string here means the caller gave something the text path cannot use.

The scan text is capped at 200,000 UTF-16 units while `content` keeps the whole
thing: the detectors must not be handed a multi-megabyte file, but the export
still needs the bytes."
  (let* ((timings (let ((v (field recon "timings")))
                    (if (vectorp v) (coerce v 'list) '())))
         (lookup (build-timing-lookup timings))
         (stack-profile (let ((v (field recon "stackProfile")))
                          (if (vovas.engine.panel.model:js-truthy v) v nil)))
         (assets '())
         (index 0))
    (dolist (item inputs)
      (let* ((raw-url (field-str item "url"))
             (url (if (zerop (length raw-url))
                      (format nil "inline/script-~a.js" (1+ index))
                      raw-url))
             (raw-content (field item "content"))
             (content (if (stringp raw-content) raw-content ""))
             (scan-text (if (> (vovas.engine.util:utf16-length content) 200000)
                            (vovas.engine.util:utf16-prefix content 200000)
                            content))
             (timing (or (cdr (assoc (normalize-url-key url) lookup :test #'string=))
                         (cdr (assoc (strip-url-variant url) lookup :test #'string=))))
             (imports (extract-import-specifiers scan-text))
             (signals (make-module-signals
                       :import-count (length imports)
                       :dynamic-imports (count-matches scan-text *dyn-import-re*)
                       :requires (count-matches scan-text *require-re*)
                       :exports (count-matches scan-text *export-re*)))
             (bundler (detect-bundler-name url scan-text))
             (framework (detect-framework-hints url scan-text stack-profile))
             (routes (extract-route-hints-from-url url))
             (startup (detect-startup-signals url scan-text))
             (classification (classify-script-asset url scan-text bundler framework startup))
             (bare (let ((b (get-bare-file-name url)))
                     (if (zerop (length b)) (format nil "script-~a" (1+ index)) b)))
             (digest (vovas.engine.text:hash-string url))
             (asset (%make-script-asset
                     :id (format nil "chunk-~a-~a"
                                 (vovas.engine.text:sanitize-path-part bare "script")
                                 (subseq digest 0 (min 8 (length digest))))
                     :url url
                     :file (vovas.engine.text:sanitize-filename url)
                     :size (vovas.engine.util:utf16-length content)
                     :transfer-size (if timing
                                        (let ((v (field timing "transferSize")))
                                          (if (vovas.engine.panel.model:js-truthy v)
                                              (vovas.engine.panel.model:js-number v)
                                              0d0))
                                        0d0)
                     ;; startTime and duration are read as NUMBERS ONLY - a string
                     ;; that looks numeric is not coerced here, unlike transferSize.
                     :start-time (if timing
                                     (let ((v (field timing "startTime")))
                                       (if (numberp v) (coerce v 'double-float) 0d0))
                                     0d0)
                     :duration (if timing
                                   (let ((v (field timing "duration")))
                                     (if (numberp v) (coerce v 'double-float) 0d0))
                                   0d0)
                     :imports imports
                     :module-signals signals
                     :bundler bundler
                     :framework-hints framework
                     :route-hints routes
                     :startup-signals startup
                     :source-map-embedded (and (cl-ppcre:scan *source-map-re* scan-text) t)
                     :content content
                     :classification classification
                     :score 0d0)))
        (setf (script-asset-score asset) (score-script-asset asset))
        (push asset assets)
        (incf index)))
    (nreverse assets)))

;;; ---------------------------------------------------------------------------
;;; assetsFromInputs
;;; ---------------------------------------------------------------------------

(defun byte-values (value)
  "`byteValues`: the bytes of a binary script input, or NIL when it is not one.

The panel holds a `Uint8Array`, and `JSON.stringify` turns that into an OBJECT
keyed by decimal index, while a plain array of numbers arrives as an ARRAY. Both
shapes mean the same bytes, so both are accepted.

An EMPTY container is `None`, not an empty vector - which is what makes
`assets-from-inputs` fall through to an empty TEXT asset instead of a zero-length
bytes asset. The index keys of the object shape are sorted NUMERICALLY: a string
sort would put \"10\" before \"9\" and silently reorder the bytes."
  (let ((values
          (cond
            ((vectorp value) (coerce value 'list))
            ((hash-table-p value)
             (let ((keyed '()))
               (maphash (lambda (key item)
                          (let ((index (ignore-errors (parse-integer key))))
                            (when index (push (cons index item) keyed))))
                        value)
               (mapcar #'cdr (sort keyed #'< :key #'car))))
            (t nil))))
    (when values
      (map '(vector (unsigned-byte 8))
           (lambda (item)
             (let ((number (vovas.engine.panel.model:js-number item)))
               (if (and (numberp number) (<= 0 number))
                   (mod (truncate number) 256)
                   0)))
           values))))

(defun assets-from-inputs (inputs)
  "`assetsFromInputs`: raw script inputs as pipeline assets.

A STRING content is a text asset holding it verbatim. Anything else is offered to
`byte-values`; when that answers, the asset is bytes, and when it does not the
asset is text with EMPTY content - a shape the text path can still carry, which is
why this never drops an input.

`vovas.engine.pipeline` loads AFTER this file, so the Asset constructors are
resolved SYMBOLICALLY here rather than imported at package level: a package-level
import would be read before `pipeline.lisp` ever runs its `defpackage`, and the
reader would fail on a package that does not exist yet. The symbols resolve to
functions at call time, which is when pipeline is loaded. Only `export.rs` (not
yet ported) and this function's own tests ever reach this path."
  (flet ((text-asset (url content)
           (funcall (find-symbol "MAKE-TEXT-ASSET" :vovas.engine.pipeline)
                    url content))
         (bytes-asset (url bytes)
           (funcall (find-symbol "MAKE-BYTES-ASSET" :vovas.engine.pipeline)
                    url bytes)))
    (mapcar (lambda (input)
              (let ((url (or (field-str input "url") ""))
                    (content (field input "content")))
                (if (stringp content)
                    (text-asset url content)
                    (let ((bytes (byte-values content)))
                      (if bytes
                          (bytes-asset url bytes)
                          (text-asset url ""))))))
            inputs)))

;;; ---------------------------------------------------------------------------
;;; classifyScriptAsset
;;; ---------------------------------------------------------------------------

(defparameter *classify-runtime* (cl-ppcre:create-scanner "runtime|manifest|polyfill|bootstrap"))
(defparameter *classify-vendor* (cl-ppcre:create-scanner "vendor|node_modules|chunk-vendors"))
(defparameter *classify-framework*
  (cl-ppcre:create-scanner "react|vue|angular|next|nuxt|svelte|astro|remix"
                           :case-insensitive-mode t))

(defun classify-script-asset (url content bundler framework-hints startup-signals)
  "`classifyScriptAsset`. Order matters: a chunk-loader signal beats a vendor name,
`runtime` beats everything. The final `else` and the hydration branch both answer
\"app\", so the hydration test only decides between two spellings of the same
answer - preserved because the JS wrote it that way."
  (let ((sample (asset-sample url content))
        (has (lambda (name) (member name startup-signals :test #'string=))))
    (cond
      ((or (cl-ppcre:scan *classify-runtime* sample) (funcall has "chunk-loader"))
       "runtime")
      ((cl-ppcre:scan *classify-vendor* sample) "vendor")
      ((and framework-hints
            (cl-ppcre:scan *classify-framework*
                           (format nil "~{~a~^ ~}" framework-hints)))
       "framework")
      ((and (not (string= bundler "unknown")) (funcall has "hydration")) "app")
      (t "app"))))


;;; ---------------------------------------------------------------------------
;;; The counting helpers
;;; ---------------------------------------------------------------------------

(defun count-classifications (items)
  "`countClassifications`: classification counts, empty -> \"unknown\"."
  (let ((c (make-counts)))
    (dolist (item items)
      (let ((v (script-asset-classification item)))
        (counts-add c (if (zerop (length v)) "unknown" v))))
    c))

(defun count-boundary-labels (items)
  "`countBoundaryLabels`: every label on every item."
  (let ((c (make-counts)))
    (dolist (item items)
      (dolist (label (script-asset-boundary-labels item))
        (counts-add c label)))
    c))

(defun count-tagged-entries (items)
  "`countTaggedEntries`: items carrying at least one boundary label."
  (count-if (lambda (item) (script-asset-boundary-labels item)) items))

(defun build-chunk-summary (assets)
  "`buildChunkSummary`. `bundlersObserved` drops the literal \"unknown\", so a set
of assets with no bundler marker reports an EMPTY list rather than [\"unknown\"]."
  (let ((bundlers '())
        (sm 0)
        (dyn 0))
    (dolist (a assets)
      (let ((b (script-asset-bundler a)))
        (unless (member b bundlers :test #'string=)
          (push b bundlers)))
      (when (script-asset-source-map-embedded a) (incf sm))
      (when (plusp (module-signals-dynamic-imports (script-asset-module-signals a)))
        (incf dyn)))
    (list :total-scripts (length assets)
          :bundlers-observed (remove "unknown" (nreverse bundlers) :test #'string=)
          :classifications (counts-json (count-classifications assets))
          :boundary-labels (counts-json (count-boundary-labels assets))
          :source-map-embedded sm
          :dynamic-importers dyn
          :labeled-scripts (count-tagged-entries assets))))

(defun module-signals-plist (ms)
  (list :import-count (module-signals-import-count ms)
        :dynamic-imports (module-signals-dynamic-imports ms)
        :requires (module-signals-requires ms)
        :exports (module-signals-exports ms)))

(defun boundary-detail-plist (d)
  (list :label (boundary-detail-label d)
        :score (boundary-detail-score d)
        :reasons (boundary-detail-reasons d)))

(defun strip-chunk-asset (asset)
  "`stripChunkAsset`: the 19-key view the analysis embeds.

`content` is NOT included - that is the point of `strip`: the chunk map carries
metadata, and the source text lives in the archive."
  (list :id (script-asset-id asset)
        :url (script-asset-url asset)
        :file (script-asset-file asset)
        :size (script-asset-size asset)
        :transfer-size (script-asset-transfer-size asset)
        :start-time (script-asset-start-time asset)
        :duration (script-asset-duration asset)
        :classification (script-asset-classification asset)
        :bundler (script-asset-bundler asset)
        :framework-hints (script-asset-framework-hints asset)
        :route-hints (script-asset-route-hints asset)
        :startup-signals (script-asset-startup-signals asset)
        :boundary-labels (script-asset-boundary-labels asset)
        :primary-boundary (script-asset-primary-boundary asset)
        :boundary-reasons (script-asset-boundary-reasons asset)
        :imports (script-asset-imports asset)
        :module-signals (module-signals-plist (script-asset-module-signals asset))
        :source-map-embedded (script-asset-source-map-embedded asset)
        :score (script-asset-score asset)))

;;; ---------------------------------------------------------------------------
;;; Runtime origins
;;; ---------------------------------------------------------------------------

(defun find-asset-by-reference (reference assets)
  "`findAssetByReference`: match a stack reference against every asset.

Four comparisons in order, ANY of which is a match: exact url, fragment-stripped,
query-and-fragment-stripped, and bare file name. The last is deliberately loose -
a stack trace often carries only the file name - so this can match an asset whose
URL merely shares a basename."
  (let ((cleaned (clean-stack-reference reference)))
    (when (zerop (length cleaned))
      (return-from find-asset-by-reference nil))
    (let ((full (normalize-url-key cleaned))
          (bare (strip-url-variant cleaned))
          (file (get-bare-file-name cleaned)))
      (find-if (lambda (a)
                 (or (string= (script-asset-url a) cleaned)
                     (string= (normalize-url-key (script-asset-url a)) full)
                     (string= (strip-url-variant (script-asset-url a)) bare)
                     (string= (get-bare-file-name (script-asset-url a)) file)))
               assets))))

(defun value-text (value)
  "`valueText`: `String(value)` for a reference, empty for null."
  (cond
    ((null value) "")
    ((vovas.engine.panel.model:json-null-p value) "")
    ((stringp value) value)
    ((numberp value) (vovas.engine.number:to-string (coerce value 'double-float)))
    (t "")))

(defun determine-runtime-origin-type (entry)
  "`determineRuntimeOriginType`. The order is the contract: a blob-derived entry
wins over its kind, and a bundle-linked entry wins over its URL scheme."
  (when (field entry "blobId")
    (return-from determine-runtime-origin-type "blob-derived"))
  (let ((kind (field-str entry "kind")))
    (cond
      ((string= kind "script-injection")
       (return-from determine-runtime-origin-type "inline-script"))
      ((member kind '("worker" "shared-worker" "service-worker") :test #'string=)
       (return-from determine-runtime-origin-type "worker-bootstrap"))
      ((string= kind "wasm")
       (return-from determine-runtime-origin-type "wasm-module"))))
  (let ((chunks (field entry "relatedChunks")))
    (when (and chunks (vectorp chunks) (plusp (length chunks)))
      (return-from determine-runtime-origin-type "bundle-linked")))
  (let ((url (string-downcase (field-str entry "url"))))
    (when (and (plusp (length url)) (<= 5 (length url)) (string= "blob:" (subseq url 0 5)))
      (return-from determine-runtime-origin-type "object-url"))
    (when (and (plusp (length url)) (<= 5 (length url)) (string= "data:" (subseq url 0 5)))
      (return-from determine-runtime-origin-type "data-url")))
  "runtime-generated")

(defun score-runtime-entry (entry)
  "`scoreRuntimeEntry`: a kind base plus four additive bonuses."
  (let* ((kind (field-str entry "kind"))
         (score (cond ((member kind '("eval" "function") :test #'string=) 46d0)
                      ((string= kind "wasm") 42d0)
                      ((string= kind "script-injection") 38d0)
                      (t 28d0))))
    (let ((chunks (field entry "relatedChunks")))
      (when (and chunks (vectorp chunks) (plusp (length chunks)))
        (incf score (* (length chunks) 8d0))))
    (when (field entry "blobId") (incf score 10d0))
    (when (stringp (field entry "text")) (incf score 6d0))
    (when (field entry "timestamp") (incf score 4d0))
    score))

(defun build-runtime-origins (entries manifest assets)
  "`buildRuntimeOrigins`: the manifest entry merged with the collected record,
then annotated with stack refs, related chunks, an origin type and a score.

The manifest is merged FIRST and the entry SECOND, so the entry's own keys win -
that is `for key in manifest { merged[key] = v }` then the same for the source."
  (let ((by-id (make-hash-table :test #'equal))
        (origins '()))
    ;; A BTreeMap in the Rust: a duplicate id means the LAST manifest entry wins,
    ;; so this is a plain overwrite, not first-wins.
    (dolist (item manifest)
      (let ((id (field-str item "id")))
        (unless (zerop (length id))
          (setf (gethash id by-id) item))))
    (dolist (source entries)
      (let* ((id (field-str source "id"))
             (manifest-item (gethash id by-id))
             (merged (make-hash-table :test #'equal)))
        (when (hash-table-p manifest-item)
          (maphash (lambda (k v) (setf (gethash k merged) v)) manifest-item))
        (when (hash-table-p source)
          (maphash (lambda (k v) (setf (gethash k merged) v)) source))
        (let* ((stack (field-str merged "stack"))
               (stack-refs (extract-stack-refs stack))
               (direct (let ((u (field merged "url")))
                         (if u u (gethash "objectUrl" merged))))
               (related '()))
          (let ((asset (find-asset-by-reference (value-text direct) assets)))
            (when asset (push (script-asset-id asset) related)))
          (dolist (ref stack-refs)
            (let ((asset (find-asset-by-reference ref assets)))
              (when asset (push (script-asset-id asset) related))))
          (setf related (unique-strings (nreverse related)))
          (setf (gethash "stackRefs" merged) (coerce stack-refs 'vector)
                (gethash "relatedChunks" merged) (coerce related 'vector))
          (setf (gethash "originType" merged)
                (determine-runtime-origin-type merged)
                (gethash "score" merged)
                (score-runtime-entry merged))
          (push merged origins))))
    (nreverse origins)))


(defun count-origin-property (origins key)
  "`countOriginProperty`: counts KEY across origins, empty -> \"unknown\"."
  (let ((c (make-counts)))
    (dolist (o origins)
      (let ((v (field-str o key)))
        (counts-add c (if (zerop (length v)) "unknown" v))))
    c))

(defun build-runtime-summary (origins)
  "`buildRuntimeSummary`.

The boundary-label counter is a Counts, not a sorted map - `PORTING.md` records the
alphabetical BTreeMap as a bug that was fixed everywhere else and MISSED here, and
the analysis files serialize key order."
  (let ((linked 0) (labeled 0) (labels (make-counts)))
    (dolist (o origins)
      (let ((chunks (gethash "relatedChunks" o)))
        (when (and chunks (vectorp chunks) (plusp (length chunks))) (incf linked)))
      (let ((bl (gethash "boundaryLabels" o)))
        (when (and bl (vectorp bl) (plusp (length bl))) (incf labeled))
        (when (vectorp bl)
          (loop for label across bl
                when (stringp label)
                  do (counts-add labels label)))))
    (list :total-runtime-entries (length origins)
          :kinds (counts-json (count-origin-property origins "kind"))
          :origin-types (counts-json (count-origin-property origins "originType"))
          :boundary-labels (counts-json labels)
          :linked-to-chunks linked
          :labeled-entries labeled)))

(defun strip-runtime-entry (entry)
  "`stripRuntimeEntry`: the 16-key view the analysis embeds.

`text` is deliberately absent, so the runtime record carries a score and a note but
not the captured code itself - that lives in the archive."
  (let ((blob (field entry "blobId"))
        (related (gethash "relatedChunks" entry))
        (refs (gethash "stackRefs" entry)))
    (list :id (let ((v (gethash "id" entry))) (if v v nil))
          :kind (let ((v (gethash "kind" entry))) (if v v nil))
          :file (field-str entry "file")
          :source (field-str entry "source")
          :url (field-str entry "url")
          :object-url (field-str entry "objectUrl")
          :blob-id (if blob blob nil)
          :origin-type (let ((v (gethash "originType" entry))) (if v v nil))
          :related-chunks (if (vectorp related) related #())
          :stack-refs (if (vectorp refs) refs #())
          :timestamp (field-number entry "timestamp")
          :mime-type (field-str entry "mimeType")
          :size (field-number entry "size")
          :truncated (and (vovas.engine.panel.model:js-truthy
                           (gethash "truncated" entry)) t)
          :note (field-str entry "note")
          :score (field-number entry "score"))))
