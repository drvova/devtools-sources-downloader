;;;; beautify.asd — the beautify module and its gate, loadable on its own.
;;;;
;;;; `:depends-on ("vovas-engine")` rather than listing package/util/scanner,
;;;; so this slice keeps working when the integrator reorders the base system.
;;;; `:serial t` because the gate file names the module's package at read time.
;;;;
;;;; The components are BARE `(:file ...)` names, not wrapped in
;;;; `(:module "engine" ...)`. This .asd already lives in tools/cl/engine/, so a
;;;; module wrapper resolves to tools/cl/engine/engine/beautify.lisp and ASDF
;;;; fails with "Failed to find the TRUENAME" for a file that plainly exists.
;;;;
;;;; cl-unicode is a dependency of BEAUTIFY itself, not only of the gate: the
;;;; regex crate's `\w` includes the `Alphabetic` property, whose
;;;; Other_Alphabetic component is not reachable through SBCL's general
;;;; categories alone.

(asdf:defsystem "vovas-engine.beautify"
  :description "Minified detection and the scanner-aware JavaScript reformatter (beautify.rs)"
  :author "sashathelambo"
  :license "MIT"
  :depends-on ("vovas-engine" "cl-unicode")
  :serial t
  :components ((:file "beautify")
               (:file "gate-beautify")))
