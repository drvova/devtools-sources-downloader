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

;;; ---------------------------------------------------------------------------
;;; The label patterns
;;;
;;; Every pattern is a plain CL-PPCRE scanner built from a single-quoted-free
;;; string: no `format`, so no backslash doubling to get wrong. The Rust adds
;;; `(?-u:\b)` to two of these to force an ASCII word boundary; cl-ppcre rejects
;;; that flag group and does not need it, because its `\b` is ASCII-only already.
;;; Dropping the flag is a faithful translation, not a relaxation - the same
;;; reasoning recorded in `assets.lisp` for the import patterns.
;;; ---------------------------------------------------------------------------

(defparameter *re-bootstrap*
  (cl-ppcre:create-scanner
   "hydration|hydrateroot|reactdom\\.hydrate|bootstrap|domcontentloaded|__webpack_require__|webpackchunk|parcelrequire|__vite__"))

(defparameter *re-router*
  (cl-ppcre:create-scanner
   "router|routes\\b|history\\.pushstate|next/router|vue-router|react-router|createbrowserrouter|browserrouter|remix"))

(defparameter *re-state*
  (cl-ppcre:create-scanner
   "redux|zustand|mobx|recoil|vuex|pinia|createstore|configurestore|createslice|dispatch\\(|subscribe\\(|setstate\\("))

(defparameter *re-data*
  (cl-ppcre:create-scanner
   "graphql|apollo|relay|axios|tanstack/query|react-query|swr|trpc|fetch\\(|xmlhttprequest|/api/|urql"))

(defparameter *re-auth*
  (cl-ppcre:create-scanner
   "auth0|next-auth|firebase/auth|supabase\\.auth|oauth|bearer|jwt|csrf|signin|signout|login|logout|session|tokenrefresh|clerk|okta|passport"))

(defparameter *re-analytics*
  (cl-ppcre:create-scanner
   "gtag|google-analytics|googletagmanager|segment|mixpanel|amplitude|posthog|hotjar|fullstory|datadogrum|sentry|analytics\\.track|fbq\\("))

(defparameter *re-editor*
  (cl-ppcre:create-scanner
   "monaco|codemirror|tiptap|prosemirror|quill|slate|draftjs|tinymce|ckeditor|editorjs|ace\\.edit"))

(defparameter *re-vendor*
  (cl-ppcre:create-scanner
   "node_modules|chunk-vendors|polyfill|core-js|regenerator-runtime|cdn"))

(defparameter *re-worker* (cl-ppcre:create-scanner "worker|service-worker"))

(defparameter *bootstrap-signals*
  '("hydration" "chunk-loader" "service-worker-register"
    "worker-bootstrap" "wasm-bootstrap")
  "The startup signals that mean bootstrap even when the sample does not match.

Kept as a list beside the pattern rather than inside it because the Rust tests
these with `iter().any(|s| s == ...)` - EXACT string equality on a list field,
not a scan of its text. A signal of \"hydration-enabled\" must not match.")

;;; ---------------------------------------------------------------------------
;;; buildBoundarySample
;;; ---------------------------------------------------------------------------

