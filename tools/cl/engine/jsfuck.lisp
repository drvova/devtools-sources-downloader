;;;; jsfuck.lisp — JSFuck ([], (), !, +) decoding without eval/Function.
;;;;
;;;; Ported from unpack-rs/src/jsfuck.rs. The original's header says it best:
;;;; the JavaScript implementation of this decoder EVALUATES the grammar over
;;;; real JavaScript values, so `+`, `!`, `String()` and every method call
;;;; delegate to the engine. A port with no host engine cannot do that, so the
;;;; value model below implements exactly the coercion surface and builtin
;;;; set the canonical encoder (jsfuck.com 0.5.0) can reach:
;;;;
;;;;   - arrays, groups, unary `!`/`+`, binary `+`
;;;;   - Array.prototype: at, entries, concat, join
;;;;   - String.prototype: at, concat, split, fontcolor, italics
;;;;   - Number.prototype.toString(radix)
;;;;   - constructors read as VALUES ('function Number() { [native code] }')
;;;;   - Function/eval modelled as CAPTURE SEAMS, never executed
;;;;   - Function("return X") bodies: this / eval / builtin-by-name / regex
;;;;     literal / quoted payload / raw payload
;;;;   - escape() and Date() for the encoder's percent and date recipes
;;;;
;;;; Two things about this file that are not obvious.
;;;;
;;;; THE ORACLE, NOT THE RUST, IS THE SPECIFICATION. Where the two disagree
;;;; the shipped engine wins. The sharpest case is `invoke-native`: the Rust
;;;; unwraps the CALL RECEIVER to a primitive before asking "is this an array?",
;;;; and `unwrap_to_primitive` turns every array into a string — so the array
;;;; branches of `at`, `join` and `concat` are DEAD CODE. Measured on the
;;;; shipped engine: `[[+[]]]["at"](+[])` answers "0" (string indexing of "0"),
;;;; `[[+[]],[+[]]]["join"]()` answers null (join refuses a non-array
;;;; receiver), and `[+[]]["concat"](...)` takes the string branch. That looks
;;;; like a bug and it is preserved anyway, because "fixing" it would make the
;;;; port answer where the engine refuses. `is-array` is therefore still
;;;; consulted — the structure of the original is kept so the dead branch stays
;;;; recognisable — but it is unreachable, exactly as in the original.
;;;;
;;;; RECURSION IS BOUNDED BY TWO COUNTERS, not by the Lisp stack. `nodes`
;;;; (2,000,000) and `depth` (10,000) are the Rust's own budgets; the host
;;;; stack is a third, lower limit the Rust does not have. That is a real
;;;; fidelity gap: an input nested deeper than the host stack permits fails
;;;; with a storage-condition rather than the Rust's "nesting too deep"
;;;; message. `interpret-jsfuck` catches every condition and answers NIL, which
;;;; is what decode-jsfuck does with any error, so the WIRE answer is identical
;;;; even though the internal route differs. Adversarial deep nesting is the
;;;; only input where the two implementations can disagree, and both refuse.

(in-package :cl-user)

