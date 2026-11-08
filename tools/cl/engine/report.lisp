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

;;; ---------------------------------------------------------------------------
;;; The waterfall report
;;;
;;; Geometry is fixed: rows are 22 units tall, the label column is 360 wide, and
;;; the bar area starts 8 units past it inside a 1200-wide viewBox. `to_x` maps a
;;; millisecond timestamp into that bar area, scaled by the LATEST response end.
;;;
;;; FIVE bar segments are drawn per row, each conditional on its own pair of
;;; timings, and each floored at 1 unit of width so a sub-pixel phase is still
;;; visible. The TCP bar is special: when a secure connection started after the
;;; TCP connect began, TCP is TRUNCATED at secureStart so the SSL segment can take
;;; the rest - otherwise the two bars would overlap.
;;; ---------------------------------------------------------------------------

(defparameter *wf-row-h* 22d0)
(defparameter *wf-label-w* 360d0)
(defparameter *wf-total-w* 1200d0)
(defparameter *wf-bar-start* (+ *wf-label-w* 8d0))
(defparameter *wf-bar-w* (- *wf-total-w* *wf-bar-start* 10d0))

(defparameter *wf-color-dns* "rgba(3,169,244,0.6)")
(defparameter *wf-color-tcp* "rgba(255,152,0,0.6)")
(defparameter *wf-color-ssl* "rgba(156,39,176,0.6)")
(defparameter *wf-color-ttfb* "rgba(76,175,80,0.6)")
(defparameter *wf-color-download* "rgba(3,169,244,0.9)")
(defparameter *wf-color-text* "#ccc")
(defparameter *wf-color-bg* "#242424")
(defparameter *wf-color-stripe* "#2a2a2a")

