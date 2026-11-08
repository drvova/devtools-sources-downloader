;;;; gate-workspace-builders.lisp - the workspace and journey builders.
;;;;
;;;; Six oracle sections cover this tier, and they are unusually well-shaped for
;;;; verification because each one pins a DIFFERENT filter:
;;;;
;;;;   buildBoundaryWorkspace        - one boundary, matches-boundary-entry
;;;;   buildFrameworkStateWorkspace  - five boundaries, matches-ANY-boundary
;;;;   buildFrameworkStateEvents     - the collection fan-out and its 24 cap
;;;;   buildJourneyViews             - four journeys, each a different predicate
;;;;   buildInvestigationWorkspace   - the whole assembly
;;;;   getBoundaryTitle/Questions    - already gated in gate-workspace
;;;;
;;;; The journeys are the interesting case: two of them use a boundary test, one
;;;; uses a relation test, and one uses a kind test, so a single wrong predicate
;;;; shows up in exactly one journey rather than everywhere.

(in-package :vovas.engine.gate)

(defun gate-analysis-fixture ()
  "The analysis object the workspace builders read, built from the fixture's own
inputs through the same pipeline the Rust test uses.

The Rust test calls build_semantic_analysis, but that is the CAPSTONE and not yet
ported; this assembles the same shape from the parts that ARE ported, which is
enough for every workspace section because none of them read the fields analysis
adds beyond what boundary/flow already produce."
  (let* ((fx (read-json-file (fixture-path "panel/boundary-oracle.json")))
         (input (gethash "input" fx))
         (scripts (coerce (gethash "scriptFixture" input) 'list))
         (recon-fixture (gethash "reconFixture" input))
         (recon (let ((c (make-hash-table :test #'equal)))
                  (maphash (lambda (k v) (setf (gethash k c) v)) recon-fixture)
                  (setf (gethash "recon" c) (gethash "recon" input))
                  c))
         (assets (vovas.engine.panel.assets:prepare-script-assets scripts recon-fixture))
         (origins (vovas.engine.panel.assets:build-runtime-origins
                   (coerce (gethash "runtimeEntries" input) 'list)
                   (coerce (gethash "runtimeManifest" input) 'list)
                   assets))
         (report (vovas.engine.panel.boundary:build-boundary-labels assets origins))
         (flows (vovas.engine.panel.boundary:build-cross-boundary-flows
                 recon assets origins))
         (chunk-summary (vovas.engine.panel.assets:build-chunk-summary assets))
         (runtime-summary (vovas.engine.panel.assets:build-runtime-summary origins))
         (analysis (make-hash-table :test #'equal)))
    ;; The analysis shape the workspace tier reads: items arrays, the flow
    ;; report, the boundary report, the entrypoint list and frameworkRuntime.
    (let ((chunk-map (make-hash-table :test #'equal))
          (runtime-origins (make-hash-table :test #'equal)))
      (setf (gethash "summary" chunk-map) chunk-summary
            (gethash "items" chunk-map)
            ;; WIRE-SHAPED, not the plist view: `strip-chunk-asset` returns a
            ;; keyword plist, while every consumer here (`field`,
            ;; `matches-boundary-entry`, and the oracle itself) reads camelCase
            ;; STRING keys. `script-asset->json` is the same mapping the real
            ;; analysis serialises, so it is the faithful choice.
            (coerce (mapcar #'script-asset-wire assets)
                    'vector)
            (gethash "summary" runtime-origins) runtime-summary
            (gethash "items" runtime-origins)
            (coerce (mapcar #'vovas.engine.panel.assets:strip-runtime-entry origins)
                    'vector)
            (gethash "chunkMap" analysis) chunk-map
            (gethash "runtimeOrigins" analysis) runtime-origins))
    (setf (gethash "boundaryLabels" analysis) report
          (gethash "crossBoundaryFlows" analysis) flows
          (gethash "interestingEntrypoints" analysis)
          (vovas.engine.panel.boundary:collect-interesting-entrypoints assets origins)
          (gethash "frameworkState" analysis)
          ;; The fixture carries frameworkState at input.frameworkState, NOT
          ;; under reconFixture - the Rust test passes it into the analysis
          ;; separately. Reading it from recon gave NIL, so the framework-state
          ;; workspace saw no state and produced zero events.
          (vovas.engine.panel.boundary:build-framework-state-summary
           (let ((v (gethash "frameworkState" input)))
             (and (vovas.engine.panel.model:js-truthy v) v)))
          (gethash "frameworkRuntime" analysis)
          (vovas.engine.panel.boundary:build-framework-runtime-summary
           recon assets origins
           (coerce (vovas.engine.panel.boundary:collect-interesting-entrypoints
                    assets origins) 'list)
           report flows))
    analysis))

(defun run-workspace-builders-gate (&key (verbose t))
  (let* ((result (make-gate-result))
         (count 0)
         (fx (read-json-file (fixture-path "panel/boundary-oracle.json")))
         (exp (gethash "expected" fx))
         (analysis (gate-analysis-fixture)))

    ;; ---- buildBoundaryWorkspace -----------------------------------------
    ;;
    ;; Four cases, each a different boundary: one with content in every
    ;; collection, the ones with partial content, and an unknown label to pin
    ;; the generic title/description fallbacks.
    (let ((want (gethash "buildBoundaryWorkspace" exp)))
      (loop for index below (length want)
            for case = (aref want index)
            for boundary = (coerce (gethash "id" case) 'string)
            do (incf count)
               (check result (format nil "boundaryWorkspace/~a" boundary) "workspace"
                      (and (gate-json=
                            (vovas.engine.panel.workspace:build-boundary-workspace
                             boundary analysis)
                            case)
                           t)
                      t)))

    ;; ---- buildFrameworkStateEvents --------------------------------------
    ;; The oracle key holds TWO cases, and the ORDER is populated-then-null:
    ;; index 0 is the event list for the fixture's framework state, index 1 is
    ;; the empty list for a null state. (Verified against the oracle: index 0
    ;; carries the six framework-* events, index 1 is empty.)
    (let ((cases (gethash "buildFrameworkStateEvents" exp)))
      (incf count)
      (check result "frameworkStateEvents/null" "events"
             (length (vovas.engine.panel.workspace:build-framework-state-events nil))
             (length (aref cases 1)))
      (let ((want (aref cases 0))
            (got (vovas.engine.panel.workspace:build-framework-state-events
                  (gethash "frameworkState" analysis))))
        (incf count)
        (check result "frameworkStateEvents/count" "count"
               (length got) (length want))
        (incf count)
        (check result "frameworkStateEvents/content" "events"
               (and (gate-json= (coerce got 'vector) (coerce want 'vector)) t)
               t)))

    ;; ---- buildFrameworkStateWorkspace -----------------------------------
    ;; ALL FIVE focus boundaries must exist as workspaces, not just one:
    ;; `supportingWorkspaces` walks the focus list and picks each matching
    ;; workspace, so passing only bootstrap makes four of five vanish and the
    ;; field reads 1-vs-5 for a correct implementation.
    (let ((want (gethash "buildFrameworkStateWorkspace" exp))
          (workspaces
            (coerce (mapcar (lambda (b)
                              (vovas.engine.panel.workspace:build-boundary-workspace
                               b analysis))
                            '("bootstrap" "router" "state" "data" "auth"))
                    'list)))
      (incf count)
      (check result "frameworkStateWorkspace" "workspace"
             (and (gate-json=
                   (vovas.engine.panel.workspace:build-framework-state-workspace
                    analysis (coerce workspaces 'list))
                   want)
                  t)
             t))

    ;; ---- buildJourneyViews ----------------------------------------------
    ;;
    ;; Each journey uses a DIFFERENT transition predicate, so this compares them
    ;; one at a time - a single mismatched journey names its own predicate.
    (let* ((workspaces (let ((out '()))
                         (dolist (category vovas.engine.panel.boundary:*boundary-labels*)
                           (push (vovas.engine.panel.workspace:build-boundary-workspace
                                  category analysis)
                                 out))
                         (nreverse out)))
           (workspaces (append workspaces
                               (list (vovas.engine.panel.workspace:build-framework-state-workspace
                                      analysis workspaces))))
           (got (vovas.engine.panel.workspace:build-journey-views analysis workspaces))
           (want (gethash "buildJourneyViews" exp)))
      (incf count)
      (check result "journeyViews/count" "count" (length got) (length want))
      (loop for index below (min (length got) (length want))
            do (incf count)
               (check result (format nil "journeyViews/~a"
                                     (vovas.engine.panel.assets:field-str (aref got index) "id"))
                      "journey"
                      (and (gate-json= (aref got index) (aref want index)) t)
                      t)))

    (when verbose
      (format t "~&workspace builders gate: ~a/~a cases match~%"
              (gate-result-passed result) (gate-result-total result))
      (report-failures result))

    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp count))))

;;; ---------------------------------------------------------------------------
;;; buildInvestigationWorkspace
;;;
;;; The whole assembly: 8 boundary workspaces (one per registry label), the
;;; framework-state workspace appended as the 9th, and the four journeys.
;;;
;;; This runs against the SAME reconstructed analysis as the sections above. The
;;; Rust test drives it through build_semantic_analysis, which is not yet ported -
;;; so a failure here is evidence about the workspace code against a fixture
;;; shape, not against the capstone. It gets re-run through the real capstone
;;; once build-semantic-analysis lands.
;;; ---------------------------------------------------------------------------

(defun run-investigation-workspace-gate (&key (verbose t))
  (let* ((result (make-gate-result))
         (count 0)
         (fx (read-json-file (fixture-path "panel/boundary-oracle.json")))
         (want (gethash "buildInvestigationWorkspace" (gethash "expected" fx)))
         (analysis (gate-analysis-fixture))
         (got (vovas.engine.panel.workspace:build-investigation-workspace analysis)))

    ;; `generatedAt` is a clock: stripped from both sides.
    (let ((gc (gate-without-generated-at got))
          (wc (gate-without-generated-at want)))
      (dolist (key '("page" "profile" "summary"))
        (incf count)
        (check result (format nil "investigation/~a" key) "field"
               (and (gate-json= (gethash key gc) (gethash key wc)) t)
               t))

      ;; ---- workspaces, one at a time so a failure names its boundary -----
      (let ((gw (gethash "workspaces" gc))
            (ww (gethash "workspaces" wc)))
        (incf count)
        (check result "investigation/workspaces/count" "count"
               (length gw) (length ww))
        (incf count)
        (check result "investigation/workspaces/ids" "ids"
               (and (gate-json= (coerce (mapcar (lambda (w) (vovas.engine.panel.assets:field-str w "id"))
                                                (coerce gw 'list))
                                        'vector)
                                (coerce (mapcar (lambda (w) (vovas.engine.panel.assets:field-str w "id"))
                                                (coerce ww 'list))
                                        'vector))
                    t)
               t)
        (loop for index below (min (length gw) (length ww))
              do (incf count)
                 (check result (format nil "investigation/workspaces/~a"
                                       (vovas.engine.panel.assets:field-str (aref gw index) "id"))
                        "workspace"
                        (and (gate-json= (aref gw index) (aref ww index)) t)
                        t)))

      ;; ---- journeys ------------------------------------------------------
      (let ((gj (gethash "journeys" gc))
            (wj (gethash "journeys" wc)))
        (incf count)
        (check result "investigation/journeys/count" "count"
               (length gj) (length wj))
        (loop for index below (min (length gj) (length wj))
              do (incf count)
                 (check result (format nil "investigation/journeys/~a"
                                       (vovas.engine.panel.assets:field-str (aref gj index) "id"))
                        "journey"
                        (and (gate-json= (aref gj index) (aref wj index)) t)
                        t))))

    (when verbose
      (format t "~&investigation workspace gate: ~a/~a cases match~%"
              (gate-result-passed result) (gate-result-total result))
      (report-failures result))

    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp count))))

;;; ---------------------------------------------------------------------------
;;; script-asset-wire
;;;
;;; `script-asset->json` in `boundary` is the INFERENCE view: it carries the
;;; fields the boundary rules read and deliberately omits the rest. The analysis
;;; object carries the full serde shape - 19 keys including `bundler`,
;;; `startTime`, `moduleSignals` and `sourceMapEmbedded` - because
;;; `buildBoundaryWorkspace` passes chunks straight through to the report.
;;;
;;; Using the inference view here made every chunk look wrong (8 missing keys and
;;; 4 extra) while the boundary logic was fine. This is the faithful projection.
;;; ---------------------------------------------------------------------------

(defun gate-js-number (value)
  "The JSON number a double should print as: integral in range -> integer."
  (let ((v (coerce (or value 0d0) 'double-float)))
    (if (and (zerop (nth-value 1 (truncate v))) (< (abs v) 9007199254740992d0))
        (truncate v)
        v)))

(defun script-asset-wire (asset)
  "A `script-asset` in the 19-key wire shape the analysis serialises."
  (let ((out (make-hash-table :test #'equal))
        (signals (vovas.engine.panel.assets:script-asset-module-signals asset)))
    (setf (gethash "id" out) (vovas.engine.panel.assets:script-asset-id asset)
          (gethash "url" out) (vovas.engine.panel.assets:script-asset-url asset)
          (gethash "file" out) (vovas.engine.panel.assets:script-asset-file asset)
          (gethash "size" out) (vovas.engine.panel.assets:script-asset-size asset)
          (gethash "transferSize" out)
          (gate-js-number (vovas.engine.panel.assets:script-asset-transfer-size asset))
          (gethash "startTime" out)
          (gate-js-number (vovas.engine.panel.assets:script-asset-start-time asset))
          (gethash "duration" out)
          (gate-js-number (vovas.engine.panel.assets:script-asset-duration asset))
          (gethash "classification" out)
          (vovas.engine.panel.assets:script-asset-classification asset)
          (gethash "bundler" out) (vovas.engine.panel.assets:script-asset-bundler asset)
          (gethash "frameworkHints" out)
          (coerce (vovas.engine.panel.assets:script-asset-framework-hints asset) 'vector)
          (gethash "routeHints" out)
          (coerce (vovas.engine.panel.assets:script-asset-route-hints asset) 'vector)
          (gethash "startupSignals" out)
          (coerce (vovas.engine.panel.assets:script-asset-startup-signals asset) 'vector)
          (gethash "boundaryLabels" out)
          (coerce (vovas.engine.panel.assets:script-asset-boundary-labels asset) 'vector)
          (gethash "primaryBoundary" out)
          (vovas.engine.panel.assets:script-asset-primary-boundary asset)
          (gethash "boundaryReasons" out)
          (coerce (vovas.engine.panel.assets:script-asset-boundary-reasons asset) 'vector)
          (gethash "imports" out)
          (coerce (vovas.engine.panel.assets:script-asset-imports asset) 'vector)
          (gethash "sourceMapEmbedded" out)
          (and (vovas.engine.panel.assets:script-asset-source-map-embedded asset) t)
          (gethash "score" out)
          (gate-js-number (vovas.engine.panel.assets:script-asset-score asset)))
    (let ((ms (make-hash-table :test #'equal)))
      (setf (gethash "importCount" ms)
            (vovas.engine.panel.assets:module-signals-import-count signals)
            (gethash "dynamicImports" ms)
            (vovas.engine.panel.assets:module-signals-dynamic-imports signals)
            (gethash "requires" ms)
            (vovas.engine.panel.assets:module-signals-requires signals)
            (gethash "exports" ms)
            (vovas.engine.panel.assets:module-signals-exports signals))
      (setf (gethash "moduleSignals" out) ms))
    out))
