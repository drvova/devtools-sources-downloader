;;;; gate-export.lisp - exportSemanticAnalysis.
;;;;
;;;; No oracle exists for this function - the Rust has no assertion for
;;;; `export_semantic_analysis` either, because it is a COMPOSITION of parts that
;;;; each carry their own oracle. So this gate verifies the contract instead:
;;;;
;;;;   - every artifact declared in *analysis-artifacts* is actually written
;;;;   - the readable reconstructions come FIRST (the engine's stated order, so
;;;;     an interrupted export still has the human-readable files)
;;;;   - exactly one index.html
;;;;   - nine workspaces and four journeys, each named by a non-empty id
;;;;   - every .json artifact parses, so nothing is written malformed
;;;;
;;;; A structural gate cannot prove the CONTENT is right. It can prove the
;;;; composition happened, which is the failure mode this function actually had.

(in-package :vovas.engine.gate)

(defun gate-export-inputs ()
  "The fixture's own pipeline inputs, assembled the way the Rust test does."
  (let* ((fx (read-json-file (fixture-path "panel/boundary-oracle.json")))
         (input (gethash "input" fx))
         (rf (gethash "reconFixture" input))
         (recon (let ((c (make-hash-table :test #'equal)))
                  (maphash (lambda (k v) (setf (gethash k c) v)) rf)
                  (setf (gethash "recon" c) (gethash "recon" input))
                  (setf (gethash "frameworkState" c) (gethash "frameworkState" input))
                  c)))
    (values (coerce (gethash "scriptFixture" input) 'list)
            recon
            (coerce (gethash "runtimeEntries" input) 'list)
            (coerce (gethash "runtimeManifest" input) 'list))))

(defun run-export-semantic-gate (&key (verbose t))
  (let* ((result (make-gate-result))
         (count 0)
         (written '()))
    (multiple-value-bind (scripts recon entries manifest) (gate-export-inputs)
      (vovas.engine.panel.report:export-semantic-analysis
       (lambda (path content) (push (cons path content) written))
       scripts recon entries manifest))
    (setf written (nreverse written))
    ;; The prefix LENGTHS are taken from the literals rather than typed:
    ;; "_analysis/workspaces/" is 21 characters, not 22, and a hardcoded 22
    ;; compared a 22-character slice against a 21-character string - never
    ;; equal, so both counts read 0 while the files were plainly on disk.
    (let* ((paths (mapcar #'car written))
           (ws-prefix "_analysis/workspaces/")
           (jn-prefix "_analysis/journeys/"))

      ;; ---- every declared analysis artifact is present -------------------
      (dolist (pair vovas.engine.panel.paths:*analysis-artifacts*)
        (incf count)
        (check result (format nil "export/artifact/~a" (cdr pair)) "present"
               (and (member (car pair) paths :test #'string=) t)
               t))

      ;; ---- the readable reconstructions come first -----------------------
      (incf count)
      (check result "export/order/readable-first" "prefix"
             (and (search "_analysis/readable/" (first paths)) t)
             t)

      ;; ---- the console page is written exactly once ----------------------
      (incf count)
      (check result "export/index-once" "count"
             (count vovas.engine.panel.paths:*analysis-index-html* paths
                    :test #'string=)
             1)

      ;; ---- one file per workspace, and no id may be empty ---------------
      (let ((ws (remove-if-not
                  (lambda (p)
                    (and (>= (length p) (length ws-prefix))
                         (string= ws-prefix (subseq p 0 (length ws-prefix)))))
                  paths)))
        (incf count)
        (check result "export/workspaces/count" "files" (length ws) 9)
        (incf count)
        (check result "export/workspaces/no-empty-id" "ids"
               (and (every (lambda (p)
                             (> (length p)
                                (length "_analysis/workspaces/.json")))
                           ws)
                    t)
               t))

      ;; ---- one file per journey -----------------------------------------
      (incf count)
      (check result "export/journeys/count" "files"
             (length (remove-if-not
                      (lambda (p)
                        (and (>= (length p) (length jn-prefix))
                             (string= jn-prefix (subseq p 0 (length jn-prefix)))))
                      paths))
             4)

      ;; ---- nothing written is malformed JSON -----------------------------
      (dolist (pair written)
        (when (search ".json" (car pair))
          (incf count)
          (check result (format nil "export/parses/~a" (car pair)) "json"
                 (handler-case (progn (com.inuoe.jzon:parse (cdr pair)) t)
                   (error () nil))
                 t))))

    (when verbose
      (format t "~&export semantic gate: ~a/~a cases match~%"
              (gate-result-passed result) (gate-result-total result))
      (report-failures result))

    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp count))))
