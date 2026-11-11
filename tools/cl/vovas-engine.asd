;;;; vovas-engine.asd — the engine port.
;;;;
;;;; ONE system: every module and every gate, in one serial order.
;;;;
;;;; ORDER. Modules are serial, in dependency order:
;;;;   package   all defpackages, because :import-from needs its source package
;;;;             to exist at READ time
;;;;   util      JavaScript string semantics, UTF-16, the LIMITS parameters
;;;;   number    ECMAScript Number::toString / toFixed
;;;;   transforms the one decodeURIComponent + the sourceURL pattern
;;;;   decoders  escape decoding, base64, bytes-to-text
;;;;   scanner   the string/comment-aware walker
;;;;   digest    SHA-256
;;;;   bundler   webpack module splitting (uses scanner + transforms)
;;;;   text      the panel's path writers (uses transforms)
;;;;   beautify  indentation (uses scanner)
;;;;   detectors the layer detector (uses scanner + the stage seams)
;;;;   sourcemaps source-map refs and parsing
;;;;   packers   packers/obfuscators, the largest text module
;;;;   pipeline  the peel chain (last: it consumes the others)
;;;;
;;;; The gate file loads last and holds every run-*-gate entry point.

(asdf:defsystem "vovas-engine"
  :description "JavaScript-to-Lisp port of the DevTools sources-downloader engine"
  :author "sashathelambo"
  :license "MIT"
  :depends-on ("cl-ppcre" "com.inuoe.jzon" "ironclad" "babel" "chipz" "salza2"
               ;; cl-unicode: beautify.rs tests JS identifier characters with a
               ;; Unicode property lookup (`has-property c "Alphabetic"`), which
               ;; no ASCII range can express.
               "cl-unicode")
  :serial t
  :components ((:module "engine"
                :serial t
                :components ((:file "package")
                             (:file "util")
                             (:file "number")
                             (:file "transforms")
                             (:file "decoders")
                             (:file "scanner")
                             (:file "digest")
                             (:file "bundler")
                             (:file "text")
                             (:file "beautify")
                             (:file "detectors")
                             (:file "sourcemaps")
                             (:file "packers")
                             ;; binary tier
                             (:file "wasm")
                             (:file "jscbytecode")
                             (:file "v8codecache")
                             (:file "zip")
                             ;; jsfuck LAST of the modules. Its defpackage lives in
                             ;; its own file and imports CIVIL-FROM-UNIX-SECS from
                             ;; vovas.engine.zip, so zip must be loaded first - the
                             ;; package-order trap, again, in a file I did not write.
                             (:file "jsfuck")
                             ;; pipeline LAST of the modules: it calls every one
                             ;; of them, so anything after it would be a forward
                             ;; reference at load time.
                             (:file "pipeline")
                             ;; panel tier: policy is a LEAF (text.rs is already
                             ;; ported as text.lisp), so it goes here rather than
                             ;; with the panel modules that follow later.
                             (:file "stackprofile")
                             (:file "policy")
                             (:file "model")
                             (:file "assets")
                             ;; paths right after assets: it needs only model and
                             ;; assets, and report reads its artifact tables.
                             (:file "paths")
                             ;; boundary sits beside assets: it imports the
                             ;; field accessors, and assets is its only
                             ;; panel-tier dependency.
                             (:file "boundary")
                             (:file "workspace")
                             ;; analysis LAST of the panel modules: it calls every
                             ;; one of them, so it must load after them.
                             (:file "analysis")
                             (:file "wf-consts")
                             (:file "inv-consts")
                             (:file "report")
                             (:file "export")
                             (:file "graph")
                             ;; view BEFORE artifacts: artifacts escapes XML and
                             ;; attributes with view's `escape-html`, so the order
                             ;; is a real dependency, not a preference.
                             (:file "view")
                             (:file "artifacts")
                             ;; api.lisp is the PUBLIC SURFACE: wasm_api.rs's
                             ;; dispatch table. It goes after EVERY module it can
                             ;; name, because it is the one file that references all
                             ;; of them - and before gate.lisp, which asserts its
                             ;; key set against the Rust source.
                             (:file "api")
                             ;; gate.lisp FIRST: it owns the harness every other
                             ;; gate file calls (read-json-file, fixture-path,
                             ;; binary-fixture-path, check, report-failures).
                             ;; Loading a gate file before it leaves those as
                             ;; undefined-function calls that only explode at run
                             ;; time.
                             (:file "gate")
                             (:file "gate-beautify")
                             (:file "gate-detectors")
                             (:file "gate-sourcemaps")
                             (:file "gate-packers")
                             (:file "gate-jsfuck")
                             (:file "gate-wasm")
                             (:file "gate-jscbytecode")
                             (:file "gate-v8codecache")
                             (:file "gate-zip")
                             (:file "gate-pipeline")
                             (:file "gate-policy")
                             (:file "gate-model")
                             (:file "gate-assets")
                             (:file "gate-boundary")
                             (:file "gate-workspace")
                             (:file "gate-workspace-builders")
                             (:file "gate-analysis")
                             (:file "gate-report")
                             (:file "gate-export")
                             (:file "gate-transforms")
                             (:file "gate-paths")
                             (:file "gate-graph")
                             (:file "gate-stackprofile")
                             (:file "gate-view")
                             (:file "gate-artifacts")
                             (:file "gate-api")))))
