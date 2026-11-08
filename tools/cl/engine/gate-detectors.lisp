;;;; gate-detectors.lisp — does the layer detector answer what the shipped
;;;; engine answers?
;;;;
;;;; THREE PASSES, and the split is the whole point.
;;;;
;;;; 1. AMBIENT PASS. Every one of the 17 `detectLayers` oracle cases is run
;;;;    through the port as it actually stands. Findings produced by a detector
;;;;    this slice does not own (the eval-payload collector, packer, jsfuck,
;;;;    string-array) are subtracted from BOTH sides and the remainder must
;;;;    match - so what this port owns is proven even while those modules are
;;;;    still being ported, and nothing about the comparison is loosened for the
;;;;    part it does own. Each input that expects a foreign finding is reported
;;;;    by name as a KNOWN GAP.
;;;;
;;;; 2. STUBBED PASS. The four seams are pointed at stubs that answer exactly
;;;;    what the oracle says those detectors answer, and all 17 cases must then
;;;;    match IN FULL - length, order, score and detail string. This is what
;;;;    proves the arithmetic (`0.7 + min(n/20, 0.3)`, `0.5 + min(len/4000,
;;;;    0.3)`), the detail formatting, and the descending stable sort, all of
;;;;    which live in this file and none of which a "subtract the foreign
;;;;    findings" comparison can reach. A stubbed pass is not a faked pass: the
;;;;    stub replaces another module's DETECTOR, never this module's scoring.
;;;;
;;;; 3. STRUCTURAL PROBES. No oracle key exists for `evalHeads`,
;;;;    `functionHeads` or `longestBase64Literal` (they are internal helpers,
;;;;    not bridge exports), so they are pinned by construction, together with
;;;;    a set of PLAUSIBLE WRONG implementations that must NOT be what the port
;;;;    answers. Each wrong implementation is one a careful person writes first:
;;;;    greedy `search` instead of the boundary pattern, first literal instead
;;;;    of longest, count-only instead of count-and-ratio, in-place sort instead
;;;;    of stable, and the threshold read as `>=` instead of `>`.

(in-package :vovas.engine.gate)

;;; ---------------------------------------------------------------------------
;;; Findings and comparison
;;; ---------------------------------------------------------------------------

(defun finding-tool (finding) (getf finding :tool))
(defun finding-score (finding) (getf finding :score))
(defun finding-detail (finding) (getf finding :detail))

(defun finding= (a b)
  "Equal when the wire tool name and the detail are string-identical and the
score is numerically identical.

`equal` on the plists would compare the score with `eql`, which is float TYPE and
value: a score computed as `(+ 0.7d0 0.05d0)` and one parsed from JSON as `0.75`
are the same double, but a port that produced a SINGLE float would fail on type
alone and the report would read like a wrong number."
  (and (string= (finding-tool a) (finding-tool b))
       (= (finding-score a) (finding-score b))
       (string= (finding-detail a) (finding-detail b))))

