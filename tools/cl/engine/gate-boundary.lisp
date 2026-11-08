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
