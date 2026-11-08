;;;; api.lisp — the engine's PUBLIC SURFACE: `wasm_api.rs`'s dispatch table.
;;;;
;;;; Everything below this file is a pure function library. This is the one layer
;;;; that turns a NAME plus a positional JSON argument array into an answer,
;;;; which is exactly what `xu_call` does in the wasm build. It matters because
;;;; until it exists the engine is correct and unreachable: 47 gates prove the
;;;; functions answer the right things and nothing can ask them anything.
;;;;
;;;; Three things live here and nowhere below:
;;;;
;;;;   1. THE ARGUMENT CONTRACT. The arms read positional JSON (`arg_str(a, 0)`,
;;;;      `arg_usize(a, 1)`) and refuse with a named message when a required one
;;;;      is absent. That text is wire contract - the JS bridge surfaces it
;;;;      verbatim in a trap explanation - so it is reproduced exactly.
;;;;   2. PER-ARM DEFAULTS, which are NOT uniform. `sanitizeFilename` uses
;;;;      `unwrap_or_default()` and so answers "" for a missing argument;
;;;;      `sha256Hex` REFUSES. `parseSealedV8` treats empty bytes as null;
;;;;      `detectV8CodeCache` treats them as false. A uniform "require all args"
;;;;      rule would change the behaviour of half the table.
;;;;   3. THE HOST SHAPES: `HostAsset` (camelCase, bytes as base64) and
;;;;      `HostOptions` translating to the pipeline's records, and files back
;;;;      out as `{path, content}` or `{path, base64}`.
;;;;
;;;; Deliberately absent: `xu_alloc`/`xu_free`/the linear memory. That is the
;;;; wasm ABI, and this build has no memory to manage - a call returns a value.
;;;; `lastFailure` IS present because a caller polling it needs the same answer,
;;;; and the honest answer outside wasm is "nothing failed" unless a call was
;;;; refused.
;;;;
;;;; ALL references are package-qualified on purpose. The modules export their
;;;; own narrow sets and several export the same NAME (`build-zip` lives in both
;;;; `pipeline` and `zip`), so an import list here would silently bind one and
;;;; shadow the other - a trap this tree has already paid for once.

