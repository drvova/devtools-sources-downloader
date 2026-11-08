;;;; sourcemaps.asd — the sourcemaps slice, loadable on its own.
;;;;
;;;; Depends on `vovas-engine` for the shared util/text/decoders definitions it
;;;; borrows, and loads its gate immediately after the module so the gate can
;;;; never be run against a stale version of the port.
;;;;
;;;; Separate from vovas-engine.asd because that file belongs to the integrator:
;;;; a worker adds its own system and the integrator decides when it joins the
;;;; main one. :serial t inside the module keeps the module-then-gate order,
;;;; which matters because the gate calls the port at load time only inside
;;;; function bodies - a reversed order would still load, but a mistake in the
;;;; module would then surface as a gate failure instead of a compile error.

(asdf:defsystem "vovas-engine.sourcemaps"
  :description "sourceMappingURL discovery and source-map decoding, ported from sourcemaps.rs"
  :author "sashathelambo"
  :license "MIT"
  :depends-on ("vovas-engine")
  :serial t
  :components ((:file "sourcemaps")
               (:file "gate-sourcemaps")))
