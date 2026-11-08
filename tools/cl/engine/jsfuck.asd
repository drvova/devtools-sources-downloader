;;;; jsfuck.asd — the JSFuck decoder, gated against the shipped wasm engine.
;;;;
;;;; Depends on `vovas-engine` for four things and cannot carry its own copies:
;;;;   vovas.engine.util    js-trim / js-whitespace-p  (String.prototype.trim's
;;;;                        whitespace set, which CL's `string-trim` does not
;;;;                        match)
;;;;   vovas.engine.number  to-string / to-radix-string / to-number — the
;;;;                        ECMAScript number semantics the value model's
;;;;                        ToString and ToNumber delegate to. Reimplementing
;;;;                        them here would be a second definition of a function
;;;;                        the engine already owns, and the two would drift.
;;;;   vovas.engine.zip     civil-from-unix-secs, for `Date()` called as a
;;;;                        function. It lives in zip.lisp because the DOS
;;;;                        timestamps need it too.
;;;;   cl-ppcre             the three `return ...` body scanners
;;;;
;;;; `:serial t` because the gate file compiles against the module's symbols.

(asdf:defsystem "vovas-engine.jsfuck"
  :description "JSFuck ([], (), !, +) decoding ported from jsfuck.rs, gated on the shipped wasm engine"
  :author "sashathelambo"
  :license "MIT"
  :depends-on ("vovas-engine")
  :serial t
  :components ((:file "jsfuck")
               (:file "gate-jsfuck")))
