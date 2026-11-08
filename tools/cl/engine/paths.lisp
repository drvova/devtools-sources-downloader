;;;; paths.lisp — the archive's own layout, from panel/paths.rs.
;;;;
;;;; A path written by one module and referenced by another is a CONTRACT, so it
;;;; is spelled once here. Renaming an artifact is then a change at every
;;;; reference rather than a report linking to a file nothing writes.
;;;;
;;;; This module is two tables and one presence rule. That is the whole point: the
;;;; value is that nothing else spells these paths, not that there is logic in
;;;; them.

(in-package :vovas.engine.panel.paths)

;;; ---------------------------------------------------------------------------
;;; Framework-state slices: archive path -> state key
;;; ---------------------------------------------------------------------------

(defparameter *framework-artifacts*
  '(("_framework/summary.json" . "summary")
    ("_framework/router-state.json" . "router")
    ("_framework/framework-roots.json" . "roots")
    ("_framework/store-snapshots.json" . "stores")
    ("_framework/query-caches.json" . "queries")
    ("_framework/hydration-payloads.json" . "hydration")
    ("_framework/auth-state.json" . "auth"))
  "The seven framework-state slices the export writes, as (path . state-key).

An alist rather than two parallel lists so a path and its key cannot drift apart
by an edit to only one of them.")

;;; ---------------------------------------------------------------------------
;;; Analysis artifact paths
;;;
;;; Spelled as constants because other modules reference them by name, and a
;;; literal in two places is a path that can be renamed in one.
;;; ---------------------------------------------------------------------------

(defparameter *analysis-chunk-map* "_analysis/chunk-map.json")
(defparameter *analysis-cross-boundary-flows* "_analysis/cross-boundary-flows.json")
(defparameter *analysis-module-graph* "_analysis/module-graph.json")
(defparameter *analysis-startup-chain* "_analysis/startup-chain.json")
(defparameter *analysis-runtime-origins* "_analysis/runtime-origins.json")
(defparameter *analysis-boundary-labels* "_analysis/boundary-labels.json")
(defparameter *analysis-framework-runtime* "_analysis/framework-runtime.json")
(defparameter *analysis-interesting-entrypoints* "_analysis/interesting-entrypoints.json")
(defparameter *analysis-index-html* "_analysis/index.html"
  "The human-readable analysis page. Not in the artifact table below: it is
written but is not addressed by an analysis KEY, which is why it is separate.")

(defparameter *analysis-artifacts*
  (list (cons *analysis-chunk-map* "chunkMap")
        (cons *analysis-cross-boundary-flows* "crossBoundaryFlows")
        (cons *analysis-module-graph* "moduleGraph")
        (cons *analysis-startup-chain* "startupChain")
        (cons *analysis-runtime-origins* "runtimeOrigins")
        (cons *analysis-boundary-labels* "boundaryLabels")
        (cons *analysis-framework-runtime* "frameworkRuntime")
        (cons *analysis-interesting-entrypoints* "interestingEntrypoints"))
  "The EIGHT analysis artifacts the export writes, as (path . analysis-key).
`*analysis-index-html*` is deliberately absent - see its docstring.")

;;; ---------------------------------------------------------------------------
;;; Presence
;;; ---------------------------------------------------------------------------

(defun framework-slice-present-p (state key)
  "Whether framework-state slice KEY is present in STATE.

Presence is ONE rule for objects, arrays and strings alike, because it goes
through `assets::keys_len`. The writer and the artifact index used to test
presence differently - the writer counted keys, the index demanded an object or an
array - so a slice holding a NON-EMPTY STRING was written to the archive and left
out of the index that points at it. That is the bug this function exists to make
impossible: one predicate, called by both sides."
  (> (vovas.engine.panel.assets:keys-len
      (and (hash-table-p state) (gethash key state)))
     0))
