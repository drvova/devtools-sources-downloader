;;;; policy.lisp — the capture policy the page world applies, from panel/policy.rs.
;;;;
;;;; This module is almost entirely CONSTANTS, and that is the point: the redaction
;;;; rule decided whether a captured token could reach an exported archive, and it
;;;; used to live inside a page-world JavaScript bundle with no test at all. It is
;;;; policy, not mechanism, so it belongs where it can be typed and checked.
;;;;
;;;; The panel injects this object into the page ahead of its first line
;;;; (`window.__CAPTURE__.policy`), so the page world reads one source of truth.
;;;;
;;;; The patterns are held as STRINGS, not as compiled scanners, because that is
;;;; what the engine ships: the object crosses into the page world and is compiled
;;;; there as a RegExp. Compiling them here as well would create a second
;;;; definition free to drift, so the gate compiles a fresh scanner from the string
;;;; each time instead.

(in-package :vovas.engine.panel.policy)

;;; ---------------------------------------------------------------------------
;;; The patterns
;;; ---------------------------------------------------------------------------

(defparameter *redact-key-pattern*
  "token|secret|password|passwd|cookie|authorization|bearer|jwt|session"
  "Object keys matching this are replaced with [redacted], case-insensitively.

A plain substring alternation with no word boundaries on purpose, and the oracle
pins the consequence: `sessions`, `sessionless` and `jwtoken` all match, while
`authHeader` does NOT (only `authorization` is listed). Widening this to word
boundaries would silently stop redacting `my_token_here` - a leak, not a tidiness
issue.")

(defparameter *text-mime-pattern*
  "(?:javascript|ecmascript|typescript|json|text|xml|svg|html|css)"
  "A payload whose MIME type matches this is decoded as text, not kept as bytes.
Substring, so `application/json; charset=utf-8` matches.")

(defparameter *graphql-url-marker* "graphql"
  "A request URL containing this is treated as a GraphQL endpoint.")

(defparameter *graphql-body-pattern*
  "(?:^|\\b)(query|mutation|subscription)\\b|operationName"
  "A request body whose text matches this is treated as a GraphQL operation.

Written in a form BOTH engines accept: the page world compiles it as a RegExp and
the engine compiles it with `unicode(false)` so the word boundary is ASCII there
too. The two sides used to spell this predicate separately, which is the same rule
written twice and free to drift. `operationName` is in the alternation because it
is a plain substring test, not a word-boundary one.")

(defparameter *graphql-body-keys* '("query" "operationName" "extensions")
  "Object keys whose presence marks a request body as a GraphQL operation.")

;;; ---------------------------------------------------------------------------
;;; Limits
;;;
;;; Eighteen budgets, all in one object because the page world reads them by name
;;; and a name that drifts stops a limit being enforced - silently, since nothing
;;; fails when a budget is simply never read.
;;; ---------------------------------------------------------------------------

(defparameter *limits*
  (list :items 12
        :keys 24
        :string 240
        :mutations 500
        :runtime-items 200
        :runtime-text 262144
        :runtime-binary 1048576
        :resource-urls 160
        :script-urls 80
        :endpoints 20
        :response-text 10000
        :socket-message 2000
        :mutation-text 200
        :element-text 80
        :element-label 40
        :class-names 8
        :query-items 6
        :technologies 12)
  "The budgets the page world enforces while capturing. Keys use the Lisp-side
kebab form; `capture-policy` renders the camelCase wire names.")

;;; ---------------------------------------------------------------------------
;;; default-strategy
;;;
;;; Owned by panel/stackprofile.rs, which IS ported - `default-strategy` below
;;; delegates to `panel.stackprofile:default-strategy`, which owns the function
;;; in the Rust. It was inlined here when policy was the only ported user; the
;;; delegation is the move the old note promised.
;;; ---------------------------------------------------------------------------

(defun default-strategy ()
  "`default_strategy`.

ONE DEFINITION: this now delegates to `panel.stackprofile`, which owns the
function in the Rust. It was inlined here when policy was the only ported user,
with a note saying it would move - this is that move."
  (vovas.engine.panel.stackprofile:default-strategy))

;;; ---------------------------------------------------------------------------
;;; Rendering the wire object
;;;
;;; The keys below are the BOUNDARY CONTRACT: the page world reads
;;; `window.__CAPTURE__.policy.redactKey` and friends by literal name, so the
;;; camelCase spellings are load-bearing and cannot be tidied into kebab.
;;; ---------------------------------------------------------------------------

(defun policy-wire-name (lisp-name)
  "`BOOT-DELAY-MS` -> `bootDelayMs`. Only hyphens become camel humps; everything
else is lowercased, so a name with no hyphens passes through unchanged."
  (let ((out (make-string-output-stream))
        (upcase-next nil))
    (loop for c across (string-downcase lisp-name)
          do (cond ((char= c #\-) (setf upcase-next t))
                   (upcase-next (write-char (char-upcase c) out) (setf upcase-next nil))
                   (t (write-char c out))))
    (get-output-stream-string out)))

(defun strategy-wire (strategy)
  "The strategy plist as wire keys, in the engine's insertion order."
  (loop for (k v) on strategy by #'cddr
        collect (intern (policy-wire-name (symbol-name k)) :keyword)
        collect v))

(defun limits-wire (limits)
  "The limits plist as wire keys, preserving the engine's key ORDER.

Order matters because the object is serialized and compared as text in the
archive; serde_json with `preserve_order` emits insertion order, so a plist
rebuilt in a different order would produce a different artifact from identical
values."
  (loop for (k v) on limits by #'cddr
        collect (intern (policy-wire-name (symbol-name k)) :keyword)
        collect v))

(defun capture-policy ()
  "`capture_policy`: the object the panel injects as `window.__CAPTURE__.policy`.

Key order follows the Rust's `json!` macro, which preserves insertion order under
`serde_json`'s `preserve_order`."
  (list :redact-key *redact-key-pattern*
        :text-mime *text-mime-pattern*
        :graphql-url *graphql-url-marker*
        :graphql-body *graphql-body-pattern*
        :graphql-body-keys *graphql-body-keys*
        :default-strategy (strategy-wire (default-strategy))
        :limits (limits-wire *limits*)))
