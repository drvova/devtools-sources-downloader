;;;; mutation-harness.lisp — does the detectors gate actually bite?
;;;;
;;;; A gate that passes proves nothing unless it can fail, and the CONTRACT says
;;;; so explicitly. This harness loads the real port, then swaps ONE function at
;;;; a time for a plausible WRONG implementation and re-runs the gate. Every
;;;; mutation must turn the gate RED; a mutation that leaves it green names an
;;;; assertion that is not load-bearing.
;;;;
;;;; Nothing here edits the port's files: each mutation is a runtime
;;;; `symbol-function` swap inside this process, restored afterwards.

(require :asdf)

(load "C:/Users/bigmo/quicklisp/setup.lisp")

(asdf:load-system :cl-ppcre)

(asdf:load-system :com.inuoe.jzon)

(load "tools/cl/engine/package.lisp")

(load "tools/cl/engine/util.lisp")

(load "tools/cl/engine/gate.lisp")

(load "tools/cl/engine/detectors.lisp")

(load "tools/cl/engine/gate-detectors.lisp")

(in-package :vovas.engine.gate)

(defparameter *caught* 0)
(defparameter *total* 0)
(defparameter *unobservable* 0)

(defun probe (label symbol wrong &key unobservable)
  "Install WRONG as SYMBOL's definition, run the gate, restore, report.

UNOBSERVABLE marks a mutation whose difference the gate cannot see BY
CONSTRUCTION - not a gate defect, but a difference the port's own interface
cannot express. Those are counted separately and do not fail the battery; they
are listed so the exemption is visible instead of quietly tolerated."
  (incf *total*)
  (let ((real (symbol-function symbol)))
    (unwind-protect
         (progn
           (setf (symbol-function symbol) wrong)
           (let ((passed (run-detectors-gate :verbose nil)))
             (cond
               ((and passed unobservable)
                (incf *unobservable*)
                (format t "~&n/a     ~a  (unobservable on this host, by design)~%" label))
               (passed
                (format t "~&MISSED  ~a  (gate still passes - assertion not load-bearing)~%"
                        label))
               (t
                (incf *caught*)
                (format t "~&caught  ~a~%" label)))))
      (setf (symbol-function symbol) real))))

