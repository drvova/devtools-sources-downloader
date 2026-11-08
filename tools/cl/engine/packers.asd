;;;; packers.asd — the packer/obfuscator module, gated against the wasm oracle.
;;;;
;;;; Depends on `vovas-engine` for `vovas.engine.util` (regex-escape,
;;;; utf16-prefix) and for cl-ppcre; the gate file comes last because it needs
;;;; the module to exist when it compiles.

(asdf:defsystem "vovas-engine.packers"
  :description "Packer and obfuscator layers ported from packers.rs, gated on the wasm oracle"
  :author "sashathelambo"
  :license "MIT"
  :depends-on ("vovas-engine")
  :serial t
  :components ((:file "packers")
               (:file "gate-packers")))
