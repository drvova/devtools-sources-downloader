;;;; gate-boundary.lisp - the boundary predicate tier.
;;;;
;;;; WHAT THIS GATE CAN AND CANNOT PROVE.
;;;;
;;;; The boundary oracle carries `matchesBoundaryEntry`, `chainTouchesBoundary`
;;;; and `arrayTouchesAny` result vectors, but NOT the inputs that produced
;;;; them - unlike every other oracle key, no capture script recorded the probe
;;;; arguments, and the Rust tests never assert those three keys at all. So the
;;;; values are unusable as an oracle: reconstructing inputs to match a known
;;;; answer would be writing the test to fit the code.
;;;;
;;;; What IS usable is `taggedAssets`, which records, for each of the four
;;;; fixture chunks, its id, its primary boundary and its full label list as the
;;;; real pipeline produced them. That is ground truth for the predicates in
;;;; both directions: a label present must match, and every label absent must
;;;; not. That is what this gate asserts, plus the structural rules the
;;;; predicates are specified by (path-only chains, absent-entry tolerance).

(in-package :vovas.engine.gate)

(defun run-boundary-gate (&key (verbose t))
  (let* ((result (make-gate-result))
         (count 0)
         (fx (read-json-file (fixture-path "panel/boundary-oracle.json")))
         (exp (gethash "expected" fx))
         (tagged (gethash "taggedAssets" exp))
         (all-labels '("bootstrap" "router" "state" "data" "auth"
                       "analytics" "editor" "vendor")))

    ;; --------------------------------------------------------------------
    ;; The label registry the report walks. Order is load-bearing: the
    ;; category list is built by walking it, so a missing label silently
    ;; drops a category from the report.
    ;; --------------------------------------------------------------------
    (incf count)
    (check result "boundary-labels/registry" "labels"
           vovas.engine.panel.boundary:*boundary-labels*
           all-labels)

    ;; --------------------------------------------------------------------
    ;; taggedAssets as ground truth: every recorded label matches, and no
    ;; OTHER label does. This is the pair that makes the assertion
    ;; non-vacuous - a predicate that answered T for everything would pass
    ;; the first half and fail the second.
    ;; --------------------------------------------------------------------
    (loop for entry across tagged
          do (let* ((items (coerce entry 'list))
                    (id (first items))
                    (primary (second items))
                    (labels (coerce (third items) 'list))
                    (ht (ht "id" id
                            "primaryBoundary" primary
                            "boundaryLabels" (coerce labels 'vector))))
               ;; the primary boundary must match
               (incf count)
               (check result (format nil "matches/~a/primary=~a" id primary) "bool"
                      (and (vovas.engine.panel.boundary:matches-boundary-entry
                            ht primary) t)
                      t)
               ;; every listed label must match
               (loop for label in labels
                     do (incf count)
                        (check result (format nil "matches/~a/label=~a" id label) "bool"
                               (and (vovas.engine.panel.boundary:matches-boundary-entry
                                     ht label) t)
                               t))
               ;; and every label NOT listed must not match
               (dolist (label all-labels)
                 (unless (member label labels :test #'string=)
                   (incf count)
                   (check result (format nil "no-match/~a/absent=~a" id label) "bool"
                          (and (vovas.engine.panel.boundary:matches-boundary-entry
                                ht label) t)
                          nil)))))

    ;; --------------------------------------------------------------------
    ;; chainTouchesBoundary reads the PATH only. A chain whose endpoints are
    ;; labeled but whose path omits the boundary does not touch it - the
    ;; path is what the workspace renders as the crossing.
    ;; --------------------------------------------------------------------
    (let ((chain (ht "from" (ht "primaryBoundary" "auth")
                     "to" (ht "primaryBoundary" "data")
                     "path" (vector "bootstrap" "router"))))
      (incf count)
      (check result "chain/path-hit" "bool"
             (and (vovas.engine.panel.boundary:chain-touches-boundary chain "router") t) t)
      (incf count)
      (check result "chain/endpoint-is-not-path" "bool"
             (and (vovas.engine.panel.boundary:chain-touches-boundary chain "auth") t) nil)
      (incf count)
      (check result "chain/absent-boundary" "bool"
             (and (vovas.engine.panel.boundary:chain-touches-boundary chain "vendor") t) nil))

    ;; --------------------------------------------------------------------
    ;; Absent / non-object inputs answer NIL rather than signalling. The
    ;; walkers pass whatever they found, so every predicate must be total.
    ;; --------------------------------------------------------------------
    (dolist (empty (list nil 0 "" (ht)))
      (incf count)
      (check result (format nil "total/matches/~s" (type-of empty)) "bool"
             (and (vovas.engine.panel.boundary:matches-boundary-entry empty "auth") t) nil)
      (incf count)
      (check result (format nil "total/chain/~s" (type-of empty)) "bool"
             (and (vovas.engine.panel.boundary:chain-touches-boundary empty "auth") t) nil)
      (incf count)
      (check result (format nil "total/flow/~s" (type-of empty)) "bool"
             (and (vovas.engine.panel.boundary:flow-touches-boundary empty "auth") t) nil))

    ;; --------------------------------------------------------------------
    ;; arrayContainsAny: exact, case-sensitive membership.
    ;; --------------------------------------------------------------------
    (incf count)
    (check result "array/hit" "bool"
           (and (vovas.engine.panel.boundary:array-contains-any
                 '("data" "auth") '("auth")) t) t)
    (incf count)
    (check result "array/miss" "bool"
           (and (vovas.engine.panel.boundary:array-contains-any
                 '("data" "auth") '("router")) t) nil)
    (incf count)
    (check result "array/case-sensitive" "bool"
           (and (vovas.engine.panel.boundary:array-contains-any
                 '("data") '("DATA")) t) nil)
    (incf count)
    (check result "array/empty-candidates" "bool"
           (and (vovas.engine.panel.boundary:array-contains-any '("data") '()) t) nil)

    ;; --------------------------------------------------------------------
    ;; flowTouchesAnyBoundary / matchesAnyBoundary walk a boundary list.
    ;; An absent flow answers NIL even when the list is non-empty.
    ;; --------------------------------------------------------------------
    (let ((flow (ht "fromBoundary" "auth" "toBoundary" "data")))
      (incf count)
      (check result "flow-any/hit" "bool"
             (and (vovas.engine.panel.boundary:flow-touches-any-boundary
                   flow '("router" "data")) t) t)
      (incf count)
      (check result "flow-any/miss" "bool"
             (and (vovas.engine.panel.boundary:flow-touches-any-boundary
                   flow '("router" "vendor")) t) nil)
      (incf count)
      (check result "flow-any/absent-flow" "bool"
             (and (vovas.engine.panel.boundary:flow-touches-any-boundary
                   nil '("auth")) t) nil)
      (incf count)
      (check result "matches-any/hit" "bool"
             (and (vovas.engine.panel.boundary:matches-any-boundary
                   (ht "boundaryLabels" (vector "vendor")) '("router" "vendor")) t) t))

    (when verbose
      (format t "~&boundary gate: ~a/~a cases match~%"
              (gate-result-passed result) (gate-result-total result))
      (report-failures result))

    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp count))))

;;; ---------------------------------------------------------------------------
;;; The label-inference tier
;;;
;;; Unlike the predicate tier, THIS one has reproducible inputs: the Rust test
;;; spells out all thirteen probe entries, the three runtime probes and the apply
;;; target. So the oracle values are usable as oracles here, and this section is
;;; the real proof of the labeling rules.
;;; ---------------------------------------------------------------------------

(defun gate-json= (got want)
  "Deep equality between a port value and a JZON oracle value.

JZON gives vectors for JSON arrays and a symbol for null, while the port builds
vectors and hash tables. Scalars compare through `equal`; numbers compare by
VALUE across the integer/double boundary, because a score of 24 arrives as a JSON
integer and is produced as an integer, but a fixture may carry 24.0."
  (cond
    ((and (or (vectorp got) (listp got)) (or (vectorp want) (listp want)))
     (let ((g (coerce got 'list)) (w (coerce want 'list)))
       (and (= (length g) (length w))
            (every #'gate-json= g w))))
    ((and (hash-table-p got) (hash-table-p want))
     (and (= (hash-table-count got) (hash-table-count want))
          (loop for k being the hash-keys of want
                always (and (nth-value 1 (gethash k got))
                            (gate-json= (gethash k got) (gethash k want))))))
    ((and (numberp got) (numberp want)) (= got want))
    ((and (stringp got) (stringp want)) (string= got want))
    ((and (null got) (hash-table-p want) (zerop (hash-table-count want))) t)
    (t (equal got want))))

(defun run-boundary-label-gate (&key (verbose t))
  (let* ((result (make-gate-result))
         (count 0)
         (fx (read-json-file (fixture-path "panel/boundary-oracle.json")))
         (exp (gethash "expected" fx))
         (empty-map (make-hash-table :test #'equal)))

    ;; ---- buildBoundarySample -------------------------------------------
    ;;
    ;; Sample 0 is a LENGTH, not a string: the Rust asserts utf16_len. Sample 1
    ;; is the empty sample, which is twelve newlines - thirteen empty fields and
    ;; twelve separators. Both are pinned because a naive "join the non-empty
    ;; parts" would give "" and silently change every pattern's chances.
    (let* ((sample-entry (ht "url" "https://demo.test/A.JS" "file" "F.js"
                             "kind" "eval" "source" "Src" "originType" "ot"
                             "classification" "app"
                             "frameworkHints" (vector "React")
                             "routeHints" (vector "app")
                             "startupSignals" (vector "hydration")
                             "imports" (vector "react")
                             "note" "N" "mimeType" "M" "stack" "S"
                             "content" "CONTENT" "text" "TEXT"))
           (sample-want (gethash "buildBoundarySample" exp)))
      (incf count)
      (check result "buildBoundarySample/length" "utf16 length"
             (vovas.engine.util:utf16-length
              (vovas.engine.panel.boundary:build-boundary-sample sample-entry))
             (aref sample-want 0))
      (incf count)
      (check result "buildBoundarySample/empty" "sample"
             (vovas.engine.panel.boundary:build-boundary-sample nil)
             (coerce (aref sample-want 1) 'string)))

    ;; ---- the thirteen label probes --------------------------------------
    (let ((entries (list
                     (ht)
                     (ht "classification" "runtime" "url" "https://x/runtime.js")
                     (ht "classification" "vendor" "url" "https://x/vendor.js")
                     (ht "classification" "framework" "url" "https://x/app.js")
                     (ht "url" "https://x/a.js" "routeHints" (vector "app"))
                     (ht "url" "https://x/a.js" "startupSignals" (vector "chunk-loader"))
                     (ht "url" "https://x/a.js" "content" "redux createStore dispatch(x)")
                     (ht "url" "https://x/a.js" "content" "axios.get(\"/api/x\")")
                     (ht "url" "https://x/a.js" "content" "localStorage token signin()")
                     (ht "url" "https://x/a.js" "content" "gtag(\"event\")")
                     (ht "url" "https://x/a.js" "content" "monaco.editor.create()")
                     (ht "url" "https://x/a.js" "content" "node_modules/core-js polyfill")
                     (ht "kind" "worker" "url" "blob:https://x/w")))
          (want (gethash "inferBoundaryLabels" exp)))
      (loop for entry in entries
            for index from 0
            do (incf count)
               (check result (format nil "inferBoundaryLabels/~a" index) "matches"
                      (and (gate-json=
                            (vovas.engine.panel.boundary:infer-boundary-labels
                             entry :is-runtime nil :classifications empty-map)
                            (aref want index))
                           t)
                      t)))

    ;; ---- the three runtime probes ---------------------------------------
    ;;
    ;; These prove the is-runtime branches: a worker kind bootstraps, a runtime
    ;; spawned from a vendor chunk is vendor-by-parentage at score 16, and one
    ;; spawned from an app chunk earns nothing.
    (let ((entries (list
                     (ht "kind" "worker" "url" "blob:https://x/w")
                     (ht "kind" "eval" "relatedChunks" (vector "vendor-1"))
                     (ht "kind" "eval" "relatedChunks" (vector "app-1"))))
          (map (let ((m (make-hash-table :test #'equal)))
                 (setf (gethash "vendor-1" m) "vendor"
                       (gethash "app-1" m) "app")
                 m))
          (want (gethash "inferBoundaryLabelsRuntime" exp)))
      (loop for entry in entries
            for index from 0
            do (incf count)
               (check result (format nil "inferBoundaryLabels/runtime/~a" index) "matches"
                      (and (gate-json=
                            (vovas.engine.panel.boundary:infer-boundary-labels
                             entry :is-runtime t :classifications map)
                            (aref want index))
                           t)
                      t)))

    ;; ---- applyBoundaryLabels --------------------------------------------
    ;;
    ;; The pinned case has BOTH state and data at 24, and primaryBoundary is
    ;; "state" - which only holds if the sort is stable and the insertion order
    ;; survives. That makes this case a stability test, not just a merge test.
    (let ((target (ht "url" "https://x/a.js"
                      "content" "axios.get(\"/api/x\") redux dispatch(x)")))
      (vovas.engine.panel.boundary:apply-boundary-labels
       target
       (vovas.engine.panel.boundary:infer-boundary-labels
        target :is-runtime nil :classifications empty-map))
      (let ((want (gethash "applyBoundaryLabels" exp)))
        (dolist (key '("url" "content" "boundaryLabels" "primaryBoundary"
                       "boundaryReasons" "boundaryDetails"))
          (incf count)
          (check result (format nil "applyBoundaryLabels/~a" key) "field"
                 (gate-json= (gethash key target) (gethash key want))
                 t))))

    (when verbose
      (format t "~&boundary label gate: ~a/~a cases match~%"
              (gate-result-passed result) (gate-result-total result))
      (report-failures result))

    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp count))))

;;; ---------------------------------------------------------------------------
;;; buildBoundaryLabels - the whole tier, end to end
;;;
;;; This one runs the FIXTURE'S OWN INPUTS through the real pipeline:
;;; prepare-script-assets, then build-runtime-origins, then the labeling. So it
;;; exercises classification, the runtime origin types and the label rules
;;; together, and compares against a report the shipped engine produced from the
;;; same inputs.
;;;
;;; The oracle omits `generatedAt` (it is a clock), so that key is dropped from
;;; the comparison on both sides rather than being faked.
;;; ---------------------------------------------------------------------------

(defun run-boundary-report-gate (&key (verbose t))
  (let* ((result (make-gate-result))
         (count 0)
         (fx (read-json-file (fixture-path "panel/boundary-oracle.json")))
         (input (gethash "input" fx))
         (want (gethash "buildBoundaryLabels" (gethash "expected" fx)))
         (scripts (coerce (gethash "scriptFixture" input) 'list))
         (recon-fixture (gethash "reconFixture" input))
         (entries (coerce (gethash "runtimeEntries" input) 'list))
         (manifest (coerce (gethash "runtimeManifest" input) 'list))
         (assets (vovas.engine.panel.assets:prepare-script-assets scripts recon-fixture))
         (origins (vovas.engine.panel.assets:build-runtime-origins
                   entries manifest assets))
         (got (vovas.engine.panel.boundary:build-boundary-labels assets origins)))

    ;; ---- categories ------------------------------------------------------
    (incf count)
    (check result "buildBoundaryLabels/categories" "labels"
           (and (gate-json= (gethash "categories" got) (gethash "categories" want)) t)
           t)

    ;; ---- summary ---------------------------------------------------------
    ;;
    ;; Four numbers and two count maps. The maps are compared as ALISTS so the
    ;; comparison does not depend on hash iteration order - the wire order comes
    ;; from insertion, which `counts-alist` provides.
    (let ((gs (gethash "summary" got))
          (ws (gethash "summary" want)))
      (dolist (key '("taggedChunks" "taggedRuntime"))
        (incf count)
        (check result (format nil "buildBoundaryLabels/summary/~a" key) "count"
               (gethash key gs) (gethash key ws)))
      (dolist (key '("chunkLabels" "runtimeLabels"))
        (incf count)
        (check result (format nil "buildBoundaryLabels/summary/~a" key) "counts"
               (and (gate-json=
                     ;; the port keeps counts as an insertion-ordered ALIST; the
                     ;; oracle has a JSON object. Convert rather than compare
                     ;; across shapes, so a missing or extra label is a diff.
                     (let ((h (make-hash-table :test #'equal)))
                       (dolist (pair (gethash key gs))
                         (setf (gethash (car pair) h) (cdr pair)))
                       h)
                     (gethash key ws))
                    t)
               t)))

    ;; ---- chunks ----------------------------------------------------------
    ;;
    ;; Sorted by score descending, and the fixture has TIES - so this also pins
    ;; that the sort is stable, the same property the apply case pins.
    (let ((gc (gethash "chunks" got))
          (wc (gethash "chunks" want)))
      (incf count)
      (check result "buildBoundaryLabels/chunks/count" "count"
             (length gc) (length wc))
      (loop for index below (min (length gc) (length wc))
            do (incf count)
               (check result (format nil "buildBoundaryLabels/chunks/~a" index)
                      "chunk"
                      (and (gate-json= (aref gc index) (aref wc index)) t)
                      t)))

    ;; ---- runtime ---------------------------------------------------------
    (let ((gr (gethash "runtime" got))
          (wr (gethash "runtime" want)))
      (incf count)
      (check result "buildBoundaryLabels/runtime/count" "count"
             (length gr) (length wr))
      (loop for index below (min (length gr) (length wr))
            do (incf count)
               (check result (format nil "buildBoundaryLabels/runtime/~a" index)
                      "runtime"
                      (and (gate-json= (aref gr index) (aref wr index)) t)
                      t)))

    (when verbose
      (format t "~&boundary report gate: ~a/~a cases match~%"
              (gate-result-passed result) (gate-result-total result))
      (report-failures result))

    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp count))))

;;; ---------------------------------------------------------------------------
;;; collectInterestingEntrypoints
;;;
;;; Six pinned entries from the fixture's own pipeline output. The oracle fixes
;;; the ORDER as well as the contents, so this gates the two-key sort (score
;;; descending, then timestamp ascending) rather than just the field mapping.
;;; ---------------------------------------------------------------------------

(defun run-boundary-entrypoints-gate (&key (verbose t))
  (let* ((result (make-gate-result))
         (count 0)
         (fx (read-json-file (fixture-path "panel/boundary-oracle.json")))
         (input (gethash "input" fx))
         (want (gethash "collectInterestingEntrypoints" (gethash "expected" fx)))
         (scripts (coerce (gethash "scriptFixture" input) 'list))
         (recon-fixture (gethash "reconFixture" input))
         (assets (vovas.engine.panel.assets:prepare-script-assets scripts recon-fixture))
         (origins (vovas.engine.panel.assets:build-runtime-origins
                   (coerce (gethash "runtimeEntries" input) 'list)
                   (coerce (gethash "runtimeManifest" input) 'list)
                   assets))
         ;; Labeling FIRST, exactly as the Rust test does: the entrypoint rows
         ;; report primaryBoundary and boundaryLabels, which prepare-script-assets
         ;; leaves empty and build-boundary-labels fills in.
         (_labels (vovas.engine.panel.boundary:build-boundary-labels assets origins))
         (got (vovas.engine.panel.boundary:collect-interesting-entrypoints
               assets origins)))

    (declare (ignore _labels))

    ;; The labeling has to run first: entrypoints report primaryBoundary and
    ;; boundaryLabels, which `prepare-script-assets` leaves empty. The Rust test
    ;; calls build_boundary_labels before this, so the gate does too.
    (incf count)
    (check result "collectInterestingEntrypoints/count" "count"
           (length got) (length want))

    (loop for index below (min (length got) (length want))
          do (incf count)
             (check result (format nil "collectInterestingEntrypoints/~a" index)
                    "entrypoint"
                    (and (gate-json= (aref got index) (aref want index)) t)
                    t))

    (when verbose
      (format t "~&boundary entrypoints gate: ~a/~a cases match~%"
              (gate-result-passed result) (gate-result-total result))
      (report-failures result))

    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp count))))

;;; ---------------------------------------------------------------------------
;;; buildFrameworkStateSummary + collectFrameworkArtifactPaths
;;;
;;; The fixture's technologies array is deliberately messy - a duplicate, an
;;; empty object and a JSON null - so this gates the dedup, the truthiness filter
;;; on each item, and the drop of empty names all at once.
;;;
;;; It also gates the PRESENCE rule that couples the writer to the index:
;;; `hydration` is an empty array, so hydrationCount is 0 AND
;;; _framework/hydration-payloads.json is absent from relatedArtifacts. An
;;; implementation that treated an empty array as present would list a file that
;;; was never written.
;;; ---------------------------------------------------------------------------

(defun gate-framework-state-fixture ()
  "The exact framework_state the Rust test builds, including its awkward entries.

The `null` member is JZON's null SYMBOL, not CL NIL: a CL NIL inside a vector
would read as \"no name\" through js-truthy anyway, but it is not the same value
the JSON parser produces, and the point of this fixture is to feed the port what
the engine saw."
  (let ((technologies (vector (ht "name" "Next.js")
                              (ht "name" "Next.js")
                              (ht)
                              (intern "NULL" :com.inuoe.jzon))))
    (ht "profile" "next"
        "generatedAt" "2026-01-01T00:00:00.000Z"
        "reason" "why"
        "roots" (vector 1 2)
        "stores" (vector 1)
        "queries" (vector 1 2 3)
        "hydration" #()
        "auth" (vector 1)
        "router" (ht "framework" "next" "route" "/a" "source" "x"
                     "queryKeys" (vector "q"))
        "summary" (ht "routerFramework" "fallback"
                      "detectedTechnologies" (vector "Redux"))
        "technologies" technologies)))

(defun run-framework-state-gate (&key (verbose t))
  (let* ((result (make-gate-result))
         (count 0)
         (fx (read-json-file (fixture-path "panel/boundary-oracle.json")))
         (exp (gethash "expected" fx))
         (state (gate-framework-state-fixture))
         (got (vovas.engine.panel.boundary:build-framework-state-summary state)))

    ;; ---- the full summary ------------------------------------------------
    (let ((want (gethash "buildFrameworkStateSummary" exp)))
      (dolist (key '("profile" "generatedAt" "reason" "rootCount" "storeCount"
                     "queryCount" "hydrationCount" "authCount"
                     "routerFramework" "route" "routerSource" "queryKeyCount"))
        (incf count)
        (check result (format nil "frameworkState/~a" key) "field"
               (and (gate-json= (gethash key got) (gethash key want)) t)
               t))
      (dolist (key '("detectedTechnologies" "roots" "stores" "queries"
                     "hydration" "auth" "relatedArtifacts"))
        (incf count)
        (check result (format nil "frameworkState/~a" key) "slice"
               (and (gate-json= (gethash key got) (gethash key want)) t)
               t)))

    ;; ---- the null branch -------------------------------------------------
    ;;
    ;; A non-truthy state answers JSON null, not an empty summary - the caller
    ;; uses that to tell "no framework state" from "empty framework state".
    ;;
    ;; The comparison NORMALISES both sides: JZON parses null to its own symbol
    ;; while the port answers CL NIL, and `(equal nil <symbol>)` is false - which
    ;; would read as a wrong answer rather than a null.
    (incf count)
    (check result "frameworkState/null" "null"
           (json-null (vovas.engine.panel.boundary:build-framework-state-summary nil))
           (json-null (gethash "buildFrameworkStateSummaryNull" exp)))

    ;; ---- collectFrameworkArtifactPaths ----------------------------------
    (incf count)
    (check result "artifactPaths/present" "paths"
           (and (gate-json=
                 (coerce (vovas.engine.panel.paths:collect-framework-artifact-paths state)
                         'vector)
                 (gethash "collectFrameworkArtifactPaths" exp))
                t)
           t)
    (incf count)
    (check result "artifactPaths/empty-state" "paths"
           (length (vovas.engine.panel.paths:collect-framework-artifact-paths
                    (ht)))
           (length (gethash "collectFrameworkArtifactPathsEmpty" exp)))

    (when verbose
      (format t "~&framework state gate: ~a/~a cases match~%"
              (gate-result-passed result) (gate-result-total result))
      (report-failures result))

    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp count))))
