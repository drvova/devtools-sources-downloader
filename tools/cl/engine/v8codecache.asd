;;;; v8codecache.asd — the V8 code-cache reader slice, loadable on its own.
;;;;
;;;; `:depends-on ("vovas-engine")` rather than on any sibling module system: the
;;;; reader shares only `util`-level concerns and reaches nothing in the pipeline,
;;;; so it must LOAD and its gate must RUN before the sibling binary-tier slices
;;;; exist. The gate file is a component of the same system, after the module, so
;;;; loading `vovas-engine.v8codecache` gives you both the port and its check.

(asdf:defsystem "vovas-engine.v8codecache"
  :description "V8 code-cache reader (v8codecache.rs) for the DevTools sources-downloader engine"
  :author "sashathelambo"
  :license "MIT"
  :depends-on ("vovas-engine")
  :serial t
  :components ((:file "v8codecache")
               (:file "gate-v8codecache")))