(defun findings= (got want)
  (and (= (length got) (length want))
       (every #'finding= got want)))

(defun findings->string (findings)
  "One compact line per finding list. The plists print long enough that a
10-finding mismatch is unreadable inside a failure report."
  (if (null findings)
      "[]"
      (format nil "[~{~a~^ | ~}]"
              (mapcar (lambda (f)
                        (format nil "~a ~,4f ~s"
                                (finding-tool f) (finding-score f)
                                (finding-detail f)))
                      findings))))

;;; ---------------------------------------------------------------------------
;;; Calling the port defensively
;;; ---------------------------------------------------------------------------

(defun safe-detect-layers (text)
  "`detect-layers` with a condition turned into a value.

A neighbour's detector signalling inside a seam must not take the gate down with
it: an aborted run prints a Lisp backtrace and no verdict, which reads as \"the
gate is broken\" when the real finding is \"the packer detector threw on input
X\". So an error is captured and compared like any other wrong answer - it can
never equal a finding list, so it fails the case with the condition's text
visible in the report."
  (handler-case (vovas.engine.detectors:detect-layers text)
    (error (condition)
      (format nil "<signalled ~a: ~a>"
              (type-of condition) condition))))

(defun findings->string-or-condition (value)
  (if (stringp value) value (findings->string value)))

(defun safe-tool-names (text)
  "The wire layer names `detect-layers` reports for TEXT, or the captured
condition in place of a list. Every structural probe goes through this, because
a probe on a synthetic input still runs the neighbour detectors - a packer
detector that throws on `\\x41` repeated would otherwise abort the gate."
  (let ((findings (safe-detect-layers text)))
    (if (stringp findings) findings (mapcar #'finding-tool findings))))

(defun findings-score-of (findings tool)
  "TOOL's score in FINDINGS, or NIL. Answers NIL rather than signalling when the
finding is absent, so a missing finding fails the assertion with `want` visible
instead of aborting the run."
  (when (listp findings)
    (let ((finding (find tool findings :key #'finding-tool :test #'string=)))
      (and finding (finding-score finding)))))

(defun findings-detail-of (findings tool)
  (when (listp findings)
    (let ((finding (find tool findings :key #'finding-tool :test #'string=)))
      (and finding (finding-detail finding)))))

;;; ---------------------------------------------------------------------------
;;; Oracle plumbing
;;; ---------------------------------------------------------------------------

(defun detector-sources ()
  "The 17 source texts, straight from the fixture. Never retyped: a hand-copied
input would let the gate drift from the oracle it is checking."
  (let ((inputs (read-json-file (fixture-path "text-tier-inputs.json"))))
    (gethash "sources" inputs)))

(defun detect-layers-expectations ()
  "The oracle's `detectLayers` object: input key -> vector of findings."
  (gethash "detectLayers" (read-json-file (fixture-path "text-tier-oracle.json"))))

(defun json-finding->plist (table)
  "One serialised finding as (:tool string :score double :detail string)."
  (list :tool (gethash "tool" table)
        :score (float (gethash "score" table) 1d0)
        :detail (gethash "detail" table)))

(defun oracle-findings (case)
  "The expectation for CASE as a list of plists, in the oracle's order."
  (map 'list #'json-finding->plist (coerce case 'vector)))

(defun foreign-tools ()
  "The wire names of the layers whose DETECTOR lives in a module this slice
does not own. A finding for one of these can only appear once that module is
loaded, so its absence is a gap and never a mismatch."
  '("eval-unwrap" "packer" "jsfuck" "string-array"))

(defun foreign-findings (findings)
  (let ((foreign (foreign-tools)))
    (remove-if-not (lambda (f) (member (finding-tool f) foreign :test #'string=))
                   findings)))

(defun own-findings (findings)
  "FINDINGS minus every layer whose detector is another module's, whether that
module is loaded or not.

Subtracting by TOOL rather than by missing SEAM is deliberate. If a neighbour's
detector is loaded but disagrees with the oracle, its finding is still not this
port's output - this module only converts the detector's answer into a score and
a detail. Judging the neighbour here would make this gate fail for a bug it
cannot fix, and would hide that bug inside a list of this port's own failures.
The neighbour's divergence is reported separately and loudly by
`classify-foreign-findings` below."
  (let ((foreign (foreign-tools)))
    (remove-if (lambda (f) (member (finding-tool f) foreign :test #'string=))
               findings)))

(defun missing-seam-tools ()
  "The wire names of foreign layers whose seam is currently empty."
  (let ((missing '()))
    (unless (vovas.engine.detectors:resolve-provider :eval-payloads)
      (push "eval-unwrap" missing))
    (unless (vovas.engine.detectors:resolve-provider :packer)
      (push "packer" missing))
    (unless (vovas.engine.detectors:resolve-provider :jsfuck)
      (push "jsfuck" missing))
    (unless (vovas.engine.detectors:resolve-provider :string-array)
      (push "string-array" missing))
    missing))

;;; ---------------------------------------------------------------------------
;;; Fixture answers for the four foreign detectors
;;; ---------------------------------------------------------------------------
;;;
;;; `detect_layers` turns a detector's answer into a score and a detail string,
;;; then sorts. THAT conversion is this module's code and the oracle pins it
;;; exactly - but it cannot be exercised through a seam that is empty, and it
;;; cannot be checked by subtracting the foreign findings from the comparison
;;; either, because subtracting throws away the score, the detail and the
;;; position.
;;;
;;; So the pass below supplies the foreign detectors' ANSWERS as fixtures,
;;; transcribed from the oracle, and then demands the FULL finding list match.
;;; The fixture is input to the scoring, not a detector: it answers per input
;;; key, it never inspects the text, and the numbers it carries (base 4, 4
;;; words, purity 100.0%, `_0x5e6f`, 5 literals) are read straight off the
;;; oracle's detail strings.
;;;
;;; DRIFT GUARD. These values are a COPY of oracle data, and a copy goes stale
;;; silently - the fixtures were regenerated once already while this port was
;;; being written (`bundle` 110 -> 197 chars, `stringArray` 128 -> 426, both
;;; samples replaced). A stale copy would make the full pass assert the OLD
;;; oracle and fail for a reason that looks like a porting bug. So the gate
;;; re-derives every fixture value from the oracle's own detail strings and
;;; fails loudly if this table and the fixture disagree; see
;;; `check-fixture-table-matches-oracle`. The table is then only a convenient
;;; shape adapter, never an independent source of truth.

(defparameter *stage-fixtures*
  '(("evalLayer"   :eval-payloads 1)
    ("packed"      :eval-payloads 1 :packer (:base 4 :words 4))
    ("jsfuck"      :jsfuck (:detected t :purity 1d0))
    ("stringArray" :string-array (:array-id "_0x5e6f" :literals 5)))
  "Per input key, what the foreign detectors answer for that input.

A key absent from this table has no foreign findings, which is the oracle's
answer for 13 of the 17 inputs. Every value here is cross-checked against the
oracle's detail strings by `check-fixture-table-matches-oracle`, so this table
cannot drift from the fixture it mirrors.")

(defun stage-fixture (key field)
  (getf (cdr (assoc key *stage-fixtures* :test #'string=)) field))

(defun fixture-eval-payloads (key)
  "N payloads, since `detect_layers` only reads the count."
  (let ((n (stage-fixture key :eval-payloads)))
    (when n (make-list n :initial-element "payload"))))

(defun fixture-packer (key)
  (let ((spec (stage-fixture key :packer)))
    (when spec
      (list :base (getf spec :base)
            :words (make-list (getf spec :words) :initial-element "w")))))

(defun fixture-jsfuck (key)
  (stage-fixture key :jsfuck))

(defun fixture-string-array (key)
  (stage-fixture key :string-array))

(defparameter *fixture-field->tool*
  '((:eval-payloads . "eval-unwrap")
    (:packer . "packer")
    (:jsfuck . "jsfuck")
    (:string-array . "string-array"))
  "Which wire layer each fixture field answers for, so the coverage assertion
compares like with like instead of re-deriving the mapping.")

(defun fixture-tool-names (key)
  "The wire layer names KEY's fixture provides answers for."
  (loop for (field . rest) on (cdr (assoc key *stage-fixtures* :test #'string=))
        by #'cddr
        collect (cdr (assoc field *fixture-field->tool*))))

(defun with-fixture-seams (key thunk)
  "Call THUNK with all four seams answering CASE KEY's fixture."
  (let ((vovas.engine.detectors::*stage-providers*
          (list (cons :eval-payloads (lambda (text)
                                       (declare (ignore text))
                                       (fixture-eval-payloads key)))
                (cons :packer (lambda (text)
                                (declare (ignore text))
                                (fixture-packer key)))
                (cons :jsfuck (lambda (text)
                                (declare (ignore text))
                                (fixture-jsfuck key)))
                (cons :string-array (lambda (text)
                                      (declare (ignore text))
                                      (fixture-string-array key))))))
    (funcall thunk)))

(defun with-absent-seams (thunk)
  "Call THUNK with all four seams explicitly absent, whatever is installed."
  (let ((vovas.engine.detectors::*stage-providers*
          (list (cons :eval-payloads nil)
                (cons :packer nil)
                (cons :jsfuck nil)
                (cons :string-array nil))))
    (funcall thunk)))

;;; ---------------------------------------------------------------------------
;;; What state is each foreign stage in?
;;; ---------------------------------------------------------------------------
;;;
;;; Three states per foreign layer, and conflating them is how a gate lies:
;;;
;;;   :landed    the module is loaded AND its finding matches the oracle. The
;;;              full comparison must pass - no subtraction, no excuse.
;;;   :absorbed  the module is loaded but answers NIL where the oracle has a
;;;              finding, or answers a DIFFERENT finding. Either way that is a
;;;              bug in the neighbour's detector, not in this port; named
;;;              precisely, excluded from the ambient comparison, and reported.
;;;   :absent    no implementation at all. Named as a known gap.
;;;
;;; The distinction between :absorbed and :absent is made by asking whether the
;;; SEAM has a function behind it, never by a hand-written list of what has
;;; landed, so it cannot go stale as neighbours arrive.

(defun foreign-stage-state (key tool got-foreign want-finding seam-key)
  "Classify one (input, tool) pair."
  (cond
    ((null (vovas.engine.detectors:resolve-provider seam-key)) :absent)
    (t (let ((got-finding (find tool got-foreign
                                :key #'finding-tool :test #'string=)))
         (cond ((null got-finding) :absorbed)
               ((finding= got-finding want-finding) :landed)
               (t :absorbed))))))

(defun tool->seam (tool)
  "Which seam produces TOOL."
  (cdr (assoc tool '(("eval-unwrap" . :eval-payloads)
                     ("packer" . :packer)
                     ("jsfuck" . :jsfuck)
                     ("string-array" . :string-array))
               :test #'string=)))

(defun classify-foreign-findings (sources expectations)
  "An alist of ((input-key tool) . state) for every foreign finding the oracle
expects, classified against what the port currently answers."
  (let ((out '()))
    (loop for key being the hash-keys of expectations using (hash-value case)
          do (let* ((text (gethash key sources))
                    (want (foreign-findings (oracle-findings case)))
                    (got (safe-detect-layers text))
                    (got-foreign (and (listp got) (foreign-findings got))))
               (dolist (want-finding want)
                 (let ((tool (finding-tool want-finding)))
                   (push (cons (list key tool)
                               (handler-case
                                   (foreign-stage-state key tool got-foreign
                                                        want-finding (tool->seam tool))
                                 (error () :absorbed))
                               )
                         out)))))
    (nreverse out)))

(defun foreign-state-summary (classification)
  "Classification grouped by state, for the report."
  (loop for state in '(:landed :absorbed :absent)
        collect (cons state
                      (loop for (pair . s) in classification
                            when (eq s state) collect pair))))

;;; ---------------------------------------------------------------------------
;;; The drift guard
;;; ---------------------------------------------------------------------------
;;;
;;; `*stage-fixtures*` repeats numbers that also live in the oracle's detail
;;; strings. Two copies of a fact is one copy too many, and the second copy is
;;; the one nobody updates. So every number is re-derived from the detail text
;;; and compared: if the fixture is regenerated and this table is not, the gate
;;; says so by name instead of failing the full pass with a confusing mismatch.
;;;
;;; Each parser reads the one phrasing the Rust `format!` produces, which is
;;; also what makes the assertion meaningful - it proves the detail STRING and
;;; the fixture NUMBER agree, not just that two numbers were both typed once.

(defun parse-leading-integer (text)
  "The first run of digits in TEXT, or NIL."
  (let ((start (position-if #'digit-char-p text)))
    (when start
      (let ((end (or (position-if-not #'digit-char-p text :start start)
                     (length text))))
        (parse-integer text :start start :end end)))))

(defun parse-all-integers (text)
  "Every run of digits in TEXT, in order."
  (let ((out '())
        (i 0)
        (n (length text)))
    (loop while (< i n)
          do (if (digit-char-p (char text i))
                 (let ((start i))
                   (loop while (and (< i n) (digit-char-p (char text i)))
                         do (incf i))
                   (push (parse-integer text :start start :end i) out))
                 (incf i)))
    (nreverse out)))

(defun parse-array-id (text)
  "The `_0x...` token in TEXT, or NIL.

The scan starts AFTER the `_0x` prefix: `_` is neither a hex digit nor `x`, so
starting on it would answer the empty string and make every comparison fail
with a blank where an identifier was expected."
  (let ((start (search "_0x" text)))
    (when start
      (let* ((body (+ start 3))
             (end (or (position-if-not (lambda (c) (digit-char-p c 16))
                                       text :start body)
                      (length text))))
        (when (> end body)
          (subseq text start end))))))

(defun parse-purity-percent (text)
  "The percentage in `jsfuck, purity 50.0%` as a fraction, or NIL.

One decimal place is the Rust's `{:.1}`, so 50.0% is 0.5 - parsed as a decimal
number rather than a float so the comparison against the fixture's 0.5d0 is
exact."
  (let ((pct (position #\% text)))
    (when pct
      (let ((start (position-if (lambda (c)
                                  (or (digit-char-p c) (char= c #\.)))
                                text :end pct)))
        (when start
          (/ (read-from-string (subseq text start pct)) 100))))))

(defun check-fixture-table-matches-oracle (result expectations)
  "Assert every value in `*stage-fixtures*` is consistent with the oracle's
detail strings, so a regenerated fixture cannot be compared against a stale
copy of itself.

What is checkable differs per layer, and the honest assertions are not all the
same shape:

  :packer        the detail IS `base N, M words`, so both numbers are compared
                 against the fixture exactly.
  :jsfuck        the detail IS `purity P%`, compared as a fraction.
  :string-array  the detail IS `string array ID, N literals`, so the id and the
                 literal count are both compared.
  :eval-payloads the detail reports eval()/Function() CALL counts, not the
                 payload count, so the payload number is literally not in the
                 oracle. Nothing honest can be cross-checked for this field, so
                 it is deliberately skipped rather than given a fake assertion -
                 the value's real effect is pinned by the score cases in the
                 structural probes instead."
  (dolist (entry *stage-fixtures*)
    (destructuring-bind (key . fields) entry
      (let ((want (oracle-findings (gethash key expectations))))
        (loop for (field value) on fields by #'cddr
              do (let* ((tool (cdr (assoc field *fixture-field->tool*)))
                        (finding (find tool want
                                       :key #'finding-tool :test #'string=)))
                   (unless finding
                     (check result
                            (format nil "fixture ~a names ~a but the oracle has none" key field)
                            key nil t)
                     (loop-finish))
                   (let ((detail (finding-detail finding)))
                     (case field
                       (:eval-payloads
                        ;; Deliberately no assertion: the oracle's detail
                        ;; carries the eval()/Function() call counts, never the
                        ;; payload count, so there is nothing here to compare
                        ;; against without inventing a fact. The value's real
                        ;; effect is pinned by the eval-unwrap score cases.
                        nil)
                       (:packer
                        (let ((numbers (parse-all-integers detail)))
                          (check result
                                 (format nil "fixture ~a/:packer agrees with the oracle detail (~s)" key detail)
                                 detail
                                 (list (getf value :base) (getf value :words))
                                 numbers)))
                       (:jsfuck
                        (check result
                               (format nil "fixture ~a/:jsfuck purity agrees with the oracle detail (~s)" key detail)
                               detail
                               (float (getf value :purity) 1d0)
                               (float (or (parse-purity-percent detail) -1) 1d0)))
                       (:string-array
                        (check result
                               (format nil "fixture ~a/:string-array agrees with the oracle detail (~s)" key detail)
                               detail
                               (list (getf value :array-id)
                                     (format nil "~a literals" (getf value :literals)))
                               (list (or (parse-array-id detail) "")
                                     ;; from the FIRST digit of the count to the
                                     ;; end: "5 literals"
                                     (let ((count-start
                                             (position-if #'digit-char-p detail
                                                          :from-end t
                                                          :end (or (search "literals" detail)
                                                                   (length detail)))))
                                       (if count-start
                                           (subseq detail count-start)
                                           "")))))))))))))

;;; ---------------------------------------------------------------------------
;;; The gate
;;; ---------------------------------------------------------------------------

(defun run-detectors-gate (&key (verbose t))
  "Assert the port against the wasm oracle's `detectLayers` and against the
structural properties no oracle key covers.

Returns T when every assertion holds and the case count is positive. Two extra
values are answered for the report: the list of (input tool) pairs where a
NEIGHBOUR's loaded detector disagrees with the oracle, and the list that has no
implementation at all. Neither is this port's failure, and both are printed."
  (let ((result (make-gate-result))
        (sources (detector-sources))
        (expectations (detect-layers-expectations)))
    ;; ---- pass 1: ambient, own findings only -----------------------------
    ;;
    ;; Subtracted by TOOL, not by missing seam, and the two are not the same
    ;; thing: a neighbour's detector can be loaded and still disagree with the
    ;; oracle. In that case its finding is present but wrong, and this pass still
    ;; judges only what THIS module owns. The disagreement is surfaced by
    ;; `classify-foreign-findings` at the end, with the tool and the input named,
    ;; so it cannot hide.
    (loop for key being the hash-keys of expectations using (hash-value case)
          do (let* ((text (gethash key sources))
                    (want (oracle-findings case))
                    (got (safe-detect-layers text))
                    (got-own (if (listp got) (own-findings got) got))
                    (want-own (own-findings want)))
               (unless text
                 (error "oracle names input ~s but the inputs fixture has no such source"
                        key))
               (record result
                       (and (listp got) (findings= got-own want-own))
                       (format nil "detectLayers/~a (own findings)" key)
                       (format nil "~a chars" (length text))
                       (findings->string-or-condition got-own)
                       (findings->string want-own))))
    (check result "oracle case count is positive"
           "detectLayers"
           (> (hash-table-count expectations) 0)
           t)
    (check result "every oracle case has a source text"
           "detectLayers"
           (hash-table-count expectations)
           (count-if (lambda (key) (gethash key sources))
                     (loop for key being the hash-keys of expectations collect key)))

    ;; ---- pass 1b: the fixture table has not gone stale -------------------
    ;;
    ;; Runs before the full pass so a regenerated fixture is reported as a
    ;; stale TABLE, not as a wrong finding list from this port.
    (check-fixture-table-matches-oracle result expectations)

    ;; ---- pass 2: full comparison, foreign detectors fed their fixture ----
    ;;
    ;; This is the pass that exercises the arithmetic and the sort. Each input
    ;; gets its fixture answers, so the finding list must match the oracle in
    ;; full: same length, same order, same scores, same detail strings.
    (let ((covered '()))
      (loop for key being the hash-keys of expectations using (hash-value case)
            do (let ((want (oracle-findings case)))
                 (dolist (f want) (pushnew (finding-tool f) covered :test #'string=))
                 (with-fixture-seams
                   key
                   (lambda ()
                     (check result
                            (format nil "detectLayers/~a (full, foreign detectors from fixture)"
                                    key)
                            key
                            (safe-detect-layers (gethash key sources))
                            want)))))
      ;; The pass is only meaningful if it actually reaches the foreign layers;
      ;; otherwise it is 17 comparisons of empty lists.
      ;;
      ;; NOTE WHAT THIS ASSERTS, because it is itself a fact about the oracle:
      ;; across all 17 inputs the oracle's `detectLayers` names ONLY the four
      ;; foreign layers (eval-unwrap, packer, jsfuck, string-array). None of the
      ;; self-contained detectors - base64, hex-escape, unescape, charcode,
      ;; reverse, rot13 - ever fires on the fixture corpus, so the oracle gives
      ;; them no coverage at all and the structural probes below are their only
      ;; proof. Asserting equality with the whole vocabulary would be asserting
      ;; something false.
      (check result "the full pass reaches every foreign layer the oracle names"
             "tool coverage"
             (sort (copy-seq covered) #'string<)
             (sort (copy-list (foreign-tools)) #'string<))
      ;; ... and the fixtures themselves must be derived from the oracle, not
      ;; invented: every foreign finding in the oracle has a fixture entry.
      (let ((unfixtured '()))
        (loop for key being the hash-keys of expectations using (hash-value case)
              do (dolist (f (foreign-findings (oracle-findings case)))
                   (unless (member (finding-tool f) (fixture-tool-names key)
                                   :test #'string=)
                     (push (list key (finding-tool f)) unfixtured))))
        (check result "every foreign oracle finding has a fixture entry"
               "fixture coverage"
               (nreverse unfixtured)
               nil)))

    ;; ---- pass 3: structural probes for the keyless helpers ---------------
    (let ((eval-text (gethash "evalLayer" sources))
          (fn-text (gethash "functionLayer" sources))
          (b64-text (gethash "base64" sources))
          (plain-text (gethash "plain" sources))
          (empty-text (gethash "empty" sources)))
      (check result "eval-heads finds a head in evalLayer"
             "evalLayer"
             (plusp (length (vovas.engine.detectors:eval-heads eval-text)))
             t)
      (check result "eval-heads answers the eval at index 0 of evalLayer"
             "evalLayer"
             (vovas.engine.detectors:eval-heads eval-text)
             '(0))
      (check result "eval-heads is empty on functionLayer"
             "functionLayer"
             (vovas.engine.detectors:eval-heads fn-text)
             nil)
      (check result "eval-heads is empty on empty input"
             "empty"
             (vovas.engine.detectors:eval-heads empty-text)
             nil)
      (check result "function-heads finds a head in functionLayer"
             "functionLayer"
             (plusp (length (vovas.engine.detectors:function-heads fn-text)))
             t)
      (check result "function-heads spans `new Function(` in functionLayer"
             "functionLayer"
             (vovas.engine.detectors:function-heads fn-text)
             ;; "var f = new Function(" - the boundary space at 7 through the
             ;; `(` at 20, end exclusive.
             '((7 . 21)))
      (check result "function-heads is empty on evalLayer"
             "evalLayer"
             (vovas.engine.detectors:function-heads eval-text)
             nil)

      ;; The `base64` fixture's literal is 36 characters, BELOW the 40-character
      ;; floor in the pattern, and the oracle agrees nothing is detected
      ;; (`detectLayers/base64` is []). So "finds the long literal in `base64`"
      ;; is not what the shipped engine does - recorded here as a disagreement
      ;; with the brief rather than bent into a passing shape.
      (check result "longest-base64-literal answers NIL on the 36-char base64 fixture"
             "base64"
             (vovas.engine.detectors:longest-base64-literal b64-text)
             nil)
      (check result "longest-base64-literal answers NIL on plain text"
             "plain"
             (vovas.engine.detectors:longest-base64-literal plain-text)
             nil)
      (let ((long (make-string 44 :initial-element #\A)))
        (check result "longest-base64-literal finds a 44-char literal"
               "44 A's in a double-quoted string"
               (vovas.engine.detectors:longest-base64-literal
                (format nil "var payload = \"~a\";" long))
               long))

      ;; rot13 is its own inverse on a mixed-case sample and leaves non-letters
      ;; alone.
      (let* ((sample "Hello, World! 123 Café")
             (once (vovas.engine.detectors:rot13 sample)))
        (check result "rot13 rotates upper and lower case"
               sample once "Uryyb, Jbeyq! 123 Pnsé")
        (check result "rot13 is its own inverse"
               sample (vovas.engine.detectors:rot13 once) sample)))

    ;; ---- plausible wrong implementations --------------------------------
    ;; (1) greedy search instead of the boundary pattern.
    (check result "WRONG-IMPL: `myeval(` is not an eval head"
           "myeval(1)"
           (vovas.engine.detectors:eval-heads "myeval(1)")
           nil)
    (check result "WRONG-IMPL: `obj.eval(` is not an eval head"
           "obj.eval(1)"
           (vovas.engine.detectors:eval-heads "obj.eval(1)")
           nil)
    (check result "WRONG-IMPL: a lowercase `function` is not a Function head"
           "function(){ return 1 }"
           (vovas.engine.detectors:function-heads "function(){ return 1 }")
           nil)
    (check result "`Function(` without `new` IS a head"
           "Function(\"a\", \"return a\")"
           (vovas.engine.detectors:function-heads "Function(\"a\", \"return a\")")
           ;; the match starts at 0 with no boundary character consumed;
           ;; `Function` is 8 characters, then `(` -> end exclusive at 9.
           '((0 . 9)))
    ;; (2) first literal instead of the longest.
    (let* ((short (make-string 40 :initial-element #\b))
           (long (make-string 60 :initial-element #\c)))
      (check result "WRONG-IMPL: the LONGEST base64 literal wins, not the first"
             "40 b's then 60 c's"
             (vovas.engine.detectors:longest-base64-literal
              (format nil "x = \"~a\"; y = \"~a\";" short long))
             long))
    ;; (3) count-only hex escapes: 9 of them inside a 336-character text are
    ;; ordinary content, because the ratio gate is part of the detector.
    (let ((dilute (format nil "~{~a~}~a"
                          (loop repeat 9 collect "\\x41")
                          (make-string 300 :initial-element #\a))))
      (check result "WRONG-IMPL: 9 \\x escapes in a 336-char text are NOT hex-escape"
             "ratio below 15%"
             (safe-tool-names dilute)
             nil))
    (let ((dense (format nil "~{~a~}" (loop repeat 9 collect "\\x41"))))
      (check result "9 \\x escapes in a 36-char text ARE hex-escape"
             "ratio above 15%"
             (safe-tool-names dense)
             '("hex-escape")))
    ;; (4) the thresholds are `>` 8, not `>= 8`, and the charcode body floor.
    (let ((eight (format nil "~{~a~}" (loop repeat 8 collect "%u0041"))))
      (check result "WRONG-IMPL: 8 %uXXXX escapes are below the threshold"
             "8 escapes"
             (safe-tool-names eight)
             nil))
    (let ((nine (format nil "~{~a~}" (loop repeat 9 collect "%u0041"))))
      (check result "9 %uXXXX escapes are unescape"
             "9 escapes"
             (safe-tool-names nine)
             '("unescape")))
    (check result "WRONG-IMPL: a 3-character fromCharCode body is not a payload"
           "String.fromCharCode(6,7)"
           (safe-tool-names "String.fromCharCode(6,7)")
           nil)
    (check result "a 14-character fromCharCode body is a charcode layer"
           "String.fromCharCode(65,66,67,68,69)"
           (safe-tool-names "String.fromCharCode(65,66,67,68,69)")
           '("charcode"))
    ;; (5) descending order. charcode scores 0.65 and a 100-char base64 literal
    ;; scores 0.525, so an implementation that returned push order (base64
    ;; first) or ascending order fails here.
    (let* ((literal (make-string 100 :initial-element #\A))
           (text (format nil "var a = \"~a\"; eval(String.fromCharCode(65,66,67,68,69));"
                         literal)))
      (check result "WRONG-IMPL: findings come out by descending score"
             "charcode + base64"
             (safe-tool-names text)
             '("charcode" "base64")))
    ;; (5c) The base64 SCORE AND DETAIL exactly. The oracle corpus contains no
    ;; base64 finding at all - its only candidate literal is 36 characters,
    ;; below the 40-character floor - so nothing in `detectLayers` pins this
    ;; formula, and a port that divided by 400 instead of 4000 would pass every
    ;; oracle case. These two assertions are the whole proof of it: one below
    ;; the 0.3 cap and one above it, since the `min` is the second half of the
    ;; formula.
    (let ((literal (make-string 100 :initial-element #\A)))
      (check result "base64 score is 0.5 + len/4000 below the cap"
             "100-char literal"
             (safe-detect-layers (format nil "x = \"~a\";" literal))
             (list (list :tool "base64" :score 0.525d0 :detail "100 char literal"))))
    (let ((literal (make-string 4000 :initial-element #\A)))
      (check result "base64 score is capped at 0.8"
             "4000-char literal"
             (safe-detect-layers (format nil "x = \"~a\";" literal))
             (list (list :tool "base64" :score 0.8d0 :detail "4000 char literal"))))
    ;; (6) the `+ 2` margin: one recovered keyword is not evidence of a layer.
    (check result "a plain function is not reported as reverse or rot13"
           "function f() { return 1; }"
           (safe-tool-names "function f() { return 1; }")
           nil)
    ;; (6b) POSITIVE coverage for reverse and rot13. Without these the margin
    ;; is only ever asserted from the negative side, and a port that never
    ;; fired them at all would still pass - so these cases, not the negative
    ;; ones, are what prove the two detectors work.
    ;;
    ;; `(rot13 "function a(){ return null }")` decodes to three keywords and
    ;; carries none itself, so it clears the margin by three.
    (check result "a rot13-encoded function IS reported as rot13"
           "shapgvba n(){ erghea ahyy }"
           (safe-tool-names
            (vovas.engine.detectors:rot13 "function a(){ return null }"))
           '("rot13"))
    (check result "a reversed function IS reported as reverse"
           "reversed source"
           (safe-tool-names (reverse "function a(){ return null }"))
           '("reverse"))
    ;; ... and the margin is STRICTLY greater than two: a text that decodes to
    ;; exactly two keywords is still ordinary source, not a layer. This is the
    ;; assertion an off-by-one (`+ 1`) fails and nothing else does.
    (check result "WRONG-IMPL: improving by exactly 2 keywords is NOT a rot13 layer"
           "erghea ahyy (decodes to `return null`)"
           (safe-tool-names (vovas.engine.detectors:rot13 "return null"))
           nil)
    (check result "WRONG-IMPL: improving by exactly 2 keywords is NOT a reverse layer"
           "llun nruter (reversed `return null`)"
           (safe-tool-names (reverse "return null"))
           nil)
    ;; (5b) EQUAL scores keep their push order: hex-escape is pushed before
    ;; unescape and both score 0.6, so the answer is the push order, not the
    ;; reverse. This is the only case in the whole gate where a sort is
    ;; observably order-sensitive at equal keys, and it is part of what a
    ;; `stable-sort` buys. Written through the documented API, so it survives
    ;; any rewrite of the internals.
    (let ((both (format nil "~{~a~}~{~a~}"
                        (loop repeat 9 collect "\\x41")
                        (loop repeat 9 collect "%u0041"))))
      (check result "equal-scoring findings keep push order (hex-escape before unescape)"
             "9 \\x41 then 9 %u0041"
             (safe-tool-names both)
             '("hex-escape" "unescape")))
    ;; (5b) EQUAL scores keep their push order: hex-escape is pushed before
    ;; unescape and both score 0.6, so the answer is the push order, not the
    ;; reverse. This is the only case in the whole gate where a sort is
    ;; observably order-sensitive at equal keys, and it is what a `stable-sort`
    ;; buys. Written through the documented API, so it survives any rewrite of
    ;; the internals.
    (let ((both (format nil "~{~a~}~{~a~}"
                        (loop repeat 9 collect "\\x41")
                        (loop repeat 9 collect "%u0041"))))
      (check result "equal-scoring findings keep push order (hex-escape before unescape)"
             "9 \\x41 then 9 %u0041"
             (mapcar #'finding-tool (safe-detect-layers both))
             '("hex-escape" "unescape")))
    ;; (7) rot13 must not shift digits or non-ASCII letters.
    (check result "WRONG-IMPL: rot13 leaves digits and non-ASCII alone"
           "0123456789 é ü"
           (vovas.engine.detectors:rot13 "0123456789 é ü")
           "0123456789 é ü")
    ;; (8) the trailing space in `var `/`let `/`const ` is load-bearing.
    (check result "WRONG-IMPL: `variable` does not count as a keyword"
           "variable"
           (vovas.engine.detectors:gain "variable")
           0)
    (check result "`var ` with its trailing space does count"
           "var x"
           (vovas.engine.detectors:gain "var x")
           1)
    ;; (9) the seam must gate the finding, not the head counts. With every seam
    ;; absent, a text whose only layer would be eval-unwrap must report nothing:
    ;; an implementation that scored from the head counts alone would claim a
    ;; payload it never collected, and would break the oracle's `functionLayer`
    ;; case, which has a Function() head and no finding.
    (with-absent-seams
      (lambda ()
        (check result "evalLayer reports no eval-unwrap while its seam is absent"
               "evalLayer, seams absent"
               (mapcar #'finding-tool
                       (vovas.engine.detectors:detect-layers
                        (gethash "evalLayer" sources)))
               nil)
        (check result "functionLayer reports nothing while its seam is absent"
               "functionLayer, seams absent"
               (vovas.engine.detectors:detect-layers
                (gethash "functionLayer" sources))
               nil)))
    ;; ... and a seam that answers reproduces the oracle's score, detail and
    ;; position - which is what makes the gap above a GAP and not a wrong answer.
    (with-fixture-seams
      "evalLayer"
      (lambda ()
        (check result "a fixture-fed eval-payloads seam reproduces the oracle finding"
               "evalLayer + fixture seam"
               (safe-detect-layers (gethash "evalLayer" sources))
               (list (list :tool "eval-unwrap" :score 0.75d0
                           :detail "1 eval() / 0 Function() call(s)")))))
    ;; (9b) The eval-unwrap formula's two halves. The oracle pins ONE payload
    ;; count (1, giving 0.7 + 1/20 = 0.75) and never reaches the 0.3 cap, so a
    ;; port that dropped the `min` or divided by the wrong denominator would
    ;; still match every oracle case. Six payloads is 0.7 + 6/20 = 1.0, which
    ;; the cap holds at 1.0; twenty-five is 0.7 + 1.25, capped hard at 1.0.
    (dolist (case '((1 . 0.75d0) (6 . 1.0d0) (25 . 1.0d0)))
      (let* ((count (car case))
             (want (cdr case))
             (providers
               (list (cons :eval-payloads
                           (lambda (text)
                             (declare (ignore text))
                             (make-list count :initial-element "p")))
                     (cons :packer (lambda (text) (declare (ignore text)) nil))
                     (cons :jsfuck (lambda (text) (declare (ignore text)) nil))
                     (cons :string-array (lambda (text) (declare (ignore text)) nil))))
             (vovas.engine.detectors::*stage-providers* providers))
        (check result
               (format nil "eval-unwrap score for ~a payload(s) is ~,4f" count want)
               (format nil "~a payloads" count)
               (findings-score-of (safe-detect-layers "eval(1)") "eval-unwrap")
               want)))
    ;; (9c) The jsfuck detail format string, `purity {:.1}%` - the Rust prints
    ;; one decimal place, so 0.5 is "50.0%" and 0.123 is "12.3%". The oracle
    ;; only ever exercises purity 1.0, where a format bug is invisible.
    (dolist (case '((0.5d0 . "jsfuck, purity 50.0%")
                    (0.123d0 . "jsfuck, purity 12.3%")
                    (1d0 . "jsfuck, purity 100.0%")))
      (let* ((purity (car case))
             (want (cdr case))
             (providers
               (list (cons :eval-payloads (lambda (text) (declare (ignore text)) nil))
                     (cons :packer (lambda (text) (declare (ignore text)) nil))
                     (cons :jsfuck (lambda (text)
                                     (declare (ignore text))
                                     (list :detected t :purity purity)))
                     (cons :string-array (lambda (text) (declare (ignore text)) nil))))
             (vovas.engine.detectors::*stage-providers* providers))
        (check result
               (format nil "jsfuck detail for purity ~a" purity)
               (format nil "purity ~a" purity)
               (findings-detail-of (safe-detect-layers "x") "jsfuck")
               want)))
    ;; (9d) A MISS must not be cached. The parallel slices load in any order, so
    ;; this system can legitimately resolve `:packer` to NIL before
    ;; `vovas-engine.packers` exists. If that NIL were cached, the packer layer
    ;; would stay dead for the life of the image and the symptom would look like
    ;; a wrong detector rather than a stale cache - which is exactly the bug this
    ;; port had. Simulated by resolving a key with no implementation, then
    ;; installing one and resolving again.
    (let ((key :gate-probe-seam))
      (push (cons key (list "VOVAS.ENGINE.NO-SUCH-PACKAGE" "NOT-THERE"))
            vovas.engine.detectors::*provider-sources*)
      (setf vovas.engine.detectors::*resolved-providers*
            (remove key vovas.engine.detectors::*resolved-providers* :key #'car))
      (let ((first (vovas.engine.detectors:resolve-provider key)))
        ;; Now make it resolvable by defining the package and the function.
        (unless (find-package "VOVAS.ENGINE.NO-SUCH-PACKAGE")
          (make-package "VOVAS.ENGINE.NO-SUCH-PACKAGE" :use '()))
        (intern "NOT-THERE" "VOVAS.ENGINE.NO-SUCH-PACKAGE")
        (setf (symbol-function (intern "NOT-THERE" "VOVAS.ENGINE.NO-SUCH-PACKAGE"))
              (lambda (text) (declare (ignore text)) :ok))
        (let ((second (vovas.engine.detectors:resolve-provider key)))
          (check result "WRONG-IMPL: a failed provider lookup is not cached"
                 "absent then present"
                 (list (null first) (and second (funcall second "x")))
                 '(t :ok)))
        ;; Clean up so nothing else in the run sees a synthetic seam.
        (setf vovas.engine.detectors::*provider-sources*
              (remove key vovas.engine.detectors::*provider-sources* :key #'car))
        (setf vovas.engine.detectors::*resolved-providers*
              (remove key vovas.engine.detectors::*resolved-providers* :key #'car))
        (delete-package "VOVAS.ENGINE.NO-SUCH-PACKAGE")))

    ;; (10) a provider answering the wrong SHAPE must signal, not be coerced: a
    ;; silently mis-read provider would score a plausible number for the wrong
    ;; text, which is the failure mode no oracle case can catch.
    (let ((vovas.engine.detectors::*stage-providers*
            (list (cons :packer (lambda (text) (declare (ignore text)) 42)))))
      (check result "WRONG-IMPL: a malformed packer answer signals instead of scoring"
             "packer provider answering 42"
             (handler-case (progn (vovas.engine.detectors:detect-layers "x") :no-error)
               (error () :signalled))
             :signalled))

    ;; ---- foreign-stage status, classified from the actual answers --------
    (let* ((classification (classify-foreign-findings sources expectations))
           (by-state (foreign-state-summary classification))
           (absent (cdr (assoc :absent by-state)))
           (absorbed (cdr (assoc :absorbed by-state))))
      ;; Every foreign finding the oracle expects is accounted for in exactly
      ;; one bucket. A pair in NO bucket would mean the classifier silently
      ;; dropped it, and the report below would then understate the gaps.
      (check result "every foreign oracle finding is classified"
             "foreign coverage"
             (length classification)
             (loop for key being the hash-keys of expectations
                   sum (length (foreign-findings
                                (oracle-findings (gethash key expectations))))))
      (when verbose
        (format t "~&detectors gate: ~a/~a cases match~%"
                (gate-result-passed result) (gate-result-total result))
        (report-failures result)
        (format t "~&~%  FOREIGN STAGE STATUS (detectors owned by other modules):~%")
        (dolist (state '(:landed :absorbed :absent))
          (let ((pairs (cdr (assoc state by-state))))
            (format t "    ~a: ~:[none~;~{~{~a/~a~}~^, ~}~]~%"
                    (string-upcase (string state))
                    pairs
                    (mapcar (lambda (p) (list (first p) (second p))) pairs))))
        (when absorbed
          (format t "~%  NEIGHBOUR BUG (detector loaded, answer disagrees with the oracle):~%")
          (dolist (pair absorbed)
            (destructuring-bind (key tool) pair
              (format t "    ~a: ~a - the other module's detector, not this port~%"
                      key tool))))
        (when absent
          (format t "~%  KNOWN GAPS (no implementation available yet):~%")
          (dolist (pair absent)
            (destructuring-bind (key tool) pair
              (format t "    ~a expects ~a~%" key tool)))))
      ;; A neighbour's disagreement is a real defect someone must fix, and this
      ;; gate is where it gets named. It is not this port's failure, so it does
      ;; not fail the gate - but it is never silent either.
      (values (= (gate-result-passed result) (gate-result-total result))
              (plusp (gate-result-total result))
              absorbed
              absent))))