(defpackage :vovas.engine.jsfuck
  (:use :cl)
  (:import-from :vovas.engine.util
                #:js-trim
                #:js-whitespace-p)
  (:import-from :vovas.engine.number
                #:to-string
                #:to-radix-string
                #:to-number)
  (:import-from :vovas.engine.zip
                #:civil-from-unix-secs)
  (:export
   #:detect-jsfuck
   #:decode-jsfuck))

(in-package :vovas.engine.jsfuck)

;;; ---------------------------------------------------------------------------
;;; Detection
;;; ---------------------------------------------------------------------------

(defparameter *jsfuck-charset* "[]()!+"
  "The six characters of the JSFuck alphabet, as a string for MEMBER/HUNT use.

A DEFPARAMETER, not a DEFCONSTANT: `defconstant` on a string mints a fresh
object per compile and reloading signals DEFCONSTANT-UNEQL even for identical
text. The checkout's CONTRACT.md records this trap; it is why every string here
is a parameter.")

(defparameter *max-parse-nodes* 2000000
  "The Rust's MAX_PARSE_NODES. A budget, not a safety net: it is what stops a
hostile input from spinning forever, and it is part of the specification because
a port with no budget would answer where the engine refuses.")

(defparameter *max-parse-depth* 10000
  "The Rust's MAX_PARSE_DEPTH, in RECURSIVE CALLS of the parser, which is not the
same unit as the host stack's capacity. See the header note.")

(defparameter *detect-min-length* 12
  "`detect_jsfuck`'s floor, in CHARACTERS (Rust `.chars().count()`), not bytes.
The distinction matters for any non-ASCII input: a 12-character body of
multi-byte characters is the boundary the Rust compares against, and a port
using `length` on a byte vector would refuse or accept on the wrong side.")

(defparameter *detect-min-purity* 0.95d0
  "The purity floor. Strictly below is refused, so exactly 0.95 detects.")

(defparameter *detect-min-hits* 12
  "Charset-byte count floor, independent of purity. An input that is 100% pure
but shorter than this is refused by THIS test with the purity message, which is
why the two conditions share one branch and one reason string.")

(defparameter *detect-max-chain* 4096
  "The longest run of `+` tolerated. Longer chains are refused as a denial-of-
service shape: a wall of `+` is the cheapest way to make the decoder allocate
without ever producing a value.")

(defun longest-operator-chain (text)
  "The longest run of `+` in TEXT.

A fold in the Rust that keeps (best, run) and resets the run on any other
character. Written as an explicit LOOP here because the fold's tuple is harder
to read than the intent, and the intent is the whole point: the chain length,
not the count."
  (let ((best 0)
        (run 0))
    (loop for c across text
          do (if (char= c #\+)
                 (progn (incf run)
                        (when (> run best) (setf best run)))
                 (setf run 0)))
    best))

(defun detect-jsfuck (source)
  "Detection, ported from the disrobe heuristic.

Answers a plist `(:detected BOOLEAN :purity DOUBLE :reason STRING)` — the three
keys `JsfuckDetect` serialises, in declaration order.

The test order is load-bearing, because each test OWNS its reason string and the
reason strings reach the panel's report:

  1. length < 12            -> \"too short\", purity 0.0 — and note the purity is
                               ZERO here, not the measured value; a port that
                               measured first would report a plausible ratio for
                               an input nobody looked at.
  2. purity < 0.95 or hits < 12 -> \"purity N.N% (M charset bytes)\". The purity
                               IS reported from here on.
  3. chain > 4096           -> \"operator chain too long (N)\".
  4. otherwise              -> detected, reason \"\" (empty, not NIL: the report
                               prints it directly).

Purity excludes SPACES ONLY from the denominator (`c != ' '`), not all
whitespace. A tab therefore counts against purity while contributing no hit,
which is why the oracle's one-tab case sits at 94.7% where reading `\\s` would
have put it at 100%."
  (let ((trimmed (js-trim source)))
    (if (< (length trimmed) *detect-min-length*)
        (list :detected nil :purity 0d0 :reason "too short")
        (let ((hits 0)
              (counted 0))
          (loop for c across trimmed
                do (when (find c *jsfuck-charset*) (incf hits))
                   (unless (char= c #\Space) (incf counted)))
          (let ((purity (if (plusp counted)
                            (/ (coerce hits 'double-float)
                               (coerce counted 'double-float))
                            0d0)))
            (if (or (< purity *detect-min-purity*) (< hits *detect-min-hits*))
                (list :detected nil
                      :purity purity
                      ;; `{:.1}` on purity*100: one decimal, which is what the
                      ;; panel shows and what the oracle pins. `~,1f` rounds the
                      ;; exact value, so 94.7368... prints as "94.7".
                      :reason (format nil "purity ~,1f% (~d charset bytes)"
                                      (* purity 100d0) hits))
                (let ((chain (longest-operator-chain trimmed)))
                  (if (> chain *detect-max-chain*)
                      (list :detected nil
                            :purity purity
                            :reason (format nil "operator chain too long (~d)" chain))
                      (list :detected t :purity purity :reason "")))))))))

;;; ---------------------------------------------------------------------------
;;; The value model
;;;
;;; One struct with a KIND tag instead of a CLOS hierarchy or a tagged list. The
;;; Rust enum has twelve variants and every operation dispatches on the variant,
;;; so a flat tag plus three generic slots is both smaller and a closer match to
;;; the original's shape than a class per variant would be.
;;; ---------------------------------------------------------------------------

(defstruct (jv (:constructor jv (kind &optional value aux)))
  (kind :undefined :type keyword)
  ;; :bool -> T/NIL | :num -> double-float | :str -> string
  ;; :arr -> list of JV | :native, :constructor -> name string
  ;; :from-source -> body string | :regexp -> source string
  value
  ;; :regexp only -> flags string
  aux)

(defun make-undefined () (jv :undefined))
(defun make-bool (b) (jv :bool (and b t)))
(defun make-num (n) (jv :num n))
(defun make-str (s) (jv :str s))
(defun make-arr (items) (jv :arr items))
(defun make-native (name) (jv :native name))
(defun make-constructor (name) (jv :constructor name))
(defun make-array-iterator () (jv :array-iterator))
(defun make-function-model () (jv :function-model))
(defun make-eval-model () (jv :eval-model))
(defun make-from-source (body) (jv :from-source body))
(defun make-global () (jv :global))
(defun make-regexp (source flags) (jv :regexp source flags))

(defun jv-kind-p (value kind) (eq (jv-kind value) kind))

(defun nan ()
  "A fresh quiet NaN.

Not `(/ 0d0 0d0)`: SBCL's compiler CONSTANT-FOLDS that division and folding
signals FLOATING-POINT-INVALID-OPERATION, so the division idiom fails at compile
time through a `let` as well as directly. Building the IEEE-754 quiet-NaN bit
pattern is an integer operation, which folds to a value with no float trap.

`vovas.engine.number` has the same function but does not export it, so the
pattern is repeated here rather than reaching into that package's internals."
  (sb-kernel:make-double-float #x7ff80000 0))

(defun double-nan-p (value)
  "Not `(/= value value)`: SBCL SIGNALS on that comparison rather than answering
T, turning every NaN check into a crash the moment a NaN arrives."
  (and (floatp value) (sb-ext:float-nan-p value)))

(defun double-infinity-p (value)
  (and (floatp value) (not (null (sb-ext:float-infinity-p value)))))

;;; ---------------------------------------------------------------------------
;;; Coercions
;;;
;;; The four ECMAScript abstract operations the model needs, each with the case
;;; the Rust's match has and nothing more.
;;; ---------------------------------------------------------------------------

(defun canonical-index (key)
  "The array index KEY denotes, or NIL.

Canonical means the round-trip is exact: \"0\" and \"42\" are indices, while
\"00\", \"-1\", \"1.0\" and \"\" are PROPERTY NAMES — JavaScript's own rule,
because `arr[\"00\"]` looks up a plain property and finds nothing. A port that
just called PARSE-INTEGER would answer element 0 for \"00\" and \"-1\" alike.

The round-trip comparison is by TEXT, not by re-parse, and the parse is guarded
because an all-digit key longer than a fixnum would otherwise signal where the
Rust answers None (a failed `parse`)."
  (when (or (zerop (length key))
            (not (every #'digit-char-p key)))
    (return-from canonical-index nil))
  (let ((parsed (ignore-errors (parse-integer key))))
    (when (and parsed (string= key (write-to-string parsed)))
      parsed)))

(defun join-strings (strings separator)
  "Join a list of strings with SEPARATOR.

Not `format ~{~a~^~a~}`: that directive pattern takes the separator from a
SEPARATE argument list, so on two elements it reads the second STRING as a
separator and interleaves both. Written out because the obvious FORMAT idiom is
wrong here and produces plausible-looking output on exactly the small inputs a
probe would use."
  (with-output-to-string (s)
    (loop for item in strings
          for first = t then nil
          do (unless first (write-string separator s))
             (write-string item s))))

(defun array-text (items)
  "Array.prototype.toString for the model: elements joined with \",\", with
undefined and holes rendering as the empty string.

This is a SEPARATE function from DISPLAY-STRING only because it recurses through
it; keeping them apart makes it obvious that the `undefined -> \"\"` rule applies
to array ELEMENTS and not to a top-level undefined, which renders \"undefined\"."
  (format nil "~{~a~^,~}"
          (loop for item in items
                collect (if (jv-kind-p item :undefined)
                            ""
                            (display-string item)))))

(defun display-string (value)
  "JS `String(value)` / implicit ToString for the model — what `+` and the
explicit coercions use.

Every arm is the Rust `to_display_string`. The two that surprise readers:

  - An ARRAY renders through ARRAY-TEXT, so `[]` is \"\" and `[1,[2]]` is
    \"1,2\" — the nested array flattens because its own ToString runs.
  - An empty REGEXP source renders \"/(?:)/\" with the flags appended. V8 prints
    the empty pattern that way rather than \"//\" (which would read as a comment
    to any human and as the empty source to nobody)."
  (ecase (jv-kind value)
    (:undefined "undefined")
    (:bool (if (jv-value value) "true" "false"))
    (:num (to-string (jv-value value)))
    (:str (jv-value value))
    (:arr (array-text (jv-value value)))
    (:native (format nil "function ~a() { [native code] }" (jv-value value)))
    (:constructor (format nil "function ~a() { [native code] }" (jv-value value)))
    (:array-iterator "[object Array Iterator]")
    (:function-model "function Function() { [native code] }")
    (:eval-model "function eval() { [native code] }")
    (:from-source "[object Object]")
    (:global "[object global]")
    (:regexp (let ((source (jv-value value))
                   (flags (or (jv-aux value) "")))
               (if (zerop (length source))
                   (format nil "/(?:)/~a" flags)
                   (format nil "/~a/~a" source flags))))))

(defun is-array (value) (jv-kind-p value :arr))

(defun unwrap-to-primitive (value)
  "ToPrimitive for the model.

Arrays, the iterator, the global and Function results all become STRINGS.
Functions and regexps also become their SOURCE TEXT — that is how `true + [].at`
spells out the function's body, and it is the single most load-bearing coercion
in the whole encoding scheme.

Everything else is returned unchanged, including a number, a boolean and a
string."
  (ecase (jv-kind value)
    (:arr (make-str (array-text (jv-value value))))
    (:array-iterator (make-str "[object Array Iterator]"))
    (:global (make-str "[object global]"))
    (:from-source (make-str "[object Object]"))
    ((:native :constructor :function-model :eval-model :regexp)
     (make-str (display-string value)))
    ((:undefined :bool :num :str) value)))

(defun to-boolean (value)
  "ToBoolean for the model: false, 0, -0, NaN, \"\" and undefined are falsy."
  (ecase (jv-kind value)
    (:undefined nil)
    (:bool (jv-value value))
    (:num (let ((n (jv-value value)))
            (and (not (zerop n)) (not (double-nan-p n)))))
    (:str (plusp (length (jv-value value))))
    ((:arr :native :constructor :array-iterator :function-model :eval-model
      :from-source :global :regexp)
     t)))

(defun jv-to-number (value)
  "ToNumber for the model.

Delegates the STRING grammar to the IMPORTED `vovas.engine.number:to-number`,
which is the ported `js_string_to_number`: trimmed decimal and exponent forms, 0x
hex, Infinity/NaN by name, empty -> 0, anything else NaN. Reimplementing that here
would be a second definition of a function the engine already owns.

NAMED `jv-to-number`, NOT `to-number`. The first draft called it `to-number` and
`in-package`'s `import-from` had already interned that name in this package, so
the definition SHADOWED the import — and the delegate call at the bottom then
recursed into itself. SBCL accepted it with only a style warning about
redefinition, and every `+[]` in the oracle hung instead of answering. A
different name is the fix; `:shadow`-ing the import would work too and would be
harder to see.

Undefined is NaN, not 0 — the distinction `+[]` (0) versus `+[][[]]` (NaN)
rests on."
  (ecase (jv-kind value)
    (:undefined (nan))
    (:bool (if (jv-value value) 1d0 0d0))
    (:num (jv-value value))
    ((:str :arr :native :constructor :array-iterator :function-model :eval-model
      :from-source :global :regexp)
     (to-number (display-string value)))))

(defun js-plus (left right)
  "JS binary `+`: concatenation when either side unwraps to a string, numeric
addition otherwise.

Both operands are unwrapped FIRST, which is what makes `[]+[]` the empty string
rather than a type error, and `+![]+[]` the three characters \"NaN\"."
  (let ((l (unwrap-to-primitive left))
        (r (unwrap-to-primitive right)))
    (if (or (jv-kind-p l :str) (jv-kind-p r :str))
        (make-str (concatenate 'string (display-string l) (display-string r)))
        (make-num (+ (jv-to-number l) (jv-to-number r))))))

(defun value-type-name (value)
  "The `typeof`-ish name the Rust's error messages print."
  (ecase (jv-kind value)
    (:undefined "undefined")
    (:bool "boolean")
    (:num "number")
    (:str "string")
    ((:arr :native :constructor :array-iterator :function-model :eval-model
      :from-source :global :regexp)
     "object")))

;;; ---------------------------------------------------------------------------
;;; Prototype surfaces
;;;
;;; Three tables, one per receiver type, because the Rust has three functions
;;; and the split is semantic: the same key name can mean different methods on
;;; different receivers (`at` exists on both arrays and strings, `constructor`
;;; resolves to three different constructors).
;;; ---------------------------------------------------------------------------

(defun array-member (key)
  (cond
    ((string= key "at") (make-native "at"))
    ((string= key "entries") (make-native "entries"))
    ((string= key "concat") (make-native "concat"))
    ((string= key "join") (make-native "join"))
    ;; Reading an array's constructor yields the Function MODEL, not
    ;; Constructor(\"Array\"): `[].constructor` IS the Function function, which is
    ;; the whole trick the encoder uses to reach Function at all.
    ((string= key "constructor") (make-function-model))
    (t (make-undefined))))

(defun string-member (key)
  (cond
    ((string= key "at") (make-native "at"))
    ((string= key "concat") (make-native "concat"))
    ((string= key "split") (make-native "split"))
    ((string= key "fontcolor") (make-native "fontcolor"))
    ((string= key "italics") (make-native "italics"))
    ((string= key "constructor") (make-constructor "String"))
    (t (make-undefined))))

(defun number-member (key)
  (cond
    ((string= key "toString") (make-native "toString"))
    ((string= key "constructor") (make-constructor "Number"))
    (t (make-undefined))))

;;; ---------------------------------------------------------------------------
;;; escape() and Date()
;;; ---------------------------------------------------------------------------

(defun js-escape (text)
  "The legacy JS `escape()`: A-Za-z0-9 and @*_+-./ pass through, everything
through U+00FF becomes %XX uppercase, and anything above that becomes %uXXXX per
UTF-16 code unit.

`jsnumber.rs` keeps this next to ToNumber because the encoder's percent recipes
(C, D, G, M, T) are built on it; it is not in `vovas.engine.number`'s ported
surface, so this is its only definition.

Surrogate-pair expansion is the reason the loop is explicit rather than a
per-character `format`: an astral character must emit TWO %u escapes."
  (with-output-to-string (out)
    (loop for c across text
          for code = (char-code c)
          do (cond
               ((or (ascii-alphanumeric-p c)
                    (find c "@*_+-./"))
                (write-char c out))
               ((<= code #xFF)
                (format out "%~2,'0X" code))
               ((> code #xFFFF)
                (let ((v (- code #x10000)))
                  (format out "%u~4,'0X" (+ #xD800 (ash v -10)))
                  (format out "%u~4,'0X" (+ #xDC00 (logand v #x3FF)))))
               (t
                (format out "%u~4,'0X" code))))))

(defun js-date-string ()
  "`Date()` called as a function: V8's UTC format string.

The Rust reads the host clock. The shipped engine cannot: wasm32 has no clock,
and asking for one PANICS (\"time not implemented on this platform\"). That means
this function is UNREACHABLE from the oracle — measured, `Function(\"return
Date\")()()` traps the bridge rather than answering — so its exact output is
unpinnable and no gate case can cover it. It is ported anyway because dropping
it would make `Function(\"return Date\")()` fall into the capture arm and answer a
payload where the engine traps.

The weekday comes from the day count, not from a date library: 1970-01-01 was a
Thursday (index 4), so day N lands on (N + 4) mod 7."
  (let* ((now (max (- (get-universal-time) 2208988800) 0))
         (days (floor now 86400))
         (names #("Sun" "Mon" "Tue" "Wed" "Thu" "Fri" "Sat"))
         (weekday (aref names (mod (+ days 4) 7))))
    (multiple-value-bind (year month day hour minute second)
        (vovas.engine.zip:civil-from-unix-secs now)
      ;; `civil-from-unix-secs` lives in zip.lisp because the DOS timestamps need
      ;; it too. Reusing it rather than copying Hinnant's algorithm a second time
      ;; is the same rule the CONTRACT applies to limits: one definition.
      (format nil "~a ~2,'0d ~2,'0d ~d ~2,'0d:~2,'0d:~2,'0d GMT+0000 (Coordinated Universal Time)"
              weekday month day year hour minute second))))

;;; ---------------------------------------------------------------------------
;;; String literal unescaping
;;;
;;; The Rust runs one regex with five alternatives over the raw literal. Written
;;; as a scanner here because the alternative ORDER is the semantics and a
;;; regex's leftmost-first alternation is easier to get subtly wrong than to
;;; write out:
;;;
;;;   \\uXXXX   four hex digits
;;;   \\xHH     two hex digits
;;;   \\ooo     one to three OCTAL digits, greedy
;;;   \\<CR|LF> a line continuation, which contributes NOTHING
;;;   \\<any>   the character itself, after the five named escapes below
;;;
;;; A trailing lone backslash matches no alternative and is left alone, which is
;;; what `replace_all` does with an unmatched prefix.
;;; ---------------------------------------------------------------------------

(defparameter *literal-escapes*
  (list (cons "n" #\Newline)          ; \n
        (cons "r" #\Return)           ; \r
        (cons "t" #\Tab)              ; \t
        (cons "b" #\Backspace)        ; \b
        (cons "f" (code-char 12))     ; \f  form feed — no portable CL name
        (cons "v" (code-char 11))     ; \v  vertical tab — no portable CL name
        (cons "0" (code-char 0)))     ; \0  unreachable; see below
  "The single-character escapes the Rust's group 5 maps.

`f` and `v` are built from CODE POINTS because CL has no portable name for them
(SBCL has neither #\\FormFeed nor a vertical-tab character name), and the Rust's
table is about code points anyway.

`\\0` is UNREACHABLE: the octal alternative matches `0` first and answers the same
NUL. It is listed so the table reads as the Rust's match rather than as the
subset of it that happens to fire.")

(defun ascii-alphanumeric-p (c)
  "A-Z, a-z, 0-9 only.

Not `alphanumericp`: the standard leaves that implementation-defined above
ASCII, and `escape()`'s pass-through set is explicitly ASCII in the Rust. An
implementation that extended it would silently stop escaping an accented
character the encoder expects percent-encoded."
  (or (char<= #\a c #\z) (char<= #\A c #\Z) (char<= #\0 c #\9)))

(defun hex-code (text start end)
  "The integer value of TEXT[START:END] as hexadecimal, or NIL if any character
is not a hex digit. The Rust uses `unwrap_or(0)`; NIL is used here so a malformed
escape can be distinguished from `\\u0000`, and `unescape-literal` maps NIL to
the replacement character exactly as `char::from_u32(0)` would NOT."
  (let ((value 0))
    (loop for i from start below end
          for digit = (digit-char-p (char text i) 16)
          do (if digit
                 (setf value (+ (* value 16) digit))
                 (return-from hex-code nil)))
    value))

(defun octal-code (text start end)
  (let ((value 0))
    (loop for i from start below end
          do (setf value (+ (* value 8) (- (char-code (char text i)) (char-code #\0)))))
    value))

(defun code-char-or-replacement (code)
  "`char::from_u32(code)`, with the replacement character where Rust answers
None. Rust refuses SURROGATES and anything above U+10FFFF, and SBCL's CODE-CHAR
refuses the same surrogates, so the two agree on which codes fail."
  (or (ignore-errors (code-char code)) (code-char #xFFFD)))

(defun unescape-literal (raw)
  "Decode the escapes in a `return \"...\"` body, as the Rust's ESCAPE regex does."
  (let ((n (length raw))
        (i 0))
    (with-output-to-string (out)
      (loop while (< i n)
            do (let ((c (char raw i)))
                 (if (and (char= c #\\) (< (1+ i) n))
                     (let ((next (char raw (1+ i))))
                       (cond
                         ;; \uXXXX
                         ((and (char-equal next #\u)
                               (<= (+ i 6) n)
                               (hex-code raw (+ i 2) (+ i 6)))
                          (write-char (code-char-or-replacement
                                       (hex-code raw (+ i 2) (+ i 6)))
                                      out)
                          (incf i 6))
                         ;; \xHH
                         ((and (char-equal next #\x)
                               (<= (+ i 4) n)
                               (hex-code raw (+ i 2) (+ i 4)))
                          (write-char (code-char-or-replacement
                                       (hex-code raw (+ i 2) (+ i 4)))
                                      out)
                          (incf i 4))
                         ;; \ooo, one to three octal digits
                         ((digit-char-p next 8)
                          (let ((end (1+ i)))
                            (loop while (and (< end n)
                                             (< (- end (1+ i)) 3)
                                             (digit-char-p (char raw end) 8))
                                  do (incf end))
                            (write-char (code-char-or-replacement
                                         (octal-code raw (1+ i) end))
                                        out)
                            (setf i end)))
                         ;; line continuation: contributes nothing
                         ((or (char= next #\Newline) (char= next #\Return))
                          (incf i 2))
                         (t
                          (let ((mapped (assoc (string next) *literal-escapes*
                                               :test #'string=)))
                            (write-char (if mapped (cdr mapped) next) out))
                          (incf i 2))))
                     (progn
                       (write-char c out)
                       (incf i))))))))

;;; ---------------------------------------------------------------------------
;;; The interpreter
;;;
;;; A struct, not a closure, because the Rust hands `&mut self` to every method
;;; and the position/budget/capture triple must be shared across the recursion.
;;; ---------------------------------------------------------------------------

(defstruct (interp (:constructor make-interp (source)))
  (source "" :type string)
  (pos 0 :type fixnum)
  (nodes 0)
  ;; `capture` in the Rust is Option<String>, so "no capture yet" and "captured
  ;; the empty string" are DIFFERENT states. A bare NIL would collapse them and
  ;; `eval()` with no argument captures "". Hence the flag.
  (capture nil)
  (captured-p nil))

(defun ip-peek (ip)
  "The character at POS, or NIL at end of input. Only safe because NIL is not a
character: end-of-input can never be confused with a real character."
  (let ((pos (interp-pos ip)))
    (when (< pos (length (interp-source ip)))
      (char (interp-source ip) pos))))

(defun rust-whitespace-p (c)
  "Rust's `char::is_whitespace`, which is the Unicode White_Space property.

Written out rather than reused from `vovas.engine.util:js-whitespace-p` because
the two sets are NOT the same and the difference is reachable: JavaScript's `\\s`
(and so `js-whitespace-p`) includes U+FEFF, the zero-width no-break space, which
Rust's `is_whitespace` does not. A scanner skipping U+FEFF would consume a
character the engine's parser rejects, changing a refusal into an answer."
  (let ((code (char-code c)))
    (or (<= code 32)                    ; TAB, LF, VT, FF, CR, space
        (= code #x85)                   ; NEXT LINE
        (= code #xA0)                   ; NO-BREAK SPACE
        (= code #x1680)                 ; OGHAM SPACE MARK
        (<= #x2000 code #x200A)         ; EN QUAD .. HAIR SPACE
        (= code #x2028)                 ; LINE SEPARATOR
        (= code #x2029)                 ; PARAGRAPH SEPARATOR
        (= code #x202F)                 ; NARROW NO-BREAK SPACE
        (= code #x205F)                 ; MEDIUM MATHEMATICAL SPACE
        (= code #x3000))))              ; IDEOGRAPHIC SPACE

(defun ip-skip-noise (ip)
  "Skip whitespace between tokens.

JSFuck's own alphabet holds no whitespace, so this only ever consumes cosmetic
separators in hand-written input — but the SET matters for refusals: an input
whose only non-charset character is U+FEFF must be REFUSED, so U+FEFF must not be
skipped."
  (loop for c = (ip-peek ip)
        while (and c (rust-whitespace-p c))
        do (incf (interp-pos ip))))

(defun ip-error (ip format-control &rest args)
  "Signal a parse error with the position prefix the Rust's JsfuckError carries.
`decode-jsfuck` catches every condition, so the MESSAGE never reaches a caller —
but a probe or a REPL sees it, and a message without the offset would make an
unexpected refusal impossible to locate."
  (error "jsfuck decode error at ~d: ~a"
         (interp-pos ip)
         (apply #'format nil format-control args)))

(defun ip-expect (ip ch)
  (ip-skip-noise ip)
  (unless (and (ip-peek ip) (char= (ip-peek ip) ch))
    (ip-error ip "expected ~a" ch))
  (incf (interp-pos ip)))

(defun ip-charge-node (ip)
  "Spend one unit of the parse budget, or refuse.

The budget is checked in BOTH parse-primary and parse-expression in the Rust —
that is not redundancy: a chain of `a+a+a` pays in parse-expression while a
chain of `((((a))))` pays in parse-primary, so one counter in one place would
leave the other shape unbounded."
  (incf (interp-nodes ip))
  (when (> (interp-nodes ip) *max-parse-nodes*)
    (ip-error ip "expression budget exceeded")))

(defun ip-check-depth (ip depth)
  (when (> depth *max-parse-depth*)
    (ip-error ip "nesting too deep")))

(defun parse-primary (ip depth)
  "Parse one primary: a group, an array literal, `!<primary>` or `+<primary>`.

Note that `!` and `+` recurse into PARSE-PRIMARY, not parse-expression — so
`!a+b` is `(!a)+b`, and a prefix operator binds tighter than `+`. That is real
JavaScript precedence and it is why the encoder can nest unary runs at all."
  (ip-charge-node ip)
  (ip-check-depth ip depth)
  (ip-skip-noise ip)
  (let ((c (ip-peek ip)))
    (cond
      ((null c) (ip-error ip "unexpected end of input"))
      ((char= c #\()
       (incf (interp-pos ip))
       (let ((value (parse-expression ip (1+ depth))))
         (ip-expect ip #\))
         value))
      ((char= c #\[)
       (incf (interp-pos ip))
       (let ((elements '()))
         (ip-skip-noise ip)
         (if (and (ip-peek ip) (char= (ip-peek ip) #\]))
             (progn (incf (interp-pos ip)) (make-arr '()))
             (progn
               (loop
                 (push (parse-expression ip (1+ depth)) elements)
                 (ip-skip-noise ip)
                 (if (and (ip-peek ip) (char= (ip-peek ip) #\,))
                     (progn
                       (incf (interp-pos ip))
                       (ip-skip-noise ip)
                       ;; A trailing comma is tolerated. JSFuck never emits one,
                       ;; but the Rust accepts it and refusing would be a
                       ;; gratuitous divergence.
                       (when (and (ip-peek ip) (char= (ip-peek ip) #\]))
                         (return)))
                     (return)))
               (ip-expect ip #\])
               (make-arr (nreverse elements))))))
      ((char= c #\!)
       (incf (interp-pos ip))
       (make-bool (not (to-boolean (parse-primary ip (1+ depth))))))
      ((char= c #\+)
       (incf (interp-pos ip))
       (make-num (jv-to-number (parse-primary ip (1+ depth)))))
      (t
       (ip-error ip "unexpected character ~s" c)))))

(defun parse-suffixes (ip value depth)
  "Apply member reads and calls left to right, remembering the CALL RECEIVER.

`receiver` is the receiver of the most recent MEMBER READ, and it is consumed by
the very next call. That is how `this` is bound: `[][\"at\"](0)` calls `at` with
the empty array as `this`, while `([])[\"at\"](0)` does the same. A port that
carried the receiver across unrelated calls would bind `this` to the wrong
object on every chained expression.

The receiver is CLEARED by `take` on the call, so `f(1)(2)` binds `this` only for
the first call — exactly the Rust's `receiver.take()`."
  (let ((receiver nil))
    (loop
      (ip-skip-noise ip)
      (let ((c (ip-peek ip)))
        (cond
          ((and c (char= c #\[))
           (incf (interp-pos ip))
           (let ((key (parse-expression ip (1+ depth))))
             (ip-expect ip #\])
             (setf receiver value)
             (setf value (read-member ip value key))))
          ((and c (char= c #\())
           (incf (interp-pos ip))
           (let ((args '()))
             (ip-skip-noise ip)
             (unless (and (ip-peek ip) (char= (ip-peek ip) #\)))
               (loop
                 (push (parse-expression ip (1+ depth)) args)
                 (ip-skip-noise ip)
                 (if (and (ip-peek ip) (char= (ip-peek ip) #\,))
                     (incf (interp-pos ip))
                     (return))))
             (ip-expect ip #\))
             (setf value (call-value ip value (nreverse args) receiver))
             (setf receiver nil)))
          (t (return value)))))))

(defun parse-expression (ip depth)
  "Parse a primary with its suffixes, then any `+` chain.

`depth` is NOT incremented for the right operand of `+`: a chain is iterative in
the Rust, and incrementing would make a 5000-term sum read as 5000-deep nesting
and trip the depth budget that exists for parentheses."
  (ip-charge-node ip)
  (let ((value (parse-suffixes ip (parse-primary ip depth) depth)))
    (loop
      (ip-skip-noise ip)
      (let ((c (ip-peek ip)))
        (unless (and c (char= c #\+))
          (return value))
        (incf (interp-pos ip))
        (let ((right (parse-suffixes ip (parse-primary ip depth) depth)))
          (setf value (js-plus value right)))))))

(defun read-member (ip base key-expression)
  "Read BASE[KEY] with JavaScript's semantics for the model."
  (let ((key (display-string (unwrap-to-primitive key-expression))))
    (when (jv-kind-p base :global)
      (return-from read-member (read-global-member key)))
    (ecase (jv-kind base)
      (:undefined
       (ip-error ip "member access on ~a for key ~s" (display-string base) key))
      (:arr
       (let ((index (canonical-index key)))
         (if index
             (or (nth index (jv-value base)) (make-undefined))
             (array-member key))))
      (:str
       (let ((index (canonical-index key)))
         (if index
             (let ((text (jv-value base)))
               (if (< index (length text))
                   (make-str (string (char text index)))
                   (make-undefined)))
             (string-member key))))
      (:num (number-member key))
      (:bool (if (string= key "constructor")
                 (make-constructor "Boolean")
                 (make-undefined)))
      ((:native :constructor)
       (cond
         ((string= key "constructor") (make-function-model))
         ((string= key "name") (make-str (jv-value base)))
         (t (make-undefined))))
      (:regexp
       (cond
         ((string= key "constructor") (make-constructor "RegExp"))
         ((string= key "source") (make-str (jv-value base)))
         (t (make-undefined))))
      ((:array-iterator :from-source) (make-undefined))
      ((:function-model :eval-model)
       (cond
         ((string= key "constructor") (make-function-model))
         ((string= key "name")
          (make-str (if (jv-kind-p base :function-model) "Function" "eval")))
         (t (make-undefined))))
      (:global (make-undefined)))))

(defun read-global-member (key)
  "Reading a property of the global object.

The list is exactly the encoder's reach: `this` gives it a way to name
everything, and the seven builtins plus undefined/NaN/Infinity are what its
recipes spell. Anything else is undefined rather than an error, because the
global object genuinely answers undefined for an unknown property."
  (cond
    ((string= key "eval") (make-eval-model))
    ((string= key "Function") (make-function-model))
    (t
     (cond
       ((string= key "Array") (make-constructor "Array"))
       ((string= key "Number") (make-constructor "Number"))
       ((string= key "String") (make-constructor "String"))
       ((string= key "Boolean") (make-constructor "Boolean"))
       ((string= key "RegExp") (make-constructor "RegExp"))
       ((string= key "Date") (make-native "Date"))
       ((string= key "escape") (make-native "escape"))
       ((string= key "undefined") (make-undefined))
       ((string= key "NaN") (make-num (nan)))
       ((string= key "Infinity")
        (make-num sb-ext:double-float-positive-infinity))
       (t (make-undefined))))))

;;; ---------------------------------------------------------------------------
;;; Calls
;;; ---------------------------------------------------------------------------

(defparameter *return-name-scanner*
  (cl-ppcre:create-scanner "^return\\s+([A-Za-z_$][\\w$]*)$")
  "`^return\\s+([A-Za-z_$][\\w$]*)$` — a body that returns a bare identifier.

Anchored at both ends, so `return a` matches but `return a + b` does not and
falls through to the payload arm. `\\w` is the Unicode word class in both Rust's
regex and cl-ppcre, so an identifier with an accented letter matches in both —
irrelevant to real JSFuck, and a divergence a narrower class would introduce.")

(defparameter *return-regex-scanner*
  (cl-ppcre:create-scanner "^return\\s*/(.*)/([a-z]*)\\s*$")
  "`^return\\s*/(.*)/([a-z]*)\\s*$` — a body that returns a regex LITERAL.

`.` does not cross a newline in either implementation (cl-ppcre's default is the
same as Rust's), and `.*` is greedy so the LAST slash decides: `return/a/b/g`
gives source \"a/b\" and flags \"g\", which is what the JS grammar does too.")

(defparameter *return-quoted-scanner*
  (cl-ppcre:create-scanner "^return\\s*\"((?:[^\"\\\\]|\\\\.)*)\"\\s*$")
  "`^return\\s*\"((?:[^\"\\\\]|\\\\.)*)\"\\s*$` — a body that returns a quoted
STRING. The inner group allows any escaped pair, so `return \"a\\\"b\"` captures
`a\\\"b` and UNESCAPE-LITERAL decodes it. This is the one body shape that answers a
VALUE instead of capturing, and it is the branch a naive seam-capture port
misses.")

(defun call-value (ip callee args receiver)
  "Call CALLEE with ARGS and RECEIVER (the `this` of a method call)."
  (ecase (jv-kind callee)
    (:function-model
     ;; Function(a, b, ...) joins every argument's primitive text with \",\",
     ;; which is JavaScript's own rule for multiple parameters and is what lets
     ;; `Function(\"a\",\"return a\")` round-trip through the capture arm.
     (make-from-source
      (format nil "~{~a~^,~}"
              (loop for a in args
                    collect (display-string (unwrap-to-primitive a))))))
    (:eval-model
     ;; eval(payload) is THE capture point. Record, never execute: this port has
     ;; no host engine and running the payload would be a remote-code hole in
     ;; the middle of a decoder. A missing argument captures \"\", not nil —
     ;; `unwrap_or_default()` in the Rust.
     (let ((text (if args
                     (display-string (unwrap-to-primitive (car args)))
                     "")))
       (setf (interp-capture ip) text
             (interp-captured-p ip) t)
       (make-undefined)))
    (:from-source (call-from-source ip (jv-value callee)))
    ((:native :constructor) (invoke-native ip callee args receiver))
    ((:undefined :bool :num :str :arr :array-iterator :global :regexp)
     (ip-error ip "call target is ~a, not a function" (value-type-name callee)))))

(defun call-from-source (ip body)
  "Call a `Function(body)` result.

Three recognised body shapes answer a VALUE; everything else is PAYLOAD and is
captured. The order is the Rust's and it matters: `return this` could also match
the generic payload arm, and answering the global object is the whole point of
that shape (it is how the encoder reaches every builtin)."
  (multiple-value-bind (whole groups) (cl-ppcre:scan-to-strings *return-name-scanner* body)
    (declare (ignore whole))
    (when groups
      ;; scan-to-strings answers GROUPS as a simple-vector, not a list.
      (let ((name (aref groups 0)))
        (cond
          ((string= name "this") (return-from call-from-source (make-global)))
          ((string= name "eval") (return-from call-from-source (make-eval-model)))
          (t
           (return-from call-from-source
             (cond
               ((string= name "Array") (make-constructor "Array"))
               ((string= name "Number") (make-constructor "Number"))
               ((string= name "String") (make-constructor "String"))
               ((string= name "Boolean") (make-constructor "Boolean"))
               ((string= name "RegExp") (make-constructor "RegExp"))
               ((string= name "Date") (make-native "Date"))
               ((string= name "escape") (make-native "escape"))
               ((string= name "NaN") (make-num (nan)))
               ((string= name "Infinity")
                (make-num sb-ext:double-float-positive-infinity))
               (t (ip-error ip "unknown builtin ~s in fromSource" name)))))))))
  (multiple-value-bind (whole groups) (cl-ppcre:scan-to-strings *return-regex-scanner* body)
    (declare (ignore whole))
    (when groups
      (return-from call-from-source
        (make-regexp (aref groups 0) (aref groups 1)))))
  (multiple-value-bind (whole groups) (cl-ppcre:scan-to-strings *return-quoted-scanner* body)
    (declare (ignore whole))
    (when groups
      (return-from call-from-source (make-str (unescape-literal (aref groups 0))))))
  ;; Payload code: capture instead of executing.
  (setf (interp-capture ip) body
        (interp-captured-p ip) t)
  (make-undefined))

(defun split-string (text separator)
  "JS `String.prototype.split(separator)` for a non-empty separator: the parts
BETWEEN occurrences, with the leading and trailing empty parts kept.

`\"abc\".split(\"b\")` -> (\"a\" \"c\"), `\"\".split(\",\")` -> (\"\"), and a
separator that never occurs gives the whole string as one part. CL has no
substring split, and `cl-ppcre:split` differs on the empty-string input, so the
scan is explicit."
  (let ((parts '())
        (start 0)
        (sep-length (length separator)))
    (loop
      (let ((hit (search separator text :start2 start)))
        (unless hit
          (push (subseq text start) parts)
          (return))
        (push (subseq text start hit) parts)
        (setf start (+ hit sep-length))))
    (nreverse parts)))

(defun invoke-native (ip callee args receiver)
  "Call a modelled builtin.

`this` is the receiver UNWRAPPED TO A PRIMITIVE — and that is the fidelity trap
described in the file header: an array receiver becomes its string form, so
`is-array` below is never true and the array branches of `at`, `join` and
`concat` are dead. Measured against the shipped engine, `[][\"join\"]()` refuses
rather than joining, and this port reproduces the refusal.

The index arithmetic in `at` is the ECMAScript `Array.prototype.at` rule —
negative counts from the end — and it is applied to the STRING branch because
that is the only branch reached. A fractional index and NaN both answer
undefined rather than truncating: `at` requires an integer, and truncating would
make `[].at(0.5)` answer where the engine refuses.

THE BOUND IS INCLUSIVE. Rust writes `(0.0..len).contains(&idx)`, a half-open
range, so 0 IS in range and len is not. An earlier draft of this port wrote
`(< 0d0 idx len)`, which excluded 0 — and because the only observable effect is
that `[].at(0)` and `\"...\".at(0)` return undefined, the whole encoder's
character-lookup idiom (`(false+\"\")[0]` for the letter `f`) collapsed to null.
The oracle caught it: `falseIndexZero` and `strAtZero` both failed."
  (let ((name (jv-value callee))
        (this (if receiver
                  (unwrap-to-primitive receiver)
                  (make-undefined))))
    (cond
      ;; ---- at -----------------------------------------------------------
      ((string= name "at")
       (let ((index (if args (jv-to-number (car args)) (nan))))
         (cond
           ((double-nan-p index) (make-undefined))
           ((is-array this)
            ;; Unreachable for the reason in the docstring; kept because the
            ;; Rust keeps it and deleting a branch changes nothing observable.
            (let* ((items (jv-value this))
                   (len (coerce (length items) 'double-float))
                   (idx (if (minusp index) (+ len index) index)))
              (if (or (not (<= 0d0 idx (1- len)))
                      (/= (nth-value 1 (ffloor idx)) 0d0))
                  (make-undefined)
                  (or (nth (truncate idx) items) (make-undefined)))))
           (t
            (let* ((text (display-string this))
                   (len (coerce (length text) 'double-float))
                   (idx (if (minusp index) (+ len index) index)))
              (if (or (not (<= 0d0 idx (1- len)))
                      (/= (nth-value 1 (ffloor idx)) 0d0))
                  (make-undefined)
                  (make-str (string (char text (truncate idx))))))))))
      ;; ---- entries ------------------------------------------------------
      ((string= name "entries") (make-array-iterator))
      ;; ---- concat -------------------------------------------------------
      ((string= name "concat")
       (if (is-array this)
           (let ((out (copy-list (jv-value this))))
             (dolist (a args)
               (if (is-array a)
                   (setf out (append out (jv-value a)))
                   (setf out (append out (list a)))))
             (make-arr out))
           (make-str
            (with-output-to-string (s)
              (write-string (display-string this) s)
              (dolist (a args)
                (write-string (display-string (unwrap-to-primitive a)) s))))))
      ;; ---- join ---------------------------------------------------------
      ((string= name "join")
       (let ((sep (if args
                      (display-string (unwrap-to-primitive (car args)))
                      ",")))
         (if (is-array this)
             (make-str
              (join-strings
               (loop for item in (jv-value this)
                     collect (if (jv-kind-p item :undefined)
                                 ""
                                 (display-string item)))
               sep))
             (ip-error ip "join on non-array receiver"))))
      ;; ---- split --------------------------------------------------------
      ((string= name "split")
       (let* ((text (display-string this))
              (sep (if args
                       (display-string (unwrap-to-primitive (car args)))
                       "")))
         (if (zerop (length sep))
             ;; An empty separator splits into CHARACTERS, which is the encoder's
             ;; favourite way to get one character at a time.
             (make-arr (loop for c across text collect (make-str (string c))))
             (make-arr (loop for part in (split-string text sep)
                             collect (make-str part))))))
      ;; ---- fontcolor ----------------------------------------------------
      ((string= name "fontcolor")
       (let ((color (if args
                        (display-string (unwrap-to-primitive (car args)))
                        "undefined")))
         (make-str (format nil "<font color=\"~a\">~a</font>"
                           (replace-char-with-string color #\" "&quot;")
                           (display-string this)))))
      ;; ---- italics ------------------------------------------------------
      ((string= name "italics")
       (make-str (format nil "<i>~a</i>" (display-string this))))
      ;; ---- toString(radix) ----------------------------------------------
      ((string= name "toString")
       (let ((radix (if args (jv-to-number (car args)) (nan))))
         (if (and (not (double-nan-p radix))
                  (<= 2d0 radix 36d0)
                  (= (nth-value 1 (ffloor radix)) 0d0))
             ;; The RECEIVER decides which number: a string receiver is
             ;; ToNumber'd, everything else is too (the Rust's arms all funnel
             ;; into `to_number`), so one expression covers all of them.
             (make-str (to-radix-string (jv-to-number this) (truncate radix)))
             (make-str (display-string this)))))
      ;; ---- escape -------------------------------------------------------
      ((string= name "escape")
       (make-str (js-escape
                  (display-string
                   (unwrap-to-primitive (or (car args) (make-undefined)))))))
      ;; ---- Date ---------------------------------------------------------
      ((string= name "Date") (make-str (js-date-string)))
      ;; ---- constructors -------------------------------------------------
      ((string= name "Array") (make-arr '()))
      ((string= name "Number")
       (make-num (jv-to-number (or (car args) (make-undefined)))))
      ((string= name "String")
       (make-str (display-string
                  (unwrap-to-primitive (or (car args) (make-undefined))))))
      ((string= name "Boolean")
       (make-bool (to-boolean (or (car args) (make-undefined)))))
      ((string= name "RegExp")
       (make-regexp (if args
                        (display-string (unwrap-to-primitive (car args)))
                        "")
                    (if (cadr args)
                        (display-string (unwrap-to-primitive (cadr args)))
                        "")))
      (t (ip-error ip "unmodeled builtin ~s" name)))))

(defun replace-char-with-string (text from to)
  "Replace every occurrence of the CHARACTER FROM in TEXT with the STRING TO.

`substitute` cannot do this: it maps character to CHARACTER, so `&quot;` (six
characters) is not representable. A manual scan is the only option, and it has to
be a scan rather than `cl-ppcre:regex-replace-all` because FROM is a literal
character, not a pattern.

This exists for exactly one call site — `fontcolor`'s HTML-escaped argument —
which is the only place the model rewrites its own output."
  (with-output-to-string (s)
    (loop for c across text
          do (if (char= c from)
                 (write-string to s)
                 (write-char c s)))))

;;; ---------------------------------------------------------------------------
;;; The two entry points
;;; ---------------------------------------------------------------------------

(defun interpret-jsfuck (source)
  "Evaluate SOURCE as JSFuck.

Answers `(values value captured-string captured-p)` or NIL on any error. The
whole parse is wrapped because `decode-jsfuck` treats every failure identically —
null, not captured — so a condition escaping here would be a behaviour the Rust
does not have. Catching a host STORAGE-CONDITION (stack exhaustion on
adversarially deep nesting) is the one place this differs internally from the
Rust, which has no host stack to exhaust; the answer on the wire is the same."
  (handler-case
      (let ((ip (make-interp source)))
        (let ((value (parse-expression ip 0)))
          (ip-skip-noise ip)
          (when (< (interp-pos ip) (length (interp-source ip)))
            (ip-error ip "trailing input"))
          (values value (interp-capture ip) (interp-captured-p ip))))
    ((or error storage-condition) () nil)))

(defun decode-jsfuck (source)
  "Decode SOURCE, answering `(:value STRING-OR-NIL :captured BOOLEAN)`.

The precedence is the whole function:

  1. If evaluation reached a Function/eval SEAM, the captured payload wins and
     `captured` is true — even when the expression also produced a value, and
     even when the payload is the empty string.
  2. Otherwise a STRING result is the answer with `captured` false. That is the
     expression case: `[]+[]` answers \"\".
  3. Any other value (a number, an array, undefined, a constructor) answers
     `:value NIL` with `captured` false — NOT its string form. This is why
     `[][\"join\"]()` and `[[]][\"at\"](0)` both read as null on the wire even
     though the first is an error and the second is a number: the Rust only ever
     surfaces a Str result, and widening that would be a divergence.
  4. A parse error answers `:value NIL :captured NIL`-ish — false, same shape.

`captured` is a real boolean, never a truthy value, because the panel serialises
it straight to JSON."
  (multiple-value-bind (value capture captured-p) (interpret-jsfuck source)
    (cond
      (captured-p (list :value capture :captured t))
      ((and value (jv-kind-p value :str))
       (list :value (jv-value value) :captured nil))
      (t (list :value nil :captured nil)))))
