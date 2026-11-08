;;;; boundary.lisp - the boundary predicates.
;;;;
;;;; PORTING NOTE. `boundary.rs` is 2,418 lines across 38 items, but only the
;;;; predicate tier is needed to unblock `workspace` (which imports exactly
;;;; these six) and `analysis`. Porting the whole module in one pass would put a
;;;; 2,000-line unreviewed block behind a single gate; this file is the part
;;;; `workspace` actually calls, gated on its own terms, and the label-inference
;;;; and flow-building tiers land on top of it.
;;;;
;;;; The predicates are pure and total: every one accepts a non-object, a JSON
;;;; null and a missing key without signalling, because their callers iterate
;;;; over arrays assembled from several sources and any element can be absent.

(in-package :vovas.engine.panel.boundary)

(defparameter *boundary-labels*
  '("bootstrap" "router" "state" "data" "auth" "analytics" "editor" "vendor")
  "`BoundaryLabel::ALL`, in declaration order.

The order is load-bearing twice over: `count-boundary-labels` walks it to build
the report's category list, so a label added to the enum but not here is
attributed to chunks and never appears in the report at all. Pinned by the
boundary oracle.")

;;; ---------------------------------------------------------------------------
;;; arrayContainsAny
;;; ---------------------------------------------------------------------------

(defun array-contains-any (values candidates)
  "`arrayContainsAny`: whether any CANDIDATE appears in VALUES.

Both sides are string lists. Membership is by `string=`, so it is exact and
case-sensitive - the labels are lowercase wire spellings on both sides."
  (let ((wanted (if (listp candidates) candidates (coerce candidates 'list))))
    (and (some (lambda (candidate)
                 (member candidate
                         (if (listp values) values (coerce values 'list))
                         :test #'string=))
               wanted)
         t)))

;;; ---------------------------------------------------------------------------
;;; matchesBoundaryEntry
;;; ---------------------------------------------------------------------------

(defun matches-boundary-entry (entry boundary)
  "`matchesBoundaryEntry`: whether ENTRY carries BOUNDARY.

`primary-boundary` is checked first and short-circuits; the `boundary-labels`
array is the second chance, so an entry whose primary is something else but
which was also tagged with BOUNDARY still matches. A non-object entry answers NIL
rather than signalling - the flow walkers pass whatever they found."
  (when (vovas.engine.panel.model:js-truthy entry)
    (or (string= (field-str entry "primaryBoundary") boundary)
        (let ((labels (field entry "boundaryLabels")))
          (and (or (vectorp labels) (listp labels))
               (some (lambda (label)
                       (and (stringp label) (string= label boundary)))
                     (if (listp labels) labels (coerce labels 'list)))
               t)))))

;;; ---------------------------------------------------------------------------
;;; The touch predicates
;;; ---------------------------------------------------------------------------

(defun flow-touches-boundary (flow boundary)
  "`flowTouchesBoundary`: whether the flow starts or ends at BOUNDARY.

Four tests, in the original's order: the two textual boundary fields, then the
nested `from` and `to` entries. The textual check comes first because it is the
cheap one and because a flow may name a boundary without carrying either entry."
  (when (vovas.engine.panel.model:js-truthy flow)
    (or (string= (field-str flow "fromBoundary") boundary)
        (string= (field-str flow "toBoundary") boundary)
        (matches-boundary-entry (field flow "from") boundary)
        (matches-boundary-entry (field flow "to") boundary))))

(defun chain-touches-boundary (chain boundary)
  "`chainTouchesBoundary`: whether BOUNDARY appears anywhere in the chain's path.

The path is the ONLY field consulted. A chain whose endpoints name a boundary but
whose path was pruned does not touch it - which is the intent, because the path is
what the workspace renders as the boundary crossing."
  (when (vovas.engine.panel.model:js-truthy chain)
    (let ((path (field chain "path")))
      (and (or (vectorp path) (listp path))
           (some (lambda (item) (and (stringp item) (string= item boundary)))
                 (if (listp path) path (coerce path 'list)))
           t))))

(defun flow-touches-any-boundary (flow boundaries)
  "`flowTouchesAnyBoundary`: whether ANY of BOUNDARIES is touched by FLOW.

The truthiness gate is separate from the list walk so an absent flow answers NIL
without pretending an empty boundary list matched."
  (when (vovas.engine.panel.model:js-truthy flow)
    (let ((list (if (listp boundaries) boundaries (coerce boundaries 'list))))
      (and (some (lambda (boundary) (flow-touches-boundary flow boundary)) list) t))))

(defun matches-any-boundary (entry boundaries)
  "`matchesAnyBoundary`: whether ENTRY matches any of BOUNDARIES.

No truthiness gate on ENTRY here, unlike the flow walker: `matches-boundary-entry`
already answers NIL for a non-truthy entry, and adding a second gate would change
nothing observable while adding a place to get it wrong."
  (let ((list (if (listp boundaries) boundaries (coerce boundaries 'list))))
    (and (some (lambda (boundary) (matches-boundary-entry entry boundary)) list) t)))
