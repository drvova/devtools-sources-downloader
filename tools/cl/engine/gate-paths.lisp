;;;; gate-paths.lisp — the archive layout gate.
;;;;
;;;; There is no JSON oracle for paths.rs, and it does not need one: the module is
;;;; two tables and a presence predicate. What matters is that the tables match the
;;;; Rust EXACTLY (a wrong path is a report linking to a file nothing writes) and
;;;; that the presence rule is the single one the docstring says it is.
;;;;
;;;; The presence assertions are the point of this gate. The Rust records that the
;;;; writer and the artifact index used to test presence differently, so a slice
;;;; holding a NON-EMPTY STRING was written and then left out of the index. The
;;;; string case below is that bug, pinned.

(in-package :vovas.engine.gate)

(defun run-paths-gate (&key (verbose t))
  (let ((result (make-gate-result))
        (count 0))

    ;; --- 1. the framework table, path and key both ------------------------
    (incf count)
    (check result "framework-artifacts/paths" "all seven"
           (mapcar #'car vovas.engine.panel.paths:*framework-artifacts*)
           '("_framework/summary.json"
             "_framework/router-state.json"
             "_framework/framework-roots.json"
             "_framework/store-snapshots.json"
             "_framework/query-caches.json"
             "_framework/hydration-payloads.json"
             "_framework/auth-state.json"))
    (incf count)
    (check result "framework-artifacts/keys" "all seven"
           (mapcar #'cdr vovas.engine.panel.paths:*framework-artifacts*)
           '("summary" "router" "roots" "stores" "queries" "hydration" "auth"))
    (incf count)
    (check result "framework-artifacts/count" "seven"
           (length vovas.engine.panel.paths:*framework-artifacts*) 7)

    ;; --- 2. the analysis table -------------------------------------------
    (incf count)
    (check result "analysis-artifacts/count" "eight"
           (length vovas.engine.panel.paths:*analysis-artifacts*) 8)
    (incf count)
    (check result "analysis-artifacts/keys" "all eight"
           (mapcar #'cdr vovas.engine.panel.paths:*analysis-artifacts*)
           '("chunkMap" "crossBoundaryFlows" "moduleGraph" "startupChain"
             "runtimeOrigins" "boundaryLabels" "frameworkRuntime"
             "interestingEntrypoints"))
    ;; every analysis path must be UNDER _analysis/ and end .json, and the index
    ;; page must NOT be in the table - it is written but addressed by no key
    (incf count)
    (check result "analysis-artifacts/paths-shape" "prefix and suffix"
           (every (lambda (pair)
                    (and (search "_analysis/" (car pair))
                         (let ((n (length (car pair))))
                           (and (> n 5)
                                (string= ".json" (subseq (car pair) (- n 5)))))))
                  vovas.engine.panel.paths:*analysis-artifacts*)
           t)
    (incf count)
    (check result "analysis-artifacts/index-not-in-table" "index.html absent"
           (find "_analysis/index.html"
                 (mapcar #'car vovas.engine.panel.paths:*analysis-artifacts*)
                 :test #'string=)
           nil)
    (incf count)
    (check result "analysis-index-html" "value"
           vovas.engine.panel.paths:*analysis-index-html* "_analysis/index.html")

    ;; --- 3. keys-len: the JS Object.keys rule -----------------------------
    (let ((json (lambda (text)
                  (let ((*read-default-float-format* 'double-float))
                    (com.inuoe.jzon:parse text)))))
      (dolist (case '(("{}" . 0)
                      ("{\"a\":1}" . 1)
                      ("{\"a\":1,\"b\":2}" . 2)
                      ("[]" . 0)
                      ("[1,2,3]" . 3)
                      ("\"\"" . 0)
                      ("\"abc\"" . 3)
                      ("5" . 0)
                      ("true" . 0)
                      ("null" . 0)))
        (incf count)
        (check result "keys-len" (car case)
               (vovas.engine.panel.assets:keys-len (funcall json (car case)))
               (cdr case))))

    ;; --- 4. framework-slice-present-p: the bug this rule prevents ---------
    ;;
    ;; A STRING slice is present. The old index demanded an object or array and
    ;; so skipped it, which is exactly the divergence the Rust docstring records.
    (let ((state (make-hash-table :test #'equal)))
      (setf (gethash "summary" state)
            (let ((*read-default-float-format* 'double-float))
              (com.inuoe.jzon:parse "{\"a\":1}"))
            (gethash "auth" state)
            (let ((*read-default-float-format* 'double-float))
              (com.inuoe.jzon:parse "\"token\""))
            (gethash "stores" state)
            (let ((*read-default-float-format* 'double-float))
              (com.inuoe.jzon:parse "{}")))
      (flet ((present (key)
               (and (vovas.engine.panel.paths:framework-slice-present-p state key) t)))
        (incf count)
        (check result "slice-present" "object with a key" (present "summary") t)
        (incf count)
        (check result "slice-present" "NON-EMPTY STRING" (present "auth") t)
        (incf count)
        (check result "slice-present" "empty object" (present "stores") nil)
        (incf count)
        (check result "slice-present" "absent key" (present "queries") nil))
      ;; and a state that is not a table at all must be absent, not crash
      (incf count)
      (check result "slice-present" "non-object state"
             (and (vovas.engine.panel.paths:framework-slice-present-p
                   nil "summary") nil)
             nil))

    (when verbose
      (format t "~&paths gate: ~a/~a cases match~%"
              (gate-result-passed result) (gate-result-total result))
      (report-failures result))
    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp count))))
