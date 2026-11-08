;;;; gate-packers.lisp — the packer tier's gate, against the wasm oracle.
;;;;
;;;; Four oracle keys drive it: `detectPacker`, `unpackPacker`,
;;;; `detectStringArray`, `transformStringArray`, over the SAME 17 input texts
;;;; the rest of the text tier uses. The inputs come from
;;;; text-tier-inputs.json rather than being retyped here, so the gate cannot
;;;; drift from the oracle it checks.
;;;;
;;;; Two things this gate does that a plain comparison would not:
;;;;
;;;;   1. It asserts the shipped-engine cases EXPLICITLY, by the values the
;;;;      oracle records, not merely "differs from nil". A port that answered a
;;;;      plausible-but-wrong struct would still pass a null/non-null check.
;;;;   2. It runs eight wrong-implementation probes. A gate that only agrees with
;;;;      the oracle proves the port agrees; it does not prove the port agrees
;;;;      for the right reason, and that is the failure mode that survives a
;;;;      green run.
;;;;
;;;; JSON SHAPES. JZON parses an object to a hash-table with string keys, an
;;;; array to a vector, and `null` to its own symbol. The port answers plists
;;;; with keyword keys. The adapters below do that translation ONCE, in the
;;;; gate, so a port that answered hash-tables or alists would FAIL instead of
;;;; being quietly accommodated.

(in-package :vovas.engine.gate)

;;; ---------------------------------------------------------------------------
;;; Oracle adapters
;;; ---------------------------------------------------------------------------

(defun packers-json-null-p (value)
  "JZON's null is a symbol named NULL, not NIL, so \"absent\" and \"null\" must be
distinguished before either is compared to a port's NIL."
  (and (symbolp value) (string= (symbol-name value) "NULL")))

(defun packers-null (value)
  "The oracle value with JZON's null mapped to NIL."
  (if (packers-json-null-p value) nil value))

(defun packers-json-strings (value)
  "A JSON array of strings -> a list of strings. Anything else answers the
keyword `:not-a-string-array`, which can never equal the port's list and so fails
loudly rather than comparing a vector to a list."
  (if (vectorp value)
      (loop for item across value collect item)
      :not-a-string-array))

(defun packers-plist (value fields)
  "A JSON object -> a plist over FIELDS, in FIELDS order, with the null mapping
applied, where FIELDS is an alist of (plist-keyword . json-key).

The JSON key is spelled out rather than derived. Two of the three keys are
`serde(rename_all = \"camelCase\")` output (`arrayId`) while one is a plain word
(`literals`), so a `string-downcase` of the keyword answers `array-id` for a field
the oracle calls `arrayId` — and a rule that special-cased the hyphen would be a
re-derivation of serde's renaming rules living in the gate. A missing key answers
NIL for that field, which is what the port's plist also does, and which the
serialized struct never is: `StringArrayDetected` always carries all three."
  (if (hash-table-p value)
      (loop for (field . json-key) in fields
            append (list field (packers-null (gethash json-key value))))
      value))

