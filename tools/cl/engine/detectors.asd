;;;; detectors.asd — the layer detector slice, loadable on its own.
;;;;
;;;; `:depends-on ("vovas-engine")` rather than the sibling module systems,
;;;; because the four stages `detect_layers` calls are reached through the
;;;; `*stage-providers*` seams: this slice must LOAD and its gate must RUN
;;;; before those modules exist, and must pick them up automatically when they
;;;; do. Depending on them here would make the port unbuildable until every
;;;; parallel slice landed.
;;;;
;;;; The gate file is a component of the same system, after the module, so
;;;; loading `vovas-engine.detectors` gives you both the thing and the check.
;;;;
;;;; ASDF prints a warning on every load: a file `engine/detectors.asd` is
;;;; expected to define `detectors` or a `detectors/...` subsystem, and this one
;;;; defines `vovas-engine.detectors` because the port's naming contract fixes
;;;; that name. Measured: `asdf:defsystem*` does NOT suppress it (tried, still
;;;; warns), so the warning is accepted rather than papered over - renaming the
;;;; system to satisfy the file-name check would break every caller, which is a
;;;; far worse trade than two lines of stderr on a gate run.

(asdf:defsystem "vovas-engine.detectors"
  :description "Obfuscation-layer detection (detectors.rs) for the DevTools sources-downloader engine"
  :author "sashathelambo"
  :license "MIT"
  :depends-on ("vovas-engine")
  :serial t
  :components ((:file "detectors")
               (:file "gate-detectors")))
