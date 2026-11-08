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

`stack-profile` is an optional plist whose `:technologies` is a list of plists with
a `:name`; only non-empty names are added. The cap is applied AFTER
deduplication, so a duplicate early does not cost a later distinct hint its slot."
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
    (let ((hints (nreverse hints)))
      (when stack-profile
        (dolist (tech (getf stack-profile :technologies))
          (let ((name (and (listp tech) (getf tech :name))))
            (when (and name (stringp name) (plusp (length name)))
              (push name hints)))))
      (let ((uniq (unique-strings hints)))
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

(defparameter *js-s-chars* " \t\n\u{b}\u{c}\r"
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
  "`entry[key]`, or NIL when ENTRY is not an object or the key is absent.

NIL and JSON null are both "absent" here, which matches the Rust: it matches on
`Some(value)` only, so an explicit null falls to the same branch as a missing key."
  (when (hash-table-p entry)
    (multiple-value-bind (value present) (gethash key entry)
      (when present
        (if (vovas.engine.panel.model:json-null-p value) nil value)))))

(defun field-str (entry key)
  "`fieldStr`: a STRING for a string or number field, empty otherwise.

A number renders through the JS number formatting, so `5` becomes "5" and not
"5.0" - and an object or array becomes EMPTY, not "[object Object]", because
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
