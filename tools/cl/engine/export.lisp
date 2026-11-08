;;;; export.lisp - the export orchestration, from panel/export.rs.
;;;;
;;;; `finalize-zip-with-recon` is the whole export in one call: the `_recon/*`
;;;; artifacts, the runtime payloads, the semantic analysis, and TWO unpack
;;;; passes whose reports are merged into the summary object.
;;;;
;;;; The JavaScript version is one async function that fetches runtime payloads
;;;; through the page and hands the finished blob to `saveAs`. Here the platform
;;;; halves stay on the caller's side: payload collection is the caller's job and
;;;; the archive is the writer seam, so everything in this file is synchronous.

(in-package :vovas.engine.panel.export)

;;; ---------------------------------------------------------------------------
;;; writeReconArtifacts
;;; ---------------------------------------------------------------------------

(defun non-empty-slice (data key)
  "DATA[KEY] when it is JS-truthy AND has a non-zero `keys-len`.

Two tests, and both are needed: truthiness rejects null/false/0, and `keys-len`
rejects an EMPTY object or array. A slice that is `{}` writes no file at all,
which is what keeps the archive index and the archive contents in agreement."
  (let ((value (vovas.engine.panel.assets:field data key)))
    (when (and (vovas.engine.panel.model:js-truthy value)
               (> (vovas.engine.panel.assets:keys-len value) 0))
      value)))

(defparameter *recon-slice-artifacts*
  '(("xhr" . "_recon/xhr.json")
    ("fetch" . "_recon/fetch.json")
    ("websockets" . "_recon/websockets.json")
    ("sse" . "_recon/sse.json")
    ("mutations" . "_recon/mutations.json"))
  "The recon sub-slices written when non-empty, in the engine's order.

Note this list is narrower than `non-empty-slice`'s callers: these have no
truthiness pre-test, only the keys-len one.")

