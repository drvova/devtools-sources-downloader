;;;; vovas-tools.asd — SBCL toolchain + CDP client for devtools-sources-downloader.

(asdf:defsystem "vovas-tools"
  :description "Build/check/pack toolchain and a Chrome DevTools Protocol client"
  :author "sashathelambo"
  :depends-on ("usocket" "babel" "com.inuoe.jzon" "cl-base64" "ironclad")
  :serial t
  :components ((:file "package")
               (:file "util")
               (:file "sexp")
               (:file "ws")
               (:file "http")
               (:file "chrome")
               (:file "cdp")
               (:file "panel")
               (:file "tasks")
               (:file "main")))
