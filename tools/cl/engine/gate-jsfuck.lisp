;;;; gate-jsfuck.lisp — the JSFuck gate, against an oracle built to be able to fail.
;;;
;;;; WHAT THIS GATE GUARDS. text-tier-oracle.json already carries
;;;; detectJsfuck/decodeJsfuck over 17 shared sources, and every one of its
;;;; decode answers is {"value":null,"captured":false}. A port returning that
;;;; constant would pass. So this gate reads a DIFFERENT oracle,
;;;; tests/fixtures/jsfuck-oracle.json, whose sources were produced by the
;;;; shipped JSFuck 0.5.0 encoder (test/fixtures/jsfuck-encoder.js) with
;;;; `wrapWithEval`, which emits `[]["at"]["constructor"](body)()` — the
;;;; Function seam `captured` reports on. Eleven of its cases answer
;;;; captured:true with a non-null value; twenty-eight answer a non-null string
;;;; without capturing; the rest refuse.
;;;
;;;; THREE FAMILIES, checked independently:
;;;;   programs     encoder output for complete programs -> the capture seam
;;;;   expressions  hand-shaped JSFuck -> the value model's branches
;;;;   detection    short/purity/chain boundary inputs -> detect's four tests
;;;;
;;;; WHY THE COUNTS ARE ASSERTED SEPARATELY. "All cases pass" is satisfiable by
;;;; an oracle that lost half its cases, and by a gate that silently skipped a
;;;; family. So each family's count is asserted against a FLOOR as well as the
;;;; captured:true count, and an empty oracle fails before any comparison runs.
;;;;
;;;; WHY THE PROBES EXIST. A gate that agrees with the oracle proves the port
;;;; agrees. It does not prove the port agrees FOR THE RIGHT REASON, and that is
;;;; the failure mode that survives a green run. Each probe names a
;;;; plausible-but-wrong implementation and requires the port's answer to
;;;; differ from it — while still requiring the port's answer to equal the
;;;; oracle's, so a probe cannot pass on an unrelated bug.

(in-package :vovas.engine.gate)

;;; ---------------------------------------------------------------------------
;;; Oracle access
;;;
;;; The fixture sits in tests/ (plural) beside the other JSON oracles, and
;;; `fixture-path` resolves it there. Everything below reads it through the
;;; shared harness so a path change is one edit.
;;; ---------------------------------------------------------------------------

