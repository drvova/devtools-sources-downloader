;;;; pipeline.asd — the asset pipeline, loadable on its own.
;;;;
;;;; `:depends-on ("vovas-engine")` rather than naming the sibling module
;;;; systems: the pipeline reaches EVERY module (transforms, bundler, beautify,
;;;; sourcemaps, wasm, jscbytecode, v8codecache, zip, digest), and the engine
;;;; system already provides all of them in dependency order. Listing them again
;;;; here would be a second copy of that order, free to drift.
;;;;
;;;; The gate file is a component of the same system, AFTER the module, so
;;;; loading `vovas-engine.pipeline` gives both the thing and the check.

(asdf:defsystem "vovas-engine.pipeline"
  :description "The asset pipeline (pipeline.rs) for the DevTools sources-downloader engine"
  :author "sashathelambo"
  :license "MIT"
  :depends-on ("vovas-engine")
  :serial t
  :components ((:file "pipeline")
               (:file "gate-pipeline")))