(defun string-list (entry key)
  "`stringList`: the STRING members of a list field, or NIL.

Non-string members are dropped rather than stringified: the patterns are matched
against text, and `(princ 7)` would invent a digit that the entry never carried
as a string."
  (let ((value (field entry key)))
    (when (or (vectorp value) (listp value))
      (remove-if-not #'stringp (coerce value 'list)))))

(defun build-boundary-sample (entry)
  "`buildBoundarySample`: the lowercased text the label patterns scan.

Every scalar field is joined with newlines, then the list fields, then `content`
and `text` TRUNCATED to 120,000 units each. The truncation is per-field, so a
huge content cannot crowd the metadata out of the sample.

An absent entry yields the EMPTY-STRING fields joined - twelve newlines, not the
empty string - which is what the oracle pins as sample 1. That distinction
matters: a single-character class still scans twelve characters."
  (let ((parts
          (list
            (field-str entry "url") (field-str entry "file") (field-str entry "kind")
            (field-str entry "source") (field-str entry "originType")
            (field-str entry "classification")
            (format nil "~{~a~^~%~}" (string-list entry "frameworkHints"))
            (format nil "~{~a~^~%~}" (string-list entry "routeHints"))
            (format nil "~{~a~^~%~}" (string-list entry "startupSignals"))
            (format nil "~{~a~^~%~}" (string-list entry "imports"))
            (field-str entry "note") (field-str entry "mimeType")
            (field-str entry "stack"))))
    ;; content and text go LAST, after everything above, and they APPEND rather
    ;; than push: pushing here and reversing at the end would also reverse the
    ;; thirteen metadata fields, which changes the sample text and therefore
    ;; which patterns match.
    (dolist (key '("content" "text"))
      (let ((value (field entry key)))
        (when (stringp value)
          (setf parts (append parts (list (vovas.engine.util:utf16-prefix value 120000)))))))
    (string-downcase (format nil "~{~a~^~%~}" parts))))

;;; ---------------------------------------------------------------------------
;;; pushBoundaryLabel
;;; ---------------------------------------------------------------------------

(defun push-boundary-label (matches label score reason)
  "`pushBoundaryLabel`: add or MERGE one label match into MATCHES.

A label already present has its SCORE SUMMED and the reason appended if new, so
two independent signals for the same subsystem strengthen one entry rather than
producing two. The merge is why `apply-boundary-labels` sees scores above any
single rule's weight.

MATCHES is in insertion order and the merge searches linearly - the list is at
most eight long, so a hash table would cost more than it saves and would lose the
order that the stable sort downstream depends on."
  (let ((existing (find label matches :key (lambda (m) (field-str m "label"))
                                      :test #'string=)))
    (if existing
        (progn
          (setf (gethash "score" existing)
                (js-number-value
                 (+ (or (field existing "score") 0d0) score)))
          (when reason
            (let ((reasons (gethash "reasons" existing)))
              (unless (and reasons
                           (some (lambda (r) (and (stringp r) (string= r reason)))
                                 (coerce reasons 'list)))
                (setf (gethash "reasons" existing)
                      (concatenate 'vector (or reasons #()) (vector reason)))))))
        (push (let ((m (make-hash-table :test #'equal)))
                (setf (gethash "label" m) label
                      (gethash "score" m) (js-number-value score)
                      (gethash "reasons" m) (if reason (vector reason) #()))
                m)
              matches))
    matches))

;;; ---------------------------------------------------------------------------
;;; inferBoundaryLabels
;;; ---------------------------------------------------------------------------

(defun infer-boundary-labels (entry &key is-runtime classifications)
  "`inferBoundaryLabels`: the boundary matches for one entry.

`is-runtime` changes THREE rules, and each is deliberate:

  - a non-runtime entry whose CLASSIFICATION is \"runtime\" bootstraps, while a
    runtime entry does not re-earn bootstrap for being runtime;
  - a runtime whose KIND matches `*re-worker*` bootstraps instead;
  - only a runtime consults `related-chunks` for a vendor parentage, scoring 16
    rather than the 20 a direct vendor signal earns.

CLASSIFICATIONS maps asset id to classification, used only by that last rule. A
runtime spawned from a vendor chunk is vendor-by-parentage; the Rust breaks after
the FIRST such chunk, so a runtime with two vendor parents still scores 16 once."
  (let ((sample (build-boundary-sample entry))
        (matches '())
        (route-hints (string-list entry "routeHints"))
        (startup-signals (string-list entry "startupSignals"))
        (classification (field-str entry "classification")))
    (when (or (and (not is-runtime) (string= classification "runtime"))
              (cl-ppcre:scan *re-bootstrap* sample)
              (intersection startup-signals *bootstrap-signals* :test #'string=)
              (and is-runtime
                   (cl-ppcre:scan *re-worker* (field-str entry "kind"))))
      (setf matches (push-boundary-label matches "bootstrap" 30d0
                                         "bootstraps the page or runtime loader")))
    (when (or route-hints (cl-ppcre:scan *re-router* sample))
      (setf matches (push-boundary-label matches "router" 24d0
                                         "contains route or navigation signals")))
    (when (cl-ppcre:scan *re-state* sample)
      (setf matches (push-boundary-label matches "state" 24d0
                                         "contains state container signals")))
    (when (or (cl-ppcre:scan *re-data* sample)
              (member "graphql-client" startup-signals :test #'string=))
      (setf matches (push-boundary-label matches "data" 24d0
                                         "contains data-fetching or API signals")))
    (when (cl-ppcre:scan *re-auth* sample)
      (setf matches (push-boundary-label matches "auth" 24d0
                                         "contains authentication or session signals")))
    (when (cl-ppcre:scan *re-analytics* sample)
      (setf matches (push-boundary-label matches "analytics" 22d0
                                         "contains analytics or telemetry signals")))
    (when (cl-ppcre:scan *re-editor* sample)
      (setf matches (push-boundary-label matches "editor" 24d0
                                         "contains editor/runtime authoring signals")))
    (when (or (and (not is-runtime)
                   (member classification '("vendor" "framework") :test #'string=))
              (cl-ppcre:scan *re-vendor* sample))
      (setf matches (push-boundary-label matches "vendor" 20d0
                                         "looks like third-party or framework code")))
    (when is-runtime
      (let ((related (field entry "relatedChunks")))
        (when (or (vectorp related) (listp related))
          (dolist (chunk (coerce related 'list))
            (when (stringp chunk)
              (let ((parent (and classifications (gethash chunk classifications))))
                (when (member parent '("vendor" "framework") :test #'string=)
                  (setf matches (push-boundary-label
                                 matches "vendor" 16d0
                                 "spawned from a vendor/framework chunk"))
                  (return))))))))
    (nreverse matches)))

;;; ---------------------------------------------------------------------------
;;; boundaryOutcome
;;; ---------------------------------------------------------------------------

(defun boundary-outcome (matches)
  "`boundaryOutcome`: the four fields a labeled entry carries.

The sort is by score DESCENDING and must be STABLE: `state` and `data` both score
24 and the oracle pins `primaryBoundary: \"state\"`, which only holds if the
insertion order of `infer-boundary-labels` survives the sort. CL's `sort` is
stable for lists, but `stable-sort` says so at the call site instead of relying on
a reader knowing that.

`details` keeps at most FOUR matches, `labels` mirrors them in the same order, and
`primary` is the first label - so a fifth match influences nothing except its own
absence. `reasons` is deduplicated and capped at eight, formatted \"label: reason\".
The dedup happens AFTER formatting, so two identical texts from different labels
both survive: the label prefix is what distinguishes them."
  (let* ((sorted (stable-sort (copy-list matches) #'>
                               :key (lambda (m) (or (field m "score") 0d0))))
         (details (subseq sorted 0 (min 4 (length sorted))))
         (labels (mapcar (lambda (m) (field-str m "label")) details))
         (primary (or (first labels) ""))
         (reasons '()))
    (dolist (item details)
      (let ((label (field-str item "label"))
            (list (field item "reasons")))
        (when (or (vectorp list) (listp list))
          (dolist (reason (coerce list 'list))
            (when (stringp reason)
              (push (format nil "~a: ~a" label reason) reasons))))))
    (let ((unique (vovas.engine.panel.assets:unique-strings (nreverse reasons))))
      (list :details details
            :labels labels
            :primary primary
            :reasons (subseq unique 0 (min 8 (length unique)))))))

(defun apply-boundary-labels (entry matches)
  "`applyBoundaryLabels` on a JSON entry: write the four fields back onto ENTRY.

Mutates in place and answers ENTRY. The field NAMES are the wire spellings, so
this is where an entry becomes something `strip-boundary-entry` and the report can
read."
  (let ((outcome (boundary-outcome matches)))
    (setf (gethash "boundaryDetails" entry) (coerce (getf outcome :details) 'vector)
          (gethash "boundaryLabels" entry) (coerce (getf outcome :labels) 'vector)
          (gethash "primaryBoundary" entry) (getf outcome :primary)
          (gethash "boundaryReasons" entry) (coerce (getf outcome :reasons) 'vector))
    entry))

;;; ---------------------------------------------------------------------------
;;; stripBoundaryEntry
;;; ---------------------------------------------------------------------------

(defun strip-boundary-entry (entry kind)
  "`stripBoundaryEntry`: the trimmed shape the report renders.

`label` is the BARE FILE NAME when there is one, falling back to the id; `file`
and `url` are kept as separate fields, and `url` falls back to `objectUrl` because
runtime origins carry the object URL rather than a plain url. The fallback chain
is why a chunk shows \"main.js\" while a runtime shows its id."
  (let* ((file (field-str entry "file"))
         (file-or-url (cond ((plusp (length file)) file)
                            ((plusp (length (field-str entry "url"))) (field-str entry "url"))
                            (t (field-str entry "id"))))
         (bare (vovas.engine.panel.assets:get-bare-file-name file-or-url))
         (label (if (plusp (length bare)) bare (field-str entry "id")))
         (url (let ((u (field-str entry "url")))
                (if (plusp (length u)) u (field-str entry "objectUrl"))))
         (labels (field entry "boundaryLabels"))
         (reasons (field entry "boundaryReasons"))
         (out (make-hash-table :test #'equal)))
    (setf (gethash "kind" out) kind
          (gethash "id" out) (field-str entry "id")
          (gethash "label" out) label
          (gethash "file" out) (field-str entry "file")
          (gethash "url" out) url
          (gethash "primaryBoundary" out) (field-str entry "primaryBoundary")
          (gethash "boundaryLabels" out)
          (if (or (vectorp labels) (listp labels)) labels #())
          (gethash "boundaryReasons" out)
          (if (or (vectorp reasons) (listp reasons)) reasons #())
          (gethash "classification" out) (field-str entry "classification")
          (gethash "originType" out) (field-str entry "originType")
          (gethash "score" out)
          (js-number-value
           (or (field entry "score") 0d0)))
    out))