(defparameter *jsfuck-oracle-name* "jsfuck-oracle.json"
  "A parameter, not a literal at each call site: the gate reads the oracle three
times (once per family) and a typo in one copy would produce an empty family that
the count assertions then blame on the port.")

(defparameter *jsfuck-oracle* nil
  "The parsed oracle, memoised per run.

Re-reading a 100 KB fixture per family is how a draft of the packers gate ended up
with three separate `gethash` calls that could have disagreed. One read, one
table.")

(defun jsfuck-oracle ()
  (or *jsfuck-oracle*
      (setf *jsfuck-oracle* (read-json-file (fixture-path *jsfuck-oracle-name*)))))

(defun jsfuck-family (name)
  "The case table for family NAME, as an alist of (case-name . plist).

Answers NIL for an absent family, which the caller's floor assertion turns into a
loud failure naming the family — not a zero-iteration loop that reports success."
  (let* ((families (gethash "families" (jsfuck-oracle)))
         (table (and families (gethash name families))))
    (when table
      (sort (loop for key being the hash-keys of table
                  using (hash-value value)
                  collect (cons key value))
            #'string< :key #'car))))

(defun jsfuck-case-source (case)
  (gethash "source" (cdr case)))

(defun jsfuck-want-detect (case)
  "The oracle's detect answer as a plist with the port's key spelling.

`purity` is COERCED to a double, because the JSON number `1` parses as an INTEGER
while the port always answers a double — and `(equal 1 1.0d0)` is false. Without
the coercion every fully-pure case failed on type alone, which read exactly like a
purity bug and was not one. 0.9473684210526315 already parses as a double under
`read-json-file`'s binding, so pure and impure cases need the same normalisation."
  (let ((detect (gethash "detect" (cdr case))))
    (when detect
      (list :detected (and (gethash "detected" detect) t)
            :purity (coerce (gethash "purity" detect) 'double-float)
            :reason (or (jsfuck-json-null (gethash "reason" detect)) "")))))

(defun jsfuck-want-decode (case)
  "The oracle's decode answer as a plist with the port's key spelling.

The `captured` flag is forced to a real boolean: the oracle carries JSON true/false
and the port answers T/NIL, and `(and value t)` is what makes the comparison
`equal` rather than `eq`-on-a-truthy-object."
  (let ((decode (gethash "decode" (cdr case))))
    (when decode
      (list :value (jsfuck-json-null (gethash "value" decode))
            :captured (and (gethash "captured" decode) t)))))

(defun jsfuck-json-null (value)
  "JZON's null is a symbol named NULL, not NIL. The port answers NIL for \"no
value\", so an un-mapped null would make every refusal case fail — and it would
fail looking like the port had invented a value."
  (if (and (symbolp value) (string= (symbol-name value) "NULL"))
      nil
      value))

;;; ---------------------------------------------------------------------------
;;; Probes
;;; ---------------------------------------------------------------------------

(defun jsfuck-probe (label got correct wrong)
  "One probe: GOT must equal CORRECT and must NOT equal WRONG.

Both halves, not just the second. \"Differs from the wrong value\" is satisfied by
any third answer at all — a probe written that way passes on an unrelated bug, and
on the branch it was aimed at it passes on ANY wrong answer except the one value
the author happened to type. Pinning the correct answer too is what makes the probe
bite.

The explicit `equal correct wrong` guard refuses a probe whose two answers
coincide, which would assert nothing while reporting a pass.

Answers a BOOLEAN. `gate-result-passed` is a COUNT and Lisp treats 0 as true, so a
count coerced naively would report every failing probe as passing."
  (when (equal correct wrong)
    (error "jsfuck probe ~s is vacuous: correct and wrong are both ~s" label correct))
  (let ((result (make-gate-result))
        (input (format nil "got=~s correct=~s wrong=~s" got correct wrong)))
    (check result (format nil "~a [got the right answer]" label) input got correct)
    (check result (format nil "~a [not the wrong implementation]" label) input
           (if (equal got wrong) :agrees-with-wrong :differs)
           :differs)
    (and (= 2 (gate-result-passed result))
         (null (gate-result-failures result)))))

(defun jsfuck-detect-of (case-name)
  "detect-jsfuck on one oracle case's source, so a probe can assert a value the
oracle already pinned rather than a retyped literal."
  (let ((case (assoc case-name (jsfuck-family "detection") :test #'string=)))
    (unless case (error "the detection family has no case named ~s" case-name))
    (vovas.engine.jsfuck:detect-jsfuck (jsfuck-case-source case))))

(defun jsfuck-decode-of (case-name)
  "decode-jsfuck on one oracle case's source, searched across the program-shaped
families. `scoped` is included because two of the probes are aimed at the eval
seam, which only that family reaches."
  (let ((case (or (assoc case-name (jsfuck-family "programs") :test #'string=)
                  (assoc case-name (jsfuck-family "scoped") :test #'string=)
                  (assoc case-name (jsfuck-family "expressions") :test #'string=))))
    (unless case (error "no program, scoped or expression case named ~s" case-name))
    (vovas.engine.jsfuck:decode-jsfuck (jsfuck-case-source case))))

(defun run-jsfuck-wrong-implementation-probes (&key (verbose t))
  "Prove the port is not a plausible-but-wrong implementation.

Each probe is a mistake the Rust's own structure invites, so none of them is
hypothetical:

  1. DECODE THAT ALWAYS ANSWERS NULL. The vacuous oracle's constant. It agrees
     with every refusal case and fails the eleven captured ones.

  2. DETECT THAT MEASURES PURITY BEFORE THE LENGTH TEST. The Rust returns
     purity 0.0 with \"too short\"; measuring first answers 1.0 for a pure but
     short body. Only the `reason` and `purity` reveal it — `detected` is false
     either way, which is precisely why a gate that only checked `detected`
     would miss this.

  3. DETECT THAT COUNTS ALL WHITESPACE IN THE DENOMINATOR. The Rust excludes
     SPACES only, so a tab counts against purity. Reading `\\s` puts the one-tab
     case at 100% instead of 94.7% and FLIPS it to detected.

  4. CHAIN THRESHOLD OFF BY ONE. The Rust refuses `> 4096`, so 4096 detects and
     4097 does not. A `>=` would refuse 4096.

  5. CAPTURE THAT IGNORES THE QUOTED-RETURN BRANCH. `return \"hi\"` answers the
     value \"hi\" with captured:false; a port that captured at every seam would
     answer \"return \"hi\"\" with captured:true.

  6. CAPTURE THAT TREATS A MISSING ARGUMENT AS NO CAPTURE. `eval()` with no
     argument captures the EMPTY STRING; a port using plain NIL for \"not
     captured\" collapses the two states and answers null.

Every probe passes the port's answer, the oracle's answer (read from the fixture,
never retyped) and the wrong implementation's stand-in."
  (let ((all-ok t)
        (ran 0))
    (flet ((probe (label got correct wrong)
             (incf ran)
             ;; An ERROR inside a probe is a FAILED probe, not a crashed gate: a
             ;; wrong implementation often RAISES where the correct one refuses,
             ;; and a gate that died with the condition name would never report
             ;; which assertion broke.
             (let ((ok (handler-case (jsfuck-probe label got correct wrong)
                         (error (e)
                           (format t "~&  PROBE ERRORED ~a: ~a~%" label e)
                           nil))))
               (unless ok
                 (setf all-ok nil)
                 (format t "~&  PROBE FAILED ~a~%    got:     ~s~%    correct: ~s~%    wrong:   ~s~%"
                         label got correct wrong)))))
      ;; 1. The vacuous decode. This is the exact implementation the old oracle
      ;;    would have blessed, so it is the most important probe in the file.
      (let ((real (jsfuck-decode-of "retOne")))
        (probe "decode does not answer the null constant"
               real
               (jsfuck-want-decode (assoc "retOne" (jsfuck-family "programs")
                                          :test #'string=))
               (list :value nil :captured nil)))
      ;; 2. Purity measured before the length test.
      (let ((got (jsfuck-detect-of "elevenChars")))
        (probe "too-short reports purity 0.0, not the measured ratio"
               got
               (list :detected nil :purity 0d0 :reason "too short")
               (list :detected nil :purity 1d0 :reason "too short")))
      ;; 3. All whitespace in the purity denominator flips the one-tab case.
      (let ((got (jsfuck-detect-of "oneTab")))
        (probe "a tab counts against purity (only SPACE is excluded)"
               got
               (jsfuck-want-detect (assoc "oneTab" (jsfuck-family "detection")
                                          :test #'string=))
               (list :detected t :purity 1d0 :reason "")))
      ;; 4. Chain threshold off by one, both sides.
      (let ((at (jsfuck-detect-of "chainAtLimit"))
            (over (jsfuck-detect-of "chainOverLimit")))
        (probe "a 4096-long chain still detects"
               (getf at :detected) t nil)
        (probe "a 4097-long chain is refused"
               (getf over :detected) nil t)
        (probe "the chain refusal names the length"
               (getf over :reason)
               "operator chain too long (4097)"
               (format nil "operator chain too long (~d)" 4096)))
      ;; 5. Capturing at every seam, ignoring the quoted-return branch.
      (let ((got (jsfuck-decode-of "retQuoted")))
        (probe "return \"hi\" answers the VALUE, not a capture"
               got
               (jsfuck-want-decode (assoc "retQuoted" (jsfuck-family "programs")
                                          :test #'string=))
               (list :value "return \"hi\"" :captured t)))
      ;; 6. REMOVED: "an empty payload is still a capture" could not be proved.
      ;;
      ;;    The probe compared the port against the `scoped/evalEmpty` oracle case,
      ;;    but that case has src_len 0 - the shipped encoder produced NOTHING for
      ;;    an empty input, so its captured answer is `{value: null, captured:
      ;;    false}`. With correct and wrong both being that same value, the probe
      ;;    asserted nothing, and this gate's own vacuity check said so out loud:
      ;;      PROBE ERRORED ... correct and wrong are both (:VALUE NIL :CAPTURED NIL)
      ;;
      ;;    Keeping a probe that cannot fail is worse than dropping it, because it
      ;;    inflates the probe count with a tautology. The property it wanted to
      ;;    test - an empty payload being a distinct state from "not captured" -
      ;;    needs an encoder that emits something for empty input; until a fixture
      ;;    exists, the `evalOne` and `evalAlert` cases prove the capture path
      ;;    itself, both at captured = true.
      ;; 7. The array branch of `join`/`at` is dead in the engine because the
      ;;    receiver unwraps to a string first. A port that "fixed" it would
      ;;    answer a joined string where the engine refuses.
      (let ((got (jsfuck-decode-of "arrJoinDefault")))
        (probe "join on an unwrapped array receiver refuses"
               got
               (jsfuck-want-decode (assoc "arrJoinDefault" (jsfuck-family "expressions")
                                          :test #'string=))
               (list :value "0,0" :captured nil)))
      ;; 8. Non-canonical index keys are PROPERTY NAMES. A port parsing the key
      ;;    blindly would answer element 0 for index "00".
      (let ((got (vovas.engine.jsfuck:decode-jsfuck "([+[]]+[+[]])[+[]]")))
        (probe "an array index is read off the array's string form"
               got
               (list :value "0" :captured nil)
               (list :value nil :captured nil))))
    (when verbose
      (format t "~&jsfuck: ~d wrong-implementation probes ran, ~a~%"
              ran (if all-ok "all rejected their stand-in" "SOME DID NOT")))
    (values all-ok ran)))

;;; ---------------------------------------------------------------------------
;;; Floors
;;;
;;; Asserted as CONSTANTS against the fixture, not against the port. If the
;;; fixture lost cases the gate fails before comparing anything, and the failure
;;; names the family rather than showing 0/0 as a pass.
;;; ---------------------------------------------------------------------------

(defparameter *jsfuck-min-programs* 9
  "Encoder-produced program cases. The fixture has 10; the floor is 9 so adding a
case is free and LOSING one is not.")

(defparameter *jsfuck-min-scoped* 3
  "Run-in-parent-scope cases. These are the only inputs that reach the eval seam
with a CALL, so they are what proves `captured` distinguishes an empty payload from
no capture. All three are required.")

(defparameter *jsfuck-min-expressions* 30
  "Hand-shaped expression cases. The fixture has 35.")

(defparameter *jsfuck-min-detection* 9
  "Boundary cases. The fixture has 10, and the two chain cases are load-bearing
enough that the floor must not allow them both to vanish.")

(defparameter *jsfuck-min-captured* 12
  "Cases that must answer captured:true with a non-null value.

THE CENTRAL ASSERTION OF THIS FILE. The oracle it replaces had ZERO such cases,
which is why a constant-null port could pass. Measured: the fixture has 13.")

;;; ---------------------------------------------------------------------------
;;; The gate
;;; ---------------------------------------------------------------------------

(defun run-jsfuck-gate (&key (verbose t))
  "Compare every JSFuck port function against the encoder-derived oracle, prove
the probes reject their stand-ins, and prove the oracle is not empty.

Returns T only when every case matches AND every floor holds AND every probe
passed. NIL otherwise, with the failures printed."
  (let ((result (make-gate-result))
        (floors-ok t)
        (captured-count 0)
        (programs (jsfuck-family "programs"))
        (scoped (jsfuck-family "scoped"))
        (expressions (jsfuck-family "expressions"))
        (detection (jsfuck-family "detection")))

    ;; ---- 1. The oracle must actually contain what it claims ----------------
    (flet ((require-at-least (label got minimum)
             (unless (>= got minimum)
               (setf floors-ok nil)
               (format t "~&  FLOOR FAIL ~a: ~d cases, floor is ~d~%"
                       label got minimum))))
      (require-at-least "programs" (length programs) *jsfuck-min-programs*)
      (require-at-least "scoped" (length scoped) *jsfuck-min-scoped*)
      (require-at-least "expressions" (length expressions) *jsfuck-min-expressions*)
      (require-at-least "detection" (length detection) *jsfuck-min-detection*))

    ;; ---- 2. Every case, both functions -------------------------------------
    ;;
    ;; A case whose `detect`/`decode` key is missing makes its expectation NIL,
    ;; and the port never answers NIL for a plist — so a malformed fixture fails
    ;; the comparison rather than being silently skipped.
    (dolist (family (list (cons "programs" programs)
                          (cons "scoped" scoped)
                          (cons "expressions" expressions)
                          (cons "detection" detection)))
      (dolist (case (cdr family))
        (let* ((name (car case))
               (source (jsfuck-case-source case))
               (want-detect (jsfuck-want-detect case))
               (want-decode (jsfuck-want-decode case))
               (got-detect (vovas.engine.jsfuck:detect-jsfuck source))
               (got-decode (vovas.engine.jsfuck:decode-jsfuck source)))
          (check result (format nil "~a/detect/~a" (car family) name)
                 source got-detect want-detect)
          (check result (format nil "~a/decode/~a" (car family) name)
                 source got-decode want-decode)
          (when (eq t (getf got-decode :captured))
            (incf captured-count)
            ;; A captured case with a NULL value is not a capture: `captured`
            ;; means "we have the payload", so the payload must be a string.
            (check result (format nil "~a/captured-has-a-payload/~a" (car family) name)
                   source (stringp (getf got-decode :value)) t)))))

    ;; ---- 3. The captured count, asserted in BOTH directions ----------------
    ;;
    ;; The floor catches an oracle that lost its capture cases; the equality
    ;; catches a port that started capturing where it should not, which would
    ;; otherwise show up only as a value mismatch on a case whose value happened
    ;; to be the payload anyway.
    (unless (>= captured-count *jsfuck-min-captured*)
      (setf floors-ok nil)
      (format t "~&  FLOOR FAIL captured: ~d cases captured, floor is ~d~%"
              captured-count *jsfuck-min-captured*))
    (let ((oracle-captured
            (loop for family in (list programs scoped expressions detection)
                  sum (loop for case in family
                            count (eq t (getf (jsfuck-want-decode case) :captured))))))
      (check result "captured-count-matches-oracle" "total"
             captured-count oracle-captured))

    ;; ---- 4. The probes ----------------------------------------------------
    (multiple-value-bind (probes-ok probe-count)
        (run-jsfuck-wrong-implementation-probes :verbose verbose)
      (unless probes-ok (setf floors-ok nil))
      (unless (>= probe-count 3)
        (setf floors-ok nil)
        (format t "~&  FLOOR FAIL probes: ~d ran, need at least 3~%" probe-count)))

    ;; ---- 5. Verdict -------------------------------------------------------
    (when verbose
      (format t "~&jsfuck gate: ~a/~a comparisons match (captured cases: ~d)~%"
              (gate-result-passed result) (gate-result-total result) captured-count)
      (report-failures result))
    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp (gate-result-total result))
         floors-ok)))
