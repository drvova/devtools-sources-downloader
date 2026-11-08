;;;; jscbytecode.asd — the JavaScriptCore cached-bytecode slice, loadable alone.
;;;;
;;;; `:depends-on ("vovas-engine")` only. This module is self-contained binary
;;;; parsing: it reads no other module's helpers, so unlike the detectors slice
;;;; it needs no seams and its gate can assert every case against the Rust
;;;; crate's fixtures directly.
;;;;
;;;; The gate file is a component of the same system, after the module, so
;;;; loading `vovas-engine.jscbytecode` gives you both the thing and the check.

(asdf:defsystem "vovas-engine.jscbytecode"
  :description "JavaScriptCore cached-bytecode recovery (jscbytecode.rs) for the DevTools sources-downloader engine"
  :author "sashathelambo"
  :license "MIT"
  :depends-on ("vovas-engine")
  :serial t
  :components ((:file "jscbytecode")
               (:file "gate-jscbytecode")))