(defun write-recon-artifacts (writer recon-data page-snapshot)
  "`writeReconArtifacts`: the `_recon/*` files, and the runtime entries to fetch.

Answers the runtime entry list, which the caller resolves payloads for. Nothing
is written when a slice is absent, empty or falsy - the archive carries no files
for data that was never captured."
  (let ((runtime-entries '()))
    (when (hash-table-p recon-data)
      (let ((data recon-data))
        ;; ---- storage
        (let ((ls (non-empty-slice data "ls")))
          (when ls (funcall writer "_recon/localStorage.json"
                            (vovas.engine.panel.report:report-pretty-json ls))))
        (let ((ss (non-empty-slice data "ss")))
          (when ss (funcall writer "_recon/sessionStorage.json"
                            (vovas.engine.panel.report:report-pretty-json ss))))
        ;; ---- cookies: parsed into an object, and only when the string has
        ;;      content after trimming. A whitespace-only string is skipped.
        (let ((cookies (vovas.engine.panel.assets:field data "cookies")))
          (when (vovas.engine.panel.model:js-truthy cookies)
            (let ((text (if (stringp cookies) cookies "")))
              (unless (zerop (length (vovas.engine.util:js-trim text)))
                (multiple-value-bind (table order)
                    (vovas.engine.panel.artifacts:parse-cookies text)
                  (declare (ignore order))
                  (funcall writer "_recon/cookies.json"
                           (vovas.engine.panel.report:report-pretty-json table)))))))
        ;; ---- page
        (let ((page (vovas.engine.panel.assets:field data "page")))
          (when (vovas.engine.panel.model:js-truthy page)
            (funcall writer "_recon/page.json"
                     (vovas.engine.panel.report:report-pretty-json page))))
        ;; ---- the stack profile, plus its two sub-documents
        (let ((profile (vovas.engine.panel.assets:field data "stackProfile")))
          (when (vovas.engine.panel.model:js-truthy profile)
            (funcall writer "_recon/stack-profile.json"
                     (vovas.engine.panel.report:report-pretty-json profile))
            (let ((evidence (vovas.engine.panel.assets:field profile "evidence")))
              (when (vovas.engine.panel.model:js-truthy evidence)
                (funcall writer "_recon/framework-signals.json"
                         (vovas.engine.panel.report:report-pretty-json evidence))))
            (let ((strategy (vovas.engine.panel.assets:field profile "strategy")))
              (when (vovas.engine.panel.model:js-truthy strategy)
                (funcall writer "_recon/capture-strategy.json"
                         (vovas.engine.panel.report:report-pretty-json strategy))))))
        ;; ---- capture status
        (let ((status (vovas.engine.panel.assets:field data "captureStatus")))
          (when (vovas.engine.panel.model:js-truthy status)
            (funcall writer "_recon/capture-status.json"
                     (vovas.engine.panel.report:report-pretty-json status))))
        ;; ---- framework state: delegated, because the slice table and the
        ;;      presence rule live in `paths` and must not be duplicated here.
        (let ((state (vovas.engine.panel.assets:field data "frameworkState")))
          (when (vovas.engine.panel.model:js-truthy state)
            (vovas.engine.panel.report:export-framework-artifacts writer state)))
        ;; ---- timings, and the waterfall rendered from them
        (let ((timings (non-empty-slice data "timings")))
          (when timings
            (funcall writer "_recon/timings.json"
                     (vovas.engine.panel.report:report-pretty-json timings))
            (funcall writer "_recon/waterfall.html"
                     (vovas.engine.panel.report:generate-waterfall-html
                      (coerce timings 'list)))))
        ;; ---- the recon block
        (let ((recon (vovas.engine.panel.assets:field data "recon")))
          (when (vovas.engine.panel.model:js-truthy recon)
            (dolist (pair *recon-slice-artifacts*)
              (let ((value (let ((v (vovas.engine.panel.assets:field
                                     recon (car pair))))
                             (when (and v
                                        (> (vovas.engine.panel.assets:keys-len v) 0))
                               v))))
                (when value
                  (funcall writer (cdr pair)
                           (vovas.engine.panel.report:report-pretty-json value)))))
            ;; GraphQL operations are written only when the capture strategy
            ;; asked for them - the strategy flag gates the collection, not just
            ;; the file.
            (let* ((profile (vovas.engine.panel.assets:field data "stackProfile"))
                   (strategy (and (hash-table-p profile)
                                  (vovas.engine.panel.assets:field profile "strategy")))
                   (captures (and (hash-table-p strategy)
                                  (vovas.engine.panel.model:js-truthy
                                   (vovas.engine.panel.assets:field
                                    strategy "captureGraphQLOps")))))
              (when captures
                (let ((ops (funcall (find-symbol "COLLECT-GRAPHQL-OPERATIONS"
                                                 :vovas.engine.panel.graph)
                                    recon)))
                  (when ops
                    (funcall writer "_recon/graphql-operations.json"
                             (vovas.engine.panel.report:report-pretty-json
                              (map 'vector
                                   (lambda (op)
                                     (vovas.engine.panel.artifacts:json-serialize-compact op))
                                   (coerce ops 'vector))))))))
            ;; the runtime entries the caller must resolve payloads for
            (let ((runtime (let ((v (vovas.engine.panel.assets:field recon "runtime")))
                             (when (and v
                                        (> (vovas.engine.panel.assets:keys-len v) 0))
                               v))))
              (when runtime
                (setf runtime-entries (coerce runtime 'list)))))))
    ;; ---- the DOM snapshot
    (when page-snapshot
      (let ((html (vovas.engine.panel.assets:field-str page-snapshot "html")))
        (unless (zerop (length html))
          (let ((page (let ((p (and (hash-table-p recon-data)
                                    (vovas.engine.panel.assets:field
                                     recon-data "page"))))
                        (if (vovas.engine.panel.model:js-truthy p)
                            p
                            (let ((title (vovas.engine.panel.assets:field-str
                                          page-snapshot "title"))
                                  (h (make-hash-table :test #'equal)))
                              (setf (gethash "title" h)
                                    (if (plusp (length title)) title "page"))
                              h))))))
            (funcall writer "_recon/dom-snapshot.html"
                     (vovas.engine.panel.artifacts:generate-dom-snapshot-html
                      html page))))))
    runtime-entries))

;;; ---------------------------------------------------------------------------
;;; finalizeZipWithRecon
;;; ---------------------------------------------------------------------------

(defun finalize-zip-with-recon (writer js-assets recon-data page-snapshot
                                runtime-payloads options)
  "`finalizeZipWithRecon`: the whole export, in the JavaScript's order.

The ORDER is the contract:
  1. `_recon/*` artifacts and the DOM snapshot;
  2. the runtime payload files plus their manifest;
  3. the semantic analysis and its artifact set;
  4. the SCRIPT unpack pass, then the RUNTIME unpack pass.

Step 4 uses a DIFFERENT path prefix for the runtime pass: the JavaScript
hardcodes `_unpack-runtime` at that call site, so the caller's prefix never
applies to it. That copy is made here rather than threaded through.

Both unpack passes go through the same TEXT writer, so the archive sees their
output interleaved exactly as the engine produced it. The answer is the merged
report - the object the panel keeps for its summary line."
  ;; ---- 1. recon artifacts (text only)
  (write-recon-artifacts (lambda (path content) (funcall writer path content))
                         recon-data page-snapshot)
  ;; ---- 2. runtime payloads (binary or text) plus the manifest
  (let ((manifest (vovas.engine.panel.report:export-runtime-artifacts
                   writer runtime-payloads)))
    ;; ---- 3. the semantic analysis (text only)
    ;; `runtime-payloads` arrives as a VECTOR from the caller but the analysis
    ;; builder walks it with `dolist`, so it is coerced once here rather than
    ;; asking every caller to remember which shape this one function wants.
    (vovas.engine.panel.report:export-semantic-analysis
     (lambda (path content) (funcall writer path content))
     js-assets recon-data (coerce runtime-payloads 'list)
     (coerce manifest 'list))
    ;; ---- 4. the two unpack passes
    ;; BOTH of these arrive as vectors from the caller and from the manifest
    ;; builder, and `build-runtime-unpack-assets` walks them with `dolist`. Same
    ;; vector-vs-list seam as the analysis builder above.
    (let* ((runtime-assets (vovas.engine.panel.artifacts:build-runtime-unpack-assets
                            (coerce runtime-payloads 'list)
                            (coerce manifest 'list)))
           (script-assets (vovas.engine.panel.assets:assets-from-inputs js-assets))
           ;; the runtime pass gets its own copy with the hardcoded prefix.
           ;; Options are a PLIST, so this is a copy with one key replaced
           ;; rather than a rebuild from accessors - a rebuild would have to
           ;; name every field and would silently drop any added later.
           (runtime-options (let ((copy (copy-list options)))
                              (setf (getf copy :path-prefix) "_unpack-runtime")
                              copy))
           (text-writer (lambda (path content) (funcall writer path content)))
           (script-report (vovas.engine.pipeline:unpack-assets-into
                           text-writer script-assets options nil))
           (runtime-report (vovas.engine.pipeline:unpack-assets-into
                            text-writer runtime-assets runtime-options nil)))
      (let ((merged (vovas.engine.panel.analysis:analysis-wire script-report))
            (runtime-value (vovas.engine.panel.analysis:analysis-wire runtime-report)))
        (vovas.engine.panel.artifacts:merge-unpack-reports merged runtime-value)
        merged))))

;;; ---------------------------------------------------------------------------
;;; exportSummary
;;; ---------------------------------------------------------------------------

(defun export-summary (report)
  "`exportSummary`: the panel's one-line summary of a finished export.

Reads through the TOTALS sub-object, so a report with no totals answers zeros
rather than signalling - the summary is displayed, not validated."
  (let ((totals (vovas.engine.panel.assets:field report "totals")))
    (flet ((n (key)
             (let ((v (and (hash-table-p totals)
                           (vovas.engine.panel.assets:field-number totals key))))
               (truncate (or v 0d0)))))
      (format nil
              "Export ready. Unpacked ~a of ~a scripts (~a beautified, ~a original sources, ~a bundle modules)."
              (n "unpacked") (n "assets") (n "beautified")
              (n "sources") (n "modules")))))
