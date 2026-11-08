;;;; analysis.lisp - the panel's whole-pipeline assembly.
;;;;
;;;; `build-semantic-analysis` runs the asset analysis, module graph, startup
;;;; chain, boundary labels, cross-boundary flows, entrypoints, framework state
;;;; and the investigation workspace in the pipeline's order and hands back the
;;;; analysis object every report renders from.
;;;;
;;;; THREE DISTINCT PROJECTIONS OF A SCRIPT ASSET appear in the output, and they
;;;; are not interchangeable:
;;;;
;;;;   assets          21 keys - the full serde shape, INCLUDING `content` and
;;;;                   `boundaryDetails`
;;;;   chunkMap.items  19 keys - `strip_chunk_asset`, which drops `content` (the
;;;;                   source text lives in the archive, not the chunk map) and
;;;;                   `boundaryDetails`
;;;;
;;;; Runtime origins need no projection at all: they are hash tables carrying the
;;;; wire keys already, so `runtimeRecords` is the same objects.

(in-package :vovas.engine.panel.analysis)

;;; ---------------------------------------------------------------------------
;;; Wire projections
;;; ---------------------------------------------------------------------------

(defun analysis-js-number (value)
  "A double as the JSON number it should print as: integral in range -> integer.

Same rule as `js-number-value`, restated here because this file must not depend
on `artifacts` (which loads after it) just to round a score."
  (let ((v (coerce (or value 0d0) 'double-float)))
    (if (and (zerop (nth-value 1 (truncate v))) (< (abs v) 9007199254740992d0))
        (truncate v)
        v)))

(defun boundary-details-wire (details)
  "The boundary-detail structs as wire tables, in order."
  (map 'vector
       (lambda (detail)
         (let ((h (make-hash-table :test #'equal)))
           (setf (gethash "label" h)
                 (vovas.engine.panel.assets:boundary-detail-label detail)
                 (gethash "score" h)
                 (analysis-js-number
                  (vovas.engine.panel.assets:boundary-detail-score detail))
                 (gethash "reasons" h)
                 (coerce (vovas.engine.panel.assets:boundary-detail-reasons detail)
                         'vector))
           h))
       (coerce details 'vector)))

(defun module-signals-wire-table (signals)
  "A `module-signals` struct as the wire object."
  (let ((h (make-hash-table :test #'equal)))
    (setf (gethash "importCount" h)
          (vovas.engine.panel.assets:module-signals-import-count signals)
          (gethash "dynamicImports" h)
          (vovas.engine.panel.assets:module-signals-dynamic-imports signals)
          (gethash "requires" h)
          (vovas.engine.panel.assets:module-signals-requires signals)
          (gethash "exports" h)
          (vovas.engine.panel.assets:module-signals-exports signals))
    h))

(defun script-asset-wire (asset &key with-content)
  "A `script-asset` in wire shape.

`with-content` selects the 21-key `assets` projection (content and boundary
details included); without it this is the 19-key `chunkMap.items` projection.
One function with a flag rather than two copies, because the 19 shared keys are
the part that must not drift between them."
  (let ((out (make-hash-table :test #'equal)))
    (setf (gethash "id" out) (vovas.engine.panel.assets:script-asset-id asset)
          (gethash "url" out) (vovas.engine.panel.assets:script-asset-url asset)
          (gethash "file" out) (vovas.engine.panel.assets:script-asset-file asset)
          (gethash "size" out) (vovas.engine.panel.assets:script-asset-size asset)
          (gethash "transferSize" out)
          (analysis-js-number
           (vovas.engine.panel.assets:script-asset-transfer-size asset))
          (gethash "startTime" out)
          (analysis-js-number
           (vovas.engine.panel.assets:script-asset-start-time asset))
          (gethash "duration" out)
          (analysis-js-number
           (vovas.engine.panel.assets:script-asset-duration asset))
          (gethash "classification" out)
          (vovas.engine.panel.assets:script-asset-classification asset)
          (gethash "bundler" out)
          (vovas.engine.panel.assets:script-asset-bundler asset)
          (gethash "frameworkHints" out)
          (coerce (vovas.engine.panel.assets:script-asset-framework-hints asset)
                  'vector)
          (gethash "routeHints" out)
          (coerce (vovas.engine.panel.assets:script-asset-route-hints asset)
                  'vector)
          (gethash "startupSignals" out)
          (coerce (vovas.engine.panel.assets:script-asset-startup-signals asset)
                  'vector)
          (gethash "boundaryLabels" out)
          (coerce (vovas.engine.panel.assets:script-asset-boundary-labels asset)
                  'vector)
          (gethash "primaryBoundary" out)
          (vovas.engine.panel.assets:script-asset-primary-boundary asset)
          (gethash "boundaryReasons" out)
          (coerce (vovas.engine.panel.assets:script-asset-boundary-reasons asset)
                  'vector)
          (gethash "imports" out)
          (coerce (vovas.engine.panel.assets:script-asset-imports asset) 'vector)
          (gethash "moduleSignals" out)
          (module-signals-wire-table
           (vovas.engine.panel.assets:script-asset-module-signals asset))
          (gethash "sourceMapEmbedded" out)
          (and (vovas.engine.panel.assets:script-asset-source-map-embedded asset) t)
          (gethash "score" out)
          (analysis-js-number
           (vovas.engine.panel.assets:script-asset-score asset)))
    (when with-content
      (setf (gethash "content" out)
            (vovas.engine.panel.assets:script-asset-content asset)
            (gethash "boundaryDetails" out)
            (boundary-details-wire
             (vovas.engine.panel.assets:script-asset-boundary-details asset))))
    out))

;;; ---------------------------------------------------------------------------
;;; Deep wire conversion
;;;
;;; The lower modules are internally consistent in PLISTS (`build-chunk-summary`,
;;; `build-runtime-summary`, `build-module-graph`, `build-startup-chain`,
;;; `strip-runtime-entry`), and their own gates compare through a wire projection
;;; at assertion time. The ANALYSIS object is different: the Rust holds
;;; `serde_json::Value` throughout, so every section is wire-shaped, and
;;; `build-boundary-workspace` reads these sections with string-keyed `field`.
;;;
;;; Converting here, once, at the boundary where plists become the published
;;; analysis, keeps both facts true - and keeps this conversion in ONE place
;;; rather than at every read site.
;;; ---------------------------------------------------------------------------

(defun analysis-wire-key (keyword)
  "`:total-scripts` -> `\"totalScripts\"`."
  (let ((out (make-string-output-stream))
        (up nil))
    (loop for c across (string-downcase (symbol-name keyword))
          do (cond ((char= c #\-) (setf up t))
                   (up (write-char (char-upcase c) out) (setf up nil))
                   (t (write-char c out))))
    (get-output-stream-string out)))

(defun analysis-proper-list-p (value)
  "Whether VALUE is a proper list (not a cons pair)."
  (and (listp value)
       (loop for tail = value then (cdr tail)
             while (consp tail)
             finally (return (null tail)))))

(defun analysis-alist-p (value)
  "Whether VALUE is a COUNTING alist - `((\"framework\" . 3) ...)`.

The test must exclude a list of PLISTS. `((:id \"page\" ...) (:id \"chunk\" ...))`
also has every element a cons, but it is a list of objects that belongs in a
VECTOR - treating it as an alist collapsed a nine-node graph into a one-entry
table whose key was the plist's first keyword. The distinguishing fact is the
KEY TYPE: a counting alist is keyed by a string (a label, a classification), while
a plist's first element is a keyword."
  (and (consp value)
       (analysis-proper-list-p value)
       (every (lambda (pair)
                (and (consp pair) (not (keywordp (car pair)))))
              value)))

(defun analysis-wire (value)
  "VALUE as the JSON wire shape, recursively.

Three list shapes are recognised, and confusing them is silent except for the
alist case, which SIGNALS:

  - a PLIST (first element a keyword) becomes a string-keyed hash table
  - an ALIST (every element a cons pair) becomes a string-keyed hash table -
    this is what `counts-alist` returns, and its pairs have dotted cdrs
  - anything else that is a sequence becomes a vector

Hash tables have their values converted. NIL is left alone; a caller that needs a
JSON null uses `json-null-symbol`."
  (cond
    ((null value) nil)
    ;; A STRING MUST BE TESTED FIRST. A CL string IS a vector, so the
    ;; vectorp branch below would decompose "bootstrap" into
    ;; #(\#b \#o \#o ...) - and every downstream `stringp` test then
    ;; rejects it. That silently emptied the boundary-category list and
    ;; collapsed nine workspaces into one.
    ((stringp value) value)
    ;; THE MARKER PASSES THROUGH UNCHANGED. A struct is not a list, so without
    ;; this test it would reach the `(t value)` fallback and survive - but every
    ;; branch that inspects SHAPE would have to be read carefully to be sure, and
    ;; the serializer is the one place that should decide how an empty container
    ;; is spelled.
    ((vovas.engine.panel.model:json-marker-p value) value)
    ((hash-table-p value)
     (let ((out (make-hash-table :test #'equal)))
       (maphash (lambda (k v) (setf (gethash k out) (analysis-wire v))) value)
       out))
    ((and (consp value) (keywordp (first value)) (analysis-proper-list-p value)
          (evenp (length value)))
     (let ((out (make-hash-table :test #'equal)))
       (loop for (k v) on value by #'cddr
             do (setf (gethash (analysis-wire-key k) out) (analysis-wire v)))
       out))
    ((analysis-alist-p value)
     (let ((out (make-hash-table :test #'equal)))
       (dolist (pair value)
         (setf (gethash (if (keywordp (car pair))
                            (analysis-wire-key (car pair))
                            (princ-to-string (car pair)))
                        out)
               (analysis-wire (cdr pair))))
       out))
    ;; A DOTTED PAIR is a single key/value entry - `("chunk" . 4)` - and it is
    ;; not a proper list, so the vector branch below never sees it and the
    ;; serialiser would receive the cons and signal "4 is not of type LIST".
    ;; One entry, as an object.
    ((and (consp value) (not (analysis-proper-list-p value)))
     (let ((out (make-hash-table :test #'equal)))
       (setf (gethash (if (keywordp (car value))
                          (analysis-wire-key (car value))
                          (princ-to-string (car value)))
                      out)
             (analysis-wire (cdr value)))
       out))
    ((or (vectorp value) (analysis-proper-list-p value))
     (coerce (mapcar #'analysis-wire (coerce value 'list)) 'vector))
    ;; A FLOAT that prints as an integer must BE an integer in the wire value.
    ;; The oracle stores `0`, not `0.0`, and a deep comparison of `0.0d0` against
    ;; `0` fails even though the printed JSON would agree.
    ((floatp value) (analysis-js-number value))
    (t value)))

;;; ---------------------------------------------------------------------------
;;; buildSemanticAnalysis
;;; ---------------------------------------------------------------------------

(defun analysis-summary-number (summary key)
  "SUMMARY[KEY] as a wire number, or JSON null when genuinely absent.

Reads with `gethash` rather than `field`, because `field` applies the JS-truthiness
rule and answers NIL for a stored `0` - and a transition count of 0 is a real
answer here, not a missing one."
  (if (hash-table-p summary)
      (multiple-value-bind (value present) (gethash key summary)
        (if present
            (if (numberp value) (analysis-js-number value) value)
            (vovas.engine.panel.model:json-null-symbol)))
      (vovas.engine.panel.model:json-null-symbol)))

(defun build-semantic-analysis (js-assets recon-data
                                runtime-entries runtime-manifest)
  "`buildSemanticAnalysis`: the whole pipeline, in the engine's order.

The ORDER is load-bearing beyond the obvious dependencies: labeling runs BEFORE
flows (flows read primaryBoundary), and entrypoints are collected AFTER labeling
for the same reason. `frameworkRuntime` is built last among the sections because
it aggregates the boundary report and the flows.

The investigation workspace is then built from the finished analysis, and its
workspaces and journeys are summarised BACK INTO frameworkRuntime as
`availableWorkspaces` / `availableJourneys` - so those two fields are not available
when the workspace itself is built, only afterwards.

`frameworkState` is filtered on `js-truthy` rather than a null check: the Rust is
`.filter(|v| !v.is_null())`, and an empty object is not null, so an empty
framework state still reaches the summary."
  (let* ((assets (vovas.engine.panel.assets:prepare-script-assets
                  js-assets recon-data))
         (origins (vovas.engine.panel.assets:build-runtime-origins
                   runtime-entries runtime-manifest assets))
         (boundary-labels (vovas.engine.panel.boundary:build-boundary-labels
                           assets origins))
         (cross-boundary-flows
           (vovas.engine.panel.boundary:build-cross-boundary-flows
            recon-data assets origins))
         (interesting-entrypoints
           (vovas.engine.panel.boundary:collect-interesting-entrypoints
            assets origins))
         (framework-state (vovas.engine.panel.boundary:build-framework-state-summary
                           (let ((v (vovas.engine.panel.assets:field
                                     recon-data "frameworkState")))
                             (and (vovas.engine.panel.model:js-truthy v) v))))
         (analysis (make-hash-table :test #'equal))
         (chunk-map (make-hash-table :test #'equal))
         (runtime-origins (make-hash-table :test #'equal)))
    (setf (gethash "generatedAt" chunk-map)
          (vovas.engine.pipeline:iso8601-now)
          (gethash "summary" chunk-map)
          (analysis-wire (vovas.engine.panel.assets:build-chunk-summary assets))
          (gethash "items" chunk-map)
          (coerce (mapcar (lambda (a) (script-asset-wire a)) assets) 'vector))
    (setf (gethash "generatedAt" runtime-origins)
          (vovas.engine.pipeline:iso8601-now)
          (gethash "summary" runtime-origins)
          (analysis-wire (vovas.engine.panel.assets:build-runtime-summary origins))
          (gethash "items" runtime-origins)
          (coerce (mapcar (lambda (o)
                            (let ((wire (analysis-wire
                                         (vovas.engine.panel.assets:strip-runtime-entry o))))
                              ;; `blobId` is `Value::Null` in the Rust when absent,
                              ;; not CL nil - the writer would omit or falsify it.
                              (when (null (gethash "blobId" wire))
                                (setf (gethash "blobId" wire)
                                      (vovas.engine.panel.model:json-null-symbol)))
                              wire))
                          origins)
                  'vector))
    (setf (gethash "assets" analysis)
          (coerce (mapcar (lambda (a) (script-asset-wire a :with-content t)) assets)
                  'vector)
          (gethash "runtimeRecords" analysis) (coerce origins 'vector)
          (gethash "chunkMap" analysis) chunk-map
          (gethash "moduleGraph" analysis)
          (analysis-wire
           (vovas.engine.panel.graph:build-module-graph recon-data assets origins))
          (gethash "startupChain" analysis)
          (analysis-wire
           (vovas.engine.panel.graph:build-startup-chain recon-data assets origins))
          (gethash "runtimeOrigins" analysis) runtime-origins
          ;; ALL THREE are wired. `crossBoundaryFlows.summary` counts relations
          ;; and event kinds as alists, and `boundaryLabels.summary` counts
          ;; labels the same way - storing either raw leaves a dotted pair for
          ;; the serializer, which signals at export time naming a cons rather
          ;; than the section it came from.
          (gethash "boundaryLabels" analysis) (analysis-wire boundary-labels)
          (gethash "crossBoundaryFlows" analysis) (analysis-wire cross-boundary-flows)
          (gethash "frameworkState" analysis) (analysis-wire framework-state)
          (gethash "frameworkRuntime" analysis)
          ;; WIRED. This section carries `assetClasses` and `runtimeKinds`, which
          ;; are counts ALISTS with dotted pairs like ("chunk" . 4). Storing it
          ;; raw left the serializer holding a cons and it signalled
          ;; "4 is not of type LIST" at export time, far from the cause.
          (analysis-wire
           (vovas.engine.panel.boundary:build-framework-runtime-summary
            recon-data assets origins
            (coerce interesting-entrypoints 'list)
            boundary-labels cross-boundary-flows))
          (gethash "interestingEntrypoints" analysis)
          (coerce interesting-entrypoints 'vector))
    ;; The workspace reads the finished analysis, then its summaries go BACK into
    ;; frameworkRuntime - which is why this is a second pass rather than an
    ;; inline field.
    (let* ((investigation
             (vovas.engine.panel.workspace:build-investigation-workspace analysis))
           (workspaces (let ((v (gethash "workspaces" investigation)))
                         (if (or (vectorp v) (listp v)) (coerce v 'list) '())))
           (journeys (let ((v (gethash "journeys" investigation)))
                       (if (or (vectorp v) (listp v)) (coerce v 'list) '())))
           (framework-runtime (gethash "frameworkRuntime" analysis)))
      (when (hash-table-p framework-runtime)
        (setf (gethash "availableWorkspaces" framework-runtime)
              (coerce
               (mapcar (lambda (workspace)
                         (let ((h (make-hash-table :test #'equal))
                               (summary (vovas.engine.panel.assets:field
                                         workspace "summary")))
                           (setf (gethash "id" h)
                                 (or (vovas.engine.panel.assets:field workspace "id")
                                     (vovas.engine.panel.model:json-null-symbol))
                                 (gethash "title" h)
                                 (or (vovas.engine.panel.assets:field workspace "title")
                                     (vovas.engine.panel.model:json-null-symbol))
                                 (gethash "itemCount" h)
                                 (analysis-summary-number summary "totalItems")
                                 (gethash "transitionCount" h)
                                 (analysis-summary-number summary "transitionCount"))
                           h))
                       workspaces)
               'vector)
              (gethash "availableJourneys" framework-runtime)
              (coerce
               (mapcar (lambda (journey)
                         (let ((h (make-hash-table :test #'equal))
                               (summary (vovas.engine.panel.assets:field
                                         journey "summary")))
                           (setf (gethash "id" h)
                                 (or (vovas.engine.panel.assets:field journey "id")
                                     (vovas.engine.panel.model:json-null-symbol))
                                 (gethash "title" h)
                                 (or (vovas.engine.panel.assets:field journey "title")
                                     (vovas.engine.panel.model:json-null-symbol))
                                 (gethash "eventCount" h)
                                 (analysis-summary-number summary "eventCount")
                                 (gethash "transitionCount" h)
                                 (analysis-summary-number summary "transitionCount"))
                           h))
                       journeys)
               'vector)))
      (setf (gethash "investigation" analysis) investigation))
    analysis))