(defparameter *wf-strip-origin* (cl-ppcre:create-scanner "^https?://[^/]+/")
  "`e.name.replace(/^https?:\\/\\/[^\\/]+\\//, '')` - drops scheme+host and the
following slash. A name with no origin is left alone.")

(defun wf-num (value)
  "A coordinate as JS would print it - integral values lose the decimal."
  (vovas.engine.number:to-string (coerce (or value 0d0) 'double-float)))

(defun wf-bar (x y width fill title)
  "One bar rect with its tooltip, as the engine emits it."
  (format nil "<rect x=\"~a\" y=\"~a\" width=\"~a\" height=\"~a\" fill=\"~a\"><title>~a</title></rect>"
          (wf-num x) (wf-num y) (wf-num width) (wf-num (- *wf-row-h* 8d0))
          fill title))

(defun generate-waterfall-html (timings)
  "`generateWaterfallHtml`: the SVG waterfall plus the resource table and script.

An empty input answers a fixed sentence rather than an empty chart, which is what
the oracle pins as the empty case."
  (when (null timings)
    (return-from generate-waterfall-html
      "<html><body>No timing data available.</body></html>"))
  (let* ((sorted (stable-sort (copy-list timings) #'<
                              :key (lambda (e)
                                     (vovas.engine.panel.assets:field-number
                                      e "startTime"))))
         (max-end 0d0))
    ;; the time axis runs to the furthest response end, or start+duration when a
    ;; response end is missing - whichever is greater across all rows
    (dolist (entry sorted)
      (let ((end (let ((v (vovas.engine.panel.assets:field-number entry "responseEnd")))
                   (if (/= v 0d0) v
                       (+ (vovas.engine.panel.assets:field-number entry "startTime")
                          (vovas.engine.panel.assets:field-number entry "duration"))))))
        (when (> end max-end) (setf max-end end))))
    (let* ((total-time max-end)
           (chart-height (+ (* (length sorted) *wf-row-h*) 60d0))
           (svg-height (+ chart-height 120d0))
           (to-x (lambda (ms) (+ *wf-bar-start*
                                (if (zerop total-time) 0d0
                                    (* (/ ms total-time) *wf-bar-w*)))))
           (rows (make-string-output-stream)))
      (loop for entry in sorted
            for r from 0
            do (let ((y (+ 40d0 (* r *wf-row-h*))))
                 ;; stripe every OTHER row, starting with the first
                 (when (evenp r)
                   (format rows "<rect x=\"~a\" y=\"~a\" width=\"~a\" height=\"~a\" fill=\"~a\" opacity=\"0.3\"/>"
                           (wf-num *wf-bar-start*) (wf-num y)
                           (wf-num *wf-bar-w*) (wf-num *wf-row-h*)
                           *wf-color-stripe*))
                 ;; label: origin stripped, then take(55) CHARACTERS
                 (let* ((name (vovas.engine.panel.assets:field-str entry "name"))
                        (stripped (cl-ppcre:regex-replace *wf-strip-origin* name ""))
                        (label (subseq stripped 0 (min 55 (length stripped)))))
                   (format rows "<text x=\"~a\" y=\"~a\" fill=\"~a\" font-size=\"11\" font-family=\"monospace\" text-anchor=\"end\">~a</text>"
                           (wf-num (- *wf-bar-start* 6d0)) (wf-num (+ y 14d0))
                           *wf-color-text*
                           (vovas.engine.panel.artifacts:escape-xml label)))
                 (let ((dns-start (vovas.engine.panel.assets:field-number entry "domainLookupStart"))
                       (dns-end (vovas.engine.panel.assets:field-number entry "domainLookupEnd"))
                       (conn-start (vovas.engine.panel.assets:field-number entry "connectStart"))
                       (conn-end (vovas.engine.panel.assets:field-number entry "connectEnd"))
                       (secure-start (vovas.engine.panel.assets:field-number entry "secureConnectionStart"))
                       (req-start (vovas.engine.panel.assets:field-number entry "requestStart"))
                       (resp-start (vovas.engine.panel.assets:field-number entry "responseStart"))
                       (resp-end (vovas.engine.panel.assets:field-number entry "responseEnd")))
                   (when (and (> dns-start 0d0) (> dns-end dns-start))
                     (write-string
                      (wf-bar (funcall to-x dns-start) (+ y 4d0)
                              (max 1d0 (- (funcall to-x dns-end) (funcall to-x dns-start)))
                              *wf-color-dns*
                              (format nil "DNS: ~a" (vovas.engine.text:format-ms (- dns-end dns-start))))
                      rows))
                   (when (and (> conn-start 0d0) (> conn-end 0d0))
                     (let ((tcp-width (max 1d0 (- (funcall to-x conn-end)
                                                  (funcall to-x conn-start)))))
                       ;; SSL eats the tail of the TCP span when it started later
                       (when (and (> secure-start 0d0) (> secure-start conn-start))
                         (setf tcp-width (max 1d0 (- (funcall to-x secure-start)
                                                     (funcall to-x conn-start)))))
                       (when (> tcp-width 0d0)
                         (write-string
                          (wf-bar (funcall to-x conn-start) (+ y 4d0) tcp-width
                                  *wf-color-tcp*
                                  (format nil "TCP: ~a" (vovas.engine.text:format-ms
                                                         (- conn-end conn-start))))
                          rows))))
                   (when (and (> secure-start 0d0) (> conn-end secure-start))
                     (write-string
                      (wf-bar (funcall to-x secure-start) (+ y 4d0)
                              (max 1d0 (- (funcall to-x conn-end) (funcall to-x secure-start)))
                              *wf-color-ssl*
                              (format nil "SSL: ~a" (vovas.engine.text:format-ms
                                                     (- conn-end secure-start))))
                      rows))
                   (when (and (> req-start 0d0) (> resp-start req-start))
                     (write-string
                      (wf-bar (funcall to-x req-start) (+ y 4d0)
                              (max 1d0 (- (funcall to-x resp-start) (funcall to-x req-start)))
                              *wf-color-ttfb*
                              (format nil "TTFB: ~a" (vovas.engine.text:format-ms
                                                      (- resp-start req-start))))
                      rows))
                   (when (and (> resp-start 0d0) (> resp-end resp-start))
                     (write-string
                      (wf-bar (funcall to-x resp-start) (+ y 4d0)
                              (max 1d0 (- (funcall to-x resp-end) (funcall to-x resp-start)))
                              *wf-color-download*
                              (format nil "Download: ~a" (vovas.engine.text:format-ms
                                                          (- resp-end resp-start))))
                      rows))
                   ;; the total duration label, right of the last bar it covers
                   (let* ((start (vovas.engine.panel.assets:field-number entry "startTime"))
                          (duration (let ((v (- resp-end start)))
                                      (if (/= v 0d0) v
                                          (vovas.engine.panel.assets:field-number
                                           entry "duration"))))
                          (anchor (if (/= resp-end 0d0) resp-end (+ start duration))))
                     (format rows "<text x=\"~a\" y=\"~a\" fill=\"#888\" font-size=\"10\" font-family=\"monospace\">~a</text>"
                             (wf-num (+ (funcall to-x anchor) 6d0))
                             (wf-num (+ y 14d0))
                             (vovas.engine.text:format-ms duration))))))
      ;; the time axis: at most 10 ticks, one per 100ms of the total, plus the
      ;; boundary tick - hence `<=` and the inclusive loop
      (let* ((num-ticks (min 10d0 (ceiling (if (zerop total-time) 0d0
                                             (/ total-time 100d0)))))
             (grid (make-string-output-stream)))
        (loop for tick from 0d0
              while (<= tick num-ticks)
              do (let ((tx (+ *wf-bar-start*
                              (if (zerop num-ticks) 0d0
                                  (* (/ tick num-ticks) *wf-bar-w*)))))
                   (format grid "<line x1=\"~a\" y1=\"40\" x2=\"~a\" y2=\"~a\" stroke=\"#333\" stroke-width=\"0.5\"/>"
                           (wf-num tx) (wf-num tx) (wf-num (- chart-height 10d0)))
                   (format grid "<text x=\"~a\" y=\"30\" fill=\"#777\" font-size=\"10\" font-family=\"monospace\" text-anchor=\"middle\">~a</text>"
                           (wf-num tx)
                           (vovas.engine.text:format-ms
                            (if (zerop num-ticks) 0d0
                                (* (/ tick num-ticks) total-time))))))
        (with-output-to-string (out)
          (write-string *wf-0* out)
          (write-string (vovas.engine.pipeline:iso8601-now) out)
          (write-string *wf-2* out)
          (princ (length sorted) out)
          (write-string *wf-4* out)
          (write-string (vovas.engine.text:format-ms total-time) out)
          (write-string *wf-6* out)
          (write-string (vovas.engine.panel.artifacts:compute-recon-stats timings) out)
          (write-string *wf-8* out)
          (write-string *wf-color-dns* out)
          (write-string *wf-10* out)
          (write-string *wf-color-tcp* out)
          (write-string *wf-12* out)
          (write-string *wf-color-ssl* out)
          (write-string *wf-14* out)
          (write-string *wf-color-ttfb* out)
          (write-string *wf-16* out)
          (write-string *wf-color-download* out)
          (write-string *wf-18* out)
          (write-string (wf-num *wf-total-w*) out)
          (write-string *wf-20* out)
          (write-string (wf-num svg-height) out)
          (write-string *wf-22* out)
          (write-string (wf-num *wf-total-w*) out)
          (write-string *wf-24* out)
          (write-string (wf-num *wf-total-w*) out)
          (write-string *wf-26* out)
          (write-string (wf-num svg-height) out)
          (write-string *wf-28* out)
          (write-string *wf-color-bg* out)
          (write-string *wf-30* out)
          (write-string (get-output-stream-string grid) out)
          (write-string (get-output-stream-string rows) out)
          (write-string *wf-33* out)
          (write-string (generate-table sorted) out)
          (write-string *wf-35* out)
          (write-string (vovas.engine.panel.artifacts:json-serialize-compact
                         (coerce sorted 'vector))
                        out)
          (write-string *wf-37* out))))))

;;; ---------------------------------------------------------------------------
;;; generateInvestigationIndexHtml
;;;
;;; The console page: a static shell with the analysis embedded as JSON in a
;;; script tag and the SCRIPT fragment driving it client-side. Both the STYLES
;;; and SCRIPT arrays are loaded from inv-consts.lisp, extracted mechanically.
;;; ---------------------------------------------------------------------------

(defparameter *investigation-doc*
  "~a<html lang=\"en\">~%<head>~%<meta charset=\"UTF-8\">~%<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">~%<title>Investigation Console</title>~%<style>~a</style>~%</head>~%<body>~%<div class=\"shell\">~%<aside class=\"sidebar\">~%<h1 class=\"title\">Investigation Console</h1>~%<div class=\"sub\">~a<br>~a</div>~%<div class=\"section-title\">Workspaces</div><div id=\"workspaceNav\" class=\"nav\"></div>~%<div class=\"section-title\">Journeys</div><div id=\"journeyNav\" class=\"nav\"></div>~%</aside>~%<main class=\"main\">~%<div id=\"summaryCards\" class=\"cards\"></div>~%<div id=\"view\"></div>~%</main>~%</div>~%<script id=\"investigation-data\" type=\"application/json\">~a</script>~%<script>~a</script>~%</body>~%</html>")

(defparameter *investigation-doctype* "<!DOCTYPE html>")

(defun generate-investigation-index-html (investigation)
  "`generateInvestigationIndexHtml`: the analysis rendered as a console page.

The TITLE in `<title>` is the constant \"Investigation Console\"; the `<h1>` is
too. Only the sidebar subtitle varies - it shows the page title, falling back to
the page URL and then to \"Investigation Console\".

The embedded data is `investigation` itself, with a non-truthy argument
serialised as `{}` so the page always parses. `<`, `>` and `&` inside it are
unicode-escaped by `serialize-inline-json`, which is what keeps a `</script>`
string from closing the tag early."
  (let* ((truthy (vovas.engine.panel.model:js-truthy investigation))
         (page (if truthy
                   (let ((v (vovas.engine.panel.assets:field investigation "page")))
                     (if (vovas.engine.panel.model:js-truthy v) v
                         (make-hash-table :test #'equal)))
                   (make-hash-table :test #'equal)))
         (title (let ((t1 (vovas.engine.panel.assets:field-str page "title")))
                  (if (plusp (length t1))
                      t1
                      (let ((u (vovas.engine.panel.assets:field-str page "url")))
                        (if (plusp (length u)) u "Investigation Console")))))
         (page-url (vovas.engine.panel.assets:field-str page "url"))
         (data (vovas.engine.panel.artifacts:serialize-inline-json
                (if truthy investigation (make-hash-table :test #'equal)))))
    (format nil *investigation-doc*
            *investigation-doctype*
            (format nil "~{~a~}" *styles*)
            (escape-html title)
            (escape-html page-url)
            data
            (format nil "~{~a~^~%~}" *script*))))

;;; ---------------------------------------------------------------------------
;;; exportReadableArtifacts / exportSemanticAnalysis
;;; ---------------------------------------------------------------------------

(defun export-readable-artifacts (writer analysis)
  "`exportReadableArtifacts`: the readable-file pass with the engine's own
beautifier.

`beautify` is reached by `find-symbol` because that module declares its
`defpackage` in its own file and loads BEFORE this one - a package-level import
would be read before the package exists."
  (export-readable-artifacts-with
   writer analysis
   (lambda (text)
     (funcall (find-symbol "LOOKS-MINIFIED-P" :vovas.engine.beautify) text))
   (lambda (text)
     (funcall (find-symbol "BEAUTIFY-JS" :vovas.engine.beautify) text))))

(defun export-semantic-analysis (writer js-assets recon-data
                                 runtime-entries runtime-manifest)
  "`exportSemanticAnalysis`: build the analysis, then write the whole artifact set.

The ORDER is the contract, because a consumer watches files appear:
  1. the readable reconstructions (first ten interesting entrypoints);
  2. the eight analysis artifacts, pretty-printed, in table order;
  3. the investigation console page;
  4. one file per workspace, then one per journey.

Step 1 runs BEFORE the analysis files because it is the expensive pass - a
beautifier over captured source - and an interrupted export should still have the
human-readable reconstructions on disk.

Artifacts are written only when the key is PRESENT; a missing section produces no
file rather than a file containing `null`, so the archive index and the archive
contents cannot disagree about what exists."
  (let* ((analysis (vovas.engine.panel.analysis:build-semantic-analysis
                    js-assets recon-data runtime-entries runtime-manifest))
         (investigation (or (vovas.engine.panel.assets:field analysis "investigation")
                            (vovas.engine.panel.model:json-null-symbol))))
    (export-readable-artifacts writer analysis)
    (dolist (pair vovas.engine.panel.paths:*analysis-artifacts*)
      (let ((value (vovas.engine.panel.assets:field analysis (cdr pair))))
        (when value
          (funcall writer (car pair) (report-pretty-json value)))))
    (funcall writer vovas.engine.panel.paths:*analysis-index-html*
             (generate-investigation-index-html investigation))
    (dolist (workspace (coerce (or (vovas.engine.panel.assets:field
                                    investigation "workspaces")
                                  #())
                               'list))
      (funcall writer
               (format nil "_analysis/workspaces/~a.json"
                       (vovas.engine.panel.assets:field-str workspace "id"))
               (report-pretty-json workspace)))
    (dolist (journey (coerce (or (vovas.engine.panel.assets:field
                                  investigation "journeys")
                                #())
                             'list))
      (funcall writer
               (format nil "_analysis/journeys/~a.json"
                       (vovas.engine.panel.assets:field-str journey "id"))
               (report-pretty-json journey)))
    analysis))
