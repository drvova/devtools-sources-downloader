;;;; gate-report.lisp - the rendered report tier.
;;;;
;;;; `describe-capture-reason` has five pinned cases covering every branch, and
;;;; the Rust test spells out all five inputs verbatim. The HTML generators are
;;;; gated separately as they land.

(in-package :vovas.engine.gate)

(defun run-report-gate (&key (verbose t))
  (let* ((result (make-gate-result))
         (count 0)
         (fx (read-json-file (fixture-path "panel/artifacts-oracle.json")))
         (want (gethash "describeCaptureReason" (gethash "expected" fx)))
         ;; the five inputs, verbatim from `capture_reason_matches_oracle`
         (status-custom (ht "reasonText" "Custom reason."))
         (status-ready (ht "ready" t))
         (profile-adaptive (ht "strategy" (ht "profile" "balanced"
                                              "reasons" (vector "steady traffic"))))
         (status-not-ready (ht "ready" nil))
         (profile-empty (ht "strategy" (ht "reasons" #())))
         (cases (list (cons status-custom nil)
                      (cons status-ready nil)
                      (cons nil profile-adaptive)
                      (cons status-not-ready profile-empty)
                      (cons nil nil))))

    ;; Each case pins a DIFFERENT branch, and the ORDER between the ready check
    ;; and the profile check is only observable at index 1.
    (loop for (status . profile) in cases
          for index from 0
          do (incf count)
             (check result (format nil "describeCaptureReason/~a" index) "sentence"
                    (vovas.engine.panel.report:describe-capture-reason status profile)
                    (coerce (aref want index) 'string)))

    (when verbose
      (format t "~&report gate: ~a/~a cases match~%"
              (gate-result-passed result) (gate-result-total result))
      (report-failures result))

    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp count))))

;;; ---------------------------------------------------------------------------
;;; generateTable
;;;
;;; The Rust compares this with `assert_same_document`, which returns early only
;;; on an EXACT string match - so this is a byte-for-byte comparison against a
;;; 1,670-character expected value. The five timing entries are replicated from
;;; the Rust test's own `timing_case` helper, including its defaults.
;;; ---------------------------------------------------------------------------

(defun gate-timing-defaults (name initiator start duration)
  (ht "name" name
      "initiatorType" initiator
      "startTime" start
      "domainLookupStart" 0
      "domainLookupEnd" 0
      "connectStart" 0
      "connectEnd" 0
      "secureConnectionStart" 0
      "requestStart" 0
      "responseStart" 0
      "responseEnd" 0
      "duration" duration
      "transferSize" 0
      "encodedBodySize" 0
      "decodedBodySize" 0))

(defparameter *gate-timing-case*
  (list
   (let ((e (gate-timing-defaults "https://demo.test/static/app.js?v=3" "script" 0.0 118.5)))
     (setf (gethash "domainLookupStart" e) 0.4
           (gethash "domainLookupEnd" e) 3.2
           (gethash "connectStart" e) 3.2
           (gethash "connectEnd" e) 14.6
           (gethash "secureConnectionStart" e) 6.1
           (gethash "requestStart" e) 15.0
           (gethash "responseStart" e) 42.75
           (gethash "responseEnd" e) 118.5
           (gethash "transferSize" e) 20480.0
           (gethash "encodedBodySize" e) 19000.0
           (gethash "decodedBodySize" e) 51000.0)
     e)
   (let ((e (gate-timing-defaults "https://cdn.other.test/lib/vendor.css" "link" 12.25 77.75)))
     (setf (gethash "connectStart" e) 12.25
           (gethash "connectEnd" e) 30.0
           (gethash "requestStart" e) 31.0
           (gethash "responseStart" e) 55.5
           (gethash "responseEnd" e) 90.0
           (gethash "decodedBodySize" e) 1200.0)
     e)
   (let ((e (gate-timing-defaults "https://demo.test/api/session" "fetch" 40.0 220.0)))
     (setf (gethash "requestStart" e) 41.0
           (gethash "responseStart" e) 180.25
           (gethash "responseEnd" e) 260.0
           (gethash "transferSize" e) 512.0
           (gethash "encodedBodySize" e) 512.0
           (gethash "decodedBodySize" e) 900.0)
     e)
   (let ((e (gate-timing-defaults "https://demo.test/img/logo.png" "img" 300.0 640.5)))
     (setf (gethash "requestStart" e) 301.0
           (gethash "responseStart" e) 305.0
           (gethash "responseEnd" e) 940.5
           (gethash "transferSize" e) 8192.0
           (gethash "encodedBodySize" e) 8192.0
           (gethash "decodedBodySize" e) 8192.0)
     e)
   (gate-timing-defaults "https://demo.test/beacon" "other" 950.0 12.0))
  "`timing_case`: the five entries the report oracle was captured from.")

(defun run-report-table-gate (&key (verbose t))
  (let* ((result (make-gate-result))
         (count 0)
         (fx (read-json-file (fixture-path "panel/artifacts-oracle.json")))
         (exp (gethash "expected" fx))
         (timings *gate-timing-case*)
         ;; the Rust test sorts by startTime BEFORE calling generate_table
         (sorted (stable-sort (copy-list timings) #'<
                              :key (lambda (e)
                                     (vovas.engine.panel.assets:field-number e "startTime")))))

    (incf count)
    (check result "generateTable" "html"
           (vovas.engine.panel.report:generate-table sorted)
           (coerce (gethash "generateTable" exp) 'string))

    (when verbose
      (format t "~&report table gate: ~a/~a cases match~%"
              (gate-result-passed result) (gate-result-total result))
      (report-failures result))

    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp count))))
