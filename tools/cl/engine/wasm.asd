;;;; wasm.asd — the WebAssembly module layer, loadable on its own.
;;;;
;;;; `:depends-on ("vovas-engine")` and nothing else: this slice reads bytes and
;;;; writes records, so it needs the base system's packages but none of the
;;;; sibling slices. The gate file is a component AFTER the module, so loading
;;;; `vovas-engine.wasm` gives you both the thing and the check.

(asdf:defsystem "vovas-engine.wasm"
  :description "WebAssembly module parsing (wasm.rs) for the DevTools sources-downloader engine"
  :author "sashathelambo"
  :license "MIT"
  :depends-on ("vovas-engine")
  :serial t
  :components ((:file "wasm")
               (:file "gate-wasm")))
