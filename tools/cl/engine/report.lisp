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
