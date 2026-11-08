;;;; gate-analysis.lisp - the capstone, against the oracle.
;;;;
;;;; This is the section that retires the reconstruction problem: until now every
;;;; workspace assertion ran against an analysis object I assembled by hand, and
;;;; five of six debugging rounds were spent on that harness rather than on the
;;;; port. Here the analysis is the REAL one, produced by
;;;; build-semantic-analysis from the fixture's own inputs.
;;;;
;;;; Two clock keys need stripping (`chunkMap.generatedAt`,
;;;; `runtimeOrigins.generatedAt`) as well as the analysis-level ones, because the
;;;; engine stamps each section separately.

(in-package :vovas.engine.gate)

(defun gate-strip-clocks (table)
  "TABLE with every `generatedAt` removed, at the top level and one level down.

The chunk map and the runtime origins each carry their own timestamp, so a check
that only stripped the top level still compared two clocks and failed on them."
  (let ((out (make-hash-table :test #'equal)))
    (when (hash-table-p table)
      (maphash (lambda (k v)
                 (unless (string= k "generatedAt")
                   (setf (gethash k out)
                         (if (hash-table-p v)
                             (gate-strip-clocks v)
                             v))))
               table))
    out))

(defun run-analysis-gate (&key (verbose t))
  (let* ((result (make-gate-result))
         (count 0)
         (fx (read-json-file (fixture-path "panel/boundary-oracle.json")))
         (input (gethash "input" fx))
         (want (gethash "buildSemanticAnalysis" (gethash "expected" fx)))
         (scripts (coerce (gethash "scriptFixture" input) 'list))
         (recon-fixture (gethash "reconFixture" input))
         ;; `prepared()` in the Rust test splices input["recon"] into the fixture
         ;; and passes THAT as recon_data.
         (recon (let ((c (make-hash-table :test #'equal)))
                  (maphash (lambda (k v) (setf (gethash k c) v)) recon-fixture)
                  (setf (gethash "recon" c) (gethash "recon" input))
                  ;; the Rust test also passes frameworkState through recon_data
                  (setf (gethash "frameworkState" c) (gethash "frameworkState" input))
                  c))
         (got (vovas.engine.panel.analysis:build-semantic-analysis
               scripts recon
               (coerce (gethash "runtimeEntries" input) 'list)
               (coerce (gethash "runtimeManifest" input) 'list))))

    ;; ---- the twelve top-level sections, one at a time --------------------
    (let ((gc (gate-strip-clocks got))
          (wc (gate-strip-clocks want)))
      (dolist (key '("assets" "runtimeRecords" "chunkMap" "moduleGraph"
                     "startupChain" "runtimeOrigins" "boundaryLabels"
                     "crossBoundaryFlows" "frameworkState" "frameworkRuntime"
                     "interestingEntrypoints" "investigation"))
        (incf count)
        (check result (format nil "analysis/~a" key) "section"
               (and (gate-json= (gethash key gc) (gethash key wc)) t)
               t))

      ;; ---- the two summary fields injected back into frameworkRuntime -----
      ;;
      ;; These are the only fields that depend on the investigation having been
      ;; built first, so they are worth naming separately: a failure here means
      ;; the back-injection did not run, not that the runtime summary is wrong.
      (let ((gr (gethash "frameworkRuntime" gc))
            (wr (gethash "frameworkRuntime" wc)))
        (dolist (key '("availableWorkspaces" "availableJourneys"))
          (incf count)
          (check result (format nil "analysis/frameworkRuntime/~a" key) "field"
                 (and (gate-json= (gethash key gr) (gethash key wr)) t)
                 t))))

    (when verbose
      (format t "~&analysis gate: ~a/~a cases match~%"
              (gate-result-passed result) (gate-result-total result))
      (report-failures result))

    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp count))))
