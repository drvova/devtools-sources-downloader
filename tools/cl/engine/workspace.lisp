;;;; workspace.lisp - the boundary/journey profiles and the workspace views.
;;;;
;;;; This file starts with the PROFILE TIER: the constant text the investigation
;;;; workspace shows for each boundary and each journey. The oracle pins both
;;;; (`getBoundaryTitle`, `getBoundaryDescription`, `getBoundaryQuestions`,
;;;; `getJourneyQuestions`), so this tier is verifiable on its own before the
;;;; workspace builders that consume it land.
;;;;
;;;; The Rust holds these as one `BoundaryProfile` table for a stated reason: they
;;;; were originally three separate matches on the same label, so adding a
;;;; boundary meant finding all three and missing one silently fell back to the
;;;; generic text while the other two looked correct. One table, one lookup.

(in-package :vovas.engine.panel.workspace)

;;; ---------------------------------------------------------------------------
;;; The boundary profiles
;;; ---------------------------------------------------------------------------

(defparameter *boundary-profiles*
  '(("bootstrap"
     "Bootstrap workspace"
     "Focus on initial loaders, hydration code, runtime bootstraps, and early execution pivots."
     ("What actually starts the application?"
      "Which chunks materialize runtime artifacts first?"
      "Where does bootstrap hand off to router, state, or data code?"))
    ("router"
     "Router workspace"
     "Focus on navigation, route loaders, route-linked chunks, and follow-on route activity."
     ("Which chunks own navigation?"
      "What route-linked requests or runtime artifacts follow router activity?"
      "Which entrypoints look route-specific?"))
    ("state"
     "State workspace"
     "Focus on stores, persistence, rehydration, and state-driven transitions into other subsystems."
     ("Which stores or persistence seams are present?"
      "Does state drive data fetches or router changes?"
      "Which runtime artifacts look state-derived?"))
    ("data"
     "Data workspace"
     "Focus on API clients, GraphQL, fetch/XHR activity, and data-triggered runtime behavior."
     ("Which requests look like the primary API layer?"
      "Which chunks and runtimes trigger requests?"
      "Are GraphQL or other data clients obvious?"))
    ("auth"
     "Auth workspace"
     "Focus on session setup, token handling, login/logout paths, and downstream auth-driven requests."
     ("Where is session or token handling initialized?"
      "Which requests belong to login/session refresh?"
      "What does auth trigger next: data, router, or analytics?"))
    ("analytics"
     "Analytics workspace"
     "Focus on telemetry, tracking beacons, pageview/reporting paths, and analytics fan-out."
     ("Which beacons or SDK seams are present?"
      "What subsystem activity feeds analytics?"
      "Which chunks likely own telemetry wiring?"))
    ("editor"
     "Editor workspace"
     "Focus on rich-text/editor runtimes, content workflows, and document mutation paths."
     ("Which assets or runtimes look content- or editor-related?"
      "What runtime materialization follows editor activity?"
      "Does editor activity lead into state or data flows?"))
    ("vendor"
     "Vendor workspace"
     "Focus on third-party/framework code that spawns runtime artifacts or crosses into business logic."
     ("Which third-party bundles are most influential?"
      "Which runtime artifacts come from vendor/framework code?"
      "Where does vendor code cross into app subsystems?")))
  "`PROFILES`: one (label title description questions) row per boundary.

The labels must cover `*boundary-labels*` exactly. A label present here but
absent there is dead text; a label there but absent here silently degrades to the
generic description, which is the failure this table exists to prevent.")

(defparameter *default-boundary-questions*
  '("Which artifacts belong here?"
    "Which flows enter or leave this boundary?")
  "`getBoundaryQuestions` for an unknown label.

A fallback VECTOR in the Rust, returned by reference rather than allocated per
call; here it is a literal list, so callers must not destructively modify it -
the accessors below copy.")

(defparameter *journey-questions*
  '(("initial-load"
     ("Which chunk booted first?"
      "What runtime artifacts were materialized during startup?"
      "Which early transitions led into data or router activity?"))
    ("auth-handshake"
     ("Which assets and requests carry auth signals?"
      "Does auth lead into data, router, or analytics behavior?"
      "Which runtime artifacts appear around session setup?"))
    ("route-change"
     ("Which chunks and requests cluster around navigation?"
      "Does route activity trigger data fetches or analytics?"
      "Which runtime artifacts appear after router activity?"))
    ("runtime-materialization"
     ("Which chunks created runtime artifacts?"
      "Which runtime artifacts spawn other runtimes?"
      "What requests or boundary transitions follow runtime generation?")))
  "`getJourneyQuestions`: keyed by journey id.

The fallback is a SEPARATE constant below, not a row here, because it must answer
for every id that is not one of the four - including an empty id and any future
journey - and a table lookup cannot express \"everything else\".")

(defparameter *default-journey-questions*
  '("What does this slice show first?"
    "Which transitions deserve inspection?"))

;;; ---------------------------------------------------------------------------
;;; Profile accessors
;;; ---------------------------------------------------------------------------

(defun boundary-profile (boundary)
  "The profile row for BOUNDARY, or NIL. Compares the LABEL only."
  (assoc boundary *boundary-profiles* :test #'string=))

(defun get-boundary-title (boundary)
  "`getBoundaryTitle`: the profile title, else \"<label> workspace\".

The fallback splices the LABEL in, so an unknown boundary still names itself
rather than showing a generic heading."
  (let ((row (boundary-profile boundary)))
    (if row
        (second row)
        (format nil "~a workspace" boundary))))

(defun get-boundary-description (boundary)
  "`getBoundaryDescription`: the profile description, else the generic line.

The generic line is deliberately vague - it is what an unknown boundary gets, and
it must not claim anything about a subsystem nobody characterised."
  (let ((row (boundary-profile boundary)))
    (if row
        (third row)
        "Focus on artifacts labeled for this subsystem.")))

(defun get-boundary-questions (boundary)
  "`getBoundaryQuestions`: the profile questions, else the generic pair.

Copied, not returned by reference: the caller assembles them into a report and the
shared literal must survive."
  (let ((row (boundary-profile boundary)))
    (copy-list (if row (fourth row) *default-boundary-questions*))))

(defun get-journey-questions (id)
  "`getJourneyQuestions`: the questions for a journey id.

An unknown id - including the empty string and any id a later build adds - gets the
two generic questions rather than an empty list, because a journey view with no
questions reads as a rendering fault."
  (let ((row (assoc id *journey-questions* :test #'string=)))
    (copy-list (if row (second row) *default-journey-questions*))))
