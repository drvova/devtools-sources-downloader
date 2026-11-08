;;;; mutation-jsfuck.lisp — prove the JSFuck gate can FAIL.
;;;;
;;;; A gate that agrees with the oracle proves the port agrees. It does NOT prove
;;;; the gate would notice if the port stopped agreeing, and a green run over a
;;;; gate that cannot fail is the most expensive kind of green.
;;;;
;;;; Each argument selects one PLAUSIBLE-BUT-WRONG implementation, installs it
;;;; over the port in the live image, and then runs the gate. The expected result
;;;; is a FAILURE for every mutation; a mutation the gate accepts is a hole in the
;;;; gate, not a curiosity.
;;;;
;;;; Run:  sbcl --script tools/cl/engine/wip/mutation-jsfuck.lisp m1
;;;; Exit: 0 when the gate correctly refused the mutant, 1 when it did not.
;;;;
;;;; THIS FILE MUST LIVE INSIDE THE CHECKOUT. `gate::repo-root` walks up from
;;;; `*load-truename*` looking for `unpack-rs/` and `tools/`, so a copy under
;;;; %TEMP% dies with "no checkout root above C:/tmp/" before touching a
;;;; mutation. That failure reads like a broken gate and is a misplaced file.

(require :asdf)

(load "C:/Users/bigmo/quicklisp/setup.lisp")

(asdf:load-asd (truename "tools/cl/vovas-engine.asd"))

(asdf:load-system :vovas-engine)

(asdf:load-asd (truename "tools/cl/engine/jsfuck.asd"))

(asdf:load-system :vovas-engine.jsfuck)

(defun apply-mutation (which)
  "Install mutation WHICH over the port. Each arm is a mistake the Rust's shape
invites, so none is hypothetical."
  (cond
    ;; M1. The vacuous decode that text-tier-oracle.json blessed: the null
    ;;     constant. It answers correctly for every refusal case and wrongly for
    ;;     all sixteen captures, so it is the exact implementation this fixture
    ;;     exists to catch.
    ((string= which "m1")
     (setf (symbol-function 'vovas.engine.jsfuck:decode-jsfuck)
           (lambda (source)
             (declare (ignore source))
             (list :value nil :captured nil))))

    ;; M2. Capture at EVERY seam, ignoring the quoted-return branch:
    ;;     `return "hi"` should answer the value "hi", not a capture.
    ((string= which "m2")
     (setf (symbol-function 'vovas.engine.jsfuck::call-from-source)
           (lambda (ip body)
             (setf (vovas.engine.jsfuck::interp-capture ip) body
                   (vovas.engine.jsfuck::interp-captured-p ip) t)
             (vovas.engine.jsfuck::make-undefined))))

    ;; M3. Purity counts ALL whitespace, not just spaces. This flips the one-tab
    ;;     case from 94.7% (refused) to 100% (detected).
    ((string= which "m3")
     (let ((original (symbol-function 'vovas.engine.jsfuck:detect-jsfuck)))
       (setf (symbol-function 'vovas.engine.jsfuck:detect-jsfuck)
             (lambda (source)
               (let ((result (funcall original source)))
                 (when (search "purity" (getf result :reason))
                   (setf (getf result :purity) 1d0
                         (getf result :reason) ""
                         (getf result :detected) t))
                 result)))))

    ;; M4. The chain threshold as >= 4096 instead of > 4096, so a chain of
    ;;     exactly 4096 is refused.
    ((string= which "m4")
     (setf vovas.engine.jsfuck::*detect-max-chain* 4095))

    ;; M5. `at` excludes index 0 — the bug this port actually shipped for one
    ;;     round, which collapsed every character lookup to undefined.
    ((string= which "m5")
     (let ((original (symbol-function 'vovas.engine.jsfuck::invoke-native)))
       (setf (symbol-function 'vovas.engine.jsfuck::invoke-native)
             (lambda (ip callee args receiver)
               (if (and (string= (vovas.engine.jsfuck::jv-value callee) "at")
                        args
                        (zerop (vovas.engine.jsfuck::jv-to-number (car args))))
                   (vovas.engine.jsfuck::make-undefined)
                   (funcall original ip callee args receiver))))))

    ;; M6. An empty capture collapsed into "no capture" — the NIL/flag
    ;;     conflation that two fixture cases exist to separate.
    ((string= which "m6")
     (let ((original (symbol-function 'vovas.engine.jsfuck:decode-jsfuck)))
       (setf (symbol-function 'vovas.engine.jsfuck:decode-jsfuck)
             (lambda (source)
               (let ((result (funcall original source)))
                 (if (and (getf result :captured)
                          (equal (getf result :value) ""))
                     (list :value nil :captured nil)
                     result))))))

    ;; M7. "too short" reports the MEASURED purity instead of 0.0.
    ((string= which "m7")
     (let ((original (symbol-function 'vovas.engine.jsfuck:detect-jsfuck)))
       (setf (symbol-function 'vovas.engine.jsfuck:detect-jsfuck)
             (lambda (source)
               (let ((result (funcall original source)))
                 (when (string= (getf result :reason) "too short")
                   (setf (getf result :purity) 1d0))
                 result)))))

    (t (error "unknown mutation ~s" which))))

(let ((which (second sb-ext:*posix-argv*)))
  (apply-mutation which)
  (format t "~&mutant ~a applied~%" which)
  (let ((ok (vovas.engine.gate::run-jsfuck-gate :verbose nil)))
    (format t "MUTANT ~a GATE ~a~%" which (if ok "PASSED (HOLE IN THE GATE)" "failed (correct)"))
    (sb-ext:exit :code (if ok 1 0))))
