;;;; mutation-jscbytecode.lisp — prove the gate has teeth.
;;;;
;;;; The gate passing proves the port agrees with the sidecars. This proves the
;;;; gate would NOTICE if the port were wrong: for each of four plausible
;;;; misreadings it rebinds the port's own function to the wrong version, reruns
;;;; the gate, and requires the verdict to flip to FAIL. A gate that survives a
;;;; broken port is a gate that asserts nothing.
;;;;
;;;; Usage: sbcl --script tools/cl/engine/wip/mutation-jscbytecode.lisp

(require :asdf)
(load "C:/Users/bigmo/quicklisp/setup.lisp")
(asdf:load-asd (truename "tools/cl/vovas-engine.asd"))
(asdf:load-asd (truename "tools/cl/engine/jscbytecode.asd"))
(asdf:load-system :vovas-engine.jscbytecode)

(defun quiet-run ()
  "True when the gate passes. A SIGNAL counts as a failure, not as a crash: a
mutated port routinely raises (an out-of-bounds slot, a type error), and letting
that unwind would abort the whole probe run and take the remaining probes with
it. Treated here as the gate refusing the mutant, which is exactly right."
  (handler-case
      (let ((*standard-output* (make-broadcast-stream)))
        (and (vovas.engine.gate::run-jscbytecode-gate :verbose nil) t))
    (error () nil)))

(defun report-mutation (label baseline caught)
  "CAUGHT is `(not gate-result)` for the mutated port — true means the gate
refused the mutant. The gate's own verdict is therefore its negation, and
printing CAUGHT as if it were the verdict inverted every line of the first run
of this file: eight correct catches read as eight weak probes."
  (format t "~&~a~%  baseline:   ~a~%  mutant gate: ~a~%  ~a~%"
          label
          (if baseline "PASS" "FAIL")
          (if caught "FAIL (rejected)" "PASS (accepted)")
          (cond ((not baseline) "UNUSABLE - baseline must pass")
                (caught "OK - the gate caught it")
                (t "WEAK - the gate accepted a broken port"))))

