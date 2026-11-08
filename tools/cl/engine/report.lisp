;;;; report.lisp - the rendered HTML the panel serves.
;;;;
;;;; SCOPE so far: `describe-capture-reason`, which is small enough to port
;;;; exactly and has five pinned oracle cases covering every branch. The HTML
;;;; generators (`generate-table`, `generate-waterfall-html`,
;;;; `generate-investigation-index-html`) are 1,154 lines of string building with
;;;; single giant expected strings; they land next, one at a time, each gated on
;;;; its own section rather than all four in a lump.

(in-package :vovas.engine.panel.report)

(defun describe-capture-reason (status profile)
  "`describeCaptureReason`: one sentence explaining why capture is where it is.

Four fallbacks, in the engine's order, and the ORDER is the whole behaviour:

  1. a non-empty `reasonText` on the capture status wins outright;
  2. otherwise a truthy `ready` flag answers the fixed \"adaptive window
     satisfied\" sentence;
  3. otherwise the PROFILE's first strategy reason produces
     \"Adaptive mode: <profile>. <reason>.\";
  4. otherwise the idle sentence.

Note that (2) is checked before (3), so a ready capture reports readiness even
when the profile carries reasons - and that a profile with an EMPTY reasons array
falls through to (4) rather than to an adaptive line with a blank reason."
  (let ((reason (and (hash-table-p status)
                     (vovas.engine.panel.assets:field-str status "reasonText"))))
    (when (and reason (plusp (length reason)))
      (return-from describe-capture-reason reason)))
  (when (and (hash-table-p status)
             (vovas.engine.panel.model:js-truthy
              (vovas.engine.panel.assets:field status "ready")))
    (return-from describe-capture-reason
      "Adaptive capture window satisfied. Export can proceed."))
  (let* ((strategy (and (hash-table-p profile)
                        (vovas.engine.panel.assets:field profile "strategy")))
         (reasons (and (hash-table-p strategy)
                       (vovas.engine.panel.assets:field strategy "reasons"))))
    (when (and (or (vectorp reasons) (listp reasons))
               (plusp (length reasons)))
      (return-from describe-capture-reason
        (format nil "Adaptive mode: ~a. ~a."
                (vovas.engine.panel.assets:field-str strategy "profile")
                (vovas.engine.panel.assets:value-text (aref (coerce reasons 'vector) 0))))))
  "Profiler idle until capture starts.")

;;; ---------------------------------------------------------------------------
;;; generateTable
;;; ---------------------------------------------------------------------------

(defun report-number-or (value fallback)
  "`number_or`: VALUE unless it is zero or NaN, else FALLBACK.

NaN is tested with `sb-ext:float-nan-p` guarded on `floatp`, because comparing a
NaN with `=` signals on SBCL rather than answering."
  (if (and (numberp value)
           (not (and (floatp value) (sb-ext:float-nan-p value)))
           (/= (coerce value 'double-float) 0d0))
      value
      fallback))

(defun generate-table (timings)
  "`generateTable`: the resource table, byte-identical to the engine's.

Timings are NOT sorted here - the caller sorts by `startTime` first. That is why
this has no internal ordering step while `generate-waterfall-html` does.

The five phase columns (DNS/TCP/SSL/TTFB/Download) print \"-\" for a zero or
negative span rather than \"0 us\", and SSL is zero unless BOTH `secureConnectionStart`
and `connectEnd` are positive - so a plain-HTTP request shows a dash, not a
negative duration."
  (with-output-to-string (out)
    (write-string "<table id=\"resTable\"><thead><tr><th>URL</th><th>Type</th><th>Status</th><th>Size</th><th>Time</th><th>DNS</th><th>TCP</th><th>SSL</th><th>TTFB</th><th>Download</th></tr></thead><tbody>" out)
    (dolist (entry timings)
      (flet ((n (key) (vovas.engine.panel.assets:field-number entry key)))
        (let* ((dns (report-number-or (- (n "domainLookupEnd") (n "domainLookupStart")) 0d0))
               (tcp (report-number-or (- (n "connectEnd") (n "connectStart")) 0d0))
               (ssl (if (and (> (n "secureConnectionStart") 0d0)
                             (> (n "connectEnd") 0d0))
                        (- (n "connectEnd") (n "secureConnectionStart"))
                        0d0))
               (ttfb (report-number-or (- (n "responseStart") (n "requestStart")) 0d0))
               (download (report-number-or (- (n "responseEnd") (n "responseStart")) 0d0))
               (status (if (or (> (n "transferSize") 0d0)
                               (> (n "encodedBodySize") 0d0))
                           "OK"
                           "from cache"))
               (size (vovas.engine.text:format-size
                      (report-number-or
                       (report-number-or (n "transferSize") (n "encodedBodySize"))
                       (report-number-or (n "decodedBodySize") 0d0))))
               (name (vovas.engine.panel.assets:field-str entry "name"))
               (initiator (let ((v (vovas.engine.panel.assets:field-str entry "initiatorType")))
                            (if (plusp (length v)) v "other"))))
          (flet ((phase-cell (value)
                   (if (> value 0d0)
                       (vovas.engine.text:format-ms value)
                       "-")))
            (write-string "<tr><td style=\"max-width:320px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap\" title=\"" out)
            (write-string (vovas.engine.panel.artifacts:escape-attr name) out)
            (write-string "\">" out)
            (write-string (vovas.engine.panel.view:escape-html name) out)
            (write-string "</td><td>" out)
            (write-string (vovas.engine.panel.view:escape-html initiator) out)
            (write-string "</td><td>" out)
            (write-string status out)
            (write-string "</td><td>" out)
            (write-string size out)
            (write-string "</td><td>" out)
            (write-string (vovas.engine.text:format-ms (report-number-or (n "duration") 0d0)) out)
            (write-string "</td><td>" out)
            (write-string (phase-cell dns) out)
            (write-string "</td><td>" out)
            (write-string (phase-cell tcp) out)
            (write-string "</td><td>" out)
            (write-string (phase-cell ssl) out)
            (write-string "</td><td>" out)
            (write-string (phase-cell ttfb) out)
            (write-string "</td><td>" out)
            (write-string (phase-cell download) out)
            (write-string "</td></tr>" out)))))
    (write-string "</tbody></table>" out)))

;;; ---------------------------------------------------------------------------
;;; exportReadableArtifacts
;;; ---------------------------------------------------------------------------

(defparameter *readable-artifact-limit* 10)

(defun export-readable-artifacts-with (writer analysis looks-minified-fn beautify-fn)
  "`exportReadableArtifactsWith`: write a readable .js per interesting entrypoint.

Entrypoints are visited in order and the FIRST TEN that resolve take slots 1..10;
the slot number is part of the filename, so it is assigned AFTER the skips, not
from the loop index.

Two skips differ by kind, and they are not the same test:
  - a chunk must carry TRUTHY `content` (an empty string is skipped);
  - a runtime must carry `text` as a STRING (empty text still qualifies, because
    the test is on the type, not the contents).

The record lookup is by id in the asset map or the runtime map according to the
entry's KIND, so an id present in both maps resolves to the right one."
  (let ((asset-map (make-hash-table :test #'equal))
        (runtime-map (make-hash-table :test #'equal))
        (written 0))
    (dolist (asset (coerce (or (vovas.engine.panel.assets:field analysis "assets") #())
                           'list))
      (setf (gethash (vovas.engine.panel.assets:field-str asset "id") asset-map) asset))
    (dolist (record (coerce (or (vovas.engine.panel.assets:field analysis "runtimeRecords") #())
                            'list))
      (setf (gethash (vovas.engine.panel.assets:field-str record "id") runtime-map) record))
    (dolist (entry (coerce (or (vovas.engine.panel.assets:field
                                analysis "interestingEntrypoints")
                              #())
                           'list))
      (when (>= written *readable-artifact-limit*)
        (return))
      (let* ((id (vovas.engine.panel.assets:field-str entry "id"))
             (kind (vovas.engine.panel.assets:field-str entry "kind"))
             (record (if (string= kind "chunk")
                         (gethash id asset-map)
                         (gethash id runtime-map))))
        (when record
          (let ((eligible
                  (if (string= kind "chunk")
                      (vovas.engine.panel.model:js-truthy
                       (vovas.engine.panel.assets:field record "content"))
                      (stringp (vovas.engine.panel.assets:field record "text")))))
            (when eligible
              (incf written)
              (let* ((label (let ((l (vovas.engine.panel.assets:field-str entry "label")))
                              (if (plusp (length l)) l id)))
                     (file (format nil "_analysis/readable/~4,'0d-~a.js"
                                   written
                                   (vovas.engine.text:sanitize-path-part
                                    label kind))))
                (funcall writer
                         file
                         (vovas.engine.panel.artifacts:build-readable-artifact-with
                          entry record looks-minified-fn beautify-fn))))))))))

;;; ---------------------------------------------------------------------------
;;; Pretty JSON
;;;
;;; `serde_json::to_string_pretty` writes two-space indents, a newline after each
;;; brace and bracket, and no trailing newline. JZON's `:pretty` mode produces
;;; byte-identical output for objects and arrays - verified against the oracle's
;;; stored strings before relying on it, because the framework export comparisons
;;; are exact.
;;; ---------------------------------------------------------------------------

(defun report-pretty-json (value)
  "VALUE as pretty JSON, the way serde_json prints it."
  (com.inuoe.jzon:stringify value :pretty t))

;;; ---------------------------------------------------------------------------
;;; exportFrameworkArtifacts
;;; ---------------------------------------------------------------------------

(defun export-framework-artifacts (writer framework-state)
  "`exportFrameworkArtifacts`: write each PRESENT framework slice, pretty-printed.

Walks `*framework-artifacts*` in table order, skipping slices
`framework-slice-present-p` rejects - so the writer and the artifact index agree
by construction, which is the whole reason that predicate is shared.

A nil state writes NOTHING: there is no framework state, so there are no files,
and an empty archive index is the honest answer."
  (when (null framework-state)
    (return-from export-framework-artifacts nil))
  (dolist (pair vovas.engine.panel.paths:*framework-artifacts*)
    (let ((path (car pair))
          (key (cdr pair)))
      (when (vovas.engine.panel.paths:framework-slice-present-p framework-state key)
        (let ((value (vovas.engine.panel.assets:field framework-state key)))
          (when value
            (funcall writer path (report-pretty-json value)))))))
  nil)

;;; ---------------------------------------------------------------------------
;;; exportRuntimeArtifacts
;;; ---------------------------------------------------------------------------

(defparameter *runtime-manifest-omitted-keys*
  '("index" "text" "base64" "hasText" "hasBase64")
  "Keys the runtime manifest drops.

The payload itself is written as a file, so the manifest carries a `file` path
instead. `index` is scratch used while building the path.")

(defun export-runtime-artifacts (writer runtime-entries)
  "`exportRuntimeArtifacts`: write each runtime payload plus the manifest.

Counters are per-KIND, so the second eval payload is `0001` only if no eval came
before it - the numbering restarts for each kind rather than running globally.

A payload is written from `text` when present, else decoded from `base64`; a
base64 payload that fails to decode is SKIPPED but still appears in the manifest
WITHOUT a `file` key, which is how a consumer tells \"no payload\" from \"payload
written under this name\".

The manifest is written exactly ONCE, after every entry has been processed."
  (let ((manifest '())
        (counters (make-hash-table :test #'equal)))
    (dolist (entry (coerce runtime-entries 'list))
      (let ((manifest-entry (make-hash-table :test #'equal)))
        ;; copy the entry's keys, minus the ones the manifest does not carry
        (when (hash-table-p entry)
          (maphash (lambda (k v)
                     (unless (member k *runtime-manifest-omitted-keys* :test #'string=)
                       (setf (gethash k manifest-entry) v)))
                   entry))
        (let ((text (let ((v (vovas.engine.panel.assets:field entry "text")))
                      (and (stringp v) v)))
              (base64 (let ((v (vovas.engine.panel.assets:field entry "base64")))
                        (and (stringp v) v))))
          (when (or text base64)
            (let ((path (vovas.engine.panel.artifacts:build-runtime-path
                         entry counters)))
              (cond
                (text (funcall writer path text))
                (base64
                 (let ((bytes (vovas.engine.decoders:decode-base64-to-bytes base64)))
                   (when bytes (funcall writer path bytes)))))
              (setf (gethash "file" manifest-entry) path))))
        (push manifest-entry manifest)))
    (let ((manifest-vector (coerce (nreverse manifest) 'vector)))
      (funcall writer "_runtime/runtime-manifest.json"
               (report-pretty-json manifest-vector))
      manifest-vector)))
