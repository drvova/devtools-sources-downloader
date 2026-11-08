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
   #:now-unix-millis
   #:now-unix-secs
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
   #:nan
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
   #:parse-url-for-panel
   #:parsed-url-path
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

(defpackage :vovas.engine.panel.model
  (:use :cl)
  (:import-from :vovas.engine.number #:to-string #:to-number #:nan)
  (:import-from :vovas.engine.util #:js-trim)
  (:import-from :vovas.engine.text #:locale-compare)
  (:export
   #:counts #:make-counts #:counts-add #:counts-alist
   #:js-string #:js-number #:js-truthy #:json-null-p
   #:resource #:make-resource
   #:resource-status #:resource-kind #:resource-source #:resource-url
   #:resource-size #:resource-time #:resource-order
   #:normalize-resource #:get-resource-time
   #:resource-filters #:make-resource-filters
   #:resource-filters-status #:resource-filters-kind
   #:resource-filters-search #:resource-filters-sort
   #:matches-resource-filters #:compare-resources
   #:collect-types #:resolve-type-selection #:utf16-less-p))

(defpackage :vovas.engine.panel.assets
  (:use :cl)
  (:import-from :vovas.engine.util #:js-trim #:utf16-length)
  ;; The counting helpers live in `model` (it owns the insertion-ordered
  ;; `counts` struct). Imported by name rather than qualified at each call site
  ;; because five functions here use them; `model` is a LEAF that loads before
  ;; `assets`, so there is no cycle.
  (:import-from :vovas.engine.panel.model #:make-counts #:counts-add
                #:counts-alist #:js-truthy #:js-number #:json-null-p)
  (:import-from :vovas.engine.text #:parse-url-for-panel #:parsed-url-path
                #:safe-decode-uri-component)
  (:export
   #:normalize-url-key #:strip-url-variant #:get-bare-file-name
   #:clean-stack-reference #:extract-stack-refs #:unique-strings
   #:asset-sample #:detect-bundler-name #:detect-framework-hints
   #:detect-startup-signals #:extract-route-hints-from-url
   #:extract-import-specifiers #:split-on-slash #:keys-len
   #:field #:field-str #:field-number
   #:byte-values #:assets-from-inputs
   #:module-signals #:make-module-signals
   #:module-signals-import-count #:module-signals-dynamic-imports
   #:module-signals-requires #:module-signals-exports
   #:script-asset #:make-script-asset
   #:script-asset-id #:script-asset-url #:script-asset-file #:script-asset-size
   #:script-asset-transfer-size #:script-asset-start-time #:script-asset-duration
   #:script-asset-imports #:script-asset-module-signals #:script-asset-bundler
   #:script-asset-framework-hints #:script-asset-route-hints
   #:script-asset-startup-signals #:script-asset-source-map-embedded
   #:script-asset-content #:script-asset-classification #:script-asset-score
   #:script-asset-boundary-details #:script-asset-boundary-labels
   #:script-asset-primary-boundary #:script-asset-boundary-reasons
   #:boundary-detail #:make-boundary-detail #:boundary-detail-label
   #:boundary-detail-score #:boundary-detail-reasons
   #:prepare-script-assets #:classify-script-asset #:score-script-asset
   #:count-classifications #:count-boundary-labels #:count-tagged-entries
   #:build-chunk-summary #:strip-chunk-asset
   #:find-asset-by-reference #:value-text
   #:determine-runtime-origin-type #:score-runtime-entry
   #:build-runtime-origins #:build-runtime-summary #:strip-runtime-entry
   #:count-origin-property #:asset-sample #:count-matches))

(defpackage :vovas.engine.panel.paths
  (:use :cl)
  (:export
   #:*framework-artifacts*
   #:*analysis-artifacts*
   #:*analysis-chunk-map*
   #:*analysis-cross-boundary-flows*
   #:*analysis-module-graph*
   #:*analysis-startup-chain*
   #:*analysis-runtime-origins*
   #:*analysis-boundary-labels*
   #:*analysis-framework-runtime*
   #:*analysis-interesting-entrypoints*
   #:*analysis-index-html*
   #:framework-slice-present-p))

(defpackage :vovas.engine.panel.graph
  (:use :cl)
  (:import-from :vovas.engine.panel.policy #:*graphql-body-pattern* #:*graphql-body-keys*)
  (:import-from :vovas.engine.panel.model #:js-truthy #:js-number #:json-null-p)
  (:import-from :vovas.engine.panel.assets #:field #:field-str #:field-number
                #:unique-strings #:find-asset-by-reference #:get-bare-file-name
                #:script-asset-id #:script-asset-url #:script-asset-imports
                #:script-asset-classification #:script-asset-bundler
                #:script-asset-primary-boundary #:script-asset-start-time
                #:script-asset-duration #:script-asset-startup-signals)
  (:import-from :vovas.engine.util #:utf16-prefix)
  (:export #:looks-like-graphql-body-p #:normalize-graphql-payload
           #:parse-graphql-operation #:collect-graphql-operations
           #:collect-network-operations #:graphql-value-text #:text-or
           #:build-module-graph #:build-startup-chain #:startup-chain-profile
           #:graph-builder #:make-graph-builder))

(defpackage :vovas.engine.panel.view
  (:use :cl)
  (:import-from :vovas.engine.panel.model #:resource-status #:resource-kind
                #:resource-source #:resource-url #:resource-size
                #:normalize-resource #:collect-types #:resolve-type-selection
                #:matches-resource-filters #:compare-resources
                #:resource-filters-kind #:resource-filters-sort)
  (:import-from :vovas.engine.text #:format-size)
  (:export #:escape-html #:resource-rows-html #:type-options-html #:tracker-view))

(defpackage :vovas.engine.panel.artifacts
  (:use :cl)
  (:import-from :vovas.engine.util #:js-trim)
  (:import-from :vovas.engine.number #:to-string)
  (:import-from :vovas.engine.text #:format-size #:format-ms)
  (:import-from :vovas.engine.panel.model #:js-truthy #:js-number #:json-null-p)
  (:import-from :vovas.engine.panel.assets #:field #:field-str)
  (:import-from :vovas.engine.panel.view #:escape-html)
  (:export
   #:js-number-value #:finite-float-p
   #:runtime-folder-name #:runtime-extension #:build-runtime-path
   #:build-runtime-unpack-assets #:merge-unpack-reports
   #:parse-cookies #:split-on-char
   #:serialize-inline-json #:json-escape-html-chars
   #:escape-xml #:escape-attr #:value-as-text
   #:compute-recon-stats #:truthy-or
   #:json-serialize-compact #:json-escape-string
   #:generate-dom-snapshot-html #:build-readable-artifact-with))

(defpackage :vovas.engine.panel.stackprofile
  (:use :cl)
  (:import-from :vovas.engine.panel.model #:js-truthy #:js-string)
  (:import-from :vovas.engine.panel.assets #:field)
  (:import-from :vovas.engine.util #:js-trim #:now-unix-millis)
  (:export #:analyze #:default-strategy #:build-strategy
           #:*version* #:normalize-list #:has-url #:snap-field
           #:empty-object #:empty-array
           #:json-marker-p #:json-marker-kind))

(defpackage :vovas.engine.gate
  (:use :cl)
  (:export
   #:run-text-gate
   #:run-all-gates))
