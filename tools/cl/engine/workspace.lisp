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

;;; ---------------------------------------------------------------------------
;;; The path predicates
;;;
;;; These are the workspace's OWN, and they are not the boundary module's:
;;; `chain_touches_any_boundary` asks `chain_touches_boundary` once per candidate,
;;; while `chain_path_touches_any` walks the path ONCE against the whole candidate
;;; set. Same answer, different cost, and the second also requires the path key to
;;; EXIST - a chain with no `path` at all is rejected before the walk.
;;; ---------------------------------------------------------------------------

(defun array-touches-any (values candidates)
  "`arrayTouchesAny`: whether any TRUTHY element equals a candidate.

A falsy element is SKIPPED rather than compared, so a null in the middle of the
path neither matches nor aborts the scan."
  (let ((list (if (or (vectorp values) (listp values))
                  (coerce values 'list)
                  '())))
    (and (some (lambda (value)
                 (and (vovas.engine.panel.model:js-truthy value)
                      (stringp value)
                      (member value candidates :test #'string=)))
               list)
         t)))

(defun string-path (value)
  "`stringPath`: the `path` array of a chain as a list, empty when absent."
  (let ((path (and (hash-table-p value) (gethash "path" value))))
    (if (or (vectorp path) (listp path)) (coerce path 'list) '())))

(defun chain-path-touches-any (chain boundaries)
  "`chainPathTouchesAny`: whether the chain's PATH names any boundary.

The `path` key must EXIST - a chain carrying no path is rejected outright, which
is stricter than `boundary:chain-touches-boundary`, whose absent-path case is a
property of its `unwrap_or(false)` rather than an explicit test."
  (when (and (vovas.engine.panel.model:js-truthy chain)
             (hash-table-p chain)
             (nth-value 1 (gethash "path" chain)))
    (array-touches-any (string-path chain) boundaries)))

(defun chain-touches-any-boundary (chain boundaries)
  "`chainTouchesAnyBoundary`: whether ANY candidate boundary is touched.

Per-candidate, delegating to the boundary module - unlike
`chain-path-touches-any`, which walks the path once. Both exist in the original."
  (when (vovas.engine.panel.model:js-truthy chain)
    (let ((list (if (listp boundaries) boundaries (coerce boundaries 'list))))
      (and (some (lambda (boundary)
                   (vovas.engine.panel.boundary:chain-touches-boundary chain boundary))
                 list)
           t))))

;;; ---------------------------------------------------------------------------
;;; The analysis readers
;;; ---------------------------------------------------------------------------

(defun items-of (analysis key)
  "`itemsOf`: the `items` array of ANALYSIS[KEY] as a list, empty when absent."
  (let* ((section (and (hash-table-p analysis) (gethash key analysis)))
         (items (and (hash-table-p section) (gethash "items" section))))
    (if (or (vectorp items) (listp items)) (coerce items 'list) '())))

(defun flows-of (analysis key)
  "`flowsOf`: a section of ANALYSIS's `crossBoundaryFlows` as a list."
  (let* ((flows (and (hash-table-p analysis) (gethash "crossBoundaryFlows" analysis)))
         (section (and (hash-table-p flows) (gethash key flows))))
    (if (or (vectorp section) (listp section)) (coerce section 'list) '())))

(defun take-n (list n)
  "The first N of LIST. A `subseq` with an explicit bound, so a short list is not
an error."
  (subseq list 0 (min n (length list))))

;;; ---------------------------------------------------------------------------
;;; buildBoundaryWorkspace
;;; ---------------------------------------------------------------------------

(defun build-boundary-workspace (boundary analysis)
  "`buildBoundaryWorkspace`: everything the analysis knows about one boundary.

Each collection is filtered to this boundary and then CAPPED, and the caps are not
interchangeable: 18 sections, 10 for entrypoints/topTransitions/chains, 24 for
events/transitions. `totalItems` counts only chunks, runtime and entrypoints - NOT
events or transitions - so it is the item count, not a sum of every collection.

The filter differs by collection: entries use `matches-boundary-entry` (primary or
labeled), transitions use `flow-touches-boundary` (from/to fields or nested
entries), chains use `chain-touches-boundary` (path membership), and topTransitions
compare from/to boundary STRINGS directly."
  (let* ((chunks (take-n (remove-if-not
                          (lambda (item)
                            (vovas.engine.panel.boundary:matches-boundary-entry
                             item boundary))
                          (items-of analysis "chunkMap"))
                         18))
         (runtime (take-n (remove-if-not
                           (lambda (item)
                             (vovas.engine.panel.boundary:matches-boundary-entry
                              item boundary))
                           (items-of analysis "runtimeOrigins"))
                          18))
         (entrypoints (take-n (remove-if-not
                               (lambda (item)
                                 (vovas.engine.panel.boundary:matches-boundary-entry
                                  item boundary))
                               (let ((v (and (hash-table-p analysis)
                                             (gethash "interestingEntrypoints" analysis))))
                                 (if (or (vectorp v) (listp v)) (coerce v 'list) '())))
                              10))
         (events (take-n (remove-if-not
                          (lambda (item)
                            (vovas.engine.panel.boundary:matches-boundary-entry
                             item boundary))
                          (flows-of analysis "events"))
                         24))
         (transitions (take-n (remove-if-not
                               (lambda (item)
                                 (vovas.engine.panel.boundary:flow-touches-boundary
                                  item boundary))
                               (flows-of analysis "transitions"))
                              24))
         (top-transitions (take-n (remove-if-not
                                   (lambda (item)
                                     (or (string= (field-str item "fromBoundary") boundary)
                                         (string= (field-str item "toBoundary") boundary)))
                                   (flows-of analysis "topTransitions"))
                                  10))
         (chains (take-n (remove-if-not
                          (lambda (item)
                            (vovas.engine.panel.boundary:chain-touches-boundary
                             item boundary))
                          (flows-of analysis "chains"))
                         10))
         (row (make-hash-table :test #'equal))
         (summary (make-hash-table :test #'equal)))
    (setf (gethash "chunkCount" summary) (length chunks)
          (gethash "runtimeCount" summary) (length runtime)
          (gethash "entrypointCount" summary) (length entrypoints)
          (gethash "eventCount" summary) (length events)
          (gethash "transitionCount" summary) (length transitions)
          (gethash "chainCount" summary) (length chains)
          (gethash "totalItems" summary) (+ (length chunks) (length runtime)
                                            (length entrypoints)))
    (setf (gethash "id" row) boundary
          (gethash "title" row) (get-boundary-title boundary)
          (gethash "description" row) (get-boundary-description boundary)
          (gethash "questions" row) (coerce (get-boundary-questions boundary) 'vector)
          (gethash "summary" row) summary
          (gethash "entrypoints" row) (coerce entrypoints 'vector)
          (gethash "chunks" row) (coerce chunks 'vector)
          (gethash "runtime" row) (coerce runtime 'vector)
          (gethash "events" row) (coerce events 'vector)
          (gethash "transitions" row) (coerce transitions 'vector)
          (gethash "topTransitions" row) (coerce top-transitions 'vector)
          (gethash "chains" row) (coerce chains 'vector)
          (gethash "relatedArtifacts" row)
          (vector (symbol-value (find-symbol "*ANALYSIS-BOUNDARY-LABELS*" :vovas.engine.panel.paths))
                  (symbol-value (find-symbol "*ANALYSIS-CROSS-BOUNDARY-FLOWS*" :vovas.engine.panel.paths))
                  (symbol-value (find-symbol "*ANALYSIS-INTERESTING-ENTRYPOINTS*" :vovas.engine.panel.paths))))
    row))

;;; ---------------------------------------------------------------------------
;;; pushFrameworkCollectionEvents + buildFrameworkStateEvents
;;; ---------------------------------------------------------------------------

(defparameter *framework-state-event-cap* 24)

(defun push-framework-collection-events (target items kind boundary fallback-label)
  "`pushFrameworkCollectionEvents`: append collection items as events, capped at 24.

The cap is checked at the TOP of each iteration, so a list longer than the
remaining room stops rather than overrunning - which is why the cap is a property
of TARGET's length, not of this call's slice.

Each field is a FALLBACK CHAIN, and the chains are ordered, not arbitrary:
label takes id, then kind, then tag, then the caller's fallback label; detail
takes source, then route, then status; score takes keyCount, then queryCount,
then childCount - a ZERO moving to the next candidate, so a store with no keyCount
reports its queryCount."
  (let ((list (if (or (vectorp items) (listp items)) (coerce items 'list) '())))
    (loop for index from 0
          for item in list
          do (when (>= (length target) *framework-state-event-cap*)
               (return))
             (let* ((safe (if (vovas.engine.panel.model:js-truthy item)
                              item (json-null-symbol)))
                    (label (let ((c (field-str safe "id")))
                             (if (plusp (length c)) c
                                 (let ((c2 (field-str safe "kind")))
                                   (if (plusp (length c2)) c2
                                       (let ((c3 (field-str safe "tag")))
                                         (if (plusp (length c3)) c3 fallback-label)))))))
                    (detail (let ((c (field-str safe "source")))
                              (if (plusp (length c)) c
                                  (let ((c2 (field-str safe "route")))
                                    (if (plusp (length c2)) c2
                                        (field-str safe "status"))))))
                    (score (let ((c (field-number safe "keyCount")))
                             (if (/= c 0d0) c
                                 (let ((c2 (field-number safe "queryCount")))
                                   (if (/= c2 0d0) c2
                                       (field-number safe "childCount"))))))
                    (row (make-hash-table :test #'equal)))
               (setf (gethash "id" row) (format nil "~a-~a" kind (1+ index))
                     (gethash "kind" row) kind
                     (gethash "boundary" row) boundary
                     (gethash "label" row) label
                     (gethash "detail" row) detail
                     (gethash "score" row) (js-number-value (or score 0d0)))
               (setf target (nconc target (list row)))))
    target))

(defun build-framework-state-events (framework-state)
  "`buildFrameworkStateEvents`: one event per framework-state slice.

A ROUTER event is synthesized first when either the route or the router framework
is present - its label names the framework or \"generic\", and its score is the
query-key count. Then the five collections contribute their own events, capped
together at 24.

The router event is NOT conditional on the collections; it is its own signal."
  (unless (vovas.engine.panel.model:js-truthy framework-state)
    (return-from build-framework-state-events '()))
  (let ((events '())
        (route (field-str framework-state "route"))
        (router-framework (field-str framework-state "routerFramework")))
    (when (or (plusp (length route)) (plusp (length router-framework)))
      (let ((row (make-hash-table :test #'equal)))
        (setf (gethash "id" row) "framework-router"
              (gethash "kind" row) "router-state"
              (gethash "boundary" row) "router"
              (gethash "label" row)
              (format nil "~a router"
                      (if (plusp (length router-framework)) router-framework "generic"))
              (gethash "detail" row) route
              (gethash "score" row)
              (js-number-value (field-number framework-state "queryKeyCount")))
        (push row events)))
    (dolist (spec '(("roots" "framework-root" "bootstrap" "root")
                    ("stores" "store-snapshot" "state" "store")
                    ("queries" "query-cache" "data" "query")
                    ("hydration" "hydration-payload" "bootstrap" "hydration")
                    ("auth" "auth-state" "auth" "auth")))
      (setf events (push-framework-collection-events
                    events (field framework-state (first spec))
                    (second spec) (third spec) (fourth spec))))
    ;; NO nreverse here. The router event is PUSHed (so it lands at the head) and
    ;; the collections are nconc'd onto the END, so `events` is already in output
    ;; order - reversing it put auth-state first and framework-router last.
    (take-n events *framework-state-event-cap*)))

;;; ---------------------------------------------------------------------------
;;; buildFrameworkStateWorkspace
;;; ---------------------------------------------------------------------------

(defparameter *framework-state-focus-boundaries*
  '("bootstrap" "router" "state" "data" "auth")
  "The five boundaries the framework-state workspace gathers.

NOT all eight: analytics, editor and vendor carry no framework state, so including
them would pad every count with zeros that mean nothing.")

(defun build-framework-state-workspace (analysis existing-workspaces)
  "`buildFrameworkStateWorkspace`: the cross-boundary framework-state view.

Gathers items from the five focus boundaries, then adds the per-collection counts
the framework state itself reports (roots, stores, queries, hydration, auth), the
router framework with a \"generic\" fallback, and the supporting workspaces - those
whose ID is one of the focus boundaries.

`events` come from `build-framework-state-events`, not from the flows; the flows
supply only transitions, chains and top-transitions."
  (let* ((framework-state (let ((v (and (hash-table-p analysis)
                                        (gethash "frameworkState" analysis))))
                            (if (vovas.engine.panel.model:js-truthy v)
                                v (make-hash-table :test #'equal))))
         (boundaries *framework-state-focus-boundaries*)
         (entrypoints-all (let ((v (and (hash-table-p analysis)
                                        (gethash "interestingEntrypoints" analysis))))
                            (if (or (vectorp v) (listp v)) (coerce v 'list) '())))
         (chunks (take-n (remove-if-not
                          (lambda (item)
                            (vovas.engine.panel.boundary:matches-any-boundary
                             item boundaries))
                          (items-of analysis "chunkMap"))
                         18))
         (runtime (take-n (remove-if-not
                           (lambda (item)
                             (vovas.engine.panel.boundary:matches-any-boundary
                              item boundaries))
                           (items-of analysis "runtimeOrigins"))
                          18))
         (entrypoints (take-n (remove-if-not
                               (lambda (item)
                                 (vovas.engine.panel.boundary:matches-any-boundary
                                  item boundaries))
                               entrypoints-all)
                              12))
         (transitions (take-n (remove-if-not
                               (lambda (item)
                                 (vovas.engine.panel.boundary:flow-touches-any-boundary
                                  item boundaries))
                               (flows-of analysis "transitions"))
                              24))
         (chains (take-n (remove-if-not
                          (lambda (item) (chain-touches-any-boundary item boundaries))
                          (flows-of analysis "chains"))
                         10))
         (events (build-framework-state-events framework-state))
         (supporting (remove-if-not
                      (lambda (workspace)
                        (member (field-str workspace "id") boundaries
                                :test #'string=))
                      existing-workspaces))
         (top-transitions (take-n (remove-if-not
                                   (lambda (item)
                                     (or (member (field-str item "fromBoundary") boundaries
                                                 :test #'string=)
                                         (member (field-str item "toBoundary") boundaries
                                                 :test #'string=)))
                                   (flows-of analysis "topTransitions"))
                                  10))
         (router-framework (let ((v (field-str framework-state "routerFramework")))
                             (if (plusp (length v)) v "generic")))
         (row (make-hash-table :test #'equal))
         (summary (make-hash-table :test #'equal)))
      (setf (gethash "chunkCount" summary) (length chunks)
            (gethash "runtimeCount" summary) (length runtime)
            (gethash "entrypointCount" summary) (length entrypoints)
            (gethash "eventCount" summary) (length events)
            (gethash "transitionCount" summary) (length transitions)
            (gethash "chainCount" summary) (length chains)
            (gethash "totalItems" summary) (+ (length chunks) (length runtime)
                                              (length entrypoints))
            (gethash "rootCount" summary) (js-number-value (field-number framework-state "rootCount"))
            (gethash "storeCount" summary) (js-number-value (field-number framework-state "storeCount"))
            (gethash "queryCount" summary) (js-number-value (field-number framework-state "queryCount"))
            (gethash "hydrationCount" summary) (js-number-value (field-number framework-state "hydrationCount"))
            (gethash "authCount" summary) (js-number-value (field-number framework-state "authCount"))
            (gethash "routerFramework" summary) router-framework
            (gethash "route" summary) (field-str framework-state "route"))
    (setf (gethash "id" row) "framework-state"
          (gethash "title" row) "Framework State workspace"
          (gethash "description" row)
          (concatenate 'string
            "Summarize the inspected framework state across router, stores, "
            "query caches, hydration payloads, auth state, and detected "
            "framework roots.")
          (gethash "focusBoundaries" row) (coerce boundaries 'vector)
          (gethash "questions" row)
          (vector "Which router state is active and where did it come from?"
                  "Which stores, caches, and hydration payloads are present?"
                  "What auth/session state is exposed?"
                  "Which supporting workspaces explain the observed framework state?")
          (gethash "summary" row) summary
          (gethash "entrypoints" row) (coerce entrypoints 'vector)
          (gethash "chunks" row) (coerce chunks 'vector)
          (gethash "runtime" row) (coerce runtime 'vector)
          (gethash "events" row) (coerce events 'vector)
          (gethash "transitions" row) (coerce transitions 'vector)
          (gethash "topTransitions" row) (coerce top-transitions 'vector)
          (gethash "chains" row) (coerce chains 'vector)
          (gethash "supportingWorkspaces" row) (coerce supporting 'vector)
          (gethash "relatedArtifacts" row)
          (vector-of (field framework-state "relatedArtifacts")))
    row))

;;; ---------------------------------------------------------------------------
;;; buildJourneyView / buildJourneyViews
;;; ---------------------------------------------------------------------------

(defun build-journey-view (id title description analysis workspace-map
                           focus-boundaries transition-filter)
  "`buildJourneyView`: one journey slice.

TRANSITION-FILTER is the journey's own predicate. A transition that fails it is
still included when its ENDPOINTS touch a focus boundary - the filter ORs a
structural test with a boundary test, so a journey shows both the transitions it
cares about AND anything happening in its boundaries.

`supporting` is built by walking FOCUS BOUNDARIES in order and taking the matching
workspace from the map - so it follows the journey's boundary order, not the
workspace list's, and a missing workspace is simply skipped."
  (let* ((transitions
           (take-n
            (remove-if-not
             (lambda (flow)
               (or (funcall transition-filter flow)
                   (let ((from (field-str flow "fromBoundary")))
                     (when (plusp (length from))
                       (array-touches-any
                        (list from (field-str flow "toBoundary"))
                        focus-boundaries)))))
             (flows-of analysis "transitions"))
            26))
         (events (take-n (remove-if-not
                          (lambda (event)
                            (vovas.engine.panel.boundary:matches-any-boundary
                             event focus-boundaries))
                          (flows-of analysis "events"))
                         28))
         (entrypoints-all (let ((v (and (hash-table-p analysis)
                                        (gethash "interestingEntrypoints" analysis))))
                            (if (or (vectorp v) (listp v)) (coerce v 'list) '())))
         (entrypoints (take-n (remove-if-not
                               (lambda (entry)
                                 (vovas.engine.panel.boundary:matches-any-boundary
                                  entry focus-boundaries))
                               entrypoints-all)
                              10))
         (chains (take-n (remove-if-not
                          (lambda (chain)
                            (chain-path-touches-any chain focus-boundaries))
                          (flows-of analysis "chains"))
                         10))
         (supporting '())
         (row (make-hash-table :test #'equal))
         (summary (make-hash-table :test #'equal)))
    (dolist (boundary focus-boundaries)
      (let ((workspace (gethash boundary workspace-map)))
        (when workspace
          (let ((s (make-hash-table :test #'equal)))
            (setf (gethash "id" s) (field-str workspace "id")
                  (gethash "title" s) (field-str workspace "title")
                  (gethash "summary" s)
                  (or (field workspace "summary") (make-hash-table :test #'equal))
                  (gethash "entrypoints" s)
                  (coerce (take-n (let ((v (field workspace "entrypoints")))
                                    (if (or (vectorp v) (listp v))
                                        (coerce v 'list) '()))
                                  3)
                          'vector))
            (push s supporting)))))
    (setf (gethash "eventCount" summary) (length events)
          (gethash "transitionCount" summary) (length transitions)
          (gethash "chainCount" summary) (length chains)
          (gethash "entrypointCount" summary) (length entrypoints))
    (setf (gethash "id" row) id
          (gethash "title" row) title
          (gethash "description" row) description
          (gethash "focusBoundaries" row) (coerce focus-boundaries 'vector)
          (gethash "summary" row) summary
          (gethash "questions" row) (coerce (get-journey-questions id) 'vector)
          (gethash "entrypoints" row) (coerce entrypoints 'vector)
          (gethash "events" row) (coerce events 'vector)
          (gethash "transitions" row) (coerce transitions 'vector)
          (gethash "chains" row) (coerce chains 'vector)
          (gethash "supportingWorkspaces" row) (coerce (nreverse supporting) 'vector)
          (gethash "relatedArtifacts" row)
          (vector (symbol-value (find-symbol "*ANALYSIS-CROSS-BOUNDARY-FLOWS*" :vovas.engine.panel.paths))
                  (symbol-value (find-symbol "*ANALYSIS-STARTUP-CHAIN*" :vovas.engine.panel.paths))
                  (symbol-value (find-symbol "*ANALYSIS-RUNTIME-ORIGINS*" :vovas.engine.panel.paths))))
    row))

(defun build-journey-views (analysis workspaces)
  "`buildJourneyViews`: the four journeys, each with its boundaries and filter.

The four are fixed, and each carries a DIFFERENT transition filter - that is the
whole distinction between them. A journey's identity is its boundary set plus what
counts as a relevant transition."
  (let ((map (make-hash-table :test #'equal)))
    (dolist (workspace workspaces)
      (setf (gethash (field-str workspace "id") map) workspace))
    (flet ((flow-from-is (boundary) (lambda (flow)
                                      (string= (field-str flow "fromBoundary") boundary)))
           (flow-to-is (boundary) (lambda (flow)
                                    (string= (field-str flow "toBoundary") boundary)))
           (flow-touches (boundary) (lambda (flow)
                                      (vovas.engine.panel.boundary:flow-touches-boundary
                                       flow boundary)))
           (relation-is (name) (lambda (flow)
                                 (string= (field-str flow "relation") name))))
      (vector
       (build-journey-view
        "initial-load" "Initial load"
        (concatenate 'string
          "Trace how bootstrap code, runtime materialization, routing, and data "
          "startup fit together during first load.")
        analysis map '("bootstrap" "router" "data" "state")
        (lambda (flow)
          (or (funcall (flow-from-is "bootstrap") flow)
              (funcall (flow-to-is "bootstrap") flow)
              (funcall (relation-is "imports-boundary") flow)
              (funcall (relation-is "materializes-runtime") flow))))
       (build-journey-view
        "auth-handshake" "Auth handshake"
        "Slice the session/auth path and its downstream transitions into data, router, and analytics."
        analysis map '("auth" "data" "router" "analytics")
        (flow-touches "auth"))
       (build-journey-view
        "route-change" "Route change"
        "Slice the navigation path through router, data, state, and analytics activity."
        analysis map '("router" "data" "state" "analytics")
        (flow-touches "router"))
       (build-journey-view
        "runtime-materialization" "Runtime materialization"
        (concatenate 'string
          "Show which chunks create runtime artifacts and how those artifacts lead "
          "into requests or more runtime generation.")
        analysis map '("bootstrap" "vendor" "data")
        (lambda (flow)
          (or (funcall (relation-is "materializes-runtime") flow)
              (funcall (relation-is "spawns-runtime") flow)
              (string= (field-str (field flow "from") "kind") "runtime")
              (string= (field-str (field flow "to") "kind") "runtime"))))))))

;;; ---------------------------------------------------------------------------
;;; buildInvestigationWorkspace
;;; ---------------------------------------------------------------------------

(defun build-investigation-workspace (analysis)
  "`buildInvestigationWorkspace`: every workspace and journey the panel renders.

One workspace per boundary CATEGORY (taken from the analysis's own
`boundaryLabels.categories`, falling back to the registry), then the
framework-state workspace appended, then the four journeys built against the
finished workspace list - which is why journeys can reference the framework-state
one.

The profile block reads `frameworkRuntime` and falls back to \"generic-app\"; an
absent boundary summary is JSON NULL, not an empty object."
  (let* ((labels (and (hash-table-p analysis) (gethash "boundaryLabels" analysis)))
         (categories (let ((v (and (hash-table-p labels) (gethash "categories" labels))))
                       (if (or (vectorp v) (listp v))
                           (remove-if-not #'stringp (coerce v 'list))
                           (copy-list vovas.engine.panel.boundary:*boundary-labels*))))
         (workspaces (mapcar (lambda (category)
                               (build-boundary-workspace category analysis))
                             categories)))
    (setf workspaces (append workspaces
                             (list (build-framework-state-workspace analysis workspaces))))
    (let* ((journeys (build-journey-views analysis workspaces))
           (framework-runtime (let ((v (and (hash-table-p analysis)
                                            (gethash "frameworkRuntime" analysis))))
                                (if (vovas.engine.panel.model:js-truthy v)
                                    v (make-hash-table :test #'equal))))
           (profile-name (let ((name (field-str framework-runtime "profile")))
                           (if (plusp (length name)) name "generic-app")))
           (profile (make-hash-table :test #'equal))
           (summary (make-hash-table :test #'equal))
           (entrypoints-all (let ((v (and (hash-table-p analysis)
                                          (gethash "interestingEntrypoints" analysis))))
                              (if (or (vectorp v) (listp v)) (coerce v 'list) '())))
           (row (make-hash-table :test #'equal)))
      (setf (gethash "name" profile) profile-name
            (gethash "confidence" profile)
            (js-number-value (field-number framework-runtime "confidence"))
            (gethash "technologies" profile)
            (vector-of (field framework-runtime "technologies"))
            (gethash "traits" profile) (vector-of (field framework-runtime "traits"))
            (gethash "captureReason" profile)
            (field-str framework-runtime "captureReason"))
      (setf (gethash "workspaceCount" summary) (length workspaces)
            (gethash "journeyCount" summary) (length journeys)
            (gethash "topBoundaryFlows" summary)
            (coerce (take-n (flows-of analysis "topTransitions") 10) 'vector)
            (gethash "likelyEntrypoints" summary)
            (coerce (take-n entrypoints-all 8) 'vector)
            (gethash "boundaryCounts" summary)
            (or (and (hash-table-p labels) (field labels "summary"))
                (json-null-symbol)))
      (setf (gethash "generatedAt" row) (vovas.engine.pipeline:iso8601-now)
            (gethash "page" row)
            (or (field framework-runtime "page") (make-hash-table :test #'equal))
            (gethash "profile" row) profile
            (gethash "summary" row) summary
            (gethash "workspaces" row) (coerce workspaces 'vector)
            (gethash "journeys" row) journeys)
      row)))
