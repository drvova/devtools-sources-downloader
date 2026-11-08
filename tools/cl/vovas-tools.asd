;;;; vovas-tools.asd — SBCL toolchain + CDP client for devtools-sources-downloader.

(asdf:defsystem "vovas-tools"
  :description "Build/check/pack toolchain and a Chrome DevTools Protocol client"
  :author "sashathelambo"
  ;; The engine is a dependency, not an optional extra: `vovas engine` and
  ;; `vovas unpack` are the native path over it, and before this line existed
  ;; the 48-gate engine was correct and unreachable from the toolchain.
  :depends-on ("usocket" "babel" "com.inuoe.jzon" "cl-base64" "ironclad"
               "vovas-engine")
  :serial t
  :components ((:file "package")
               (:file "util")
               (:file "sexp")
               (:file "ws")
               (:file "http")
               (:file "chrome")
               (:file "cdp")
               (:file "panel")
               (:file "download")
               (:file "tasks")
               (:file "cli")
               (:file "main")))
