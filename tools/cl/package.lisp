;;;; package.lisp — all packages up front so every file's symbols resolve at read time.

(defpackage :vovas.tools.util
  (:nicknames :vtu)
  (:use :cl)
  (:export
   ;; paths
   #:repo-root
   #:cache-dir
   #:powershell-exe
   ;; processes
   #:run-program
   ;; logging
   #:log-line
   ;; io helpers
   #:crlf-join
   #:split-on
   #:read-headers
   #:read-exactly
   #:read-until-eof
   #:file-size
   ;; text
   #:url-encode
   ;; json: the wire boundary only (the DevTools Protocol).
   ;; Objects decode to plists and encode from plists, so call sites read as data.
   #:json-decode
   #:json-encode))

(defpackage :vovas.cdp.ws
  (:use :cl)
  (:import-from :vovas.tools.util #:read-exactly)
  (:export
   #:ws-connect
   #:ws-send-text
   #:ws-read-message
   #:ws-close
   #:ws-conn-open-p
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
   #:cache-dir #:log-line #:url-encode)
  (:import-from :vovas.cdp.ws
   #:ws-connect #:ws-send-text #:ws-read-message #:ws-close #:ws-conn-open-p)
  (:import-from :vovas.cdp.http #:http-request)
  (:export
   ;; lifecycle
   #:launch
   #:attach
   #:kill
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
   #:smoke-test))

(defpackage :vovas.tools
  (:nicknames :vt)
  (:use :cl)
  (:import-from :vovas.cdp #:smoke-test)
  (:export #:main))
