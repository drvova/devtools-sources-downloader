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
   #:is-ascii-js-space
   #:utf16-length
   #:utf16-prefix
   #:utf16-suffix
   #:utf16-substring
   ;; path-hostile characters, one definition (the panel writes names)
   #:bad-path-chars-p
   #:bad-path-chars-with-slash-p
   #:regex-escape
   ;; lib.rs LIMITS, as parameters
   #:*limits-max-depth*
   #:*limits-max-asset-bytes*
   #:*limits-max-beautify-bytes*
   #:*limits-max-modules*
   #:*limits-max-sources*
   #:*limits-max-map-bytes*
   #:*limits-min-payload-length*))

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

(defpackage :vovas.engine.transforms
  (:use :cl)
  (:export
   #:decode-uri-component
   #:*source-url-comment*
   ;; the peel chain (transforms.rs), appended by the pipeline slice.
   ;; Structures are plists whose keys are the oracle's JSON names.
   #:is-literal-only-arg
   #:collect-eval-payloads
   #:unwrap-eval
   #:unwrap-base64
   #:unwrap-hex-escapes
   #:unwrap-unescape
   #:percent-encode-utf8
   #:unwrap-charcode
   #:js-parse-int
   #:to-uint16
   #:unwrap-reverse
   #:apply-transform
   #:collect-refusals
   #:peel-text
   ;; stage/payload constructors and readers
   #:make-text-stage
   #:make-binary-stage
   #:make-eval-payload
   #:make-peel-result
   #:eval-payload-head
   #:eval-payload-code
   #:eval-payload-end
   #:peel-result-stages
   #:peel-result-outputs
   #:peel-result-final
   #:peel-result-refusals
   ;; the jsfuck seam: NIL until vovas.engine.jsfuck lands
   #:*jsfuck-decode*
   #:*max-peel-depth*
   ;; helpers the tests pin directly
   #:printable-ratio
   #:gzip-format
   #:inflate-bytes
   #:json-quote
   #:code-unit-char
   #:split-on-char))

(defpackage :vovas.engine.text
  (:use :cl)
  (:import-from :vovas.engine.util
                #:js-trim #:utf16-length #:utf16-prefix
                #:bad-path-chars-p #:bad-path-chars-with-slash-p
                #:regex-escape)
  (:import-from :vovas.engine.number
                #:to-string #:js-round #:to-fixed)
  (:import-from :vovas.engine.transforms #:decode-uri-component)
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
   #:decode-escapes
   ;; added by the sourcemaps slice; declared HERE, not exported at load time.
   ;; A runtime `export` from the module file makes the package's own export list
   ;; disagree with the defpackage form, and SBCL reports that as a
   ;; DEFPACKAGE variance warning whose text can interleave with a runner's
   ;; output - which reads as a nondeterministic gate failure.
   #:decode-base64-to-bytes
   #:bytes-to-text
   #:ascii-js-space-p))

(defpackage :vovas.engine.scanner
  (:use :cl)
  (:import-from :vovas.engine.util #:is-ascii-js-space #:utf16-length)
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

(defpackage :vovas.engine.bundler
  (:use :cl)
  (:import-from :vovas.engine.util #:*limits-max-modules*)
  (:import-from :vovas.engine.scanner #:find-balanced)
  (:export
   #:extract-bundle-modules
   #:module-file-name
   #:safe-path
   #:bundle-module
   #:bundle-module-id
   #:bundle-module-params
   #:bundle-module-code))

(defpackage :vovas.engine.panel.policy
  (:use :cl)
  (:export
   #:capture-policy
   #:default-strategy
   #:*redact-key-pattern*
   #:*text-mime-pattern*
   #:*graphql-url-marker*
   #:*graphql-body-pattern*
   #:*graphql-body-keys*
   #:*limits*))

(defpackage :vovas.engine.gate
  (:use :cl)
  (:export
   #:run-text-gate
   #:run-all-gates))