(let ((baseline (quiet-run))
      (results '()))
  (push (cons "gate passes an unmodified port" baseline) results)

  ;; 1. THE HEADER GUARD AS AN AND. The obvious reading of
  ;;    `format != 1 && declared != len` is "both must agree", which rejects
  ;;    every Program payload.
  ;;    every Program payload.
  (let ((original (symbol-function 'vovas.engine.jscbytecode::parse-jsc-header)))
    (unwind-protect
         (progn
           (setf (symbol-function 'vovas.engine.jscbytecode::parse-jsc-header)
                 (lambda (bytes)
                   (when (>= (length bytes) 32)
                     (let ((format-word (vovas.engine.jscbytecode::ub32 bytes 4))
                           (declared (vovas.engine.jscbytecode::ub32 bytes 12)))
                       ;; THE AND. Both must agree — the obvious reading, and
                       ;; wrong: it drops every Program payload (format word 0).
                       (when (and (= format-word 1) (= declared (length bytes)))
                         (list :stamp (vovas.engine.jscbytecode::ub32 bytes 0)
                               :format format-word
                               :version (vovas.engine.jscbytecode::ub32 bytes 8)
                               :declared-length declared
                               :body-offset (vovas.engine.jscbytecode::ub32 bytes 16)))))))
           (push (cons "header guard as an AND (drops Program payloads)"
                       (not (quiet-run)))
                 results))
      (setf (symbol-function 'vovas.engine.jscbytecode::parse-jsc-header) original)))

  ;; 2. THE DENSE SHARED TABLE. The JS original's push-shifted reading, which
  ;;    is what this port documents a divergence from.
  (let ((original (symbol-function 'vovas.engine.jscbytecode::read-jsc-shared-table)))
    (unwind-protect
         (progn
           (setf (symbol-function 'vovas.engine.jscbytecode::read-jsc-shared-table)
                 (lambda (bytes offset length)
                   (let ((read (funcall original bytes offset length)))
                     (when (getf read :strings)
                       (let ((dense '()))
                         (loop for slot across (getf read :strings)
                               when slot do (push slot dense))
                         (setf (getf read :strings)
                               (coerce (nreverse dense) 'vector))))
                     read)))
           (push (cons "dense shared table (names shift down past a hole)"
                       (not (quiet-run)))
                 results))
      (setf (symbol-function 'vovas.engine.jscbytecode::read-jsc-shared-table)
            original)))

  ;; 3. THE MASKED MULTIPLY-FOLD. Masking the product before the high-half
  ;;    shift is the mistake the Rust comments warn about, and it mirrors every
  ;;    hash.
  (let ((original (symbol-function 'vovas.engine.jscbytecode::rapid-mix)))
    (unwind-protect
         (progn
           (setf (symbol-function 'vovas.engine.jscbytecode::rapid-mix)
                 (lambda (first second)
                   (let* ((product (logand (* (logand first #xFFFFFFFFFFFFFFFF)
                                              (logand second #xFFFFFFFFFFFFFFFF))
                                           #xFFFFFFFFFFFFFFFF)))
                     (logxor product (ash product -64)))))
           (push (cons "masked multiply-fold (high half folded to zero)"
                       (not (quiet-run)))
                 results))
      (setf (symbol-function 'vovas.engine.jscbytecode::rapid-mix) original)))

  ;; 4. THE WIDTH FLAG AT BIT 27. Carry the string scanner's `0x08000000` /
  ;;    `0x07FFFFFF` pair into the shared-table reader, where the flag is bit 31.
  (let ((original (symbol-function 'vovas.engine.jscbytecode::read-jsc-shared-table)))
    (unwind-protect
         (progn
           (setf (symbol-function 'vovas.engine.jscbytecode::read-jsc-shared-table)
                 (lambda (bytes offset length)
                   (let ((real (funcall original bytes offset length)))
                     (setf (getf real :resolved)
                           (or (vovas.engine.gate::width-bit-27-table bytes offset length)
                               0))
                     real)))
           (push (cons "shared table reads the width flag at bit 27"
                       (not (quiet-run)))
                 results))
      (setf (symbol-function 'vovas.engine.jscbytecode::read-jsc-shared-table)
            original)))

  ;; 5. OP COUNT FROM THE REVERSED LIST. The bug that actually happened during
  ;;    this port: `(values (nreverse names) (length names))` answers 1.
  (let ((original (symbol-function 'vovas.engine.jscbytecode::walk-jsc-ops)))
    (unwind-protect
         (progn
           (setf (symbol-function 'vovas.engine.jscbytecode::walk-jsc-ops)
                 (lambda (bytes start length table)
                   (multiple-value-bind (ops count)
                       (funcall original bytes start length table)
                     (declare (ignore count))
                     (values ops (if ops 1 0)))))
           (push (cons "op count taken after the destructive nreverse"
                       (not (quiet-run)))
                 results))
      (setf (symbol-function 'vovas.engine.jscbytecode::walk-jsc-ops) original)))

  ;; 6. TERMINAL OP SET NARROWED so `ret` is no longer terminal. The fixtures
  ;;    do not otherwise reach this: every candidate either fails the `enter`
  ;;    test or lands short of the declared end. So this mutation targets the
  ;;    structural half of the gate — the assertions that pin the terminal set
  ;;    against the real stream, which is the only thing that can notice.
  (let ((original (symbol-function 'vovas.engine.jscbytecode:is-terminal-op)))
    (unwind-protect
         (progn
           (setf (symbol-function 'vovas.engine.jscbytecode:is-terminal-op)
                 (lambda (name) (declare (ignore name)) nil))
           (push (cons "terminal set emptied (`ret` no longer terminal)"
                       (not (quiet-run)))
                 results))
      (setf (symbol-function 'vovas.engine.jscbytecode:is-terminal-op) original)))

  ;; 7. THE `enter` GATE DROPPED. Opening on `enter` is what stops a plausible
  ;;    offset from binding a stream that starts mid-instruction.
  (let ((original (symbol-function 'vovas.engine.jscbytecode::jsc-enter-opcode)))
    (unwind-protect
         (progn
           (setf (symbol-function 'vovas.engine.jscbytecode::jsc-enter-opcode)
                 (lambda (&optional table) (declare (ignore table)) nil))
           (push (cons "no `enter` opcode (every block rejected)"
                       (not (quiet-run)))
                 results))
      (setf (symbol-function 'vovas.engine.jscbytecode::jsc-enter-opcode) original)))

  ;; 8. THE 24-BIT HASH MASK DROPPED. The stored field is 24 bits; returning
  ;;    the full fold makes every comparison miss.
  (let ((original (symbol-function 'vovas.engine.jscbytecode:wtf-string-hash)))
    (unwind-protect
         (progn
           (setf (symbol-function 'vovas.engine.jscbytecode:wtf-string-hash)
                 (lambda (bytes) (logior (funcall original bytes) #x1000000)))
           (push (cons "hash not masked to 24 bits"
                       (not (quiet-run)))
                 results))
      (setf (symbol-function 'vovas.engine.jscbytecode:wtf-string-hash) original)))

  ;; NOT PROBED HERE: the LIFO walk order. It is already pinned by ORACLE — the
  ;; `kind` field of every entry in `jsc-cjs-functions-resolved.json` is the
  ;; visit order, so a FIFO walk fails the whole-tree comparison outright. There
  ;; is no need for a synthetic mutant, and a fake one that simply signalled
  ;; would prove nothing.

  (format t "~&~%== mutation probes ==~%")
  (dolist (entry (reverse results))
    (report-mutation (car entry) baseline (cdr entry)))
  (let ((all-caught (every #'cdr results)))
    (format t "~&mutation gate: ~a~%"
            (if all-caught "every wrong implementation caught" "SOME PROBES WEAK"))
    (finish-output)
    (sb-ext:exit :code (if all-caught 0 1))))
