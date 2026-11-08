;;;; zip.asd — the archive slice, loadable on its own.
;;;;
;;;; `:depends-on ("vovas-engine")` rather than the sibling module systems, for
;;;; the reason detectors.asd gives: `build-zip` reaches `decode-base64-to-bytes`
;;;; through the established `vovas.engine.decoders` package, which the engine
;;;; system provides, and `salza2`/`chipz` are declared here because they are
;;;; needed by THIS module alone - the engine proper has no compressor.
;;;;
;;;; The gate file is a component of the same system, AFTER the module, so
;;;; loading `vovas-engine.zip` gives both the thing and the check.

(asdf:defsystem "vovas-engine.zip"
  :description "The zip archive writer and reader (zip.rs) for the DevTools sources-downloader engine"
  :author "sashathelambo"
  :license "MIT"
  :depends-on ("vovas-engine" "salza2" "chipz")
  :serial t
  :components ((:file "zip")
               (:file "gate-zip")))
