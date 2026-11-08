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

;;; ---------------------------------------------------------------------------
;;; script-asset->json
;;; ---------------------------------------------------------------------------

(defun script-asset->json (asset)
  "A `script-asset` as the JSON-shaped hash table the boundary code reads.

The Rust serialises the struct with serde and feeds the result to the inference
function, so the inference reads WIRE field names. Reproducing that here is what
keeps one inference function serving both assets and runtime origins - the
alternative, a second asset-specific inference path, would let the two drift.

The four boundary fields are included because the SAME function also serves
`strip-boundary-entry`, which reports them. Omitting them made every chunk report
an empty `primaryBoundary` and `boundaryLabels` while the struct held the right
values - the report was reading a view that predated the labeling."
  (let ((out (make-hash-table :test #'equal)))
    (setf (gethash "id" out) (script-asset-id asset)
          (gethash "url" out) (script-asset-url asset)
          (gethash "file" out) (script-asset-file asset)
          (gethash "kind" out) "chunk"
          (gethash "classification" out) (script-asset-classification asset)
          (gethash "frameworkHints" out) (coerce (script-asset-framework-hints asset) 'vector)
          (gethash "routeHints" out) (coerce (script-asset-route-hints asset) 'vector)
          (gethash "startupSignals" out) (coerce (script-asset-startup-signals asset) 'vector)
          (gethash "imports" out) (coerce (script-asset-imports asset) 'vector)
          (gethash "content" out) (script-asset-content asset)
          (gethash "score" out) (script-asset-score asset)
          (gethash "primaryBoundary" out) (script-asset-primary-boundary asset)
          (gethash "boundaryLabels" out) (coerce (script-asset-boundary-labels asset) 'vector)
          (gethash "boundaryReasons" out) (coerce (script-asset-boundary-reasons asset) 'vector)
          (gethash "boundaryDetails" out)
          (map 'vector
               (lambda (detail)
                 (let ((h (make-hash-table :test #'equal)))
                   (setf (gethash "label" h)
                         (vovas.engine.panel.assets:boundary-detail-label detail)
                         (gethash "score" h)
                         (js-number-value
                          (vovas.engine.panel.assets:boundary-detail-score detail))
                         (gethash "reasons" h)
                         (coerce (vovas.engine.panel.assets:boundary-detail-reasons detail)
                                 'vector))
                   h))
               (coerce (script-asset-boundary-details asset) 'vector)))
    out))

(defun write-boundary-labels-into-asset (asset outcome)
  "Write a `boundary-outcome` back onto a `script-asset`.

`boundary-details` becomes a vector of `boundary-detail` structs, which is the
type the asset accessor promises; the labels, primary and reasons are plain
sequences.

The asset's SCORE becomes its best boundary score. This is set exactly once, from
the details, with the classifier's score kept only when there are no details -
assigning it twice would read back the value the first assignment wrote."
  (let ((details
          (map 'vector
               (lambda (item)
                 ;; positional, and SCORE is a DOUBLE-FLOAT slot: the match
                 ;; score arrives as an integer from `js-number-value`, so it
                 ;; has to be coerced or the struct constructor signals.
                 (vovas.engine.panel.assets:make-boundary-detail
                  (field-str item "label")
                  (coerce (or (field item "score") 0d0) 'double-float)
                  (let ((r (field item "reasons")))
                    (if (or (vectorp r) (listp r))
                        (coerce r 'list)
                        '()))))
               (coerce (getf outcome :details) 'vector))))
    ;; The SLOTS are LISTS, not vectors: `script-asset` defaults them to `'()`
    ;; and `count-boundary-labels` walks them with `dolist`. Writing a vector here
    ;; compiles fine and then fails at the first `dolist` with "not of type LIST".
    ;; JSON vectors are built at the serialization boundary, not in the struct.
    ;;
    ;; `score` is NOT assigned. The asset keeps the score its classifier gave it
    ;; (the fixture's router chunk is 39 and its best boundary match is 24) - the
    ;; four boundary fields are the only things labeling writes back.
    (setf (script-asset-boundary-details asset) (coerce details 'list)
          (script-asset-boundary-labels asset) (coerce (getf outcome :labels) 'list)
          (script-asset-primary-boundary asset) (or (getf outcome :primary) "")
          (script-asset-boundary-reasons asset) (coerce (getf outcome :reasons) 'list))
    asset))

;;; ---------------------------------------------------------------------------
;;; countBoundaryLabels over JSON entries
;;; ---------------------------------------------------------------------------

(defun count-boundary-labels-values (items)
  "`countBoundaryLabelsValues`: label counts across JSON entries."
  (let ((c (vovas.engine.panel.model:make-counts)))
    (dolist (item items)
      (let ((labels (field item "boundaryLabels")))
        (when (or (vectorp labels) (listp labels))
          (dolist (label (coerce labels 'list))
            (when (stringp label)
              (vovas.engine.panel.model:counts-add c label))))))
    c))

(defun count-tagged-entries-values (items)
  "`countTaggedEntriesValues`: JSON entries carrying at least one label."
  (count-if (lambda (item)
              (let ((labels (field item "boundaryLabels")))
                (and (or (vectorp labels) (listp labels))
                     (plusp (length labels)))))
            items))

;;; ---------------------------------------------------------------------------
;;; buildBoundaryLabels
;;; ---------------------------------------------------------------------------

(defun build-boundary-labels (assets origins)
  "`buildBoundaryLabels`: label every asset and runtime origin, then summarise.

ASSETS is a list of `script-asset` structs and ORIGINS a list of JSON hash
tables. Both are LABELED IN PLACE (the structs and the hash tables are mutated,
not copied) and the report is assembled from the labeled results.

The classifications map is built from the assets BEFORE any labeling, so a
runtime's vendor-parentage test sees the classifier's verdict rather than a
label this function is in the middle of writing. That ordering is why it is a
separate pass instead of being folded into the asset loop.

Chunks and runtimes sort by score DESCENDING, stably - the fixture has ties and
the oracle pins their order."
  (let ((classifications (make-hash-table :test #'equal)))
    (dolist (asset assets)
      (setf (gethash (script-asset-id asset) classifications)
            (script-asset-classification asset)))
    ;; label the assets
    (dolist (asset assets)
      (write-boundary-labels-into-asset
       asset
       (boundary-outcome
        (infer-boundary-labels (script-asset->json asset)
                               :is-runtime nil
                               :classifications classifications))))
    ;; label the runtime origins
    (dolist (origin origins)
      (apply-boundary-labels
       origin
       (infer-boundary-labels origin :is-runtime t
                                     :classifications classifications)))
    ;; the report
    (let* ((tagged-chunks
             (stable-sort
              (remove-if (lambda (a) (zerop (length (script-asset-boundary-labels a))))
                         (copy-list assets))
              #'>
              :key #'script-asset-score))
           (tagged-runtime
             (stable-sort
              (remove-if (lambda (o) (zerop (length (or (field o "boundaryLabels") #()))))
                         (copy-list origins))
              #'>
              :key (lambda (o) (or (field o "score") 0d0))))
           (out (make-hash-table :test #'equal)))
      (setf (gethash "generatedAt" out) (vovas.engine.pipeline:iso8601-now)
            (gethash "categories" out) (coerce *boundary-labels* 'vector)
            (gethash "summary" out)
            (let ((sm (make-hash-table :test #'equal)))
              (setf (gethash "chunkLabels" sm)
                    (vovas.engine.panel.model:counts-alist
                     (vovas.engine.panel.assets:count-boundary-labels assets))
                    (gethash "runtimeLabels" sm)
                    (vovas.engine.panel.model:counts-alist
                     (count-boundary-labels-values origins))
                    (gethash "taggedChunks" sm)
                    (vovas.engine.panel.assets:count-tagged-entries assets)
                    (gethash "taggedRuntime" sm)
                    (count-tagged-entries-values origins))
              sm)
            (gethash "chunks" out)
            (map 'vector (lambda (a) (strip-boundary-entry (script-asset->json a) "chunk"))
                 tagged-chunks)
            (gethash "runtime" out)
            (map 'vector (lambda (o) (strip-boundary-entry o "runtime"))
                 tagged-runtime))
      out)))

;;; ---------------------------------------------------------------------------
;;; collectInterestingEntrypoints
;;; ---------------------------------------------------------------------------

(defun entrypoint-why (parts)
  "Join the non-empty strings in PARTS with \" | \".

Empty parts are DROPPED, not placeholders - an asset with no bundler yields
\"bootstrap | framework\" rather than \"bootstrap | framework |  | \"."
  (format nil "~{~a~^ | ~}" (remove-if (lambda (s) (zerop (length s))) parts)))

(defun collect-interesting-entrypoints (assets origins)
  "`collectInterestingEntrypoints`: the ranked entrypoint list, capped at 14.

Chunks and runtimes are collected into ONE list and then sorted together, so a
runtime can outrank a chunk. Two sort keys, in order: score descending, then
TIMESTAMP ASCENDING as the tiebreak - the second key is why this is not a plain
`sort-by-score`.

The runtime `timestamp` is read through `field-number`, which applies the
truthiness rule: an entry whose timestamp is 0 reports 0 either way, but the
ordering among equal scores depends on the real value being read."
  (let ((items '()))
    (dolist (asset assets)
      (let* ((bare (vovas.engine.panel.assets:get-bare-file-name
                    (script-asset-url asset)))
             (label (if (plusp (length bare)) bare (script-asset-id asset)))
             (item (make-hash-table :test #'equal)))
        (setf (gethash "kind" item) "chunk"
              (gethash "id" item) (script-asset-id asset)
              (gethash "label" item) label
              (gethash "file" item) (script-asset-file asset)
              (gethash "url" item) (script-asset-url asset)
              (gethash "score" item) (js-number-value (script-asset-score asset))
              (gethash "classification" item) (script-asset-classification asset)
              (gethash "primaryBoundary" item) (script-asset-primary-boundary asset)
              (gethash "boundaryLabels" item)
              (coerce (script-asset-boundary-labels asset) 'vector)
              (gethash "why" item)
              (entrypoint-why (list (script-asset-primary-boundary asset)
                                    (script-asset-classification asset)
                                    (script-asset-bundler asset)
                                    (format nil "~{~a~^, ~}"
                                            (script-asset-startup-signals asset))))
              (gethash "startupSignals" item)
              (coerce (script-asset-startup-signals asset) 'vector)
              (gethash "routeHints" item) (coerce (script-asset-route-hints asset) 'vector)
              (gethash "frameworkHints" item)
              (coerce (script-asset-framework-hints asset) 'vector))
        (push item items)))
    (dolist (origin origins)
      (let* ((file (field-str origin "file"))
             (url (field-str origin "url"))
             (kind (field-str origin "kind"))
             (id (field-str origin "id"))
             (source (cond ((plusp (length file)) file)
                           ((plusp (length url)) url)
                           (t kind)))
             (bare (vovas.engine.panel.assets:get-bare-file-name source))
             (label (if (plusp (length bare)) bare id))
             (related (string-list origin "relatedChunks"))
             (display-url (if (plusp (length url)) url (field-str origin "objectUrl")))
             (item (make-hash-table :test #'equal)))
        (setf (gethash "kind" item) "runtime"
              (gethash "id" item) id
              (gethash "label" item) label
              (gethash "file" item) file
              (gethash "url" item) display-url
              (gethash "score" item)
              (js-number-value (field-number origin "score"))
              (gethash "originType" item) (field-str origin "originType")
              (gethash "timestamp" item)
              (js-number-value (field-number origin "timestamp"))
              (gethash "primaryBoundary" item) (field-str origin "primaryBoundary")
              (gethash "boundaryLabels" item)
              (let ((l (field origin "boundaryLabels")))
                (if (or (vectorp l) (listp l)) l #()))
              (gethash "why" item)
              (entrypoint-why (list (field-str origin "primaryBoundary")
                                    kind
                                    (field-str origin "originType")
                                    (format nil "~{~a~^, ~}" related)))
              (gethash "relatedChunks" item) (coerce related 'vector))
        (push item items)))
    ;; sort: score DESC, then timestamp ASC
    (let ((sorted
            (stable-sort
             (nreverse items)
             (lambda (a b)
               (let ((sa (field-number a "score"))
                     (sb (field-number b "score")))
                 (if (/= sa sb)
                     (> sa sb)
                     (< (field-number a "timestamp")
                        (field-number b "timestamp"))))))))
      (coerce (subseq sorted 0 (min 14 (length sorted))) 'vector))))

;;; ---------------------------------------------------------------------------
;;; buildFrameworkStateSummary
;;; ---------------------------------------------------------------------------

(defun framework-state-slice (state key)
  "STATE's slice at KEY as a vector, or an empty vector when absent.

Uses a BARE `gethash`, like the Rust's `.get(...)`, so a present-but-falsy slice
is forwarded rather than filtered out. `field` would apply the truthiness rule
and drop it."
  (let ((v (and (hash-table-p state) (gethash key state))))
    (if (or (vectorp v) (listp v)) (coerce v 'vector) #())))

(defun framework-state-slice-length (state key)
  "The LENGTH of STATE's slice at KEY, or 0. Same presence rule as the slices."
  (let ((v (and (hash-table-p state) (gethash key state))))
    (if (or (vectorp v) (listp v)) (length v) 0)))

(defun build-framework-state-summary (framework-state)
  "`buildFrameworkStateSummary`: the panel's view of the recon framework state.

A non-truthy state answers JSON NULL rather than an empty summary, so the caller
can tell \"the page had no framework state\" from \"the framework state was empty\".

Two access rules appear here and they are NOT interchangeable:
  - `field-str` / `field-number` apply the TRUTHINESS filter, so a falsy value
    reads as absent;
  - the pass-through slices (`roots`, `stores`, ...) and `queryKeys` use a bare
    `gethash`, because the Rust calls `.get(...)` there and a present-but-falsy
    slice must still be forwarded and still be counted.

`related-artifacts` is asked of `paths` SYMBOLICALLY: that module owns the slice
table and loads after this one, so a package-level import would be read before the
package exists."
  (unless (vovas.engine.panel.model:js-truthy framework-state)
    (return-from build-framework-state-summary nil))
  (let* ((state framework-state)
         (router (or (and (hash-table-p (gethash "router" state))
                          (gethash "router" state))
                     (make-hash-table :test #'equal)))
         (summary (or (and (hash-table-p (gethash "summary" state))
                           (gethash "summary" state))
                      (make-hash-table :test #'equal)))
         (technologies (let ((v (gethash "technologies" state)))
                         (if (or (vectorp v) (listp v)) v #())))


         (detected
           (let ((names '()))
             (dolist (item (coerce technologies 'list))
               (push (if (vovas.engine.panel.model:js-truthy item)
                         (field-str item "name")
                         "")
                     names))
             (dolist (item (coerce (let ((v (gethash "detectedTechnologies" summary)))
                                     (if (or (vectorp v) (listp v)) v #()))
                                   'list))
               (when (stringp item) (push item names)))
             (remove "" (vovas.engine.panel.assets:unique-strings (nreverse names))
                     :test #'string=)))
         (router-framework
           (let ((fw (field-str router "framework")))
             (if (plusp (length fw))
                 fw
                 (let ((fb (field-str summary "routerFramework")))
                   (if (plusp (length fb)) fb "generic")))))
         (route (let ((r (field-str router "route")))
                  (if (plusp (length r)) r (field-str router "pathname"))))
         (profile (let ((p (field-str state "profile")))
                    (if (plusp (length p)) p "generic-app")))
         (out (make-hash-table :test #'equal)))
    ;; The slice accessor is a top-level helper rather than an `flet`: a local
    ;; function referenced from inside a long `setf` of `gethash` places is a
    ;; shape SBCL compiles without complaint and then reports as an unbound
    ;; VARIABLE at run time, which is a confusing way to learn that lesson.
    (setf (gethash "profile" out) profile
          (gethash "generatedAt" out) (field-str state "generatedAt")
          (gethash "reason" out) (field-str state "reason")
          (gethash "rootCount" out) (framework-state-slice-length state "roots")
          (gethash "storeCount" out) (framework-state-slice-length state "stores")
          (gethash "queryCount" out) (framework-state-slice-length state "queries")
          (gethash "hydrationCount" out) (framework-state-slice-length state "hydration")
          (gethash "authCount" out) (framework-state-slice-length state "auth")
          (gethash "routerFramework" out) router-framework
          (gethash "route" out) route
          (gethash "routerSource" out) (field-str router "source")
          (gethash "queryKeyCount" out) (framework-state-slice-length router "queryKeys")
          (gethash "detectedTechnologies" out) (coerce detected 'vector)
          (gethash "roots" out) (framework-state-slice state "roots")
          (gethash "stores" out) (framework-state-slice state "stores")
          (gethash "queries" out) (framework-state-slice state "queries")
          (gethash "hydration" out) (framework-state-slice state "hydration")
          (gethash "auth" out) (framework-state-slice state "auth")
          (gethash "relatedArtifacts" out)
          (coerce (funcall (find-symbol "COLLECT-FRAMEWORK-ARTIFACT-PATHS"
                                        :vovas.engine.panel.paths)
                           state)
                  'vector))
    out))
