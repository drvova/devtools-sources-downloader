;;;; gate-workspace.lisp - the boundary/journey profile tier.
;;;;
;;;; The oracle carries FOUR independent pin sets here, which is unusually good
;;;; coverage for what is just constant text:
;;;;
;;;;   getBoundaryTitle       3 cases - two known labels and one UNKNOWN
;;;;   getBoundaryDescription 2 cases - a known label and the generic line
;;;;   getBoundaryQuestions   2 cases - a known label and the generic pair
;;;;   getJourneyQuestions    2 cases - a known id and the generic pair
;;;;
;;;; The unknown-label cases are the valuable ones: they pin the FALLBACK, which
;;;; is the branch a hand-written fixture forgets and the branch that silently
;;;; degrades when a table row is added or renamed.
;;;;
;;;; The titles/descriptions/questions for the OTHER six boundaries are not in
;;;; the oracle, so this gate does not invent expectations for them. What it can
;;;; prove structurally is that every label in the registry has a row, in the
;;;; same order - a missing row would degrade to generic text in the report.

(in-package :vovas.engine.gate)

(defun workspace-strings= (got want)
  "Compare two JSON arrays of strings by CONTENT.

`check` uses `equal`, and `equal` descends a vector but compares its elements with
`eql` - so two vectors holding equal-but-distinct STRINGS are not `equal`. JZON
hands back fresh strings for every oracle read, and the accessors build fresh
strings again, so identity never holds. The failure prints identically to the
success, which is why this needs its own predicate rather than a tweak to the
shared one."
  (let ((g (coerce got 'list)) (w (coerce want 'list)))
    (and (= (length g) (length w))
         (every (lambda (a b) (and (stringp a) (stringp b) (string= a b))) g w))))

(defun run-workspace-gate (&key (verbose t))
  (let* ((result (make-gate-result))
         (count 0)
         (fx (read-json-file (fixture-path "panel/boundary-oracle.json")))
         (exp (gethash "expected" fx)))

    ;; --------------------------------------------------------------------
    ;; The two UNKNOWN cases in the oracle prove the fallbacks; the title
    ;; fallback splices the LABEL so an unnamed boundary still names itself.
    ;; --------------------------------------------------------------------
    (let ((want (gethash "getBoundaryTitle" exp)))
      (dolist (pair (list (cons "bootstrap" 0)
                          (cons "vendor" 1)
                          (cons "nope" 2)))
        (incf count)
        (check result (format nil "getBoundaryTitle/~a" (car pair)) "title"
               (vovas.engine.panel.workspace:get-boundary-title (car pair))
               (coerce (aref want (cdr pair)) 'string))))

    (let ((want (gethash "getBoundaryDescription" exp)))
      (dolist (pair (list (cons "data" 0) (cons "nope" 1)))
        (incf count)
        (check result (format nil "getBoundaryDescription/~a" (car pair)) "description"
               (vovas.engine.panel.workspace:get-boundary-description (car pair))
               (coerce (aref want (cdr pair)) 'string))))

    (let ((want (gethash "getBoundaryQuestions" exp)))
      (dolist (pair (list (cons "auth" 0) (cons "nope" 1)))
        (incf count)
        (check result (format nil "getBoundaryQuestions/~a" (car pair)) "questions"
               (and (workspace-strings=
                     (vovas.engine.panel.workspace:get-boundary-questions (car pair))
                     (aref want (cdr pair)))
                    t)
               t)))

    (let ((want (gethash "getJourneyQuestions" exp)))
      ;; The four known ids are exercised, plus the fallback. Only two are
      ;; ORACLE-pinned: "initial-load" is case 0, and the unknown id is case 1.
      ;; The other ids are asserted structurally below, not against invented text.
      (loop for pair in (list (cons "initial-load" 0)
                              (cons "not-a-journey" 1))
            do (incf count)
               (check result (format nil "getJourneyQuestions/~a" (car pair)) "questions"
                      (and (workspace-strings=
                            (vovas.engine.panel.workspace:get-journey-questions (car pair))
                            (aref want (cdr pair)))
                           t)
                      t)))

    ;; --------------------------------------------------------------------
    ;; Structural: every registry label has exactly one profile row, and the
    ;; rows are in registry order. A missing row degrades to generic text; a
    ;; row for a label the registry lacks is unreachable text.
    ;; --------------------------------------------------------------------
    (let* ((registry vovas.engine.panel.boundary:*boundary-labels*)
           (rows vovas.engine.panel.workspace:*boundary-profiles*))
      (incf count)
      (check result "profiles/row-count" "count"
             (length rows) (length registry))
      (incf count)
      (check result "profiles/labels-in-registry-order" "labels"
             (and (workspace-strings= (mapcar #'first rows) registry) t)
             t)
      ;; each row must carry a title, a description and at least one question
      (dolist (row rows)
        (incf count)
        (check result (format nil "profiles/~a/complete" (first row)) "bool"
               (and (stringp (second row)) (plusp (length (second row)))
                    (stringp (third row)) (plusp (length (third row)))
                    (consp (fourth row)))
               t)))

    ;; --------------------------------------------------------------------
    ;; Structural: the journey table holds the four ids the Rust matches on,
    ;; and every row has questions. An id missing here gets the generic pair,
    ;; which reads as a rendering fault rather than an uncharacterised slice.
    ;; --------------------------------------------------------------------
    (incf count)
    (check result "journeys/ids" "ids"
           (and (workspace-strings=
                 (mapcar #'first vovas.engine.panel.workspace:*journey-questions*)
                 '("initial-load" "auth-handshake" "route-change" "runtime-materialization"))
                t)
           t)
    (dolist (row vovas.engine.panel.workspace:*journey-questions*)
      (incf count)
      (check result (format nil "journeys/~a/complete" (first row)) "bool"
             (consp (second row)) t))

    ;; --------------------------------------------------------------------
    ;; The accessors COPY their answers: the shared literals must survive a
    ;; caller that assembles and then modifies the returned list.
    ;; --------------------------------------------------------------------
    (let* ((before (vovas.engine.panel.workspace:get-boundary-questions "auth"))
           (mutated (vovas.engine.panel.workspace:get-boundary-questions "auth"))
           (after (progn (setf (first mutated) "MUTATED")
                         (vovas.engine.panel.workspace:get-boundary-questions "auth"))))
      (incf count)
      (check result "questions/accessor-copies" "bool"
             (and (equal before after)
                  (not (string= (first mutated) (first after))))
             t))

    (when verbose
      (format t "~&workspace gate: ~a/~a cases match~%"
              (gate-result-passed result) (gate-result-total result))
      (report-failures result))

    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp count))))