(defparameter *packer-fields*
  '((:payload . "payload") (:base . "base") (:count . "count") (:words . "words"))
  "`PackerFound` in declaration order: payload, base, count, words. Every key is
already lowercase, so this table only pins the order.")

(defparameter *string-array-fields*
  '((:array-id . "arrayId") (:literals . "literals") (:pivot . "pivot"))
  "`StringArrayDetected` in declaration order, with `array_id` reaching the wire as
`arrayId` because the struct is `serde(rename_all = \"camelCase\")`.")

(defun packers-want-detect-packer (value)
  (let ((plain (packers-null value)))
    (when plain
      (let ((plist (packers-plist plain *packer-fields*)))
        (setf (getf plist :words) (packers-json-strings (getf plist :words)))
        plist))))

(defun packers-want-detect-string-array (value)
  (let ((plain (packers-null value)))
    (when plain (packers-plist plain *string-array-fields*))))

;;; ---------------------------------------------------------------------------
;;; Inputs
;;; ---------------------------------------------------------------------------

(defparameter *packers-inputs* nil
  "text-tier-inputs.json, read once per gate run. Two probes and the main
comparison need the same table, and re-reading a 4 KB fixture three times is how
the earlier draft ended up with three different `(gethash \"sources\" ...)` calls
that could have disagreed.")

(defun packers-sources ()
  (or *packers-inputs*
      (setf *packers-inputs*
            (gethash "sources" (read-json-file (fixture-path "text-tier-inputs.json"))))))

(defun packers-source (name)
  "The input text for NAME. An absent key is a fixture error, not an empty input:
comparing the port against \"\" would pass for every detection-free case."
  (multiple-value-bind (value present-p) (gethash name (packers-sources))
    (unless present-p
      (error "text-tier-inputs.json has no source named ~s" name))
    value))

(defun packers-case-names (table)
  "The input names of one oracle key, SORTED so a failure report reads in a stable
order and two runs are comparable."
  (sort (loop for name being the hash-keys of table collect name) #'string<))

;;; ---------------------------------------------------------------------------
;;; Wrong-implementation probes
;;;
;;; Each probe names a plausible-but-wrong implementation and requires the port's
;;; answer to DIFFER from what that implementation would answer. Two of the wrong
;;; answers below (the `$`-anchored patterns, the hex round-trip) were mistakes
;;; this port actually made and had to fix, so they are not hypothetical.
;;; ---------------------------------------------------------------------------

(defparameter *packers-wrong-implementations* ()
  "The probes that ran, as (label . passed-p). Declared BEFORE the gate that
reports the count: a top-level definition placed after its first use compiles with
an \"undefined variable\" warning and is unbound if that path runs first.")

(defun packers-probe (label got correct wrong)
  "One probe: GOT must equal CORRECT and must NOT equal WRONG.

Both halves, not just the second. \"Differs from the wrong value\" is satisfied by
any third answer at all — a probe written that way passes on an unrelated bug, and
on the branch it was aimed at it passes on ANY wrong answer except the one value
the author happened to type. Pinning the correct answer too is what makes the
probe bite, and the explicit `correct /= wrong` guard refuses a probe whose two
answers coincide (one draft had exactly that, and it reported the port as passing
while asserting nothing).

Answers a BOOLEAN. `gate-result-passed` is a COUNT and Lisp treats 0 as true, so
a count coerced naively would report every failing probe as passing — the vacuous
gate this file exists to prevent."
  (when (equal correct wrong)
    (error "probe ~s is vacuous: its correct and wrong answers are both ~s"
           label correct))
  (let ((result (make-gate-result))
        (input (format nil "got=~s correct=~s wrong=~s" got correct wrong)))
    ;; `check` is (result LABEL INPUT GOT WANT). The first draft passed `label`
    ;; where INPUT belongs and `correct` as BOTH got and want, so the assertion
    ;; compared a value to itself and every probe passed unconditionally — a
    ;; vacuous gate hiding inside the non-vacuity section. The mutation battery
    ;; found it; reading the signature would have found it faster.
    (check result (format nil "~a [got the right answer]" label) input got correct)
    (check result (format nil "~a [not the wrong implementation]" label) input
           (if (equal got wrong) :agrees-with-wrong :differs)
           :differs)
    (and (= 2 (gate-result-passed result))
         (null (gate-result-failures result)))))

(defun packers-packer-text (base)
  "A minimal but well-formed Dean Edwards packer call at BASE, for the probes
that pin the base RANGE rather than the payload.

Written as a function because inlining the same `format` three times produced a
form whose parenthesis depth no reader could verify — and did, twice: an extra
`))` compiled to \"unmatched close parenthesis\" and then to a silently
different nesting. One name, three call sites, no nesting to get wrong.

`:other` arguments are real here: `0` and `{}` are the packer's unused fifth and
sixth parameters, so this also exercises the reader's skip branches."
  (format nil "eval(function(p,a,c,k,e,d){return p}('0',~a,1,'a'.split('|'),0,{}))"
          base))

(defun run-packers-wrong-implementation-probes (&key (verbose t))
  "Prove the port is not a plausible-but-wrong implementation. T when every probe
matched its correct answer AND rejected its stand-in.

Each probe passes three arguments: the port's answer, the answer the shipped
engine gives, and the answer a plausible-but-wrong implementation would give. The
first two come from the Rust/oracle; the third is what the wrong version of the
same branch would answer."
  (let ((packed (packers-source "packed"))
        (all-ok t)
        (results '()))
    (flet ((probe (label got correct wrong)
             ;; An ERROR inside a probe is a FAILED probe, not a crashed gate. A
             ;; wrong implementation often raises where the correct one refuses —
             ;; an off-by-one index, for instance, walks off the end of the word
             ;; list — and a gate that dies with the condition name never gets to
             ;; report which assertion broke. The mutation battery found that
             ;; too: one mutant aborted the whole run and printed no probe line.
             (let ((ok (handler-case (packers-probe label got correct wrong)
                         (error (e)
                           (format t "~&  PROBE ERRORED ~a: ~a~%" label e)
                           nil))))
               (push (cons label ok) results)
               (unless ok
                 (setf all-ok nil)
                 (format t "~&  PROBE FAILED ~a~%    got:     ~s~%    correct: ~s~%    wrong:   ~s~%"
                         label got correct wrong)))))
      ;; 1. The word list keeps its ORDER. A port that sorted it (a tempting
      ;;    "canonicalise the words" tidy-up) would answer a different sentence.
      (probe "words are not sorted"
             (getf (vovas.engine.packers:detect-packer packed) :words)
             '("console" "log" "packed" "ok")
             '("console" "log" "ok" "packed"))
      ;; 2. The base is read as a NUMBER, not left as its source text. A port
      ;;    that kept the text would answer "4", every base decode would fall
      ;;    through to the -1 refusal, and the payload would come back untouched.
      (probe "base is a number, not its source text"
             (getf (vovas.engine.packers:detect-packer packed) :base)
             4
             "4")
      ;; 3. The `.split('|')` separator is honored. Splitting on nothing (or on
      ;;    whitespace) would answer one long word and the payload would
      ;;    substitute to itself.
      (probe "the split separator is honored"
             (length (getf (vovas.engine.packers:detect-packer packed) :words))
             4
             1)
      ;; 4. Unpacking is not a no-op on already-plain text. A port that returned
      ;;    its input on failure instead of NIL would answer the source here.
      (probe "unpack-packer answers NIL for unpacked text"
             (vovas.engine.packers:unpack-packer "var a = 1;")
             nil
             "var a = 1;")
      ;; 5. detect-string-array does not fire on plain source. A port whose
      ;;    regex lost its `(?m)^` anchor would match a `= [...]` anywhere.
      (probe "detect-string-array needs a declaration"
             (vovas.engine.packers:detect-string-array (packers-source "plain"))
             nil
             :fired)
      ;; 6. `parse-int-literal` is round-trip STRICT on decimal. A port that
      ;;    accepted a valid prefix (as JavaScript's `parseInt` does) would
      ;;    answer 4 here — precisely the difference that decides the rotation.
      (probe "parse-int-literal refuses a non-round-trip decimal"
             (vovas.engine.packers::parse-int-literal "4|1|0|2|3")
             nil
             4)
      ;; 7. `parse-int-literal` DOES accept a hex prefix (the preserved
      ;;    asymmetry). A port that tidied this into strict hex would answer NIL
      ;;    and refuse a rotator pivot the shipped engine accepts.
      (probe "parse-int-literal accepts a hex prefix"
             (vovas.engine.packers::parse-int-literal "0x1aZZ")
             26
             nil)
      ;; 8. `base-decode-token` answers -1 for an out-of-base character rather
      ;;    than carrying on with a negative digit value. The input is chosen so
      ;;    the two implementations genuinely diverge: in base 62 every ASCII
      ;;    letter is a valid digit, so the only way "a_" fails is the `_`, whose
      ;;    digit value is -1. A port that checked only `>= d base` would fold
      ;;    that -1 into the accumulator and answer 619.
      ;;
      ;;    (The first draft of this probe used "_0x" in base 4, where the
      ;;    mutation ALSO answers -1 — because `x` is out of range in base 4 and
      ;;    the second check fires anyway. The probe passed under the mutation
      ;;    and pinned nothing; that is why the mutation battery exists.)
      (probe "base-decode-token refuses out-of-base characters"
             (vovas.engine.packers::base-decode-token "a_" 62)
             -1
             619)
      ;; 9. The token bound is EXCLUSIVE. `unpack_with` substitutes only when
      ;;    the decoded index is `< words.len()`, so a token whose index equals
      ;;    the list length must survive verbatim. With base 4 the words are
      ;;    indices 0-3, and token "10" is index 4 — one PAST the end — so the
      ;;    stand-in is the answer of a port that substituted anyway.
      (probe "unpack_with leaves an index past the word list alone"
             (vovas.engine.packers::unpack-with "10 3" 4 '("a" "b" "c" "d"))
             "10 d"
             "a d")
      ;; 10. An EMPTY word is not a substitution. Obfuscators emit `||` holes in
      ;;     the word list, and the engine leaves the token in place rather than
      ;;     deleting it — so `"0 1"` with an empty word 1 must keep its `1`.
      (probe "unpack_with keeps the token at an empty word"
             (vovas.engine.packers::unpack-with "0 1" 4 '("a" ""))
             "a 1"
             "a ")
      ;; 11. All four rotator witnesses are NECESSARY. `looks_like_rotator`
      ;;     requires a while, a push, a shift and a parseInt together; dropping
      ;;     any one of them must answer NIL, or the rewriter would treat any
      ;;     IIFE that merely loops as a rotator and delete it.
      ;;
      ;;     The positive case is the shipped engine's own rotator body, so this
      ;;     probe also pins the shape the fixture actually carries.
      (probe "a while loop without push/shift/parseInt is not a rotator"
             (vovas.engine.packers::looks-like-rotator-p
              "var f = function(a) { while (true) { a = a + 1; } };")
             nil
             t)
      (probe "a full rotator body is recognized"
             (vovas.engine.packers::looks-like-rotator-p
              (format nil "var f = function(a) { while (true) { if (parseInt(a[0]) === 4) break; a[\"push\"](a[\"shift\"]()); } };"))
             t
             nil)
      ;; 13. The base range is 2..=62, and BOTH ends are real. Base 1 would leave
      ;; 13. The base range is 2..=62, and BOTH ends are real. Base 1 would leave
      ;;     an empty digit alphabet and base 63 would leave the `[0-9a-zA-Z]`
      ;;     range `digit-value` knows, so either end admits a detection whose
      ;;     every token then fails to decode. The fixture only carries base 4,
      ;;     which is why a narrowed range survived the battery until this probe.
      (probe "base 1 is refused (below the range)"
             (vovas.engine.packers:detect-packer (packers-packer-text 1))
             nil
             :detected)
      (probe "base 63 is refused (above the range)"
             (vovas.engine.packers:detect-packer (packers-packer-text 63))
             nil
             :detected)
      (probe "base 62 is accepted (the top of the range)"
             (getf (vovas.engine.packers:detect-packer (packers-packer-text 62)) :base)
             62
             nil)
      ;; 14. The `.split(...)` separator is not merely defaulted, it is READ.
      ;;     The shipped fixture splits on `'|'`, which is also the fallback, so
      ;;     no fixture case can tell "read the separator" from "always use |".
      ;;     This input splits on a comma and the word list proves which happened.
      (probe "the split separator is parsed, not defaulted"
             (getf (vovas.engine.packers:detect-packer
                    (format nil "eval(function(p,a,c,k,e,d){return p}('0 1',4,2,'alpha,beta'.split(','),0,{}))"))
                   :words)
             '("alpha" "beta")
             '("alpha,beta")))
    (setf *packers-wrong-implementations* (nreverse results))
    (when verbose
      ;; Reported from the STORED list, not from `results`. `nreverse` is
      ;; destructive, so after the assignment `results` points at the last cons
      ;; and `(length results)` answers 1 — the first draft printed "1/1" for
      ;; eight probes and looked like eight probes had gone missing.
      (format t "~&packers probes: ~a/~a wrong implementations rejected~%"
              (count-if #'cdr *packers-wrong-implementations*)
              (length *packers-wrong-implementations*)))
    all-ok))

;;; ---------------------------------------------------------------------------
;;; Static-decoder inlining cases, captured from the shipped engine
;;;
;;; The fixture's `stringArray` input carries NO decoder declaration, so the
;;; whole inlining half of packers.rs — `find_decoder_decl`,
;;; `analyze_decoder_body`, `find_decoder_call_sites`, `decode_index` and the
;;; splice — is reached by no oracle case at all. These four sources were run
;;; through the SHIPPED engine (src/js/unpack-bridge.js, the same seam the
;;; text-tier oracle came from) and the expected strings below are its output
;;; verbatim. They live here rather than in the fixture because the fixture is
;;; generated by a script, not hand-edited.
;;; ---------------------------------------------------------------------------

(defparameter *packers-decoder-inline-cases*
  (list
   (list "inline"
         "var _0x1=[\"a\",\"b\",\"c\",\"d\",\"e\",\"f\",\"g\",\"h\",\"i\",\"j\",\"k\",\"l\",\"m\",\"n\",\"o\",\"p\",\"HELLO\"];\n(function(_0xa,_0xb){var _0xc=function(_0xd){while(true){if(parseInt(_0xa[0])===_0xb)break;_0xa[\"push\"](_0xa[\"shift\"]());}};_0xc(++_0xb);}(_0x1,0x0));\nvar _0x2=function(i){i=i-0x10;return _0x1[i];};console.log(_0x2(\"0x10\"));"
         "var _0x1 = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'HELLO'];\n\nvar _0x2=function(i){i=i-0x10;return _0x1[i];};console.log(_0x2(\"0x10\"));")
   (list "split"
         "var _0x1=[\"a\",\"b\",\"c\",\"d\",\"e\",\"f\",\"g\",\"h\",\"i\",\"j\",\"k\",\"l\",\"m\",\"n\",\"o\",\"p\",\"HELLO\"];\n(function(_0xa,_0xb){var _0xc=function(_0xd){while(true){if(parseInt(_0xa[0])===_0xb)break;_0xa[\"push\"](_0xa[\"shift\"]());}};_0xc(++_0xb);}(_0x1,0x0));\nvar _0x2=function(i){return _0x1[i].split('');};console.log(_0x2(0));"
         "var _0x1 = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'HELLO'];\n\nconsole.log('a');")
   (list "two"
         "var _0x1=[\"a\",\"b\",\"c\",\"d\",\"e\",\"f\",\"g\",\"h\",\"i\",\"j\",\"k\",\"l\",\"m\",\"n\",\"o\",\"p\",\"HELLO\"];\n(function(_0xa,_0xb){var _0xc=function(_0xd){while(true){if(parseInt(_0xa[0])===_0xb)break;_0xa[\"push\"](_0xa[\"shift\"]());}};_0xc(++_0xb);}(_0x1,0x0));\nvar _0x2=function(i){return _0x1[i]+_0x1[0];};console.log(_0x2(0));"
         "var _0x1 = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'HELLO'];\n\nvar _0x2=function(i){return _0x1[i]+_0x1[0];};console.log(_0x2(0));")
   (list "method"
         "var _0x1=[\"a\",\"b\",\"c\",\"d\",\"e\",\"f\",\"g\",\"h\",\"i\",\"j\",\"k\",\"l\",\"m\",\"n\",\"o\",\"p\",\"HELLO\"];\n(function(_0xa,_0xb){var _0xc=function(_0xd){while(true){if(parseInt(_0xa[0])===_0xb)break;_0xa[\"push\"](_0xa[\"shift\"]());}};_0xc(++_0xb);}(_0x1,0x0));\nvar _0x2=function(i){return _0x1[i];};console.log(_0x2(0));obj._0x2(1);"
         "var _0x1 = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'HELLO'];\n\nvar _0x2=function(i){return _0x1[i];};console.log('a');obj._0x2(1);"))
  "(name source expected) triples, copied verbatim from the shipped wasm engine.

What each one pins:

  inline  the ordinary path: `arr[i - 0x10]` with a call of `\"0x10\"` resolves
          to index 0, the call becomes `'a'`, and the declaration is deleted
          because every call resolved.
  split   the SHIPPED engine's real quirk: a body of `arr[i].split('')` is
          INLINED anyway, because the suffix test looks only for a bare `]` and
          a method call is not a statement, so the declaration is deleted and
          the call becomes `'a'` — the `.split('')` is silently dropped. That is
          a genuine upstream bug, preserved rather than corrected: matching the
          engine is the specification, and \"fixing\" it here would make the port
          disagree with the thing that ships.
  two     two lookups in the body -> the `count of [` test refuses, so the
          declaration and both calls survive verbatim.
  method  a method call `obj._0x2(1)` sets `has_unresolved`, so the
          declaration is KEPT even though the direct call inlined.")

;;; ---------------------------------------------------------------------------
;;; The gate
;;; ---------------------------------------------------------------------------

(defun run-packers-gate (&key (verbose t))
  "Compare the packer tier against the shipped wasm engine's answers.

T only when every case matches, the case count is positive, and every
wrong-implementation probe rejected its stand-in."
  (let ((oracle (read-json-file (fixture-path "text-tier-oracle.json")))
        (result (make-gate-result))
        (count 0))
    (setf *packers-inputs* nil)             ; read the fixture fresh per run

    ;; --- detectPacker ----------------------------------------------------
    (let ((cases (gethash "detectPacker" oracle)))
      (dolist (name (packers-case-names cases))
        (incf count)
        (check result "detectPacker" name
               (vovas.engine.packers:detect-packer (packers-source name))
               (packers-want-detect-packer (gethash name cases)))))

    ;; --- unpackPacker ----------------------------------------------------
    (let ((cases (gethash "unpackPacker" oracle)))
      (dolist (name (packers-case-names cases))
        (incf count)
        (check result "unpackPacker" name
               (vovas.engine.packers:unpack-packer (packers-source name))
               (packers-null (gethash name cases)))))

    ;; --- detectStringArray -----------------------------------------------
    (let ((cases (gethash "detectStringArray" oracle)))
      (dolist (name (packers-case-names cases))
        (incf count)
        (check result "detectStringArray" name
               (vovas.engine.packers:detect-string-array (packers-source name))
               (packers-want-detect-string-array (gethash name cases)))))

    ;; --- transformStringArray --------------------------------------------
    (let ((cases (gethash "transformStringArray" oracle)))
      (dolist (name (packers-case-names cases))
        (incf count)
        (check result "transformStringArray" name
               (vovas.engine.packers:transform-string-array (packers-source name))
               (packers-null (gethash name cases)))))

    ;; --- the shipped-engine cases, asserted by VALUE ----------------------
    ;;
    ;; The acceptance criteria as facts rather than as "not nil". The oracle
    ;; records exactly one non-null answer per key, and the values below are
    ;; copied from it — so a regeneration that changes them fails here and names
    ;; the change instead of passing silently.
    (incf count)
    (check result "packed/detectPacker-value" "packed"
           (vovas.engine.packers:detect-packer (packers-source "packed"))
           (list :payload "0 1(\"2 3\");"
                 :base 4
                 :count 4
                 :words '("console" "log" "packed" "ok")))
    (incf count)
    (check result "packed/unpackPacker-value" "packed"
           (vovas.engine.packers:unpack-packer (packers-source "packed"))
           "console log(\"packed ok\");")
    (incf count)
    (check result "stringArray/detectStringArray-value" "stringArray"
           (vovas.engine.packers:detect-string-array (packers-source "stringArray"))
           (list :array-id "_0x5e6f" :literals 5 :pivot 4))
    ;; The rotator's pivot is 0x4 = 4 and the first literal is "4|1|0|2|3",
    ;; which `parse-int-literal` REFUSES (round-trip strict) where JavaScript's
    ;; `parseInt` would answer 4. So no rotation applies and the array is
    ;; re-emitted in its original order; the transform still fires, because the
    ;; rotator IIFE is deleted and the declaration is rewritten as `var ...`.
    (incf count)
    (check result "stringArray/transformStringArray-value" "stringArray"
           (vovas.engine.packers:transform-string-array (packers-source "stringArray"))
           (format nil "var _0x5e6f = ['4|1|0|2|3', 'log', 'Hello', 'world', 'console'];~%~%var _0x7b9c = function(i, n) {~%  i = i - 0x0;~%  return _0x5e6f[i];~%};~%console[_0x7b9c(\"0x1\")](_0x7b9c(\"0x2\") + _0x7b9c(\"0x3\"));"))

    ;; --- the refusals, which no oracle key covers -------------------------
    ;;
    ;; `detect_aaencode` / `detect_jjencode` / `detect_jsfiretruck` /
    ;; `detect_obfuscator_io` are not exposed through the text-tier oracle at
    ;; all, so they are pinned here on the one property that must hold for every
    ;; plain or packed input: none of them fires. A detector that fired on
    ;; ordinary source would refuse to download the tool's own target files.
    (dolist (name '("plain" "packed" "stringArray" "minified" "bundle"))
      (let ((text (packers-source name)))
        (incf count)
        (check result "no-esoteric-refusal" name
               (list (vovas.engine.packers:detect-aaencode text)
                     (vovas.engine.packers:detect-jjencode text)
                     (vovas.engine.packers:detect-jsfiretruck text))
               (list nil nil nil))))
    ;; The obfuscator census is scored, so it MAY fire on obfuscated source; the
    ;; pinned fact is that plain source with no marker at all answers NIL.
    (incf count)
    (check result "obfuscator/quiet-on-plain" "plain"
           (vovas.engine.packers:detect-obfuscator-io (packers-source "plain"))
           nil)
    ;; A real obfuscator.io banner is a STRONG marker, so one is enough.
    (incf count)
    (check result "obfuscator/banner-is-strong" "banner"
           (let ((hit (vovas.engine.packers:detect-obfuscator-io
                       "var a=1; // obfuscator.io")))
             (and hit (getf hit :tool)))
           "obfuscator-io")

    ;; --- the static-decoder inlining path --------------------------------
    ;;
    ;; The fixture's `stringArray` input carries NO decoder declaration, so the
    ;; whole inlining half of packers.rs — `find_decoder_decl`,
    ;; `analyze_decoder_body`, `find_decoder_call_sites`, `decode_index` and the
    ;; splice — is otherwise reached by no oracle case at all. These four
    ;; sources were run through the SHIPPED engine (src/js/unpack-bridge.js, the
    ;; same seam the oracle came from) and the answers below are its output
    ;; verbatim. They are captured here rather than appended to the fixture
    ;; because the fixture is generated, not hand-edited.
    ;;
    ;; The third case is the interesting one: a decoder whose body is
    ;; `arr[i].split('')` IS inlined, because the suffix test only looks for a
    ;; bare `]` and `.split('')` is not a statement. That is the SHIPPED
    ;; behaviour, preserved rather than corrected — and note it also deletes the
    ;; declaration, so the port reproduces the original's real bug.
    (dolist (case *packers-decoder-inline-cases*)
      (incf count)
      (check result "stringArray/decoder-inline" (first case)
             (vovas.engine.packers:transform-string-array (second case))
             (third case)))

    ;; --- non-vacuity by count --------------------------------------------
    ;;
    ;; A mis-read oracle answers an empty table, and an empty table makes every
    ;; loop above run zero times: a gate that passes on nothing.
    (incf count)
    (check result "oracle/non-empty" "case count > 0" t (plusp count))

    (let ((probes-ok (run-packers-wrong-implementation-probes :verbose verbose)))
      (when verbose
        (format t "~&packers gate: ~a/~a cases match, ~a wrong-implementation probes~%"
                (gate-result-passed result) (gate-result-total result)
                (length *packers-wrong-implementations*))
        (report-failures result))
      (and (= (gate-result-passed result) (gate-result-total result))
           (plusp count)
           probes-ok))))