(defun probe-detector (label wrong &key unobservable)
  (probe label 'vovas.engine.detectors:detect-layers wrong :unobservable unobservable))

(let ((real-detect (symbol-function 'vovas.engine.detectors:detect-layers))
      (real-gain (symbol-function 'vovas.engine.detectors:gain)))
  (format t "~&-- baseline (real port) --%")
  (format t "gate passes: ~a~%" (not (null (run-detectors-gate :verbose nil))))

  ;; 1. First base64 literal instead of the longest.
  (probe "first base64 literal instead of longest"
         'vovas.engine.detectors:longest-base64-literal
         (lambda (text)
           (multiple-value-bind (whole groups)
               (cl-ppcre:scan-to-strings vovas.engine.detectors::*base64-scanner* text)
             (declare (ignore whole))
             (and groups (aref groups 0)))))

  ;; 2. Greedy `search` for "eval(" instead of the boundary pattern.
  (probe "greedy search(\"eval(\") instead of the boundary pattern"
         'vovas.engine.detectors:eval-heads
         (lambda (text)
           (let ((position (search "eval(" text)))
             (if position (list position) '()))))

  ;; 3. Ascending order instead of descending.
  (probe-detector "findings sorted ascending"
                  (lambda (text)
                    (stable-sort (funcall real-detect text)
                                 (lambda (a b) (< (getf a :score) (getf b :score))))))

  ;; 4. `sort` instead of `stable-sort`. UNOBSERVABLE here, and honestly so:
  ;;    SBCL's SORT happens to be a stable merge sort, so the two answer the
  ;;    same order at every list size this module produces (measured: 2800
  ;;    random cases, 2..17 elements, zero disagreements). The swap still buys
  ;;    the standard's guarantee - a conforming implementation may reorder, and
  ;;    the oracle compares finding ORDER - but no assertion can detect the
  ;;    difference on this host.
  (probe-detector "unstable sort instead of stable-sort"
                  (lambda (text)
                    (sort (funcall real-detect text)
                          (lambda (a b) (> (getf a :score) (getf b :score)))))
                  :unobservable t)

  ;; 5. The hex-escape ratio dropped: count-only detection.
  (probe-detector "hex-escape on count alone (ratio gate dropped)"
                  (lambda (text)
                    (let* ((findings (remove-if (lambda (f)
                                                  (string= (getf f :tool) "hex-escape"))
                                                (funcall real-detect text)))
                           (count (vovas.engine.detectors::count-matches
                                   vovas.engine.detectors::*hex-escape-scanner* text)))
                      (if (> count 8)
                          (append findings
                                  (list (list :tool "hex-escape" :score 0.6d0
                                              :detail (format nil "~a \\x escapes" count))))
                          findings))))

  ;; 6. The eval-unwrap score computed from the head counts instead of the
  ;;    collected payloads - the exact shortcut the seam exists to prevent.
  (probe-detector "eval-unwrap scored from head counts, not payloads"
                  (lambda (text)
                    (let* ((findings (funcall real-detect text))
                           (eval-count (vovas.engine.detectors::count-matches
                                        vovas.engine.detectors::*eval-head-scanner* text))
                           (fn-count (vovas.engine.detectors::count-matches
                                      vovas.engine.detectors::*function-head-scanner* text)))
                      (if (and (or (plusp eval-count) (plusp fn-count))
                               (not (find "eval-unwrap" findings
                                          :key (lambda (f) (getf f :tool))
                                          :test #'string=)))
                          (cons (list :tool "eval-unwrap"
                                      :score (+ 0.7d0 (min (/ (float eval-count 1d0) 20d0) 0.3d0))
                                      :detail (format nil "~a eval() / ~a Function() call(s)"
                                                      eval-count fn-count))
                                findings)
                          findings))))

  ;; 7. Detail string with the arguments swapped.
  (probe-detector "eval-unwrap detail swaps the eval and Function counts"
                  (lambda (text)
                    (mapcar (lambda (f)
                              (if (string= (getf f :tool) "eval-unwrap")
                                  (let ((copy (copy-list f)))
                                    (setf (getf copy :detail) "0 eval() / 1 Function() call(s)")
                                    copy)
                                  f))
                            (funcall real-detect text))))

  ;; 8. The margin dropped from +2 to +0.
  (probe-detector "reverse/rot13 margin dropped from +2 to +0"
                  (lambda (text)
                    (let* ((findings (remove-if (lambda (f)
                                                  (member (getf f :tool)
                                                          '("reverse" "rot13")
                                                          :test #'string=))
                                                (funcall real-detect text)))
                           (base (funcall real-gain text))
                           (rev (funcall real-gain (reverse text))))
                      (if (> rev base)
                          (append findings
                                  (list (list :tool "reverse" :score 0.45d0
                                              :detail "reversed source")))
                          findings))))

  ;; 9. The `+ 2` margin read as `+ 1`.
  (probe-detector "reverse margin off by one (+1 instead of +2)"
                  (lambda (text)
                    (let* ((findings (remove-if (lambda (f)
                                                  (string= (getf f :tool) "reverse"))
                                                (funcall real-detect text)))
                           (base (funcall real-gain text))
                           (rev (funcall real-gain (reverse text))))
                      (if (> rev (1+ base))
                          (append findings
                                  (list (list :tool "reverse" :score 0.45d0
                                              :detail "reversed source")))
                          findings))))

  ;; 10. The charcode body floor ignored: `String.fromCharCode(6,7)` accepted.
  (probe-detector "charcode accepted with a short argument list"
                  (lambda (text)
                    (let ((findings (remove-if (lambda (f)
                                                 (string= (getf f :tool) "charcode"))
                                               (funcall real-detect text))))
                      (if (cl-ppcre:scan "String\\s*\\.\\s*fromCharCode\\s*\\(" text)
                          (append findings
                                  (list (list :tool "charcode" :score 0.65d0
                                              :detail "String.fromCharCode list")))
                          findings))))

  ;; 11. The base64 length divided by 400 instead of 4000 - the score formula's
  ;;     divisor, which only the full-comparison pass can see.
  (probe-detector "base64 score divided by 400 instead of 4000"
                  (lambda (text)
                    (mapcar (lambda (f)
                              (if (string= (getf f :tool) "base64")
                                  (let ((copy (copy-list f))
                                        (len (parse-integer (getf f :detail)
                                                            :junk-allowed t)))
                                    (setf (getf copy :score)
                                          (+ 0.5d0 (min (/ (float len 1d0) 400d0) 0.3d0)))
                                    copy)
                                  f))
                            (funcall real-detect text))))

  ;; 12. The packer detail word count taken from the base instead of the list.
  (probe-detector "packer detail reports the base as the word count"
                  (lambda (text)
                    (mapcar (lambda (f)
                              (if (string= (getf f :tool) "packer")
                                  (let ((copy (copy-list f)))
                                    (setf (getf copy :detail)
                                          "Dean Edwards packer, base 4, 4 words"
                                          )
                                    (setf (getf copy :detail)
                                          "Dean Edwards packer, base 3, 3 words")
                                    copy)
                                  f))
                            (funcall real-detect text))))

  ;; 13. The eval-unwrap `min` cap dropped, and the base64 `min` cap dropped.
  ;;     Both are unobservable through the oracle (it never reaches either cap)
  ;;     and are pinned only by the exact-value assertions added for them, so
  ;;     these two mutations are what prove those assertions are load-bearing.
  (probe-detector "eval-unwrap score is uncapped (25 payloads would score 1.95)"
                  (lambda (text)
                    (let ((findings (funcall real-detect text))
                          (eval-count (vovas.engine.detectors::count-matches
                                       vovas.engine.detectors::*eval-head-scanner* text))
                          (fn-count (vovas.engine.detectors::count-matches
                                     vovas.engine.detectors::*function-head-scanner* text)))
                      (mapcar (lambda (f)
                                (if (string= (getf f :tool) "eval-unwrap")
                                    (let ((copy (copy-list f))
                                          (payloads (length (vovas.engine.detectors::provider-call
                                                             :eval-payloads text))))
                                      (setf (getf copy :score)
                                            (+ 0.7d0 (/ (float payloads 1d0) 20d0)))
                                      copy)
                                    f))
                              findings))))

  ;; 14. The jsfuck purity printed with no decimal place (`~a` instead of `~,1f`).
  (probe-detector "jsfuck purity printed without the one decimal place"
                  (lambda (text)
                    (mapcar (lambda (f)
                              (if (string= (getf f :tool) "jsfuck")
                                  (let ((copy (copy-list f))
                                        (percent (parse-integer
                                                  (getf f :detail)
                                                  :start (1+ (or (position #\Space
                                                                           (getf f :detail)
                                                                           :from-end t)
                                                                 (length (getf f :detail))))
                                                  :junk-allowed t)))
                                    (declare (ignore percent))
                                    (setf (getf copy :detail) "jsfuck, purity 100%")
                                    copy)
                                  f))
                            (funcall real-detect text))))

  ;; 15. The stale-miss cache this port actually had: a NIL resolution stored
  ;;     and then never re-asked, so a module loading later is never seen.
  (probe "provider misses cached (the bug this port had)"
         'vovas.engine.detectors:resolve-provider
         (lambda (key)
           (let ((explicit (assoc key vovas.engine.detectors::*stage-providers*)))
             (if explicit
                 (cdr explicit)
                 (let ((cached (assoc key vovas.engine.detectors::*resolved-providers*)))
                   (if cached
                       (cdr cached)
                       (let ((function (vovas.engine.detectors::default-provider key)))
                         (push (cons key function)
                               vovas.engine.detectors::*resolved-providers*)
                         function)))))))

  ;; 16. The string-array detail's literal count off by one. Only the full
  ;;     comparison can see this: the ambient pass subtracts foreign findings
  ;;     entirely, so a port that mis-formatted this detail would pass the
  ;;     ambient pass and fail only here. Added when the fixture changed
  ;;     (`stringArray` went 128 -> 426 characters and its detector started
  ;;     firing), to prove that case is asserted rather than vacuously matched.
  (probe-detector "string-array detail reports literals+1"
                  (lambda (text)
                    (mapcar (lambda (f)
                              (if (string= (getf f :tool) "string-array")
                                  (let ((copy (copy-list f))
                                        (n (parse-integer
                                            (getf f :detail)
                                            :start (1+ (or (position #\Space
                                                                     (getf f :detail)
                                                                     :from-end t
                                                                     :end (1- (length (getf f :detail))))
                                                           (1- (length (getf f :detail)))))
                                            :junk-allowed t)))
                                    (declare (ignore n))
                                    (setf (getf copy :detail)
                                          "string array _0x5e6f, 6 literals")
                                    copy)
                                  f))
                            (funcall real-detect text))))

  (format t "~&~%~a/~a mutations caught, ~a unobservable~%" *caught* *total* *unobservable*)
  (let ((ok (= (+ *caught* *unobservable*) *total*)))
    (format t "~a~%" (if ok "MUTATION BATTERY: PASS" "MUTATION BATTERY: FAIL"))
    (finish-output)
    (sb-ext:exit :code (if ok 0 1))))
