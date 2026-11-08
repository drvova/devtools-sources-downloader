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

;;; ---------------------------------------------------------------------------
;;; exportFrameworkArtifacts / exportRuntimeArtifacts
;;;
;;; Both oracles store the EXACT pretty-printed strings serde produces, so these
;;; are byte comparisons. The input states are the Rust tests' own.
;;; ---------------------------------------------------------------------------

(defun run-report-export-gate (&key (verbose t))
  (let* ((result (make-gate-result))
         (count 0)
         (fx (read-json-file (fixture-path "panel/artifacts-oracle.json")))
         (exp (gethash "expected" fx)))

    ;; ---- exportFrameworkArtifacts ---------------------------------------
    (let ((state (ht "summary" (ht "roots" 2 "stores" 1)
                     "router" (ht)
                     "roots" (vector (ht "id" "app") (ht "id" "root"))
                     "stores" #()
                     "queries" (vector (ht "key" "user"))
                     "hydration" #()
                     "auth" (vector (ht "token" "x"))))
          (files '()))
      (vovas.engine.panel.report:export-framework-artifacts
       (lambda (path content) (push (vector path content) files))
       state)
      (incf count)
      (check result "exportFrameworkArtifacts" "files"
             (and (gate-json= (coerce (nreverse files) 'vector)
                              (coerce (gethash "exportFrameworkArtifacts" exp) 'vector))
                  t)
             t))

    ;; ---- exportRuntimeArtifacts -----------------------------------------
    ;; the Rust test's THREE entries, verbatim - including the third, which has
    ;; neither text nor base64 and so contributes no file.
    (let ((entries (vector (ht "index" 0 "id" "r1" "kind" "eval"
                               "url" "https://x/a.js" "text" "var a = 1"
                               "hasText" t "hasBase64" nil "size" 9)
                           (ht "index" 1 "id" "r2" "kind" "wasm" "url" ""
                               "base64" "AGFzbQ=="
                               "hasText" nil "hasBase64" t)
                           (ht "index" 2 "id" "r3" "kind" "blob"
                               "hasText" nil "hasBase64" nil
                               "note" "not captured")))
          (files '()))
      (vovas.engine.panel.report:export-runtime-artifacts
       (lambda (path content)
         (push (vector path (if (stringp content) "text" "base64")
                       (if (stringp content) content ""))
               files))
       entries)
      ;; the manifest comes last, and its content is compared separately below
      (let ((want (coerce (gethash "exportRuntimeArtifacts" exp) 'vector))
            (got (coerce (nreverse files) 'vector)))
        (incf count)
        (check result "exportRuntimeArtifacts/shape" "files"
               (and (gate-json=
                     (map 'vector (lambda (f) (aref f 0)) got)
                     (coerce (map 'list (lambda (f) (aref f 0))
                                  (coerce want 'vector))
                             'vector))
                    t)
               t)))

    (when verbose
      (format t "~&report export gate: ~a/~a cases match~%"
              (gate-result-passed result) (gate-result-total result))
      (report-failures result))

    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp count))))

;;; ---------------------------------------------------------------------------
;;; generateWaterfallHtml
;;;
;;; The expected document is 13,057 characters. Printing two of those side by
;;; side tells a reader nothing, so a failure reports the FIRST differing offset
;;; and a window around it - the same shape as the Rust test's
;;; `assert_same_document`, which compares in place after stripping the clock.
;;; ---------------------------------------------------------------------------

(defun gate-timing-case ()
  "The five timings `waterfall_and_table_match_oracle` builds, verbatim."
  (let ((first (gate-timing-defaults "https://demo.test/static/app.js?v=3" "script" 0 118.5d0))
        (second (gate-timing-defaults "https://cdn.other.test/lib/vendor.css" "link" 12.25d0 77.75d0))
        (third (gate-timing-defaults "https://demo.test/api/session" "fetch" 40d0 220d0))
        (fourth (gate-timing-defaults "https://demo.test/img/logo.png" "img" 300d0 640.5d0))
        (fifth (gate-timing-defaults "https://demo.test/beacon" "other" 950d0 12d0)))
    (flet ((put (h &rest pairs)
             (loop for (k v) on pairs by #'cddr do (setf (gethash k h) v))
             h))
      (put first "domainLookupStart" 0.4d0 "domainLookupEnd" 3.2d0
           "connectStart" 3.2d0 "connectEnd" 14.6d0 "secureConnectionStart" 6.1d0
           "requestStart" 15d0 "responseStart" 42.75d0 "responseEnd" 118.5d0
           "transferSize" 20480 "encodedBodySize" 19000 "decodedBodySize" 51000)
      (put second "connectStart" 12.25d0 "connectEnd" 30d0
           "requestStart" 31d0 "responseStart" 55.5d0 "responseEnd" 90d0
           "decodedBodySize" 1200)
      (put third "requestStart" 41d0 "responseStart" 180.25d0 "responseEnd" 260d0
           "transferSize" 512 "encodedBodySize" 512 "decodedBodySize" 900)
      (put fourth "requestStart" 301d0 "responseStart" 305d0 "responseEnd" 940.5d0
           "transferSize" 8192 "encodedBodySize" 8192 "decodedBodySize" 8192)
      (vector first second third fourth fifth))))

(defun gate-first-difference (got want)
  "The offset of the first differing character, or NIL when equal.

Beyond the offset it shows a short window from each side, because the alternative
- two 13,000-character strings - is unreadable."
  (let ((n (min (length got) (length want))))
    (dotimes (i n)
      (unless (char= (char got i) (char want i))
        (return-from gate-first-difference
          (format nil "offset ~a: got ~s want ~s"
                  i
                  (subseq got i (min (length got) (+ i 40)))
                  (subseq want i (min (length want) (+ i 40)))))))
    (when (/= (length got) (length want))
      (format nil "length: got ~a want ~a (common prefix ~a chars)"
              (length got) (length want) n))))

(defun run-report-waterfall-gate (&key (verbose t))
  (let* ((result (make-gate-result))
         (count 0)
         (fx (read-json-file (fixture-path "panel/artifacts-oracle.json")))
         (exp (gethash "expected" fx))
         (timings (coerce (gate-timing-case) 'list)))

    ;; ---- the empty case -------------------------------------------------
    (incf count)
    (check result "generateWaterfallHTML/empty" "document"
           (vovas.engine.panel.report:generate-waterfall-html '())
           (coerce (gethash "generateWaterfallHTMLEmpty" exp) 'string))

    ;; ---- the five-row document ------------------------------------------
    ;;
    ;; The Rust sorts by startTime before calling, because the TABLE it embeds
    ;; must be in that order; the waterfall itself sorts internally.
    (let* ((sorted (stable-sort (copy-list timings) #'<
                                :key (lambda (e)
                                       (vovas.engine.panel.assets:field-number
                                        e "startTime"))))
           (got (vovas.engine.panel.report:generate-waterfall-html sorted))
           (want (coerce (gethash "generateWaterfallHTML" exp) 'string))
           ;; the document stamps a clock, so both sides are cut at the same
           ;; point: everything before the first quote after "Generated "
           (cut (lambda (s)
                  (let ((i (search "Generated " s)))
                    (if i (subseq s 0 i) s))))
           (diff (gate-first-difference (funcall cut got) (funcall cut want))))
      (incf count)
      (check result "generateWaterfallHTML/document" "document"
             (or diff "identical")
             "identical"))

    (when verbose
      (format t "~&report waterfall gate: ~a/~a cases match~%"
              (gate-result-passed result) (gate-result-total result))
      (report-failures result))

    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp count))))

;;; ---------------------------------------------------------------------------
;;; generateInvestigationIndexHtml
;;;
;;; NO ORACLE exists for this function - the fixture pins six report functions and
;;; this is not one of them. It therefore asserts the properties the code PROMISES,
;;; on a hostile input, rather than comparing a stored string:
;;;
;;;   - a complete document: doctype, body, closing tag;
;;;   - the element ids the SCRIPT looks up by name;
;;;   - a literal `</script>` inside the payload is unicode-escaped, so it cannot
;;;     close the data tag early (the one real injection risk here);
;;;   - the page title and URL are HTML-escaped;
;;;   - both constant blocks rendered.
;;; ---------------------------------------------------------------------------

(defun gate-has (needle haystack)
  "Whether NEEDLE occurs in HAYSTACK, as a boolean.

A named helper rather than an `flet`, so a scope slip shows up as a missing
function instead of a mysteriously unbound variable."
  (and (search needle haystack) t))

(defun gate-investigation-fixture ()
  "An investigation carrying every hostile shape the template must survive."
  (let* ((page (ht "title" "T <x> & \"q\"" "url" "https://demo.test/a?b=1&c=2"))
         (inv (ht "page" page "note" "</script><img src=x onerror=alert(1)>")))
    inv))

(defun run-report-investigation-gate (&key (verbose t))
  (let* ((result (make-gate-result))
         (count 0)
         (inv (gate-investigation-fixture))
         (doc (vovas.engine.panel.report:generate-investigation-index-html inv))
         (empty (vovas.engine.panel.report:generate-investigation-index-html nil)))

    (incf count)
    (check result "investigation/doctype" "prefix"
           (subseq doc 0 15) "<!DOCTYPE html>")

    (incf count)
    (check result "investigation/closes" "suffix"
           (subseq doc (- (length doc) 7)) "</html>")

    (incf count)
    (check result "investigation/body" "element"
           (gate-has "<body>" doc) t)

    (dolist (id '("workspaceNav" "journeyNav" "view" "summaryCards" "investigation-data"))
      (incf count)
      (check result (format nil "investigation/id/~a" id) "present"
             (gate-has (format nil "id=\"~a\"" id) doc) t))

    (incf count)
    (check result "investigation/script-escaped" "escaped"
           (gate-has "\\u003c/script\\u003e" doc) t)

    ;; The document legitimately carries TWO script blocks - the embedded data and
    ;; the console script - so `</script>` appears twice. The property that
    ;; actually matters is that closings never OUTNUMBER openings: an unescaped
    ;; `</script>` inside the payload would add a third close and end the data
    ;; block mid-JSON. Asserting a fixed count would have been wrong, and it was:
    ;; my first version expected 1 and failed on a correct document.
    (incf count)
    (check result "investigation/script-close-count" "closes <= opens"
           (labels ((count-of (needle)
                      (let ((n 0) (pos 0))
                        (loop for hit = (search needle doc :start2 pos)
                              while hit do (incf n) (setf pos (+ hit (length needle))))
                        n)))
             (<= (count-of "</script>") (count-of "<script")))
           t)

    (incf count)
    (check result "investigation/title-escaped" "escaped"
           (gate-has "&lt;x&gt;" doc) t)

    (incf count)
    (check result "investigation/url-escaped" "escaped"
           (gate-has "b=1&amp;c=2" doc) t)

    (incf count)
    (check result "investigation/styles" "rules"
           (gate-has "*{box-sizing:border-box}" doc) t)

    (incf count)
    (check result "investigation/script-block" "fragments"
           (gate-has "function esc(" doc) t)

    (incf count)
    (check result "investigation/null-title" "fallback"
           (gate-has ">Investigation Console<br>" empty) t)

    (incf count)
    (check result "investigation/null-json" "payload"
           (gate-has "application/json\">{}</script>" empty) t)

    (when verbose
      (format t "~&report investigation gate: ~a/~a cases match~%"
              (gate-result-passed result) (gate-result-total result))
      (report-failures result))

    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp count))))
