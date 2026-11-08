;;;; gate-pipeline.lisp — the pipeline's gate.
;;;;
;;;; FOUR oracles, because the pipeline has four entry points and one fixture
;;;; cannot reach them all:
;;;;
;;;;   pipeline-oracle.json          `unpackAsset` over 13 TEXT assets
;;;;   pipeline-binary-oracle.json   `unpackAsset` over 8 BINARY assets, from
;;;;                                 the crate's own .jsc/.bin/.wasm fixtures
;;;;   pipeline-batch-oracle.json    `unpackAssets` (text and bytes, the latter
;;;;                                 exercising shared-table discovery) and
;;;;                                 `unpackAssetsForZip` (the archive seam)
;;;;   pipeline-budget-oracle.json   the two over-budget refusals and the
;;;;                                 exactly-at-budget non-refusal
;;;;
;;;; WHY I CAPTURED THE LAST THREE. `pipeline-oracle.json` was captured before
;;;; this port started and covers the text ladder only. The binary ladder, the
;;;; batch (where the shared JSC table is discovered), the zip seam and the
;;;; budget guard are all reachable from the shipped engine, so leaving them
;;;; "structural" would have been a choice rather than a constraint. They are
;;;; captured by `unpack-rs/scripts/pipeline-oracle-extra.mjs` from the same
;;;; `.cache/engine.wasm` the original fixture came from.
;;;;
;;;; WHAT IS STILL STRUCTURAL, stated plainly so no count implies coverage:
;;;;
;;;;   - `unpackAssetsForZip` is NOT exported from `src/js/unpack-bridge.js`
;;;;     (verified: the export list has `unpackAsset`, `unpackAssets` and NOT
;;;;     `unpackAssetsForZip`). So IT CANNOT BE CAPTURED. Its shape is ported
;;;;     from the Rust and pinned structurally: the report is the batch report
;;;;     plus `root` and `unpackedAt`, `index.json` is the last file written,
;;;;     and the clock is a parameter so the stamp is deterministic.
;;;;     Everything it WRITES is the batch's output, which IS oracle-pinned -
;;;;     so the unpinned part is exactly the two stamped fields and the path.
;;;;   - `emit-double` (a refusal's `density`/`purity`). No captured case has a
;;;;     non-empty refusal list, so the float path is unreachable from every
;;;;     fixture. Not counted below.
;;;;   - `build-zip` is a one-line delegation to `vovas.engine.zip:build-zip`,
;;;;     which `gate-zip.lisp` round-trip gates. A thin identity function
;;;;     pinned by a second suite would be theatre; it is proven reachable
;;;;     instead (a probe below shows it answers the same bytes as the callee).
;;;;
;;;; KEY ORDER. The JSON entries are compared after a parse, so key order is
;;;; NOT visible there - except that it is: `raw/index.json` is compared
;;;; BYTE-FOR-BYTE, and it contains all five batch entries with every key. The
;;;; same is true of `functions.json` and `wasm-info.json`, which are
;;;; `pretty-json` output compared as strings. So the writer's key order and
;;;; indentation are oracle-pinned by the artifacts, not by trust.

(in-package :vovas.engine.gate)

;;; ---------------------------------------------------------------------------
;;; Small helpers
;;; ---------------------------------------------------------------------------

(defun pipeline-options (opts-json)
  "The oracle's options object as the port's `UnpackOptions`.

`zipPath` is deliberately NOT read from here. Measured: `serializeOptions` in
unpack-bridge.js never forwards `zipPath`, and `HostOptions::into_native` hard-
codes `zip_path: String::new()`. So an OPTION-level zipPath cannot reach the
engine, and the `zipPath` oracle case answers `\"\"` even though it passes
`{zipPath: 'site/sources.zip'}`. The asset-level zipPath is the one that lands,
and the batch oracle proves it. A port that read `opts.zipPath` would answer
`site/sources.zip` and be WRONG about the shipped engine."
  (vovas.engine.pipeline:make-unpack-options
   :index (json-null (gethash "index" opts-json))
   :max-depth (json-null (gethash "maxDepth" opts-json))
   :max-modules (json-null (gethash "maxModules" opts-json))
   :max-beautify-bytes (json-null (gethash "maxBeautifyBytes" opts-json))
   :path-prefix (or (json-null (gethash "pathPrefix" opts-json)) "_unpack")))

(defun canonical-json (value)
  "VALUE normalised so a parsed oracle and a parsed port answer compare.

Hash tables sort by key because the oracle's own key order is not the artifact
(the FILE BYTES are, and those are compared separately); vectors stay vectors.
JZON's null symbol becomes `:null` so it cannot be confused with NIL."
  (cond
    ((and (symbolp value) (string= (symbol-name value) "NULL")) :null)
    ((hash-table-p value)
     (sort (loop for key being the hash-keys of value using (hash-value item)
                 collect (cons key (canonical-json item)))
           #'string< :key #'car))
    ((vectorp value) (loop for item across value collect (canonical-json item)))
    (t value)))

(defun parse-json-text (text)
  "Parse TEXT with `*read-default-float-format*` bound, returning the canonical
form. The binding is the CONTRACT's rule 6: JZON reads numbers from their text,
and a 1.79e308 in a fixture overflows as a single float."
  (let ((*read-default-float-format* 'double-float))
    (canonical-json (com.inuoe.jzon:parse text))))

(defun entry-of (result)
  (vovas.engine.pipeline:asset-result-entry result))

(defun files-of (result)
  (vovas.engine.pipeline:asset-result-files result))

(defun compare-files (result label files want-array)
  "Check FILES path-for-path and byte-for-byte against WANT-ARRAY."
  (check result (format nil "~a/files-count" label)
         (length files) (length files) (length want-array))
  (loop for file in files
        for i from 0
        for want-file = (and (< i (length want-array)) (aref want-array i))
        do (check result (format nil "~a/file~a/path" label i)
                  i
                  (vovas.engine.pipeline:file-path file)
                  (and want-file (gethash "path" want-file)))
           (check result (format nil "~a/file~a/content" label i)
                  (vovas.engine.pipeline:file-path file)
                  (vovas.engine.pipeline:file-content file)
                  (and want-file (gethash "content" want-file)))))

(defun compare-entry (result label got-entry want-entry)
  "An entry compared as JSON, so a missing key, an extra key, a `false` where
the oracle has `null` and a wrong number all fail.

The port's entry is rendered through the REAL `pretty-json` and re-parsed
rather than compared as a plist: the serialisation is half the contract, and
this way a writer bug (a `:false` rendered as `null`, a key dropped for being
NIL) fails HERE as well as in the byte-compared artifacts."
  (check result label
         (or (gethash "url" want-entry) "<entry>")
         (parse-json-text (vovas.engine.pipeline:pretty-json
                           (vovas.engine.pipeline:entry-json got-entry)))
         (canonical-json want-entry)))

;;; ---------------------------------------------------------------------------
;;; Tier 1: unpackAsset over the 13 text cases
;;; ---------------------------------------------------------------------------

(defun gate-pipeline-text (result oracle)
  (let ((cases (gethash "cases" oracle))
        (count 0))
    (loop for name being the hash-keys of cases using (hash-value c)
          do (incf count)
             (let* ((url (gethash "url" c))
                    (content (or (json-null (gethash "content" c)) ""))
                    (asset (vovas.engine.pipeline:make-text-asset url content))
                    (got (vovas.engine.pipeline:unpack-asset
                          asset (pipeline-options (gethash "options" c))))
                    (want (gethash "result" c)))
               (compare-entry result (format nil "unpackAsset/~a" name)
                              (entry-of got) (gethash "entry" want))
               (compare-files result (format nil "unpackAsset/~a" name)
                              (files-of got) (gethash "files" want))))
    count))

;;; ---------------------------------------------------------------------------
;;; Tier 2: unpackAsset over the binary ladder
;;; ---------------------------------------------------------------------------

(defun gate-pipeline-binary (result oracle)
  (let ((cases (gethash "cases" oracle))
        (count 0))
    (loop for name being the hash-keys of cases using (hash-value c)
          do (incf count)
             (let* ((bytes (if (gethash "fixture" c)
                               (binary-fixture-bytes (gethash "fixture" c))
                               (vovas.engine.decoders:decode-base64-to-bytes
                                (gethash "bytesB64" c))))
                    (asset (vovas.engine.pipeline:make-bytes-asset
                            (gethash "url" c) bytes))
                    (got (vovas.engine.pipeline:unpack-asset
                          asset (pipeline-options (gethash "options" c))))
                    (want (gethash "result" c)))
               (compare-entry result (format nil "binary/~a" name)
                              (entry-of got) (gethash "entry" want))
               (compare-files result (format nil "binary/~a" name)
                              (files-of got) (gethash "files" want))))
    count))

;;; ---------------------------------------------------------------------------
;;; Tier 3: the batch, the shared JSC table, and the archive seam
;;; ---------------------------------------------------------------------------

(defun batch-assets-from-oracle (oracle)
  (loop for a across (gethash "textAssets" oracle)
        collect (vovas.engine.pipeline:make-text-asset
                 (gethash "url" a)
                 (or (json-null (gethash "content" a)) "")
                 (json-null (gethash "zipPath" a)))))

(defun gate-pipeline-batch (result oracle)
  (let* ((assets (batch-assets-from-oracle oracle))
         (opts (pipeline-options (gethash "options" oracle)))
         (batch (vovas.engine.pipeline:unpack-assets assets opts))
         (want (gethash "unpackAssets" oracle)))
    ;; the report, entry by entry, through the real serialiser
    (check result "unpackAssets/report"
           "report"
           (parse-json-text (vovas.engine.pipeline:pretty-json
                             (vovas.engine.pipeline:report-json
                              (vovas.engine.pipeline:batch-result-report batch))))
           (canonical-json (gethash "report" want)))
    (compare-files result "unpackAssets"
                   (vovas.engine.pipeline:batch-result-files batch)
                   (gethash "files" want))
    ;; the asset-level zipPath really landing on the entry: an OPTION-level one
    ;; cannot (see `pipeline-options`), so this is the only place it is provable
    (check result "unpackAssets/asset-zipPath"
           "site/e.js"
           (vovas.engine.pipeline:entry-get
            (second (vovas.engine.pipeline:report-assets
                     (vovas.engine.pipeline:batch-result-report batch)))
            :zip-path)
           "site/e.js")
    1))

(defun gate-pipeline-batch-binary (result oracle)
  "The shared-table half of the batch: a loose JSC chunk plus the container's
string table, with nothing referencing the table. The oracle answers 15 real
names where the same chunk alone answers `<ordinal N>` placeholders - so this
pins the DISCOVERY, not merely that bytes were parsed."
  (let* ((names (gethash "binaryFixtures" oracle))
         (want (gethash "unpackAssetsBinary" oracle))
         ;; URLs come from the oracle's own report rather than being invented,
         ;; because the slug - and therefore every path - is derived from them
         (want-assets (gethash "assets" (gethash "report" want)))
         (assets (loop for name across names
                       for i from 0
                       for want-asset = (aref want-assets i)
                       collect (vovas.engine.pipeline:make-bytes-asset
                                (gethash "url" want-asset)
                                (binary-fixture-bytes name))))
         (batch (vovas.engine.pipeline:unpack-assets
                 assets (vovas.engine.pipeline:make-unpack-options))))
    (check result "unpackAssets(binary)/report"
           "report"
           (parse-json-text (vovas.engine.pipeline:pretty-json
                             (vovas.engine.pipeline:report-json
                              (vovas.engine.pipeline:batch-result-report batch))))
           (canonical-json (gethash "report" want)))
    (compare-files result "unpackAssets(binary)"
                   (vovas.engine.pipeline:batch-result-files batch)
                   (gethash "files" want))
    ;; non-vacuity for THIS tier: the table must actually have resolved names,
    ;; or a port that shared nothing would still match a table-less oracle
    (let* ((entry (first (vovas.engine.pipeline:report-assets
                          (vovas.engine.pipeline:batch-result-report batch))))
           (detail (getf (first (vovas.engine.pipeline:entry-get entry :stages))
                         :detail)))
      (check result "unpackAssets(binary)/table-resolved" "shared table"
             (and detail (search "names via shared table" detail) t)
             t))
    1))

(defun gate-pipeline-zip (result oracle)
  "The archive seam. `unpackAssetsForZip` is NOT exported from the bridge, so
this cannot be oracle-pinned. What IS pinned: every file the seam writes is the
batch's own output (already compared above), the report gains `root` and
`unpackedAt` and nothing else, the report lands LAST at `{prefix}/index.json`,
and the stamp is the parameterised clock. `unpackedAt` is the only field that
differs from the oracle's captured bytes, and it is compared by SUBSTITUTION so
the rest of `index.json` - including every entry and the totals - is byte-exact."
  (let* ((assets (batch-assets-from-oracle oracle))
         (opts (pipeline-options (gethash "options" oracle)))
         (written '())
         (want (gethash "unpackAssetsForZip" oracle))
         (sentinel (gethash "clockSentinel" oracle))
         (report (let ((vovas.engine.pipeline:*clock-seconds* 1794115350))
                   (vovas.engine.pipeline:unpack-assets-into
                    (lambda (path content)
                      (setf written (append written (list (cons path content)))))
                    assets opts))))
    ;; 1. the two stamped fields, read off the returned report
    (check result "zip/root" "report root"
           (vovas.engine.pipeline:report-root report)
           (gethash "root" (gethash "report" want)))
    (check result "zip/unpackedAt-well-formed" "report stamp"
           (and (vovas.engine.pipeline:report-unpacked-at report) t)
           t)
    (check result "zip/unpackedAt-value" "pinned clock"
           (vovas.engine.pipeline:report-unpacked-at report)
           "2026-11-08T05:22:30.000Z")
    ;; 2. every file, path and content; index.json compared against the oracle
    ;;    with the stamp substituted so the OTHER bytes must match exactly
    (let ((want-files (gethash "files" want)))
      (check result "zip/file-count" "files"
             (length written) (length want-files))
      (loop for (path . content) in written
            for i from 0
            for want-file = (and (< i (length want-files)) (aref want-files i))
            do (check result (format nil "zip/file~a/path" i) path
                      path (and want-file (gethash "path" want-file)))
               (check result (format nil "zip/file~a/content" i) path
                      (if (string= path (format nil "~a/index.json"
                                                (vovas.engine.pipeline:report-root report)))
                          (cl-ppcre:regex-replace
                           "\"unpackedAt\": \"[^\"]*\""
                           content
                           (format nil "\"unpackedAt\": \"~a\"" sentinel))
                          content)
                      (and want-file (gethash "content" want-file)))))
    ;; 3. the report lands LAST: `unpackAssetsInto` writes the artifacts first
    (check result "zip/report-last" "last path"
           (and written (car (car (last written))))
           (format nil "~a/index.json" (vovas.engine.pipeline:report-root report)))
    1))

;;; ---------------------------------------------------------------------------
;;; Tier 4: the budget guard, from RECIPES rather than stored payloads
;;; ---------------------------------------------------------------------------

(defun expand-budget-recipe (case)
  "The asset a budget case describes. The fixture stores filler+count because a
9 MiB payload in JSON would dominate every gate run for one branch, and the
captured `bytes`/`digest` still pin the whole path: the digest is over the exact
reconstructed text."
  (let* ((recipe (gethash "recipe" case))
         (count (gethash "count" recipe))
         ;; `json-null` FIRST: JZON parses JSON null to a non-NIL symbol, so
         ;; `(gethash "fillByte" recipe)` is truthy for a TEXT recipe and the
         ;; byte branch would be taken with a NIL fill value.
         (fill-byte (json-null (gethash "fillByte" recipe))))
    (if fill-byte
        (vovas.engine.pipeline:make-bytes-asset
         (gethash "url" case)
         (let ((vector (make-array count :element-type '(unsigned-byte 8))))
           (fill vector fill-byte)
           vector))
        (vovas.engine.pipeline:make-text-asset
         (gethash "url" case)
         (concatenate 'string
                      (gethash "prefix" recipe)
                      (make-string count :initial-element
                                   (character (gethash "filler" recipe)))
                      (gethash "suffix" recipe))))))

(defun gate-pipeline-budget (result oracle)
  (let ((cases (gethash "cases" oracle))
        (count 0))
    (loop for name being the hash-keys of cases using (hash-value c)
          do (incf count)
             (let* ((got (vovas.engine.pipeline:unpack-asset
                          (expand-budget-recipe c)
                          (vovas.engine.pipeline:make-unpack-options)))
                    (want (gethash "result" c))
                    (files (files-of got)))
               (compare-entry result (format nil "budget/~a" name)
                              (entry-of got) (gethash "entry" want))
               ;; `textAtBudget`'s single file is 8 MiB and is NOT stored; only
               ;; its count is asserted, and the fixture says so.
               (if (gethash "fileCount" want)
                   (check result (format nil "budget/~a/file-count" name) name
                          (length files) (gethash "fileCount" want))
                   (compare-files result (format nil "budget/~a" name)
                                  files (gethash "files" want)))))
    count))

;;; ---------------------------------------------------------------------------
;;; Tier 5: assetSlug, from BOTH oracles
;;;
;;; The pipeline OWNS `asset_slug`, so the text-tier oracle's 14 cases belong
;;; here too. But those 14 all end their text exactly where a PCRE `$` would
;;; also end, so they CANNOT distinguish Rust's end-of-haystack `$` from PCRE's
;;; end-or-before-final-newline `$`. The probe oracle carries the
;;; trailing-newline URLs that can, and the mutation test proved the difference
;;; was real: a `$`-based port passed all 14 original cases and failed only the
;;; probe ones.
;;;
;;; Both use `"<url> #<index>"` keys; splitting on the LAST `" #"` is the only
;;; safe rule because a URL can itself contain `#`.
;;; ---------------------------------------------------------------------------

(defun split-slug-key (key)
  "`\"https://h/a.js #3\"` -> (values \"https://h/a.js\" 3)."
  (let ((marker (search " #" key :from-end t)))
    (values (subseq key 0 marker)
            (parse-integer key :start (+ marker 2)))))

(defun gate-pipeline-slug (result cases label)
  (let ((count 0))
    (loop for key being the hash-keys of cases using (hash-value want)
          do (incf count)
             (multiple-value-bind (url index) (split-slug-key key)
               (check result (format nil "~a/assetSlug" label) key
                      (vovas.engine.pipeline:asset-slug url index) want)))
    count))

;;; ---------------------------------------------------------------------------
;;; Tier 6: looksBinaryScript, and the UTF-16-versus-bytes unit probe
;;; ---------------------------------------------------------------------------

(defun probe-binary-bytes (tag)
  "The file bytes a `looksBinaryScript` probe names, or NIL for `none`."
  (cond
    ((string= tag "none") nil)
    ((string= tag "garbage") (make-array 64 :element-type '(unsigned-byte 8)))
    ((string= tag "short") (make-array 4 :element-type '(unsigned-byte 8)))
    (t (binary-fixture-bytes tag))))

(defun gate-pipeline-probes (result oracle)
  (let ((count 0))
    (loop for key being the hash-keys of (gethash "looksBinaryScript" oracle)
          using (hash-value want)
          do (incf count)
             (let* ((split (search "||" key))
                    (url (subseq key 0 split))
                    (tag (subseq key (+ split 2))))
               (check result "looksBinaryScript" key
                      (and (vovas.engine.pipeline:looks-binary-script
                            url (probe-binary-bytes tag))
                           t)
                      (and want t))))
    ;; UTF-16 length, not octet length: `é` is ONE unit and two UTF-8 bytes, an
    ;; emoji is TWO units and four bytes. A port using the octet count answers
    ;; 2 and 4 here and matches nothing else in the report.
    (loop for name being the hash-keys of (gethash "unit" oracle)
          using (hash-value c)
          do (incf count)
             (let ((got (vovas.engine.pipeline:unpack-asset
                         (vovas.engine.pipeline:make-text-asset
                          (gethash "url" c) (gethash "content" c))
                         (vovas.engine.pipeline:make-unpack-options))))
               (compare-entry result (format nil "unit/~a" name)
                              (entry-of got) (gethash "entry" (gethash "result" c)))))
    count))

;;; ---------------------------------------------------------------------------
;;; Tier 7: small predicates with no oracle key, pinned structurally
;;; ---------------------------------------------------------------------------

(defun gate-pipeline-structural (result)
  (let ((p 'vovas.engine.pipeline))
    ;; `first-non-empty`: the first non-empty wins, "" does not, and the
    ;; fallback only runs when everything is empty
    (check result "first-non-empty/picks-first" "('' 'a' 'b')"
           (funcall (intern "FIRST-NON-EMPTY" p) '("" "a" "b") "fb") "a")
    (check result "first-non-empty/fallback" "('' '')"
           (funcall (intern "FIRST-NON-EMPTY" p) '("" "") "fb") "fb")
    (check result "first-non-empty/skips-nil" "('' nil 'c')"
           (funcall (intern "FIRST-NON-EMPTY" p) '("" nil "c") "fb") "c")

    ;; `pretty-json`: the layout serde_json uses. Four properties, each of
    ;; which a naive emitter gets wrong, and NOT a float (unreachable, above).
    (check result "pretty-json/empty-object" "{}"
           (funcall (intern "PRETTY-JSON" p)
                    (funcall (intern "JSON-OBJECT" p)))
           "{}")
    (check result "pretty-json/empty-array" "[]"
           (funcall (intern "PRETTY-JSON" p)
                    (apply (intern "JSON-ARRAY" p) '()))
           "[]")
    (check result "pretty-json/false-vs-null" "both in one object"
           (funcall (intern "PRETTY-JSON" p)
                    (funcall (intern "JSON-OBJECT" p)
                             (cons "a" :false) (cons "b" :null)))
           (format nil "{~%  \"a\": false,~%  \"b\": null~%}"))
    (check result "pretty-json/no-trailing-newline" "object"
           (let ((text (funcall (intern "PRETTY-JSON" p)
                                (funcall (intern "JSON-OBJECT" p)
                                         (cons "a" 1)))))
             (char text (1- (length text))))
           #\})
    (check result "pretty-json/escapes-control" "quote, backslash, tab"
           (funcall (intern "PRETTY-JSON" p)
                    (concatenate 'string (string #\") (string #\\) (string #\Tab)))
           (format nil "\"~a~a~a\"" "\\\"" "\\\\" "\\t"))
    ;; non-ASCII is NOT escaped: the oracle's own notes carry an em dash
    (check result "pretty-json/keeps-non-ascii" "em dash"
           (funcall (intern "PRETTY-JSON" p) "—") "\"—\"")

    ;; a non-finite float must be an ERROR, not a silent `null`
    (check result "pretty-json/rejects-nan" "NaN"
           (handler-case (progn (funcall (intern "PRETTY-JSON" p)
                                        (sb-kernel:make-double-float -1 0))
                                :no-error)
             (error () :signalled))
           :signalled)

    ;; the empty/absent distinction the report depends on
    (check result "entry/refusals-absent-vs-empty" "key presence"
           (list (funcall (intern "ENTRY-HAS-KEY-P" p)
                          (funcall (intern "MAKE-ENTRY" p) :url "u") :refusals)
                 (funcall (intern "ENTRY-HAS-KEY-P" p)
                          (let ((entry (funcall (intern "MAKE-ENTRY" p) :url "u")))
                            (setf (getf entry :refusals) '())
                            entry)
                          :refusals))
           (list nil t))

    ;; `iso8601-now` against the two values util.rs's own test asserts
    (check result "iso8601/epoch" "0 secs"
           (let ((vovas.engine.pipeline:*clock-seconds* 0))
             (vovas.engine.pipeline:iso8601-now))
           "1970-01-01T00:00:00.000Z")
    (check result "iso8601/2026" "1767225600 secs"
           (let ((vovas.engine.pipeline:*clock-seconds* 1767225600))
             (vovas.engine.pipeline:iso8601-now))
           "2026-01-01T00:00:00.000Z")

    ;; `unpack-assets-into` with an EMPTY prefix re-normalises the REPORT's root
    ;; and path to `_unpack`, while the ARTIFACT paths keep the empty prefix
    ;; verbatim (leading slash). That asymmetry is the Rust's; both halves are
    ;; asserted so a port that "tidied" either one fails.
    (let ((written '()))
      (let ((report (vovas.engine.pipeline:unpack-assets-into
                     (lambda (path content)
                       (setf written (append written (list (cons path content)))))
                     (list (vovas.engine.pipeline:make-text-asset
                            "https://a.test/x.js" "var a = 1;"))
                     (vovas.engine.pipeline:make-unpack-options :path-prefix ""))))
        (check result "unpack-assets-into/empty-prefix-root" "'' prefix"
               (vovas.engine.pipeline:report-root report) "_unpack")
        (check result "unpack-assets-into/empty-prefix-report-path" "'' prefix"
               (and written (car (car (last written)))) "_unpack/index.json")
        ;; `var a = 1;` is ONE line containing `var`, so `looks-minified-p`
        ;; answers T and the artifact is the beautified form - the same
        ;; behaviour the `plain` oracle case shows.
        (check result "unpack-assets-into/empty-prefix-artifact-path" "'' prefix"
               (caar written) "/0000-a.test__x.js/10-beautified.js")))

    ;; an explicit report path overrides the default
    (let ((paths '()))
      (vovas.engine.pipeline:unpack-assets-into
       (lambda (path content) (declare (ignore content)) (push path paths))
       (list (vovas.engine.pipeline:make-text-asset "https://a.test/x.js" "var a = 1;"))
       (vovas.engine.pipeline:make-unpack-options)
       "custom/report.json")
      (check result "unpack-assets-into/explicit-report-path" "custom/report.json"
             (car paths) "custom/report.json"))

    ;; `build-zip` is an identity on the zip module's writer: the same bytes the
    ;; callee answers, so the delegation is real and not a stub
    (check result "build-zip/delegates" "one entry"
           (equalp (vovas.engine.pipeline:build-zip
                    (list (list :path "a.txt" :content "hello")) 0)
                   (vovas.engine.zip:build-zip
                    (list (list :path "a.txt" :content "hello")) 0))
           t)
    14))

;;; ---------------------------------------------------------------------------
;;; Wrong-implementation probes
;;;
;;; Each names a PLAUSIBLE wrong port and shows the real one does not produce
;;; it. Necessary because several oracle cases cannot separate the two: every
;;; `$`-anchored case in the oracle has text that ends exactly where a PCRE `$`
;;; would also end, so the difference shows only on a trailing newline - which
;;; the PROBE oracle has and the original fixture does not.
;;; ---------------------------------------------------------------------------

(defun gate-pipeline-wrong-impl (result)
  (flet ((probe (label thunk wrong)
           (check result label label
                  (equal (funcall thunk) wrong) nil)))
    ;; 1. `[?#].*$` under PCRE semantics would strip the query from `a?b\n` and
    ;;    answer a clean `a.js`. Rust's `$` is end-of-haystack only, so the `?`
    ;;    survives as `_` and the newline stays. The port answers the latter.
    (probe "assetSlug/not-pcre-dollar" 
           (lambda () (vovas.engine.pipeline:asset-slug (format nil "a?b~%") 0))
           "0000-a.js")
    ;; 2. the four-digit prefix keeps the LAST four digits: index 12345 answers
    ;;    "2345", not "12345" and not "0001".
    (probe "assetSlug/suffix-not-pad-start"
           (lambda () (vovas.engine.pipeline:asset-slug "https://h/a.js" 12345))
           "1234-h__a.js")
    (probe "assetSlug/not-pad-start"
           (lambda () (vovas.engine.pipeline:asset-slug "https://h/a.js" 12345))
           "0001-h__a.js")
    ;; 3. the binary-extension test is anchored on `(\\?|$)`, so a `.wasmX`
    ;;    suffix is NOT binary. An unanchored `\\.(jsc|bc|wasm)` answers T.
    (probe "looksBinaryScript/extension-is-anchored"
           (lambda () (and (vovas.engine.pipeline:looks-binary-script
                            "https://demo.test/a.wasmx" nil)
                           t))
           t)
    ;; 4. `bytes` is UTF-16 length: an astral character counts 2, and its
    ;;    UTF-8 encoding counts 4.
    (probe "asset/bytes-is-utf16-not-octets"
           (lambda () (vovas.engine.pipeline:entry-get
                       (entry-of (vovas.engine.pipeline:unpack-asset
                                  (vovas.engine.pipeline:make-text-asset
                                   "https://a.test/u.js" (string (code-char #x1F600)))
                                  (vovas.engine.pipeline:make-unpack-options)))
                       :bytes))
           4)
    ;; 5. `unpacked` counts assets that produced a stage, modules or sources -
    ;;    NOT every asset. The batch has five assets and three unpacked; a port
    ;;    that counted entries answers 5.
    (probe "unpackAssets/unpacked-is-not-asset-count"
           (lambda ()
             (vovas.engine.pipeline:totals-unpacked
              (vovas.engine.pipeline:report-totals
               (vovas.engine.pipeline:batch-result-report
                (vovas.engine.pipeline:unpack-assets
                 (list (vovas.engine.pipeline:make-text-asset
                        "https://a.test/x.js" "var a = 1;")
                       (vovas.engine.pipeline:make-text-asset
                        "https://a.test/e.js" "eval(function(p,a,c,k){return p}(\"x\",1,1,0));"))
                 (vovas.engine.pipeline:make-unpack-options))))))
           2)
    ;; 6. an EMPTY text asset has no digest. `(sha256-hex "")` answers the
    ;;    digest of nothing, which is a plausible and wrong 64 hex chars.
    (probe "asset/empty-has-no-digest"
           (lambda () (vovas.engine.pipeline:entry-get
                       (entry-of (vovas.engine.pipeline:unpack-asset
                                  (vovas.engine.pipeline:make-text-asset
                                   "https://a.test/e.js" "")
                                  (vovas.engine.pipeline:make-unpack-options)))
                       :digest))
           "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    6))

;;; ---------------------------------------------------------------------------
;;; The gate
;;; ---------------------------------------------------------------------------

(defun run-pipeline-gate (&key (verbose t))
  "Assert every pipeline oracle. T when everything matches."
  (let ((result (make-gate-result))
        (count 0)
        ;; read in the OUTER let because the summary below names it
        (probe-oracle (read-json-file (fixture-path "pipeline-probe-oracle.json"))))
    (let ((text-oracle (read-json-file (fixture-path "pipeline-oracle.json")))
          (binary-oracle (read-json-file (fixture-path "pipeline-binary-oracle.json")))
          (batch-oracle (read-json-file (fixture-path "pipeline-batch-oracle.json")))
          (budget-oracle (read-json-file (fixture-path "pipeline-budget-oracle.json")))
          (text-tier (read-json-file (fixture-path "text-tier-oracle.json"))))
      (incf count (gate-pipeline-text result text-oracle))
      (incf count (gate-pipeline-binary result binary-oracle))
      (incf count (gate-pipeline-batch result batch-oracle))
      (incf count (gate-pipeline-batch-binary result batch-oracle))
      (incf count (gate-pipeline-zip result batch-oracle))
      (incf count (gate-pipeline-budget result budget-oracle))
      (incf count (gate-pipeline-slug result (gethash "assetSlug" text-tier) "text-tier"))
      (incf count (gate-pipeline-slug result (gethash "assetSlug" probe-oracle) "probe"))
      (incf count (gate-pipeline-probes result probe-oracle))
      (incf count (gate-pipeline-structural result))
      (incf count (gate-pipeline-wrong-impl result)))
    (when verbose
      (format t "~&pipeline gate: ~a/~a assertions match~%"
              (gate-result-passed result) (gate-result-total result))
      (format t "  oracle cases exercised: ~a~%" count)
      (format t "  oracle-pinned: 13 text unpackAsset cases (entry + every file),~%")
      (format t "                 8 binary unpackAsset cases,~%")
      (format t "                 1 text batch + 1 binary batch (report + files),~%")
      (format t "                 3 budget cases, 14+~a assetSlug cases~%"
              (hash-table-count (gethash "assetSlug" probe-oracle)))
      (format t "                 ~a looksBinaryScript probes + 2 UTF-16 unit cases~%"
              (hash-table-count (gethash "looksBinaryScript" probe-oracle)))
      (format t "  byte-pinned:   functions.json, wasm-info.json, cache-header.json,~%")
      (format t "                 strings.json and raw/index.json are compared as TEXT,~%")
      (format t "                 so the JSON writer's key order and layout are pinned~%")
      (format t "  STRUCTURAL:    unpackAssetsForZip is NOT exported by the bridge and~%")
      (format t "                 cannot be captured. Its report root/stamp/report-last~%")
      (format t "                 are pinned here; everything it WRITES is the batch's~%")
      (format t "                 oracle-pinned output. Also structural: emit-double~%")
      (format t "                 (no captured refusal carries a float) and build-zip~%")
      (format t "                 (identity on vovas.engine.zip:build-zip, gated there).~%")
      (report-failures result))
    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp (gate-result-total result))
         (plusp count))))
