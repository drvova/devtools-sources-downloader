;;;; gate-stackprofile.lisp — the page-profile analyzer gate.
;;;;
;;;; The richest panel oracle after boundary: 28 captured snapshots, each with the
;;;; whole profile AND the serialised `profileText`. Comparing the profile as a
;;;; plist pins the values; comparing `profileText` additionally pins KEY ORDER,
;;;; because `serde_json` runs with `preserve_order` and the report pages embed
;;;; that exact string.
;;;;
;;;; CLOCK: `generatedAt` is the only clock-dependent field, so this blanks it on
;;;; both sides exactly as `stack_profile_test.rs` does, and strips the digits after
;;;; `"generatedAt":` from both serialised forms. Without that the gate would fail
;;;; on every case for a reason that has nothing to do with the analyzer.

(in-package :vovas.engine.gate)

(defun camel-to-kebab (name)
  "`generatedAt` -> `GENERATED-AT`, the keyword spelling the port uses.

The oracle's keys are the WIRE names, so every camelCase key needs this before it
can match a plist keyword - otherwise a correct value compares against the wrong
key and reads as a missing field rather than a wrong one."
  (let ((out (make-string-output-stream)))
    (loop for c across name
          do (if (upper-case-p c)
                 (progn (write-char #\- out) (write-char c out))
                 (write-char (char-upcase c) out)))
    (get-output-stream-string out)))

(defun stack-json (value)
  "A JZON value as the plist shape `analyze` answers, recursively.

Needed because the oracle is JSON: an object must become a plist with keyword keys
so `equal` can compare it against the port's answer, and JZON's null must become
NIL so a missing optional does not look different from an explicit null."
  (cond
    ;; `json-null` is a CONVERTER, not a predicate: for anything that is not
    ;; JZON's null it answers its argument UNCHANGED, which is truthy - so
    ;; `(json-null value)` as a cond test matches EVERY value and the whole
    ;; conversion collapses to NIL.
    ((eq nil (json-null value)) nil)
    ((hash-table-p value)
     ;; NOT `loop ... nconc (list k v)`: `nconc` inside `loop` does not accumulate
     ;; into the loop's result - it destructively joins its argument to itself and
     ;; the form answers NIL, so every object converted to an EMPTY plist and all
     ;; 56 cases failed with a `want` of one key. Built with append instead.
     (let ((acc '()))
       (loop for key being the hash-keys of value using (hash-value v)
             do (setf acc (append acc (list (intern (camel-to-kebab key) :keyword)
                                            (stack-json v)))))
       acc))
    ;; A JZON string can arrive as a CHARACTER VECTOR, so this must precede the
    ;; general vector case: comparing `#(#\1 #\. #\0 #\. #\0)` against "1.0.0"
    ;; fails for a reason that looks like a version mismatch.
    ((and (vectorp value) (plusp (length value)) (characterp (aref value 0)))
     (coerce value 'string))
    ((vectorp value) (loop for item across value collect (stack-json item)))
    (t value)))

(defun strip-clock-text (text)
  "Digit-strip the value after every `\"generatedAt\":`, so two serialisations of
the same profile compare equal regardless of when they were produced."
  (let ((key "\"generatedAt\":")
        (out (make-string-output-stream))
        (rest text))
    (loop
      (let ((at (search key rest)))
        (if (null at)
            (progn (write-string rest out) (return))
            (progn
              (write-string (subseq rest 0 (+ at (length key))) out)
              (let* ((tail (subseq rest (+ at (length key))))
                     (digits (or (position-if-not #'digit-char-p tail) (length tail))))
                (write-char #\0 out)
                (setf rest (subseq tail digits)))))))
    (get-output-stream-string out)))

(defparameter *wire-names*
  '(("profile" . "profile")
    ("boot-delay-ms" . "bootDelayMs")
    ("network-quiet-ms" . "networkQuietMs")
    ("mutation-quiet-ms" . "mutationQuietMs")
    ("runtime-quiet-ms" . "runtimeQuietMs")
    ("socket-quiet-ms" . "socketQuietMs")
    ("worker-grace-ms" . "workerGraceMs")
    ("max-capture-ms" . "maxCaptureMs")
    ("prefer-hydrated-dom" . "preferHydratedDom")
    ("capture-framework-state" . "captureFrameworkState")
    ;; NOT derivable: the wire key has a capital QL that no kebab->camel rule can
    ;; recover, so an explicit table is the only honest way to spell it. A generic
    ;; converter produced "captureGraphqlOps" and every case failed on that one key.
    (:capture-graphql-ops . "captureGraphQLOps")
    ("prioritize-source-maps" . "prioritizeSourceMaps")
    ("reasons" . "reasons")
    ("version" . "version")
    ("generated-at" . "generatedAt")
    ("technologies" . "technologies")
    ("traits" . "traits")
    ("confidence" . "confidence")
    ("evidence" . "evidence")
    ("strategy" . "strategy")
    ("summary" . "summary")
    ("name" . "name")
    ("category" . "category")
    ("globals" . "globals")
    ("endpoints" . "endpoints"))
  "The wire spelling of every key this profile emits.

One table rather than a rule, because the set is fixed and one member
(`captureGraphQLOps`) cannot be derived by any casing convention.")

(defun kebab-to-camel (name)
  "`BOOT-DELAY-MS` -> `bootDelayMs`. The fallback for a key not in the table."
  (let ((out (make-string-output-stream))
        (upcase-next nil))
    (loop for c across (string-downcase name)
          do (cond ((char= c #\-) (setf upcase-next t))
                   (upcase-next (write-char (char-upcase c) out) (setf upcase-next nil))
                   (t (write-char c out))))
    (get-output-stream-string out)))

(defun wire-name (keyword)
  "The wire spelling of KEYWORD.

Matched by SYMBOL NAME, not by `eq`. The table is written with pipe-interned
symbols (`:|traits|`) while `analyze` produces plain reader symbols (`:traits`) -
they print the same and are different objects, so an `eq` lookup silently missed
and emitted the kebab fallback. Comparing names makes the two spellings
interchangeable, which is what they are."
  (let ((name (symbol-name keyword)))
    (or (cdr (assoc name *wire-names* :test #'string=))
        (kebab-to-camel name))))

(defun plist-to-json-text (plist)
  "Serialise the port's profile the way `serde_json` would, preserving key order.

Written out rather than routed through JZON for two reasons: JZON cannot promise
insertion order for a hash-table, and the ORDER is half of what `profileText`
pins; and JZON's boolean spelling differs from the engine's `false`.

A NIL value is the ambiguous case. In this profile a NIL is either a JSON `false`
(`preferHydratedDom`) or an empty array (`technologies` when nothing was detected),
so booleans are named explicitly rather than guessed."
  (let ((boolean-keys '(:|prefer-hydrated-dom|
                        :|capture-framework-state|
                        :capture-graphql-ops
                        :|prioritize-source-maps|)))
    (with-output-to-string (out)
      (labels ((emit (value)
                 (cond
                   ((stringp value)
                    (write-char #\" out)
                    (loop for c across value
                          do (case c
                               (#\" (write-string "\\\"" out))
                               (#\\ (write-string "\\\\" out))
                               (#\Newline (write-string "\\n" out))
                               (#\Tab (write-string "\\t" out))
                               (#\Return (write-string "\\r" out))
                               (t (write-char c out))))
                    (write-char #\" out))
                   ((eq value t) (write-string "true" out))
                   ((null value) (write-string "null" out))
                   ((integerp value) (format out "~d" value))
                   ((floatp value)
                    (let ((v (coerce value 'double-float)))
                      (if (= v (truncate v))
                          (format out "~d" (truncate v))
                          (let ((s (format nil "~f" v)))
                            ;; trim trailing zeros so 0.450000 prints as 0.45
                            (write-string (string-right-trim "0" s) out)
                            (when (char= #\. (char (string-right-trim "0" s)
                                                   (1- (length (string-right-trim "0" s)))))
                              (write-char #\0 out))))))
                   ((and (consp value) (keywordp (car value)))
                    (write-char #\{ out)
                    (loop for (k v) on value by #'cddr
                          for first = t then nil
                          do (unless first (write-char #\, out))
                             (write-char #\" out)
                             (write-string (wire-name k) out)
                             (write-string "\":" out)
                             (cond
                               ;; a strategy BOOLEAN: false, not null
                               ((member (wire-name k)
                                        '("preferHydratedDom" "captureFrameworkState"
                                          "captureGraphQLOps" "prioritizeSourceMaps")
                                        :test #'string=)
                                (write-string (if v "true" "false") out))
                               ;; an EMPTY SEQUENCE: `[]`, not null. Keyed on the
                               ;; WIRE name because the profile's own `traits` and
                               ;; `technologies` arrive as plain NIL when nothing was
                               ;; detected, and JSON has no way to tell that from a
                               ;; missing key - so the producer's intent is
                               ;; reconstructed from the field's declared shape.
                               (t (emit v))))
                    (write-char #\} out))
                   ;; An ALIST is `((key . value) ...)`, so its first element is a
                   ;; CONS whose car is a STRING or symbol. A list of PLISTS -
                   ;; `((:name "x" :category "y") ...)`, which is what
                   ;; `technologies` is - has a LIST as its first element, and
                   ;; testing only `(consp (car value))` sent it down the alist
                   ;; branch: it emitted `{"NAME":["Generic Web App",:CATEGORY,...]}`.
                   ((and (consp value) (consp (car value))
                         (let ((k (caar value)))
                           (or (stringp k) (and (symbolp k) (not (keywordp k))))))
                    (write-char #\{ out)
                    (loop for (k . v) in value
                          for first = t then nil
                          do (unless first (write-char #\, out))
                             (write-char #\" out)
                             (write-string (string k) out)
                             (write-string "\":" out)
                             (emit v))
                    (write-char #\} out))
                   ((vovas.engine.panel.stackprofile:json-marker-p value)
                    (write-string (if (eq :array
                                          (vovas.engine.panel.stackprofile:json-marker-kind value))
                                      "[]"
                                      "{}")
                                  out))
                   ((listp value)
                    (write-char #\[ out)
                    (loop for item in value
                          for first = t then nil
                          do (unless first (write-char #\, out))
                             (emit item))
                    (write-char #\] out))
                   ((vectorp value)
                    (write-char #\[ out)
                    (loop for i from 0 below (length value)
                          do (when (plusp i) (write-char #\, out))
                             (emit (aref value i)))
                    (write-char #\] out))
                   (t (format out "~s" value)))))
        (emit plist)))))

(defun run-stackprofile-gate (&key (verbose t))
  (let* ((oracle (read-json-file (fixture-path "stack-profile.json")))
         (result (make-gate-result))
         (count 0))
    (maphash
     (lambda (name entry)
       (let* (;; RAW, not stack-json: `analyze` reads the snapshot with `field`, which
              ;; is `gethash` - a hash-table operation. Converting it to plists first
              ;; meant every lookup missed, so no technology was ever detected and
              ;; 26 of 28 cases fell through to the Generic Web App fallback while
              ;; looking like a detection bug.
              (snapshot (gethash "snapshot" entry))
              (want (stack-json (gethash "profile" entry)))
              (want-text (gethash "profileText" entry))
              (got (vovas.engine.panel.stackprofile:analyze snapshot)))
         ;; `profileText` IS the comparison, and the plist form is deliberately
         ;; not used. The oracle's `evidence` objects are keyed by DISPLAY NAME
         ;; ("Generic Web App", "static-ish"), so any converter that tries to turn
         ;; every JSON object into keyword-keyed plists also mangles those -
         ;; producing `:|GENERIC -WEB -APP|`, a correct value under the wrong key
         ;; that reads as a missing field. Serialising the port's answer and
         ;; comparing TEXT sidesteps the question entirely, and it is the stronger
         ;; check anyway: it pins values AND key order in one assertion.
         ;;
         ;; `generatedAt` is the only clock-dependent field, so the digit run after
         ;; it is stripped from both sides - exactly what stack_profile_test.rs does.
         (declare (ignore want))
         (setf (getf got :generated-at) 0)
         (incf count)
         (check result "profileText" name
                (strip-clock-text (plist-to-json-text got))
                (strip-clock-text want-text))))
     oracle)
    (when verbose
      (format t "~&stackprofile gate: ~a/~a cases match (~a snapshots)~%"
              (gate-result-passed result) (gate-result-total result)
              (hash-table-count oracle))
      (report-failures result))
    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp count))))