(defpackage :vovas.engine.panel.api
  (:use :cl)
  (:nicknames :vovas.api)
  (:export
   #:call #:call-bytes #:dispatch #:dispatch-bytes
   #:arm-names #:arm-name-p
   #:last-failure-value #:record-failure))

(in-package :vovas.engine.panel.api)

;;; ---------------------------------------------------------------------------
;;; Wire helpers
;;; ---------------------------------------------------------------------------
;;;
;;; The arms receive `serde_json::Value`s: objects are hash tables, arrays and
;;; byte arrays are vectors, strings are strings, null is NIL. The readers below
;;; are the Lisp spelling of `arg_str` / `arg_usize` / `arg_bytes` / `arg_array`,
;;; and each one's comment says what the Rust does rather than what would be
;;; convenient.

(defun arg-raw (args index)
  "ARGS[INDEX], or NIL when out of range. ARGS is a vector."
  (and (vectorp args) (< index (length args)) (aref args index)))

(defun arg-str (args index &optional label)
  "ARGS[INDEX] as a string; signal LABEL's message when it is not one.

`as_str()` answers None for an absent AND for a wrong-typed argument, so the
arm refuses in both cases. LABEL is the arm's own text (`\"sha256Hex: text\"`),
because the bridge prints it and a port whose refusals read differently is a
port whose failures read differently in the panel."
  (let ((value (arg-raw args index)))
    (if (stringp value)
        value
        (error "~a" (or label "argument")))))

(defun arg-str-or-empty (args index)
  "ARGS[INDEX] as a string, or \"\" - `unwrap_or_default()`.

Used only by the arms that call `unwrap_or_default()`: they answer an empty
string for a missing argument rather than refusing, and collapsing the two would
make `sanitizeFilename` reject a call the shipped engine accepts."
  (let ((value (arg-raw args index)))
    (if (stringp value) value "")))

(defun arg-str-or-nil (args index)
  "ARGS[INDEX] as a string, or NIL - the `if let Some` arms."
  (let ((value (arg-raw args index)))
    (and (stringp value) value)))

(defun arg-usize (args index)
  "ARGS[INDEX] as a non-negative integer, or NIL - `arg_usize`.

`as_u64()` answers None for a float, a negative, or a non-number, so a caller
passing 2.5 gets the arm's `None` branch rather than a silent truncation."
  (let ((value (arg-raw args index)))
    (cond
      ((and (integerp value) (not (minusp value))) value)
      (t nil))))

(defun arg-bytes-or-empty (args index)
  "ARGS[INDEX] as an octet vector; empty when absent - `unwrap_or_default()`.

The JS bridge sends binary as `Array.from(bytes)`, so the wire shape is a JSON
array of small integers. A value outside 0-255 becomes 0, which is what
`serde` does when it coerces such an array into `Vec<u8>`."
  (let ((value (arg-raw args index)))
    (if (vectorp value)
        (let ((out (make-array (length value) :element-type '(unsigned-byte 8))))
          (loop for i below (length value)
                for v = (aref value i)
                do (setf (aref out i)
                         (if (and (integerp v) (<= 0 v 255)) v 0)))
          out)
        #())))

(defun arg-object-or-nil (args index)
  "ARGS[INDEX] as an object, or NIL - the `and_then(as_object)` arms."
  (let ((value (arg-raw args index)))
    (and (hash-table-p value) value)))

(defun obj-get (object key)
  "OBJECT[KEY], or NIL. A non-object reads as no field at all."
  (and (hash-table-p object) (gethash key object)))

(defun obj-str (object key &optional (default ""))
  "OBJECT[KEY] as a string, or DEFAULT - `and_then(as_str).unwrap_or(..)`."
  (let ((value (obj-get object key)))
    (if (stringp value) value default)))

(defun obj-usize (object key)
  "OBJECT[KEY] as a non-negative integer, or NIL."
  (let ((value (obj-get object key)))
    (and (integerp value) (not (minusp value)) value)))

;;; ---------------------------------------------------------------------------
;;; Host shapes
;;; ---------------------------------------------------------------------------

(defun host-asset->native (host)
  "A HostAsset object as the pipeline's asset record.

`bytesB64` wins on PRESENCE, not on a flag - the Rust matches on the field, so
an asset carrying both is binary and its text is ignored. A base64 string that
will not decode becomes EMPTY BYTES, because `decode_base64_to_bytes(..)
.unwrap_or_default()` is what the Rust does; refusing here would reject a
capture the shipped engine accepts."
  (let ((url (obj-str host "url"))
        (zip-path (obj-get host "zipPath"))
        (b64 (obj-get host "bytesB64")))
    (cond
      ((stringp b64)
       (vovas.engine.pipeline:make-bytes-asset
        url (or (vovas.engine.decoders:decode-base64-to-bytes b64) #())
        zip-path))
      (t
       (vovas.engine.pipeline:make-text-asset
        url (obj-str host "content") zip-path)))))

(defun host-options->native (host)
  "A HostOptions object as `UnpackOptions`.

`into_native` defaults `path_prefix` to `_unpack` when the field is absent, and
that default is load-bearing: every artifact path in every report starts with
it. It is applied here, where the Rust applies it, rather than left to the
pipeline's separate empty-string re-normalisation."
  (vovas.engine.pipeline:make-unpack-options
   :index (obj-usize host "index")
   :path-prefix (or (obj-str host "pathPrefix") "_unpack")
   :max-depth (obj-usize host "maxDepth")
   :max-modules (obj-usize host "maxModules")
   :max-beautify-bytes (obj-usize host "maxBeautifyBytes")
   ;; A JS function cannot cross the boundary, so the caller supplies a static
   ;; { url: text } map and the seam consults it before any host fetch.
   :fetch-text (let ((map (obj-get host "fetchMap")))
                 (and (hash-table-p map)
                      (lambda (url) (obj-get map url))))))

(defun file->wire (path content)
  "One file as `{path, content}`, or `{path, base64}` when CONTENT is bytes.

`finalize_zip_with_recon`'s writer receives `&[u8]` and the arm decides by
`from_utf8`: readable bytes become `content`, anything else becomes base64. The
distinction is not cosmetic - a binary payload sent as `content` would be
mangled by the JSON encoder."
  (let ((table (make-hash-table :test #'equal)))
    (setf (gethash "path" table) path)
    (cond
      ((stringp content) (setf (gethash "content" table) content))
      (t (setf (gethash "base64" table)
               (vovas.engine.decoders:encode-base64 content))))
    table))

(defun files->wire (files)
  "FILES as the wire array of `{path, content}` objects - `files_json`."
  (coerce (loop for file in files
                collect (let ((table (make-hash-table :test #'equal)))
                          (setf (gethash "path" table)
                                (vovas.engine.pipeline:file-path file))
                          (setf (gethash "content" table)
                                (vovas.engine.pipeline:file-content file))
                          table))
          'vector))

(defun source-map-ref->wire (ref)
  "A source-map reference as `{kind, value}` - `source_map_ref_json`."
  (let ((table (make-hash-table :test #'equal)))
    (setf (gethash "kind" table)
          (string-downcase (symbol-name (getf ref :kind))))
    (setf (gethash "value" table) (getf ref :value))
    table))

;;; ---------------------------------------------------------------------------
;;; The failure slot
;;; ---------------------------------------------------------------------------

(defvar *last-failure* nil
  "The last refusal recorded by `dispatch`, or NIL.

The wasm keeps a thread-local so the bridge can read the real cause of a trap
after the instance has failed. Outside wasm a call ANSWERS or signals, so this
records refusals a caller asked for by name; it is not a crash oracle and
claiming otherwise would misrepresent what this build does.")

(defun record-failure (message)
  "Record MESSAGE as the last failure."
  (setf *last-failure* message))

(defun last-failure-value ()
  "The last recorded failure as a JSON value: a string, or NIL for null."
  *last-failure*)

;;; ---------------------------------------------------------------------------
;;; The table
;;; ---------------------------------------------------------------------------
;;;
;;; Keyed by the EXACT arm names `wasm_api.rs` matches. Those names cross the
;;; wasm boundary from the JS bridge, so they are wire contract rather than
;;; internal identifiers - a rename here breaks the bridge silently, which is
;;; why the gate compares this table's key set against the Rust source.

(defparameter *arms* (make-hash-table :test #'equal)
  "Name -> function of the positional argument vector. The JSON arms.")

(defparameter *byte-arms* (make-hash-table :test #'equal)
  "Name -> function of the positional argument vector. The BYTES arms.")

(defmacro defarm (name (args) &body body)
  "Register a JSON arm NAME answering the value BODY produces."
  (let ((fn (intern (format nil "ARM-~a" (string-upcase (string name)))
                    :vovas.engine.panel.api)))
    `(progn
       (defun ,fn (,args) ,@body)
       (setf (gethash ,(string name) *arms*) #',fn)
       ,(string name))))

(defmacro defbytearm (name (args) &body body)
  "Register a BYTES arm NAME answering an octet vector."
  (let ((fn (intern (format nil "BYTEARM-~a" (string-upcase (string name)))
                    :vovas.engine.panel.api)))
    `(progn
       (defun ,fn (,args) ,@body)
       (setf (gethash ,(string name) *byte-arms*) #',fn)
       ,(string name))))

;;; --- meta ------------------------------------------------------------------

(defarm "LIMITS" (args)
  "The engine's limits as `LIMITS` reports them."
  (declare (ignore args))
  (let ((table (make-hash-table :test #'equal)))
    (setf (gethash "maxDepth" table) vovas.engine.util:*limits-max-depth*)
    (setf (gethash "maxAssetBytes" table) vovas.engine.util:*limits-max-asset-bytes*)
    (setf (gethash "maxBeautifyBytes" table) vovas.engine.util:*limits-max-beautify-bytes*)
    (setf (gethash "maxModules" table) vovas.engine.util:*limits-max-modules*)
    (setf (gethash "maxSources" table) vovas.engine.util:*limits-max-sources*)
    (setf (gethash "maxMapBytes" table) vovas.engine.util:*limits-max-map-bytes*)
    (setf (gethash "minPayloadLength" table) vovas.engine.util:*limits-min-payload-length*)
    table))

(defarm "lastFailure" (args)
  "The last recorded failure, or NIL for JSON null. Always answered."
  (declare (ignore args))
  (last-failure-value))

;;; --- panel -----------------------------------------------------------------

(defarm "panelCapturePolicy" (args)
  "`capture_policy()` - the capture strategy for this build."
  (declare (ignore args))
  (vovas.engine.panel.policy:capture-policy))

(defarm "panelStackProfileAnalyze" (args)
  "`analyze(snapshot)` - the technology/trait profile.

`a.first().unwrap_or(&Value::Null)` means an absent argument is JSON null, and
`analyze` treats a null snapshot as an empty one rather than refusing."
  (vovas.engine.panel.stackprofile:analyze (or (arg-raw args 0) nil)))

(defarm "panelTrackerView" (args)
  "`trackerView(tracker, filters)` - the resources view model.

The filters object's four string fields default INDIVIDUALLY (`status` \"all\",
`kind` \"all\", `search` \"\", `sort` \"newest\"), and an absent filters object
means `ResourceFilters::default()` - the same four values."
  (let* ((tracker (arg-raw args 0))
         (raw (arg-object-or-nil args 1))
         (filters (vovas.engine.panel.model:make-resource-filters
                   :status (obj-str raw "status" "all")
                   :kind (obj-str raw "kind" "all")
                   :search (obj-str raw "search" "")
                   :sort (obj-str raw "sort" "newest"))))
    (vovas.engine.panel.view:tracker-view (or tracker nil) filters)))

(defarm "panelDescribeCaptureReason" (args)
  "`describeCaptureReason(status, profile)` - the sentence the panel shows.

Both arguments are filtered for null BEFORE the call, so a JSON null status is
the same as an absent one."
  (vovas.engine.panel.report:describe-capture-reason
   (let ((v (arg-raw args 0))) (and v v))
   (let ((v (arg-raw args 1))) (and (hash-table-p v) v))))

(defarm "panelFinalizeZipWithRecon" (args)
  "`finalizeZipWithRecon(assets, recon, snapshot, payloads, options)`.

The assets are `ScriptInput`, NOT `HostAsset` - the arm deserialises them to
that type and `finalize_zip_with_recon` runs `assets_from_inputs` over them
itself. Converting here would be a second, different translation: it drops the
fields only ScriptInput carries (which showed up as a beautified count of 1
where the engine reports 2), so the raw vector is handed through unchanged.

The writer decides text-or-base64 per file, exactly as the arm does, so a
binary payload crosses as base64 rather than as mangled text."
  (let* ((assets (coerce (or (arg-raw args 0) #()) 'list))
         (recon (arg-raw args 1))
         (snapshot (arg-raw args 2))
         (payloads (coerce (or (arg-raw args 3) #()) 'list))
         (options (host-options->native (arg-object-or-nil args 4)))
         (files '()))
    (let ((report (vovas.engine.panel.export:finalize-zip-with-recon
                   (lambda (path content)
                     (push (file->wire path content) files))
                   assets
                   (and (hash-table-p recon) recon)
                   (and (hash-table-p snapshot) snapshot)
                   payloads
                   options)))
      (let ((table (make-hash-table :test #'equal)))
        (setf (gethash "files" table) (coerce (nreverse files) 'vector))
        ;; The report is ALREADY a wire-shaped hash table: `analysis-wire` built
        ;; it, so serialising it again here would double-encode every nested
        ;; object. The arm hands `serde` a `Value` and serde encodes it; the
        ;; equivalent here is to hand back the value the encoder expects.
        (setf (gethash "report" table) report)
        (setf (gethash "summary" table)
              (vovas.engine.panel.export:export-summary report))
        table))))

;;; --- digests and naming ----------------------------------------------------

(defarm "sha256Hex" (args)
  "SHA-256 of a text argument's UTF-8 bytes, lowercase hex. REFUSES on absence."
  (vovas.engine.digest:sha256-hex (arg-str args 0 "sha256Hex: text")))

(defarm "sha256HexBytes" (args)
  "SHA-256 of a byte array, lowercase hex, or NIL when the digest refuses."
  (vovas.engine.digest:sha256-hex-bytes (arg-bytes-or-empty args 0)))

(defarm "sanitizeFilename" (args)
  "A URL as an archive filename. A missing argument becomes \"\"."
  (vovas.engine.text:sanitize-filename (arg-str-or-empty args 0)))

(defarm "sanitizePageTitle" (args)
  "A page title as a filesystem-safe name. A missing argument becomes \"\"."
  (vovas.engine.text:sanitize-page-title (arg-str-or-empty args 0)))

;;; --- text helpers ----------------------------------------------------------

(defarm "collectStringLiterals" (args)
  "String literals in TEXT, at least `minLength` characters.

`minLength` is read out of the OPTIONS OBJECT (not a positional number) and
defaults to 0; a non-object second argument is the same as an absent one."
  (vovas.engine.scanner:collect-string-literals
   (arg-str args 0 "collectStringLiterals: text")
   (or (obj-usize (arg-object-or-nil args 1) "minLength") 0)))

(defarm "findBalanced" (args)
  "The index closing the bracket at IDX, or NIL when IDX is absent.

The Rust computes `arg_usize(a, 1)` FIRST and only then reads the text, so a
missing index answers null without refusing even when the text is missing too.
Keeping that order matters: the arm is the contract, not the tidier version."
  (let ((index (arg-usize args 1)))
    (if (null index)
        nil
        (vovas.engine.scanner:find-balanced
         (arg-str args 0 "findBalanced: text") index))))

(defarm "decodeEscapes" (args)
  "Backslash escapes in RAW decoded to their characters."
  (vovas.engine.decoders:decode-escapes (arg-str args 0 "decodeEscapes: raw")))

(defarm "bytesToText" (args)
  "Bytes decoded as UTF-8 text. Absent bytes decode to \"\"."
  (vovas.engine.decoders:bytes-to-text (arg-bytes-or-empty args 0)))

(defarm "printableRatio" (args)
  "The fraction of TEXT that is printable."
  (vovas.engine.transforms:printable-ratio
   (arg-str args 0 "printableRatio: text")))

(defarm "detectLayers" (args)
  "The wrapping layers detected in TEXT."
  (vovas.engine.detectors:detect-layers (arg-str args 0 "detectLayers: text")))

(defarm "peelText" (args)
  "TEXT with its layers peeled, bounded by `maxDepth`.

`maxDepth` is read from the OPTIONS OBJECT and stays NIL when the field is
absent OR explicitly null - the arm tests `is_null()` before `as_u64()`, so an
explicit null means \"no bound\" rather than 0."
  (let* ((raw (arg-object-or-nil args 1))
         (depth (obj-usize raw "maxDepth")))
    (vovas.engine.transforms:peel-text
     (arg-str args 0 "peelText: text") depth)))

(defarm "looksMinified" (args)
  "Whether TEXT is minified."
  (vovas.engine.beautify:looks-minified-p (arg-str args 0 "looksMinified: text")))

(defarm "beautifyJs" (args)
  "TEXT reformatted; MAX-BYTES bounds the work and NIL means no bound."
  (vovas.engine.beautify:beautify-js
   (arg-str args 0 "beautifyJs: text")
   (arg-usize args 1)))

;;; --- bundler ---------------------------------------------------------------

(defarm "extractBundleModules" (args)
  "The modules inside a bundle as `{id, params, code}`, capped at MAX-MODULES."
  (let ((modules (vovas.engine.bundler:extract-bundle-modules
                  (arg-str args 0 "extractBundleModules: text")
                  (arg-usize args 1))))
    (coerce (loop for module in modules
                  collect (let ((table (make-hash-table :test #'equal)))
                            (setf (gethash "id" table) (getf module :id))
                            (setf (gethash "params" table) (getf module :params))
                            (setf (gethash "code" table) (getf module :code))
                            table))
            'vector)))

;;; --- source maps -----------------------------------------------------------

(defarm "findSourceMapRef" (args)
  "The source-map reference in TEXT as `{kind, value}`, or NIL."
  (let ((ref (vovas.engine.sourcemaps:find-source-map-ref
              (arg-str args 0 "findSourceMapRef: text"))))
    (and ref (source-map-ref->wire ref))))

(defarm "parseSourceMap" (args)
  "A source map parsed from JSON text: `{files, sourceRoot, file}`, or NIL.

A map that will not parse answers NULL rather than refusing - the arm maps the
error to `Value::Null`, because a page with a broken map is a page with no map,
not a failed capture."
  (let ((parsed (ignore-errors
                  (vovas.engine.sourcemaps:parse-source-map
                   (arg-str args 0 "parseSourceMap: json")))))
    (when parsed
      (let ((table (make-hash-table :test #'equal)))
        (setf (gethash "files" table)
              (coerce (loop for f in (getf parsed :files)
                            collect (let ((file (make-hash-table :test #'equal)))
                                      (setf (gethash "path" file) (getf f :path))
                                      (setf (gethash "content" file) (getf f :content))
                                      file))
                      'vector))
        (setf (gethash "sourceRoot" table) (getf parsed :source-root))
        (setf (gethash "file" table) (getf parsed :file))
        table))))

(defarm "decodeInlineSourceMap" (args)
  "An inline source map data URI decoded to its text, or NIL."
  (vovas.engine.sourcemaps:decode-inline-source-map
   (arg-str args 0 "decodeInlineSourceMap: dataUri")))

(defarm "resolveMapUrl" (args)
  "MAP-REF resolved against SCRIPT-URL."
  (vovas.engine.sourcemaps:resolve-map-url
   (arg-str args 0 "resolveMapUrl: scriptUrl")
   (arg-str args 1 "resolveMapUrl: mapRef")))

(defarm "assetSlug" (args)
  "A stable short slug for URL at INDEX. The index is REQUIRED here."
  (vovas.engine.pipeline:asset-slug
   (arg-str args 0 "assetSlug: url")
   (or (arg-usize args 1) (error "assetSlug: index"))))

;;; --- the pipeline ----------------------------------------------------------

(defarm "unpackAsset" (args)
  "One host asset unpacked: `{report, files}`."
  (let* ((asset (host-asset->native (arg-object-or-nil args 0)))
         (options (host-options->native (arg-object-or-nil args 1)))
         (result (vovas.engine.pipeline:unpack-asset asset options)))
    (let ((table (make-hash-table :test #'equal)))
      (setf (gethash "report" table)
            (vovas.engine.pipeline:batch-result-report result))
      (setf (gethash "files" table)
            (files->wire (vovas.engine.pipeline:batch-result-files result)))
      table)))

(defarm "unpackAssets" (args)
  "A batch of host assets unpacked: `{report, files}`."
  (let* ((assets (coerce (loop for host across (or (arg-raw args 0) #())
                               collect (host-asset->native host))
                         'list))
         (options (host-options->native (arg-object-or-nil args 1)))
         (result (vovas.engine.pipeline:unpack-assets assets options)))
    (let ((table (make-hash-table :test #'equal)))
      (setf (gethash "report" table)
            (vovas.engine.pipeline:batch-result-report result))
      (setf (gethash "files" table)
            (files->wire (vovas.engine.pipeline:batch-result-files result)))
      table)))

(defarm "unpackAssetsForZip" (args)
  "A batch unpacked with the report stamped: `{report, files}`.

`unpack_assets_into` writes the report as its LAST file, so these files already
carry `index.json` and the caller does not add one."
  (let* ((assets (coerce (loop for host across (or (arg-raw args 0) #())
                               collect (host-asset->native host))
                         'list))
         (options (host-options->native (arg-object-or-nil args 1)))
         (files '()))
    (let ((report (vovas.engine.pipeline:unpack-assets-into
                   (lambda (path content)
                     (push (vovas.engine.pipeline:make-file path content) files))
                   assets options)))
      (let ((table (make-hash-table :test #'equal)))
        (setf (gethash "report" table) report)
        (setf (gethash "files" table) (files->wire (nreverse files)))
        table))))

;;; --- jsfuck ----------------------------------------------------------------

(defarm "decodeJsfuck" (args)
  "A jsfuck program decoded to its source."
  (vovas.engine.jsfuck:decode-jsfuck (arg-str args 0 "decodeJsfuck: source")))

(defarm "detectJsfuck" (args)
  "Whether SOURCE is jsfuck, and how strongly."
  (vovas.engine.jsfuck:detect-jsfuck (arg-str args 0 "detectJsfuck: source")))

;;; --- packers ---------------------------------------------------------------

(defarm "detectPacker" (args)
  "The packer detected in TEXT, or NIL."
  (vovas.engine.packers:detect-packer (arg-str args 0 "detectPacker: text")))

(defarm "unpackPacker" (args)
  "TEXT unpacked from its packer, or NIL when none applies."
  (vovas.engine.packers:unpack-packer (arg-str args 0 "unpackPacker: text")))

(defarm "detectStringArray" (args)
  "The obfuscated string-array table in SOURCE, or NIL."
  (vovas.engine.packers:detect-string-array
   (arg-str args 0 "detectStringArray: source")))

(defarm "transformStringArray" (args)
  "SOURCE with its string-array table resolved, or NIL."
  (vovas.engine.packers:transform-string-array
   (arg-str args 0 "transformStringArray: source")))

;;; --- v8 code cache ---------------------------------------------------------

(defarm "detectV8CodeCache" (args)
  "Whether BYTES look like a V8 code cache. Absent bytes answer NIL, not T."
  (let ((bytes (arg-bytes-or-empty args 0)))
    (and (plusp (length bytes))
         (vovas.engine.v8codecache:detect-v8-code-cache bytes))))

(defarm "parseV8CodeCache" (args)
  "BYTES parsed as a V8 code cache, or NIL."
  (vovas.engine.v8codecache:parse-v8-code-cache (arg-bytes-or-empty args 0)))

(defarm "extractV8Strings" (args)
  "The strings in BYTES between FROM and TO. FROM defaults to 0, TO to the end."
  (vovas.engine.v8codecache:extract-v8-strings
   (arg-bytes-or-empty args 0)
   (or (arg-usize args 1) 0)
   (arg-usize args 2)))

(defarm "parseSealedV8" (args)
  "BYTES parsed as a brotli-sealed V8 cache: `{tool, detail, inflatedBytes,
cache}`, or NIL.

The `inflate` option selects the seam: a string is taken as a mode (`\"throw\"`
refuses), and any NON-string value means the engine's own brotli - the arm maps
a JS function to \"brotli\" rather than rejecting it. Empty bytes refuse here
BEFORE the detection test, which is what makes an absent argument answer null."
  (let* ((bytes (arg-bytes-or-empty args 0))
         (raw (arg-object-or-nil args 1))
         (mode (let ((v (obj-get raw "inflate")))
                 (cond ((stringp v) v)
                       ((null v) "brotli")
                       (t "brotli")))))
    (cond
      ((zerop (length bytes)) nil)
      ((vovas.engine.v8codecache:detect-v8-code-cache bytes) nil)
      (t
       (let ((inflated (unless (string= mode "throw")
                         (vovas.engine.v8codecache:inflate-brotli-with bytes nil))))
         (cond
           ((null inflated) nil)
           ((not (vovas.engine.v8codecache:detect-v8-code-cache inflated)) nil)
           (t
            (let ((parsed (vovas.engine.v8codecache:parse-v8-code-cache inflated)))
              (when parsed
                (let ((table (make-hash-table :test #'equal)))
                  (setf (gethash "tool" table) "jsc-sealed-v8")
                  (setf (gethash "detail" table) "brotli-sealed V8 code cache")
                  (setf (gethash "inflatedBytes" table) (length inflated))
                  (setf (gethash "cache" table) parsed)
                  table))))))))))

;;; --- jsc bytecode ----------------------------------------------------------

(defarm "parseJscHeader" (args)
  "The header of a JavaScriptCore bytecode file, or NIL."
  (vovas.engine.jscbytecode:parse-jsc-header (arg-bytes-or-empty args 0)))

(defarm "detectJscBytecode" (args)
  "Whether BYTES look like JSC bytecode."
  (vovas.engine.jscbytecode:detect-jsc-bytecode (arg-bytes-or-empty args 0)))

(defarm "recoverJscStrings" (args)
  "The strings recoverable from BYTES without a shared table."
  (vovas.engine.jscbytecode:recover-jsc-strings (arg-bytes-or-empty args 0)))

(defarm "wtfStringHash" (args)
  "WTF's string hash of BYTES."
  (vovas.engine.jscbytecode:wtf-string-hash (arg-bytes-or-empty args 0)))

(defarm "analyzeJscModule" (args)
  "BYTES analysed as a JSC module, with an optional shared string table.

A null second argument means NO table rather than an empty one: the arm matches
`Some(Value::Null) | None` to None, so the analysis takes the no-table path."
  (let ((shared (arg-raw args 1)))
    (vovas.engine.jscbytecode:analyze-jsc-module
     (arg-bytes-or-empty args 0)
     (and (vectorp shared)
          (coerce (loop for s across shared
                        collect (and (stringp s) s))
                  'list)))))

(defarm "readJscSharedTable" (args)
  "The shared string table at OFFSET of LENGTH in BYTES. Both are REQUIRED."
  (vovas.engine.jscbytecode:read-jsc-shared-table
   (arg-bytes-or-empty args 0)
   (or (arg-usize args 1) (error "readJscSharedTable: offset"))
   (or (arg-usize args 2) (error "readJscSharedTable: length"))))

(defarm "findJscSharedTable" (args)
  "The shared string table referenced by BYTES, or NIL."
  (vovas.engine.jscbytecode:find-jsc-shared-table (arg-bytes-or-empty args 0)))

;;; --- wasm ------------------------------------------------------------------

(defarm "detectWasmModule" (args)
  "Whether BYTES are a WebAssembly module."
  (vovas.engine.wasm:detect-wasm-module (arg-bytes-or-empty args 0)))

(defarm "parseWasmModule" (args)
  "BYTES parsed as a WebAssembly module, or NIL."
  (vovas.engine.wasm:parse-wasm-module (arg-bytes-or-empty args 0)))

;;; --- zip -------------------------------------------------------------------

(defbytearm "buildZip" (args)
  "FILES assembled into an archive, as raw bytes.

A timestamp that is absent, non-finite, or non-positive means NOW rather than
the epoch - the engine owns a clock seam, so a caller omitting it still gets a
sane archive stamp instead of one dated 1970."
  (let* ((files (coerce (loop for file across (or (arg-raw args 0) #())
                              collect (vovas.engine.pipeline:make-file
                                       (obj-str file "path")
                                       (obj-str file "content")))
                        'list))
         (stamp (let ((v (arg-raw args 1)))
                  (if (and (realp v)
                           (vovas.engine.panel.model:finite-float-p
                            (coerce v 'double-float))
                           (plusp v))
                      (truncate v)
                      (vovas.engine.util:now-unix-millis)))))
    (vovas.engine.zip:build-zip files stamp)))

;;; ---------------------------------------------------------------------------
;;; Dispatch
;;; ---------------------------------------------------------------------------

(defun arm-names ()
  "Every callable arm name, sorted."
  (sort (append (loop for k being the hash-keys of *arms* collect k)
                (loop for k being the hash-keys of *byte-arms* collect k))
        #'string<))

(defun arm-name-p (name)
  "Whether NAME is a callable arm."
  (or (nth-value 1 (gethash name *arms*))
      (nth-value 1 (gethash name *byte-arms*))))

(defun call (name args)
  "NAME dispatched with the positional argument vector ARGS, answering a value.

ARGS is the same positional array the wasm arm reads. A name with no arm
SIGNALS: the wasm answers `{{\"__error\": ...}}` for an unknown name and the
bridge treats that as a failure rather than as silence, so the distinction is
preserved rather than flattened into NIL."
  (let ((fn (gethash name *arms*)))
    (unless fn
      (when (nth-value 1 (gethash name *byte-arms*))
        (error "~a is a BYTES arm; use call-bytes" name))
      (error "xu_call: unknown function ~a" name))
    (funcall fn (or args #()))))

(defun call-bytes (name args)
  "NAME dispatched as a BYTES arm with the positional vector ARGS."
  (let ((fn (gethash name *byte-arms*)))
    (unless fn
      (when (nth-value 1 (gethash name *arms*))
        (error "~a is a JSON arm; use call" name))
      (error "xu_call: unknown byte function ~a" name))
    (funcall fn (or args #()))))

(defun dispatch (name args)
  "NAME dispatched with ARGS, answering `(:ok value)` or `(:error message)`.

`dispatch` in the wasm answers a `Result`, and the bridge turns an Err into a
named throw. This mirrors that shape: a refusal is DATA, so a caller can report
it without an exception handler, while an unexpected Lisp error still surfaces
as exactly that rather than as a tidy string."
  (handler-case
      (list :ok (call name args))
    (error (e)
      (let ((message (format nil "~a" e)))
        (record-failure message)
        (list :error message)))))

(defun dispatch-bytes (name args)
  "NAME as a BYTES arm, answering `(:ok octets)` or `(:error message)`."
  (handler-case
      (list :ok (call-bytes name args))
    (error (e)
      (let ((message (format nil "~a" e)))
        (record-failure message)
        (list :error message)))))
