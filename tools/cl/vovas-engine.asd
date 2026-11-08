;;;; vovas-engine.asd — the engine port, loadable on its own.
;;;;
;;;; Separate from vovas-tools.asd so the port can be exercised without the
;;;; toolchain's Chrome dependencies, and so a gate run never needs a browser.
;;;;
;;;; cl-ppcre is the one dependency: the 93 `Regex::new` sites in the Rust port
;;;; are patterns over minified JavaScript, and hand-writing them would trade a
;;;; known-correct engine for a known-buggy one.

(asdf:defsystem "vovas-engine"
  :description "JavaScript-to-Lisp port of the DevTools sources-downloader engine"
  :author "sashathelambo"
  :license "MIT"
  :depends-on ("cl-ppcre" "com.inuoe.jzon" "ironclad" "babel")
  :serial t
  :components ((:module "engine"
                :serial t
                :components ((:file "package")
                             (:file "util")
                             (:file "number")
                             (:file "decoders")
                             (:file "scanner")
                             (:file "digest")
                             (:file "text")
                             (:file "gate")))))
