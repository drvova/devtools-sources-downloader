;;;; gate-artifacts.lisp — the readable-artifact helpers.
;;;;
;;;; Driven by `artifacts-oracle.json`, whose `expected` sections were captured
;;;; from the shipped engine. Every INPUT here is transcribed from the Rust test
;;;; block rather than invented, because a gate fed different inputs tests the
;;;; port against my own guess instead of against the engine.
;;;;
;;;; Two sections carry a shape that a naive comparison would pass wrongly:
;;;;   - `parseCookies` is compared by KEY ORDER as well as content, since the
;;;;     object is serialized into `_recon/cookies.json` as written
;;;;   - `serializeInlineJson` is compared as an exact string, because the
;;;;     escaping of `</script>` is the whole point of the function

(in-package :vovas.engine.gate)

(defun artifacts-json-null ()
  "The value JZON parses JSON `null` to.

It is NOT a package constant: this JZON reads null as a SYMBOL whose name is
`NULL`, which is why `gate.lisp`'s `json-null` recognises it by `symbol-name`
rather than by identity. Interning that name reproduces it."
  (intern "NULL" :com.inuoe.jzon))

(defun ht (&rest pairs)
  "A JSON-object hash table from alternating key/value arguments.

The key is a STRING because the engine's `field` looks up JSON keys by string;
a keyword here would make every lookup miss and answer NIL, which reads as a
port bug rather than a test-harness one."
  (let ((table (make-hash-table :test #'equal)))
    (loop for (key value) on pairs by #'cddr
          do (setf (gethash key table) value))
    table))

(defun ht* (pairs)
  "`ht` over an ALIST, for nested literals where the plist form is unreadable."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (pair pairs)
      (setf (gethash (car pair) table) (cadr pair)))
    table))

(defun cookie-keys (table order)
  "The keys of TABLE in first-seen ORDER - the order `_recon/cookies.json` gets."
  order)

(defun run-artifacts-gate (&key (verbose t))
  (let* ((oracle (read-json-file (fixture-path "panel/artifacts-oracle.json")))
         (exp (gethash "expected" oracle))
         (result (make-gate-result))
         (count 0))

    ;; ---- runtimeFolderName ----------------------------------------------
    ;; The LAST two kinds both answer "misc": an unknown kind and the EMPTY
    ;; string. That pair is the assertion that the lookup is a closed table and
    ;; not a prefix or a case-fold.
    (let ((kinds '("eval" "function" "blob" "worker" "shared-worker"
                   "service-worker" "script-injection" "wasm" "other" ""))
          (want (gethash "runtimeFolderName" exp)))
      (loop for kind in kinds
            for i from 0
            do (incf count)
               (check result "runtimeFolderName" i
                      (vovas.engine.panel.artifacts:runtime-folder-name kind)
                      (coerce (aref want i) 'string))))

    ;; ---- runtimeExtension ----------------------------------------------
    ;; Sixteen entries crossing the mime table, the kind table and base64. The
    ;; interesting ones are index 0 (kind wasm, NO mime) and index 16 (kind blob
    ;; with a wasm mime) - both answer "wasm", from different branches.
    (let ((entries (list (ht "kind" "wasm")
                         (ht "kind" "eval" "mimeType" "application/javascript")
                         (ht "kind" "eval" "mimeType" "application/json")
                         (ht "kind" "eval" "mimeType" "text/html")
                         (ht "kind" "eval" "mimeType" "text/css")
                         (ht "kind" "eval" "mimeType" "image/svg+xml")
                         (ht "kind" "eval" "mimeType" "application/xml")
                         (ht "kind" "eval" "mimeType" "text/plain")
                         (ht "kind" "eval")
                         (ht "kind" "function")
                         (ht "kind" "worker")
                         (ht "kind" "shared-worker")
                         (ht "kind" "service-worker")
                         (ht "kind" "script-injection")
                         (ht "kind" "blob")
                         (ht "kind" "blob" "base64" "AAAA")
                         (ht "kind" "blob" "mimeType" "application/wasm")))
          (want (gethash "runtimeExtension" exp)))
      (loop for entry in entries
            for i from 0
            do (incf count)
               (check result "runtimeExtension" i
                      (vovas.engine.panel.artifacts:runtime-extension entry)
                      (coerce (aref want i) 'string))))

    ;; ---- buildRuntimePath ----------------------------------------------
    ;; ONE counter table across all six entries: the two "eval" rows become 0001
    ;; and 0002, so a fresh table per call would answer 0001 twice.
    (let ((entries (list (ht "kind" "eval" "mimeType" "application/javascript")
                         (ht "kind" "eval")
                         (ht "kind" "wasm")
                         (ht "kind" "worker")
                         (ht "kind" "worker")
                         (ht "kind" "mystery")))
          (want (gethash "buildRuntimePath" exp))
          (counters (make-hash-table :test #'equal)))
      (loop for entry in entries
            for i from 0
            do (incf count)
               (check result "buildRuntimePath" i
                      (vovas.engine.panel.artifacts:build-runtime-path entry counters)
                      (coerce (aref want i) 'string))))

    ;; ---- buildRuntimeUnpackAssets --------------------------------------
    ;; r2 is a wasm payload (skipped), r3 has EMPTY text (skipped), r5 has no
    ;; manifest row so its zip path is empty. Three of five survive.
    (let* ((payloads (list (ht "id" "r1" "kind" "eval" "text" "var a = 1"
                               "url" "https://x/a.js")
                           (ht "id" "r2" "kind" "wasm" "text" "WASMTEXT"
                               "url" "https://x/b.wasm")
                           (ht "id" "r3" "kind" "eval" "text" "")
                           (ht "id" "r4" "kind" "eval" "label" "labelled"
                               "text" "var b = 2")
                           (ht "id" "r5" "kind" "eval" "text" "var c = 3")))
           (manifest (list (ht "id" "r1" "file" "runtime/eval-1.js")
                           (ht "id" "r4" "file" "runtime/eval-4.js")))
           (got (vovas.engine.panel.artifacts:build-runtime-unpack-assets
                 payloads manifest))
           (want (aref (gethash "buildRuntimeUnpackAssets" exp) 0)))
      (incf count) (check result "buildRuntimeUnpackAssets/count" "assets"
                          (length got) (length want))
      (incf count)
      (check result "buildRuntimeUnpackAssets/records" "url+content+zipPath"
             (mapcar (lambda (a) (list (getf a :url) (getf a :content)
                                       (getf a :zip-path)))
                     got)
             (mapcar (lambda (a) (list (coerce (gethash "url" a) 'string)
                                       (coerce (gethash "content" a) 'string)
                                       (coerce (gethash "zipPath" a) 'string)))
                     (coerce want 'list)))
      (incf count)
      (check result "buildRuntimeUnpackAssets/empty" "no payloads"
             (vovas.engine.panel.artifacts:build-runtime-unpack-assets '() '())
             '()))

    ;; ---- mergeUnpackReports --------------------------------------------
    (let ((script (ht "totals" (ht "assets" 3 "unpacked" 2 "modules" 1
                                  "sources" 4 "beautified" 1)
                     "files" (vector "a.js")))
          (runtime (ht "totals" (ht "assets" 5 "unpacked" 4 "modules" 3
                                   "sources" 2 "beautified" 2)
                      "files" (vector "b.js")))
          (want (gethash "mergeUnpackReports" exp)))
      (vovas.engine.panel.artifacts:merge-unpack-reports script runtime)
      (let ((got (gethash "totals" script))
            (want-totals (gethash "totals" want)))
        (dolist (key '("assets" "unpacked" "modules" "sources" "beautified"))
          (incf count)
          (check result (format nil "mergeUnpackReports/~a" key) "sum"
                 (gethash key got)
                 (truncate (gethash key want-totals)))))
      ;; the "files" array must survive untouched - the merge only touches totals
      (incf count)
      (check result "mergeUnpackReports/files" "untouched"
             (coerce (gethash "files" script) 'list) '("a.js")))

    ;; ---- parseCookies ---------------------------------------------------
    ;; `broken` has no `=`, so it is SKIPPED; `c=3=4` keeps the second `=` in the
    ;; value; the `;;` produces an empty segment that is skipped the same way.
    (let ((inputs '("a=1; b = 2 ;; c=3=4; broken" ""))
          (want (gethash "parseCookies" exp)))
      (loop for input in inputs
            for i from 0
            do (let ((want-obj (aref want i)))
                 (multiple-value-bind (table order)
                     (vovas.engine.panel.artifacts:parse-cookies input)
                   (incf count)
                   (check result "parseCookies/keys" i order
                          (loop for k being the hash-keys of want-obj collect k))
                   (incf count)
                   (check result "parseCookies/values" i
                          (loop for k in order collect (cons k (gethash k table)))
                          (loop for k being the hash-keys of want-obj
                                collect (cons k (coerce (gethash k want-obj) 'string))))))))

    ;; ---- serializeInlineJson -------------------------------------------
    (let ((inputs (list (ht "a" "<b>&" "c" (vector "</script>"))
                        (artifacts-json-null)))
          (want (gethash "serializeInlineJson" exp)))
      (loop for input in inputs
            for i from 0
            do (incf count)
               (check result "serializeInlineJson" i
                      (vovas.engine.panel.artifacts:serialize-inline-json input)
                      (coerce (aref want i) 'string))))

    ;; ---- escapeXml / escapeAttr ----------------------------------------
    ;; The same four inputs, and the APOSTROPHE is the only difference the two
    ;; expected lists have. escapeAttr is only asserted on the first three,
    ;; because the number case is not in its oracle slice.
    (let ((inputs (list "<a & \"b\" 'c'>" "" (artifacts-json-null) 7))
          (want-xml (gethash "escapeXml" exp))
          (want-attr (gethash "escapeAttr" exp)))
      (loop for input in inputs
            for i from 0
            do (incf count)
               (check result "escapeXml" i
                      (vovas.engine.panel.artifacts:escape-xml input)
                      (coerce (aref want-xml i) 'string)))
      (loop for input in (subseq inputs 0 3)
            for i from 0
            do (incf count)
               (check result "escapeAttr" i
                      (vovas.engine.panel.artifacts:escape-attr input)
                      (coerce (aref want-attr i) 'string))))

    ;; ---- computeReconStats ---------------------------------------------
    ;; Entry 2 is `not a url` with transferSize 0: the DOMAIN regex must not
    ;; match it, and a zero transferSize is ABSENT so the size total only sees
    ;; 1000 + 500 + 2000. Entry 1 has no responseEnd, so its duration comes from
    ;; the recorded `duration`.
    (let ((timings (list (ht "name" "https://a.test/x.js" "transferSize" 1000
                             "startTime" 10 "responseEnd" 30 "duration" 20
                             "initiatorType" "script")
                         (ht "name" "https://b.test/y.css" "encodedBodySize" 500
                             "startTime" 5 "duration" 5 "initiatorType" "link")
                         (ht "name" "not a url" "transferSize" 0
                             "startTime" 1 "duration" 0)
                         (ht "name" "https://a.test/z.png" "transferSize" 2000
                             "startTime" 1 "responseEnd" 3 "initiatorType" "img"))))
      (incf count)
      (check result "computeReconStats" "html"
             (vovas.engine.panel.artifacts:compute-recon-stats timings)
             (coerce (gethash "computeReconStats" exp) 'string))
      (incf count)
      (check result "computeReconStats/empty" "html"
             (vovas.engine.panel.artifacts:compute-recon-stats '())
             (coerce (gethash "computeReconStatsEmpty" exp) 'string)))

    (when verbose
      (format t "~&artifacts gate: ~a/~a cases match~%"
              (gate-result-passed result) (gate-result-total result))
      (report-failures result))
    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp count))))
