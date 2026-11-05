;;;; package.lisp — all packages up front so every file's symbols resolve at read time.

;; Data files are read in this package: it USEs CL, so `t` and `nil` are the
;; real booleans, and bare symbols intern here instead of polluting a real
;; package. Keywords keep their colon, exactly as in an .asd file.
(defpackage :vovas.sexp
  (:use :cl)
  (:documentation "Home package for sexp data files."))

(defpackage :vovas.tools.util
  (:nicknames :vtu)
  (:use :cl)
  (:export
   ;; paths
   #:repo-root
   #:find-on-path
   #:node-exe
   #:cargo-exe
   #:powershell-exe
   #:npm-argv
   #:cargo-argv
   ;; processes
   #:run-program
   #:run-step
   ;; logging
   #:log-line
   ;; io helpers
   #:crlf-join
   #:split-on
   #:split-lines
   #:read-headers
   #:read-exactly
   #:read-until-double-crlf
   #:read-until-eof
   #:file-size
   ;; text
   #:url-encode
   ;; sexp data files (the toolchain's own format)
   #:read-sexp
   #:read-sexp-file
   #:write-sexp-file
   #:sexp-string
   #:sexp-selftest
   #:sexp-error
   ;; json (wire only: the DevTools Protocol and Chrome's manifest.json)
   #:json-parse
   #:json-stringify
   #:json-obj))

(defpackage :vovas.cdp.ws
  (:use :cl)
  (:import-from :vovas.tools.util #:read-exactly)
  (:export
   #:ws-connect
   #:ws-send-text
   #:ws-read-message
   #:ws-close
   #:ws-open-p
   #:ws-error
   #:ws-error-message))

(defpackage :vovas.cdp.http
  (:use :cl)
  (:import-from :vovas.tools.util
   #:crlf-join #:read-headers #:read-exactly #:read-until-eof)
  (:export #:http-request))

(defpackage :vovas.cdp
  (:nicknames :vcdp)
  (:use :cl)
  (:import-from :vovas.tools.util
   #:repo-root #:find-on-path #:log-line
   #:json-parse #:json-stringify #:json-obj #:url-encode)
  (:import-from :vovas.cdp.ws
   #:ws-connect #:ws-send-text #:ws-read-message #:ws-close #:ws-open-p)
  (:import-from :vovas.cdp.http #:http-request)
  (:export
   ;; lifecycle
   #:launch
   #:attach
   #:kill
   #:with-browser
   ;; targets
   #:tabs
   #:use
   #:new-tab
   #:parse-ws-url
   #:connect-target
   ;; interaction
   #:call
   #:eval*
   #:shot
   #:nav
   ;; state
   #:*browser*
   ;; selftest
   #:smoke-test
   ;; panel verification
   #:panel-check))

(defpackage :vovas.tools
  (:nicknames :vt)
  (:use :cl)
  (:import-from :vovas.tools.util
   #:repo-root #:log-line #:json-parse #:npm-argv)
  (:import-from :vovas.cdp #:smoke-test #:panel-check)
  (:export #:main #:build #:check #:pack))
