;;;; package.lisp — the engine port's packages.
;;;;
;;;; Separate from :vovas.tools on purpose. The toolchain drives subprocesses
;;;; and Chrome; the engine is a pure function library with no I/O, so its
;;;; package must not be able to reach a shell by accident.
;;;;
;;;; Two packages instead of one:
;;;;   :vovas.engine        the port itself, JavaScript semantics implemented
;;;;                        directly. Nothing here knows the oracle exists.
;;;;   :vovas.engine.gate   the oracle readers and the comparison harness.
;;;;                        Keeping the comparison out of the port means a port
;;;;                        function can never "know" which case it is being
;;;;                        run against.

(defpackage :vovas.engine.util
  (:use :cl)
  (:export
   ;; JavaScript string semantics. Char-based here; the UTF-16 view is
   ;; `utf16-*`, because the archive paths are indexed in UTF-16 units.
   #:js-trim
   #:js-whitespace-p
   #:utf16-length
   #:utf16-prefix
   #:utf16-suffix
   #:utf16-substring
   ;; path-hostile characters, one definition (the panel writes names)
   #:bad-path-chars-p
   #:bad-path-chars-with-slash-p
   #:regex-escape))

(defpackage :vovas.engine.number
  (:use :cl)
  (:export
   ;; ECMAScript Number::toString and friends. SBCL's printer is not JS's.
   #:to-string
   #:to-radix-string
   #:to-number
   #:js-round
   #:to-fixed
   #:parse-int))

(defpackage :vovas.engine.text
  (:use :cl)
  (:import-from :vovas.engine.util
                #:js-trim #:utf16-length #:utf16-prefix
                #:bad-path-chars-p #:bad-path-chars-with-slash-p
                #:regex-escape)
  (:import-from :vovas.engine.number
                #:to-string #:js-round #:to-fixed)
  (:export
   #:hash-string
   #:safe-decode-uri-component
   #:sanitize-path-part
   #:append-path-suffix
   #:normalize-url-candidate
   #:sanitize-filename
   #:sanitize-page-title
   #:format-size
   #:format-ms
   #:locale-compare))

(defpackage :vovas.engine.decoders
  (:use :cl)
  (:export
   ;; only the escape decoder; the base64/inflate halves land with the binary tier
   #:decode-escapes))

(defpackage :vovas.engine.scanner
  (:use :cl)
  (:import-from :vovas.engine.util #:js-whitespace-p #:utf16-length)
  (:import-from :vovas.engine.decoders #:decode-escapes)
  (:export
   #:skip-quoted
   #:skip-template
   #:skip-line-comment
   #:skip-block-comment
   #:regex-start-p
   #:skip-regex
   #:collect-string-literals
   #:find-balanced))

(defpackage :vovas.engine.digest
  (:use :cl)
  (:export
   #:sha256-hex
   #:sha256-hex-bytes))

(defpackage :vovas.engine.gate
  (:use :cl)
  (:export
   #:run-text-gate
   #:run-all-gates))
