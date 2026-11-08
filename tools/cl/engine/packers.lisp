;;;; packers.lisp — the packer/obfuscator tier, ported from packers.rs.
;;;;
;;;; Four unrelated things share this file in the Rust, and they share it here
;;;; for the same reason: they are the layers that decode by PURE STATIC
;;;; REWRITING, so none of them may execute the input.
;;;;
;;;;   1. Dean Edwards' p.a.c.k.e.r — read the argument tuple off the source,
;;;;      substitute the word list, repeat while the output is still packed.
;;;;   2. The esoteric shells (aaencode / jjencode / jsfiretruck) — detected and
;;;;      REFUSED, never decoded, because decoding them means running them.
;;;;   3. obfuscator.io's marker census — a scored set of regex witnesses.
;;;;   4. The string-array + rotator rebuild with static decoder inlining.
;;;;
;;;; INDEX UNITS. packers.rs walks BYTES (`text.as_bytes()`) and slices
;;;; `&text[a..b]`. Every delimiter it looks for is ASCII, and UTF-8 has the
;;;; property that a multi-byte sequence contains no ASCII byte, so every
;;;; position it reaches is a char boundary. This port walks CHARACTERS:
;;;; `char`/`subseq` replace `b[i]`/`&text[a..b]`, and the same property holds
;;;; more strongly, because no character is a fragment of another. Every index
;;;; crossing this module's boundary is therefore a CHARACTER index — a real,
;;;; documented difference from the Rust for non-ASCII input, invisible for the
;;;; oracle's inputs.
;;;;
;;;; REGEX. cl-ppcre is the engine because Rust's `regex` crate is the
;;;; original: no lookaround, no backreferences, leftmost-first alternation,
;;;; lazy quantifiers, and cl-ppcre supports that same subset. Every
;;;; `Regex::new` site below is compiled ONCE at load time into a
;;;; `defparameter` — that is the LazyLock intent, spelled the only way a Lisp
;;;; can spell it. Four spellings needed translating, and each is called out at
;;;; the site where it matters:
;;;;
;;;;   - `\s` in Rust is Unicode White_Space; cl-ppcre's `\s` is the ASCII
;;;;     subset and MISSES U+00A0. `+re-space+` is the Unicode class.
;;;;   - `[\s\S]` (any character, newline included) is `(?s:.)` here.
;;;;   - `$` in Rust means END OF TEXT; cl-ppcre's `$` also matches before one
;;;;     trailing newline. The anchored patterns use `\z` / `\A`.
;;;;   - `\d` in Rust is Unicode Nd, but the only consumer of it
;;;;     (`parse-int-literal`) rejects non-ASCII digits anyway, so `[0-9]` is
;;;;     used: a Unicode digit would otherwise match a number that then fails to
;;;;     parse, changing a non-match into a match.
;;;;
;;;; `\w` is left verbatim: both engines mean the Unicode word class.

(defpackage :vovas.engine.packers
  (:use :cl)
  (:import-from :vovas.engine.util #:regex-escape #:utf16-prefix)
  (:export
   ;; the four oracle-gated entry points
   #:detect-packer
   #:unpack-packer
   #:detect-string-array
   #:transform-string-array
   ;; the refusals: these never decode, they only say why they will not
   #:detect-aaencode
   #:detect-jjencode
   #:detect-jsfiretruck
   #:detect-obfuscator-io))

(in-package :vovas.engine.packers)

;;; ---------------------------------------------------------------------------
;;; Constants
;;; ---------------------------------------------------------------------------

(defparameter +packer-signature+ "function(p,a,c,k,e,"
  "The 20 bytes that identify Dean Edwards' packer. Not the more famous
`eval(function(p,a,c,k,e,d)` prefix: the call may be wrapped in `eval(...` or
assigned to a variable first, so the argument-tuple signature is the one that
cannot be moved out from under the scanner.")

(defparameter +max-packer-layers+ 32
  "Repacked output nests. 32 is a stopping rule, not an expectation: a packer bug
that made the output re-detectable would otherwise loop forever.")

(defparameter +max-rotations+ 4096
  "The rotator search is a bounded simulation, so a pivot no rotation can satisfy
terminates instead of spinning.")

(defparameter +i64-max+ (1- (ash 1 63))
  "Rust `i64::MAX`, the ceiling `from_str_radix` and `str::parse` enforce.")

;;; ---------------------------------------------------------------------------
;;; Whitespace: two different sets, named so they cannot be confused
;;; ---------------------------------------------------------------------------

(declaim (inline ascii-js-space-p))
(defun ascii-js-space-p (c)
  "`is_space_byte` / `is_ascii_js_space`: space, tab, LF, VT, FF, CR — the set
the packer *scanner* skips. Deliberately not CL's `whitespace`: the six agree on
ASCII, but naming the set after the function it mirrors keeps it distinguishable
from the two other whitespace notions in this file."
  (let ((code (char-code c)))
    (or (= code 32) (<= 9 code 13))))

(defparameter +unicode-white-space-codes+
  (append (list #x09 #x0A #x0B #x0C #x0D #x20 #x85 #xA0 #x1680)
          (loop for c from #x2000 to #x200A collect c)
          (list #x2028 #x2029 #x202F #x205F #x3000))
  "Unicode White_Space, which is what Rust's `str::trim` removes — NOT the same
set as JavaScript's `\\s` (`vovas.engine.util:js-whitespace-p`). U+0085 is
White_Space but not JS `\\s`; U+FEFF is JS `\\s` but not White_Space. packers.rs
calls `str::trim`, so `js-trim` would be the wrong helper in this module.")

(defun white-space-code-p (code)
  (member code +unicode-white-space-codes+))

(defun rust-trim (text)
  "Rust `str::trim`."
  (let* ((n (length text))
         (start (loop for i from 0 below n
                      while (white-space-code-p (char-code (char text i)))
                      finally (return i)))
         (end (loop for i from n downto (1+ start)
                    while (white-space-code-p (char-code (char text (1- i))))
                    finally (return i))))
    (subseq text start end)))

(defun rust-trim-tail (text)
  "Rust `str::trim_end`."
  (let ((end (length text)))
    (loop while (and (plusp end)
                     (white-space-code-p (char-code (char text (1- end)))))
          do (decf end))
    (subseq text 0 end)))

;;; ---------------------------------------------------------------------------
;;; Character classification
;;; ---------------------------------------------------------------------------

(declaim (inline ascii-digit-p ascii-upper-p ascii-lower-p token-char-p name-char-p))
(defun ascii-digit-p (c) (let ((k (char-code c))) (<= 48 k 57)))
(defun ascii-upper-p (c) (let ((k (char-code c))) (<= 65 k 90)))
(defun ascii-lower-p (c) (let ((k (char-code c))) (<= 97 k 122)))

(defun token-char-p (c)
  "Rust `[A-Za-z0-9_]`, the packer's word alphabet. Spelled with code ranges
rather than `alphanumericp`, which answers T for every Unicode letter and would
make one token out of `über`."
  (or (ascii-digit-p c) (ascii-upper-p c) (ascii-lower-p c) (char= c #\_)))

(defun name-char-p (c)
  "`is_ascii_alphanumeric() || '_' || '$'`, the test the call-site scanner uses
to decide whether a match is a fragment of a longer identifier."
  (or (ascii-digit-p c) (ascii-upper-p c) (ascii-lower-p c)
      (char= c #\_) (char= c #\$)))

;;; ---------------------------------------------------------------------------
;;; Regex class bodies
;;; ---------------------------------------------------------------------------

(defparameter +re-js-s-chars+
  (coerce (mapcar #'code-char (list 32 9 10 11 12 13)) 'string)
  "The `JS_S` constant as a class BODY. Built from code points rather than
written as `\\t\\n` escapes: the Rust concatenates the same characters, and one
representation is easier to check than two.")

(defparameter +re-js-s+ (format nil "[~a]" +re-js-s-chars+)
  "`JS_S` ready to splice into a pattern.")

(defparameter +re-unicode-space-chars+
  (coerce (mapcar #'code-char +unicode-white-space-codes+) 'string)
  "`\\s` as Rust's regex crate means it, as a class BODY so it can be nested
inside a larger class such as `['\"\\s]`.")

(defparameter +re-space+ (format nil "[~a]" +re-unicode-space-chars+)
  "`\\s`, Unicode. Splice this wherever packers.rs wrote `\\s`.")

(defparameter +re-ws-w+ "A-Za-z0-9_"
  "The `JS_W` constant. Only ever used as a class body.")

(defparameter +re-any+ "(?s:.)"
  "`[\\s\\S]`: any character at all, newline included.")

(defun sp (&optional (times 1))
  "`\\s*` (TIMES 1) or `\\s+` (TIMES 2), the two shapes the Rust patterns use.

This exists instead of splicing `+re-space+` into `format` calls: a `format`
string with twelve `~a` directives and twelve arguments is not checkable by eye,
and the first attempt at this file silently gave the array identifier a `*` — it
compiled, it ran, and it matched nothing. Concatenating named pieces cannot
misalign."
  (cat +re-space+ (if (= times 2) "+" "*")))

(defun jsp (&optional (times 1))
  "`[{JS_S}]*` (TIMES 1) or `[{JS_S}]+` (TIMES 2) — the ASCII ECMAScript
whitespace class, NOT `\\s`.

`sp` and `jsp` are different sets and the Rust uses BOTH, so the distinction has
to survive the port. `STRING_ARRAY_RE` and the two decoder-declaration patterns
are built with `JS_S` in packers.rs — space, tab, LF, VT, FF, CR — which does not
include U+00A0 or U+3000. Using `\\s` there would let a declaration separated by a
non-breaking space match in this port and fail to match in the shipped engine, so
the divergence would only ever appear on input the oracle does not carry."
  (cat +re-js-s+ (if (= times 2) "+" "*")))

(defun cat (&rest pieces)
  "Concatenate PIECES into one pattern string."
  (apply #'concatenate 'string pieces))

;;; ---------------------------------------------------------------------------
;;; Small text utilities the Rust got from the standard library
;;; ---------------------------------------------------------------------------

(defun contains (needle text)
  "`str::contains`, answering a boolean rather than an index."
  (and (search needle text) t))

(defun rust-split (text separator)
  "Rust `str::split`. Two shapes matter and neither is CL's `uiop:split-string`:

  - a non-empty separator keeps EMPTY pieces, including a trailing one:
    `\"a|\"` splits to `(\"a\" \"\")`, so a word list keeps its length and the
    indices in the payload still line up.
  - an empty separator splits at every boundary and yields a leading AND a
    trailing empty string: `\"ab\"` -> `(\"\" \"a\" \"b\" \"\")`. That is what
    `\"\".split(\"\")` does in JavaScript too, and it is what an empty
    `.split('')` argument produces here."
  (if (zerop (length separator))
      (let ((pieces (list "")))
        (loop for c across text do (push (string c) pieces))
        (nreverse (push "" pieces)))
      (let ((pieces '())
            (start 0))
        (loop for at = (search separator text :start2 start)
              while at
              do (push (subseq text start at) pieces)
                 (setf start (+ at (length separator))))
        (nreverse (push (subseq text start) pieces)))))

(defun hex-digit-p (c)
  "`char::is_ascii_hexdigit`."
  (let ((code (char-code c)))
    (or (<= 48 code 57) (<= 65 code 70) (<= 97 code 102))))

(defun parse-hex-whole (text)
  "Rust `u32::from_str_radix(text, 16).unwrap_or(0)`: the WHOLE string must be
hex. A leading `+` is accepted (from_str_radix allows a sign); a leading `-`, an
empty string, a `0x` prefix and any non-hex character are not.

Answering 0 on failure — rather than signalling — is the quirk being preserved:
`\\x4` decodes to U+0004 because one hex digit parses, and `\\xzz` decodes to
U+0000 because it does not. Refusing instead would drop characters the shipped
engine emits."
  (let* ((n (length text))
         (start (if (and (plusp n) (char= (char text 0) #\+)) 1 0))
         (value 0))
    (when (= start n) (return-from parse-hex-whole 0))
    (loop for i from start below n
          do (let ((digit (position (char-downcase (char text i))
                                    "0123456789abcdef")))
               (if (null digit)
                   (return-from parse-hex-whole 0)
                   (setf value (+ (* value 16) digit)))))
    ;; from_str_radix is over u32: an overflowing spelling is an error, which
    ;; unwrap_or turns into 0 as well.
    (if (<= value #xFFFFFFFF) value 0)))

(defun code-unit-string (code)
  "Rust `char::from_u32(code & 0xFFFF).unwrap_or('\\u{FFFD}')` as a string.

The mask is the specification: `\\u{1F600}` written the long way decodes to two
lone surrogates, and a lone surrogate cannot be stored in a Lisp string or a Rust
`char`, so it degrades to U+FFFD in both ports. The JavaScript original produced
a real surrogate pair here; the archive's own Rust records that divergence, so
this port follows the Rust rather than re-inventing a third answer."
  (let* ((unit (logand code #xFFFF))
         (char (and (not (<= #xD800 unit #xDFFF)) (code-char unit))))
    (string (or char (code-char #xFFFD)))))

;;; ---------------------------------------------------------------------------
;;; Dean Edwards: escapes, digits, and the base decoder
;;; ---------------------------------------------------------------------------

(declaim (inline push-string))
(defun push-string (target text)
  "Append every character of TEXT to the adjustable character vector TARGET.
`write-string` needs a stream, and these scanners build vectors because they push
one character at a time; this is the one bridge between the two."
  (loop for c across text do (vector-push-extend c target))
  target)

(defun unescape-escape (raw i out)
  "Consume the escape whose character sits at I, one past the backslash, appending
its expansion to OUT. Answers the position AFTER the whole escape.

Split out of `unescape-js-literal` for one reason: the escape table is eleven
cases wide and inlining it produced a form whose parenthesis depth no reader —
and no reviewer — could check by eye. The `\\x`/`\\u` tails advance by their own
width (`i + 3`, `i + 5`) because the four/six characters of the escape INCLUDING
the leading one are already accounted for."
  (let* ((n (length raw))
         (next (char raw i)))
    (case next
      (#\n (vector-push-extend #\Newline out) (1+ i))
      (#\r (vector-push-extend #\Return out) (1+ i))
      (#\t (vector-push-extend #\Tab out) (1+ i))
      (#\b (vector-push-extend (code-char 8) out) (1+ i))
      (#\f (vector-push-extend (code-char 12) out) (1+ i))
      (#\v (vector-push-extend (code-char 11) out) (1+ i))
      (#\0 (vector-push-extend (code-char 0) out) (1+ i))
      (#\x
       (push-string out
                    (code-unit-string
                     (parse-hex-whole (subseq raw (min (1+ i) n) (min (+ i 3) n)))))
       (+ i 3))
      (#\u
       (push-string out
                    (code-unit-string
                     (parse-hex-whole (subseq raw (min (1+ i) n) (min (+ i 5) n)))))
       (+ i 5))
      (t (vector-push-extend next out) (1+ i)))))

(defun unescape-js-literal (raw)
  "`unescape_js_literal`: the escapes the packer's own arguments can contain.

Two preserved oddities. An unknown escape DROPS the backslash and keeps the
character (`\\q` -> `q`), which is JavaScript's behaviour, not an error. A
trailing lone backslash ends the scan emitting nothing, because the original
breaks out of a `while` whose counter has already advanced past the end."
  (let ((n (length raw))
        (out (make-array 0 :element-type 'character :adjustable t :fill-pointer 0))
        (i 0))
    (loop while (< i n)
          do (if (char= (char raw i) #\\)
                 (progn
                   (incf i)
                   (when (>= i n) (return))    ; trailing backslash: stop
                   (setf i (unescape-escape raw i out)))
                 (progn
                   (vector-push-extend (char raw i) out)
                   (incf i))))
    (coerce out 'string)))

(defun digit-value (c)
  "`digit_value`: 0-9 then a-z then A-Z, the base-62 alphabet the packer's word
indices use. -1 for anything else, which `base-decode-token` treats as fatal
rather than as zero — that is how `_0x` and `$` tokens stay undecoded instead of
silently resolving to index 0."
  (cond ((ascii-digit-p c) (- (char-code c) 48))
        ((ascii-lower-p c) (- (char-code c) 87))
        ((ascii-upper-p c) (- (char-code c) 55))
        (t -1)))

(defun wrap-i64 (value)
  "Rust's release-mode i64 arithmetic WRAPS. `base-decode-token` multiplies once
per character, so a long token overflows; the wasm engine ships release mode, so
wrapping — not bignum growth and not a signal — is what has to be reproduced.
The result is sign-extended from the low 64 bits."
  (let ((m (logand value (1- (ash 1 64)))))
    (if (>= m (ash 1 63)) (- m (ash 1 64)) m)))

(defun base-decode-token (token base)
  "`base_decode_token`: TOKEN read as a number in BASE, or -1 when it holds a
character outside the base. The -1 is load-bearing — it is what leaves `_0x` and
`$` tokens alone instead of decoding them as index 0."
  (let ((value 0))
    (loop for c across token
          for d = (digit-value c)
          do (if (or (minusp d) (>= d base))
                 (return-from base-decode-token -1)
                 (setf value (wrap-i64 (+ (* value base) d)))))
    value))

;;; ---------------------------------------------------------------------------
;;; JS parseIntLiteral — NOT Number::to-number, and the difference is the point
;;; ---------------------------------------------------------------------------

(defun parse-hex-limited (text)
  "`i64::from_str_radix(text, 16).ok()`: NIL on overflow, which is how a
seventeen-digit hex argument is refused instead of wrapping."
  (let ((value 0))
    (loop for c across text
          for d = (position (char-downcase c) "0123456789abcdef")
          do (setf value (+ (* value 16) d))
             (when (> value +i64-max+) (return-from parse-hex-limited nil)))
    value))

(defun parse-decimal-limited (text)
  "`text.parse::<i64>().ok()`: NIL on overflow."
  (let ((value 0))
    (loop for c across text
          do (setf value (+ (* value 10) (- (char-code c) 48)))
             (when (> value +i64-max+) (return-from parse-decimal-limited nil)))
    value))

(defun parse-int-literal (raw)
  "JS `parseIntLiteral`, the archive's own number reader.

Hex accepts a VALID PREFIX with no round-trip check (`0x1aZZ` answers 26) while
decimal must round-trip EXACTLY (`12abc` answers NIL rather than 12). That
asymmetry is the original JavaScript quirk and it decides whether a rotator pivot
parses at all, so it is preserved rather than tidied."
  (let* ((trimmed (rust-trim raw))
         (negative (and (plusp (length trimmed)) (char= (char trimmed 0) #\-)))
         (digits (if (and (plusp (length trimmed))
                          (or negative (char= (char trimmed 0) #\+)))
                     (subseq trimmed 1)
                     trimmed)))
    (if (and (>= (length digits) 2)
             (string= (string-downcase (subseq digits 0 2)) "0x"))
        (let* ((hex (subseq digits 2))
               (valid (subseq hex 0 (or (position-if-not #'hex-digit-p hex)
                                        (length hex))))
               (value (and (plusp (length valid)) (parse-hex-limited valid))))
          (when (null value) (return-from parse-int-literal nil))
          (if negative (- value) value))
        (let* ((valid (subseq digits 0 (or (position-if-not #'ascii-digit-p digits)
                                           (length digits))))
               (value (and (string= valid digits)
                           (plusp (length valid))
                           (parse-decimal-limited valid))))
          (when (null value) (return-from parse-int-literal nil))
          (if negative (- value) value)))))

;;; ---------------------------------------------------------------------------
;;; Dean Edwards: reading the argument tuple
;;;
;;; The real call is `('payload', 62, 1, 'words'.split('|'), 0, {})`, and the
;;; last two arguments are arbitrary expressions. A regex cannot balance
;;; parentheses, so the tuple is scanned by hand and the tail is skipped by
;;; depth — that is why this reader exists rather than one big pattern.
;;; ---------------------------------------------------------------------------

(defstruct (packer-arg (:constructor make-packer-arg (kind value split)))
  "One argument of the packer call: `:str` (with the optional `.split(...)`
separator), `:number`, or `:other` for a balanced expression we only skip."
  (kind :other :read-only t)
  (value nil :read-only t)
  (split nil))

(defparameter +packer-num-re+
  (cl-ppcre:create-scanner "^[-+]?(?:0x[0-9a-fA-F]+|[0-9]+(?:\\.[0-9]+)?)")
  "`NUM_RE`, compiled once. This runs once per argument of every packer call
examined; recompiling a pattern inside a scanner loop is the one thing cl-ppcre
is genuinely slow at.")

(defun match-split-suffix (text from)
  "Hand-match of `/^\\s*\\.split\\s*\\(\\s*(['\\\"]).*?\\1\\s*\\)/` anchored at
FROM. Answers (values inner-start inner-end position-after) or NIL.

This cannot be a pattern: the original contains a BACKREFERENCE (`\\1`), which
neither Rust's regex crate nor this port's engine supports, so packers.rs scans
by hand and this port scans the same way. The detail that makes the hand scan
correct is the one a naive version gets wrong: the closing quote must be followed
by optional spaces and `)`, so an earlier quote INSIDE the separator does not end
the literal."
  (let* ((n (length text))
         (p from))
    (loop while (and (< p n) (ascii-js-space-p (char text p))) do (incf p))
    (unless (and (<= (+ p 6) n) (string= (subseq text p (+ p 6)) ".split"))
      (return-from match-split-suffix nil))
    (incf p 6)
    (loop while (and (< p n) (ascii-js-space-p (char text p))) do (incf p))
    (when (or (>= p n) (char/= (char text p) #\())
      (return-from match-split-suffix nil))
    (incf p)
    (loop while (and (< p n) (ascii-js-space-p (char text p))) do (incf p))
    (when (>= p n) (return-from match-split-suffix nil))
    (let ((quote (char text p)))
      (unless (or (char= quote #\') (char= quote #\"))
        (return-from match-split-suffix nil))
      (let ((inner-start (1+ p))
            (search-from (1+ p)))
        (loop
          (let ((close (position quote text :start search-from)))
            (when (null close) (return-from match-split-suffix nil))
            (let ((after (1+ close)))
              (loop while (and (< after n) (ascii-js-space-p (char text after)))
                    do (incf after))
              (when (and (< after n) (char= (char text after) #\)))
                (return-from match-split-suffix
                  (values inner-start close (1+ after)))))
            (setf search-from (1+ close))))))))

(defun read-packer-arg (text index)
  "`read_packer_arg`: one argument after the packer's `}(`. Answers
(values arg position-after) or NIL.

The `:other` branches are not laziness: a real packer call carries `0` and `{}`
arguments that `detect_packer` never reads, so the reader must SKIP them without
understanding them — and in the same order the Rust tries the shapes, because the
order decides whether `4,4` is a number or the start of something else.

The number branch is exclusive, matching the Rust's `if let ... return`: once the
literal pattern matches at the start of the rest, the outcome is decided as
number-or-NIL, and a failed parse does NOT fall through to the identifier branch."
  (let* ((n (length text))
         (i index))
    (loop while (and (< i n) (ascii-js-space-p (char text i))) do (incf i))
    (when (>= i n) (return-from read-packer-arg nil))
    (let ((quote (char text i)))
      ;; --- a quoted literal, escapes and all ------------------------------
      (when (or (char= quote #\') (char= quote #\"))
        (let ((j (1+ i)))
          (loop while (and (< j n) (char/= (char text j) quote))
                do (if (char= (char text j) #\\) (incf j 2) (incf j)))
          (when (>= j n) (return-from read-packer-arg nil))
          (return-from read-packer-arg
            (values (make-packer-arg :str (unescape-js-literal (subseq text (1+ i) j)) nil)
                    (1+ j)))))
      ;; --- a number, or a definite refusal ---------------------------------
      (multiple-value-bind (num-start num-end)
          (cl-ppcre:scan +packer-num-re+ (subseq text i))
        (when (and num-start (zerop num-start))
          (let* ((raw (subseq text i (+ i num-end)))
                 (after (subseq text (+ i num-end)))
                 ;; A literal must be followed by a delimiter, not by identifier
                 ;; junk: `0x1a` is a number here, `0x1a.b` is not, and the
                 ;; difference is a refused detection rather than a wrong one.
                 (delimited (or (zerop (length after))
                                (let ((c (char after 0)))
                                  (or (ascii-js-space-p c)
                                      (char= c #\,) (char= c #\))
                                      (char= c #\%))))))
            (unless delimited (return-from read-packer-arg nil))
            (let ((value (parse-int-literal raw)))
              (unless value (return-from read-packer-arg nil))
              (return-from read-packer-arg
                (values (make-packer-arg :number value nil) (+ i (length raw))))))))
      ;; --- a balanced expression we only skip ------------------------------
      (when (or (char= quote #\{) (char= quote #\[) (char= quote #\())
        (let ((depth 0)
              (k i))
          (loop while (< k n)
                do (let ((c (char text k)))
                     (cond
                       ((or (char= c #\() (char= c #\[) (char= c #\{))
                        (incf depth))
                       ((or (char= c #\)) (char= c #\]) (char= c #\}))
                        (decf depth)
                        (when (zerop depth)
                          (return-from read-packer-arg
                            (values (make-packer-arg :other nil nil) (1+ k)))))
                       (t nil))
                     (incf k)))
          (return-from read-packer-arg nil)))
      ;; --- a bare lowercase identifier -------------------------------------
      (when (ascii-lower-p quote)
        (let ((w i))
          (loop while (and (< w n) (name-char-p (char text w))) do (incf w))
          (when (> w i)
            (return-from read-packer-arg
              (values (make-packer-arg :other nil nil) w)))))
      nil)))

(defun parse-packer-call (text call-start)
  "`parse_packer_call`: every argument between the `(` at CALL-START and its
matching `)`. Answers (values args position-after) or NIL.

The eight-argument cap is the original's: a real call carries six, and accepting
unbounded arguments would let a pathological input drive the scanner through the
whole file."
  (let ((n (length text))
        (i (1+ call-start))
        (args '()))
    (loop
      (loop while (and (< i n)
                       (or (ascii-js-space-p (char text i))
                           (char= (char text i) #\,)))
            do (incf i))
      (when (>= i n) (return-from parse-packer-call nil))
      (when (char= (char text i) #\))
        (return-from parse-packer-call (values (nreverse args) (1+ i))))
      (multiple-value-bind (arg end) (read-packer-arg text i)
        (when (null arg) (return-from parse-packer-call nil))
        (when (eq (packer-arg-kind arg) :str)
          (multiple-value-bind (inner-start inner-end after)
              (match-split-suffix text end)
            (when after
              (setf (packer-arg-split arg)
                    (unescape-js-literal (subseq text inner-start inner-end))
                    end after))))
        (setf i end)
        (push arg args)
        (when (> (length args) 8) (return-from parse-packer-call nil))))))

;;; ---------------------------------------------------------------------------
;;; detectPacker / unpackPacker
;;; ---------------------------------------------------------------------------

(defun detect-packer (text)
  "`detect_packer`, answering a plist or NIL.

The plist keys are the serde field names in declaration order —
`:payload :base :count :words` — because the oracle for this function IS the
serialized struct, so a key rename is a contract break rather than a style
choice. `count` is carried but never used to validate: the shipped engine
reports it and substitutes by decoded index only.

`base` must be 2..=62. Below 2 the digit alphabet is empty; above 62 it leaves
the `[0-9a-zA-Z]` range `digit-value` knows, so every token would fail to decode
and the unpacker would silently answer the payload unchanged."
  (let ((sig (search +packer-signature+ text)))
    (when sig
      (let ((call (search "}(" text :start2 sig)))
        (when call
          (multiple-value-bind (args end) (parse-packer-call text (1+ call))
            (declare (ignore end))
            (when (and args (>= (length args) 4))
              (let ((payload (nth 0 args))
                    (base (nth 1 args))
                    (count (nth 2 args))
                    (words (nth 3 args)))
                (when (and (eq (packer-arg-kind payload) :str)
                           (eq (packer-arg-kind base) :number)
                           (eq (packer-arg-kind count) :number)
                           (eq (packer-arg-kind words) :str))
                  (let ((base-value (packer-arg-value base)))
                    (when (<= 2 base-value 62)
                      (let ((separator (or (packer-arg-split words) "|")))
                        (list :payload (packer-arg-value payload)
                              :base base-value
                              :count (packer-arg-value count)
                              :words (rust-split (packer-arg-value words)
                                                 separator))))))))))))))

(defun unpack-with (payload base words)
  "`unpack_with`: substitute every word token in PAYLOAD with the word it indexes.

`regex::replace_all` with a closure, respelled as one scan so the decision per
token is visible. The three conditions are all load-bearing: a decoded index
below zero (an undecodable token), an index past the word list (the packer
truncates `k` when `c` is larger), and an EMPTY word — obfuscators emit `||` holes
in the list and the engine leaves those tokens in place rather than deleting them.

The bound test is `<` and not `<=`, and it is written to be evaluated BEFORE the
lookup: an index equal to the word count would be off the end, and letting `elt`
raise there would turn a wrong answer into a crash."
  (let ((n (length payload))
        (out (make-string-output-stream))
        (count (length words))
        (i 0))
    (loop while (< i n)
          do (let ((c (char payload i)))
               (if (token-char-p c)
                   (let ((j i))
                     (loop while (and (< j n) (token-char-p (char payload j)))
                           do (incf j))
                     (let ((token (subseq payload i j)))
                       (let ((index (base-decode-token token base)))
                         (if (and (not (minusp index))
                                  (< index count)
                                  (plusp (length (elt words index))))
                             (write-string (elt words index) out)
                             (write-string token out))))
                     (setf i j))
                   (progn (write-char c out) (incf i)))))
    (get-output-stream-string out)))

(defun unpack-packer (text)
  "`unpack_packer`: peel layers until nothing changes.

NIL when the text was never packed, so a caller can tell \"no packer here\" from
\"packed into itself\" — the second would otherwise look like a successful no-op
and hide a broken signature match."
  (let ((current text))
    (dotimes (layer +max-packer-layers+)
      (declare (ignore layer))
      (let ((found (detect-packer current)))
        (unless found (return))
        (let ((next (unpack-with (getf found :payload)
                                 (getf found :base)
                                 (getf found :words))))
          (when (string= next current) (return))
          (setf current next))))
    (if (string= current text) nil current)))

;;; ---------------------------------------------------------------------------
;;; The esoteric shells: refused, never decoded
;;; ---------------------------------------------------------------------------

(defparameter +aa-kaomoji+
  (mapcar #'code-char (list #xFF9F #x03C9 #xFF89 #x0398 #xFF70 #x0414
                            #x03A3 #x03B5 #x30CE #x2207 #x00B0 #x30FB))
  "`AA_KAOMOJI`: the twelve code points aaencode's kaomoji are built from.
Held as code points rather than as a literal string so the file's own encoding can
never silently turn one of them into a different glyph.")

(defun aa-banner (pattern-codes)
  "Build an aaencode banner needle from code points, so every banner in
`detect-aaencode` is written in one alphabet — the code-point one. Parens are
`#x28`/`#x29`: a literal `#\\(` here would be a character where a code point is
expected, and `code-char` rejects it."
  (coerce (mapcar #'code-char pattern-codes) 'string))

(defparameter +aa-banner-wave+ (aa-banner (list #xFF9F #x03C9 #xFF89))
  "( U+FF9F, omega, U+FF89 ): the `(ﾟωﾟ)` style face.")

(defparameter +aa-banner-de+ (aa-banner (list #xFF9F #x0414 #xFF9F))
  "( U+FF9F, CYRILLIC DE, U+FF9F ).")

(defparameter +aa-banner-theta+ (aa-banner (list #x28 #xFF9F #x0398 #xFF9F #x29))
  "( U+FF9F, THETA, U+FF9F ) with its parens.")

(defparameter +aa-banner-choon+ (aa-banner (list #x28 #xFF9F #xFF70 #xFF9F #x29))
  "( U+FF9F, U+FF70, U+FF9F ) with its parens.")

(defun detect-aaencode (source)
  "`detect_aaencode`: aaencode is a kaomoji shell — decoding it means EXECUTING
it, so this answers a refusal and never a string.

Two conditions, both required. A banner alone appears in every article ABOUT
aaencode; a high kaomoji density alone is ordinary CJK prose. Together they are
the encoding."
  (let ((trimmed (rust-trim source)))
    (when (< (length trimmed) 80) (return-from detect-aaencode nil))
    (let ((banner-hits 0))
      (when (contains +aa-banner-wave+ trimmed) (incf banner-hits))
      (when (contains +aa-banner-de+ trimmed) (incf banner-hits))
      (when (or (contains +aa-banner-theta+ trimmed)
                (contains +aa-banner-choon+ trimmed))
        (incf banner-hits))
      (let ((kaomoji 0)
            (total 0))
        (loop for c across trimmed
              do (incf total)
                 (when (member c +aa-kaomoji+) (incf kaomoji)))
        (let ((density (if (plusp total)
                           (/ (coerce kaomoji 'double-float)
                              (coerce total 'double-float))
                           0d0)))
          (when (and (>= banner-hits 1) (>= density 0.05d0))
            (list :tool "aaencode"
                  :detail "kaomoji shell (execution required to decode)"
                  :banner-hits banner-hits
                  :density density
                  :purity nil
                  :markers nil)))))))

(defun detect-jjencode (source)
  "`detect_jjencode`: jjencode builds every string out of `[]!+`, so it is
refused on the two markers that cannot occur together in ordinary code — the
`=~[]` coercion and the `{___:++` object literal.

Both spellings of the object literal are checked because minifiers and
hand-edits produce either: `{___:++` and `{ ___:++`."
  (let ((trimmed (rust-trim source)))
    (when (< (length trimmed) 80) (return-from detect-jjencode nil))
    (when (and (contains "=~[]" trimmed)
               (or (contains "{___:++" trimmed)
                   (contains "{ ___:++" trimmed)))
      (list :tool "jjencode"
            :detail "$=~[] global-object shell (execution required to decode)"
            :banner-hits nil
            :density nil
            :purity nil
            :markers nil))))

(defun detect-jsfiretruck (source)
  "`detect_jsfiretruck`: `[]()!+./` and nothing else.

Three gates, all required: at least 256 characters (shorter bracket runs are real
code), 90% of the NON-WHITESPACE units in the bracket alphabet, and at least
0.5% of those a dot or a slash — without a dot or slash the arithmetic that makes
jsfiretruck work is absent.

The counters mix units deliberately, as the Rust does: `units` and `whitespace`
count UTF-16 code units, `hits` counts CHARACTERS. They can only differ on astral
characters, none of which is in the alphabet, so the ratio is unaffected on real
input and identical to the Rust elsewhere."
  (let ((trimmed (rust-trim source)))
    (when (< (length trimmed) 256) (return-from detect-jsfiretruck nil))
    (let ((hits 0)
          (dot-slash 0)
          (whitespace 0)
          (units 0))
      (loop for c across trimmed
            for width = (if (> (char-code c) #xFFFF) 2 1)
            do (incf units width)
               (cond
                 ((member c '(#\[ #\] #\( #\) #\! #\+ #\. #\/))
                  (incf hits)
                  (when (or (char= c #\.) (char= c #\/)) (incf dot-slash)))
                 ((or (char= c #\Space) (char= c #\Newline)
                      (char= c #\Return) (char= c #\Tab))
                  (incf whitespace width))))
      (let ((counted (- units whitespace)))
        (when (zerop counted) (return-from detect-jsfiretruck nil))
        (let ((purity (/ (coerce hits 'double-float) (coerce counted 'double-float)))
              (ds-density (/ (coerce dot-slash 'double-float)
                             (coerce counted 'double-float))))
          (when (and (>= purity 0.9d0) (> ds-density 0.005d0) (>= hits 256))
            (list :tool "jsfiretruck"
                  :detail "[]()!+./ shell (execution required to decode)"
                  :banner-hits nil
                  :density nil
                  :purity purity
                  :markers nil)))))))

;;; ---------------------------------------------------------------------------
;;; obfuscator.io marker census
;;; ---------------------------------------------------------------------------

(defparameter +obfuscator-marker-specs+
  (list
   (list "banner" "obfuscator\\.io|javascript-obfuscator" nil)
   (list "hex identifiers" "\\b_0x[0-9a-fA-F]{3,}\\b" nil)
   (list "string array rotation"
         (cat "\\[" (sp) "['\"][^'\"]+['\"]" (sp) "\\]" (sp) "\\." (sp)
              "concat|\\.shift" (sp) "\\(" (sp) "\\)"
              "|\\.push" (sp) "\\(" (sp) "[\\w$]+" (sp) "\\[" (sp) "0" (sp) "\\]")
         nil)
   ;; `[\s\S]*?` — the Rust's lazy any-character run, which cl-ppcre spells
   ;; `(?s:.)*?` because its `.` stops at a newline without the flag.
   (list "rotation IIFE"
         (cat "\\(" (sp) "function" (sp) "\\([^)]*\\)" (sp) "\\{" (sp)
              +re-any+ "*?parseInt")
         nil)
   (list "base64 decoder"
         (cat "atob" (sp) "\\(|ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
         nil)
   (list "rc4 decoder"
         (cat "\\b_0x[0-9a-fA-F]+" (sp) "\\(" (sp) "_0x[0-9a-fA-F]+" (sp)
              "," (sp) "_0x[0-9a-fA-F]+")
         nil)
   (list "switch dispatcher"
         (cat "switch" (sp) "\\(" (sp) "_?0x[\\w$]*" (sp) "\\)"
              "|switch" (sp) "\\(" (sp) "[\\w$]+" (sp) "\\+" (sp) "parseInt")
         nil)
   (list "boolean shorthand" (cat "!!\\[\\]|\\[" (sp) "\\]") nil)
   (list "hex literals" (cat "=" (sp) "0x[0-9a-fA-F]{2,}\\b") nil)
   (list "self defending" "self.?defending" t)
   (list "debug protection" "debug.?protect" t)
   (list "console disable"
         (cat "console" (sp) "\\[|call" (sp) "\\(" (sp) "this" (sp) ","
              (sp) "console\\)")
         nil)
   (list "opaque predicate"
         "\\?\\s*['\"][^'\"]*['\"]\\s*:\\s*['\"][^'\"]*['\"]"
         nil)
   ;; The `\s` inside the class is the class BODY here: `['"\s]` cannot nest a
   ;; class inside a class.
   (list "split string concat"
         (cat "['\"][^'\"]{0,3}['\"" +re-unicode-space-chars+ "]"
              (sp) "\\+" (sp) "concat")
         nil)
   (list "renamed properties" (cat "\\." (sp) "_0x[0-9a-fA-F]{3,}\\b") nil))
  "`OBFUSCATOR_MARKER_TABLE`, in declaration order — the order reaches `detail`,
so it is part of the answer and must not be sorted.

Each entry is (name pattern case-insensitive-p). Note which `\\s` are translated
and which are not: a `\\s` that must nest inside another character class is the
class BODY `+re-unicode-space-chars+`, because a class cannot be nested in a
class; a `\\s` standing alone is `(sp)`. Both mean the Unicode set the Rust's
engine means.")

(defparameter +obfuscator-marker-scanners+
  (loop for (name pattern insensitive) in +obfuscator-marker-specs+
        collect (list name
                      (cl-ppcre:create-scanner
                       (if insensitive (format nil "(?i)~a" pattern) pattern))))
  "The table with its patterns COMPILED, once, at load. This is the LazyLock
intent made visible: fifteen `create-scanner` calls per invocation, times
seventeen inputs, would be the slowest thing in the tier.")

(defun detect-obfuscator-io (text)
  "`detect_obfuscator_io`: a scored census, not a classifier.

Only the first 256 KiB (in UTF-16 units) is examined: the markers all live in the
preamble of a real obfuscated file, and scanning a 40 MB bundle to the end is
unbounded work for no extra signal.

Refusal logic, in order: no markers at all -> NIL; any of the three STRONG markers
-> refuse; otherwise three or more weak markers -> refuse. Two weak markers is
what ordinary minified code looks like, so refusing there would fire on every
bundled file the tool exists to download."
  (let ((window (utf16-prefix text (* 256 1024)))
        (markers '()))
    (dolist (entry +obfuscator-marker-scanners+)
      (destructuring-bind (name scanner) entry
        ;; `find_iter(window).take(200).count()`: non-overlapping matches, and
        ;; the 200 is a display cap, so clamping the count is equivalent to
        ;; stopping the iteration early.
        (let ((count (min 200 (floor (length (cl-ppcre:all-matches scanner window)) 2))))
          (when (plusp count)
            (push (list :marker name :count count) markers)))))
    (setf markers (nreverse markers))
    (when (null markers) (return-from detect-obfuscator-io nil))
    (let ((score (length markers))
          (has-strong (some (lambda (m)
                              (member (getf m :marker)
                                      '("banner" "string array rotation" "rc4 decoder")
                                      :test #'string=))
                            markers)))
      (unless (or has-strong (>= score 3))
        (return-from detect-obfuscator-io nil))
      (list :tool "obfuscator-io"
            :detail (format nil "~{~a~^, ~}"
                            (mapcar (lambda (m) (getf m :marker)) markers))
            :banner-hits nil
            :density nil
            :purity nil
            :markers markers))))

;;; ---------------------------------------------------------------------------
;;; The string-array tier: parsing the array body
;;; ---------------------------------------------------------------------------

(defun parse-array-literals (body)
  "`parse_array_literals`: the string literals of an array body, in order, or NIL
when the body is not a pure list of them.

Anything that is not a literal, a comma or ASCII JS whitespace makes the WHOLE
array unparseable, on purpose: `[a, \"b\"]` is an expression, and a static
rewriter that guessed at expressions would emit wrong code instead of declining.

The `\\x` escape is STRICTER here than in `unescape-js-literal`: exactly two hex
digits or the array is refused, because this path's output is re-emitted as
source and a half-decoded byte would be a silent corruption."
  (let* ((n (length body))
         (out '())
         (i 0))
    (loop while (< i n)
          do (let ((c (char body i)))
               (cond
                 ((or (char= c #\') (char= c #\"))
                  (let ((quote c)
                        (buf (make-array 0 :element-type 'character
                                           :adjustable t :fill-pointer 0)))
                    (incf i)
                    (loop while (and (< i n) (char/= (char body i) quote))
                          do (if (char= (char body i) #\\)
                                 (progn
                                   (incf i)
                                   (when (>= i n)
                                     (return-from parse-array-literals nil))
                                   (let ((next (char body i)))
                                     (case next
                                       (#\n (vector-push-extend #\Newline buf))
                                       (#\t (vector-push-extend #\Tab buf))
                                       (#\r (vector-push-extend #\Return buf))
                                       (#\\ (vector-push-extend #\\ buf))
                                       (#\' (vector-push-extend #\' buf))
                                       (#\" (vector-push-extend #\" buf))
                                       (#\0 (vector-push-extend (code-char 0) buf))
                                       (#\x
                                        (let ((hex (subseq body (min (1+ i) n)
                                                           (min (+ i 3) n))))
                                          (unless (and (= (length hex) 2)
                                                       (every #'hex-digit-p hex))
                                            (return-from parse-array-literals nil))
                                          (push-string
                                           buf
                                           (code-unit-string (parse-hex-whole hex)))
                                          (incf i 2)))
                                       (t (vector-push-extend next buf)))
                                     (incf i)))
                                 (progn (vector-push-extend (char body i) buf)
                                        (incf i))))
                    (incf i)                        ; the closing quote
                    (when (> i n) (return-from parse-array-literals nil))
                    (push (coerce buf 'string) out)))
                 ((or (char= c #\,) (ascii-js-space-p c)) (incf i))
                 (t (return-from parse-array-literals nil)))))
    (if (null out) nil (nreverse out))))

(defstruct (string-array-found (:constructor make-string-array-found
                                             (array-id literals decl-range)))
  "`StringArrayFound`. `decl-range` is (start . end) as CHARACTER indices."
  (array-id nil :read-only t)
  (literals nil :read-only t)
  (decl-range nil :read-only t))

(defparameter +string-array-re+
  (cl-ppcre:create-scanner
   (cat "(?m)^(?:var|let|const)" (jsp 2)
        "(_?0x[0-9a-fA-F]+|[a-zA-Z_][" +re-ws-w+ "]*)" (jsp)
        "=" (jsp) "\\[([^\\]]*)\\]" (jsp) ";"))
  "`STRING_ARRAY_RE`. `(?m)` means the same thing in both engines: `^` matches at
the start of the text and after a newline, and after nothing else — a lone CR is
not a line boundary in either.

Capture 1 is the array identifier, capture 2 the raw body between the brackets.
`(?m)` is inline rather than passed as a keyword because `create-scanner` has no
multi-line keyword (an earlier probe proved that the hard way).")

(defun find-string-array (source)
  "`find_string_array`: the first `var/let/const NAME = [\"...\", ...];` whose body
parses as pure literals. A declaration whose body does not parse is NOT skipped in
favour of a later one — the Rust takes the first textual match and gives up, and
that is the behaviour the oracle pins."
  (multiple-value-bind (start end reg-starts reg-ends)
      (cl-ppcre:scan +string-array-re+ source)
    (when start
      (let ((literals (parse-array-literals
                       (subseq source (aref reg-starts 1) (aref reg-ends 1)))))
        (when literals
          (make-string-array-found
           (subseq source (aref reg-starts 0) (aref reg-ends 0))
           literals
           (cons start end)))))))

;;; ---------------------------------------------------------------------------
;;; The rotator IIFE
;;; ---------------------------------------------------------------------------

(defstruct (rotator-found (:constructor make-rotator-found (pivot-value iife-range)))
  (pivot-value nil :read-only t)
  (iife-range nil :read-only t))

(defun looks-like-rotator-p (body)
  "`looks_like_rotator`: four independent witnesses — a `while` (guarded by
`true` or `!![]`), a `push`, a `shift`, and a `parseInt`.

All four are required because each alone appears in ordinary code; together they
describe the rotate-until-parseInt loop and nothing else."
  (and (contains "while" body)
       (or (contains "!![]" body) (contains "true" body))
       (contains "push" body)
       (contains "shift" body)
       (contains "parseInt" body)))

(defun find-rotator (source array-id)
  "`find_rotator`: the IIFE that rotates ARRAY-ID, plus its pivot.

The identifier is regex-escaped into the pattern: `$` in an obfuscated name is a
real possibility and would otherwise anchor the pattern at end of subject.
Answers a `rotator-found` or NIL — including when the pattern fails to compile,
which the Rust models as `.ok()?`."
  (let* ((id (regex-escape array-id))
         (pattern
           ;; `(?ms)`: `.` spans newlines and `^`/`$` are multi-line, exactly as
           ;; the Rust's `(?ms)` flags. `(.+?)` is the IIFE body, lazy so it
           ;; stops at the FIRST `}` that is followed by the call — a greedy run
           ;; would swallow every later function in the file.
           (cat "(?ms)\\(" (sp) "function" (sp) "\\(([^)]*)\\)" (sp) "\\{"
                "(.+?)" "\\}" (sp) "\\(" (sp) id (sp) ","
                (sp) "([-+]?0x[0-9a-fA-F]+|[0-9]+)" (sp) "\\)" (sp) "\\)" (sp) ";"))
         (scanner (handler-case (cl-ppcre:create-scanner pattern)
                    (error () (return-from find-rotator nil)))))
    (multiple-value-bind (start end reg-starts reg-ends) (cl-ppcre:scan scanner source)
      (when start
        (let ((body (subseq source (aref reg-starts 1) (aref reg-ends 1))))
          (when (looks-like-rotator-p body)
            (let ((pivot (parse-int-literal (subseq source (aref reg-starts 2)
                                                    (aref reg-ends 2)))))
              (when pivot
                (make-rotator-found pivot (cons start end))))))))))

(defun simulate-rotation (strings pivot)
  "`simulate_rotation`: find the rotation the runtime loop would perform WITHOUT
running it.

The loop push-shifts forever until `parseInt(strings[0])` equals the pivot, so
the answer is the smallest k in 0..4096 whose index k mod n parses to the pivot.
`parse_int_literal` — not JavaScript's `parseInt` — decides: in the shipped
fixture the first element is `\"4|1|0|2|3\"`, which a round-trip-strict reader
refuses while `parseInt` would answer 4, so no rotation matches and the array is
emitted UNROTATED. That is exactly what the oracle records, and it is the one
place where the Rust's choice is visibly observable.

Answers (values rotated-strings rotation-index)."
  (if (null strings)
      (values strings 0)
      (let ((n (length strings)))
        (loop for k from 0 to +max-rotations+
              for index = (mod k n)
              do (let ((parsed (parse-int-literal (elt strings index))))
                   (when (and parsed (= parsed pivot))
                     (return-from simulate-rotation
                       (values (append (subseq strings index)
                                       (subseq strings 0 index))
                               index)))))
        (values strings 0))))

;;; ---------------------------------------------------------------------------
;;; Rebuilding the declaration
;;; ---------------------------------------------------------------------------

(defun js-quote-escape (text)
  "`js_quote_escape`: the five escapes needed to put TEXT inside single quotes.
Newline, tab and CR are escaped so the emitted declaration stays on one line;
everything else is literal, including characters a minifier would escape."
  (with-output-to-string (out)
    (loop for c across text
          do (case c
               (#\\ (write-string "\\\\" out))
               (#\' (write-string "\\'" out))
               (#\Newline (write-string "\\n" out))
               (#\Tab (write-string "\\t" out))
               (#\Return (write-string "\\r" out))
               (t (write-char c out))))))

(defun emit-array-decl (id literals)
  "`emit_array_decl`: `var ID = ['a', 'b'];` — always `var`, never the original
`const`/`let`. The rewritten array is reassigned by the rotator's successors in
some real files, so narrowing the binding would break them."
  (format nil "var ~a = [~{~a~^, ~}];"
          id
          (mapcar (lambda (lit) (format nil "'~a'" (js-quote-escape lit))) literals)))

(defun rebuild-string-array-source (source found rotator rotated)
  "`rebuild_string_array_source`: replace the declaration with its rotated form and
delete the rotator IIFE, whichever comes first in the file.

Order-independent on purpose: obfuscator.io emits the IIFE after the declaration,
but a hand-edited file can have them the other way round, and a splice written for
one order silently corrupts the other."
  (let* ((decl (string-array-found-decl-range found))
         (iife (rotator-found-iife-range rotator))
         (first-is-decl (< (car decl) (car iife)))
         (first (if first-is-decl decl iife))
         (second (if first-is-decl iife decl))
         (decl-text (emit-array-decl (string-array-found-array-id found) rotated))
         (out (make-string-output-stream)))
    (write-string (subseq source 0 (car first)) out)
    (when first-is-decl (write-string decl-text out))
    (write-string (subseq source (cdr first) (car second)) out)
    (unless first-is-decl (write-string decl-text out))
    (write-string (subseq source (cdr second)) out)
    (get-output-stream-string out)))

;;; ---------------------------------------------------------------------------
;;; Static decoder inlining
;;;
;;; The obfuscator's decoder is `function(i){ return arr[i - 0x10]; }` and its
;;; call sites are `d("0x12")`. Nothing here runs the decoder: the body is
;;; PROVEN to be a plain index lookup, and then each call is replaced with the
;;; literal it would have returned.
;;; ---------------------------------------------------------------------------

(defstruct (decoder-decl (:constructor make-decoder-decl (name params body range)))
  (name nil :read-only t)
  (params nil :read-only t)
  (body nil :read-only t)
  (range nil :read-only t))

(defstruct (decoder-index (:constructor make-decoder-index (offset sign)))
  "`DecoderIndex`: the body indexes `arr[i + offset]` when SIGN is #\\+, and
`arr[i - offset]` when it is #\\-."
  (offset 0 :read-only t)
  (sign #\+ :read-only t))

(defparameter +decoder-index-re+
  (cl-ppcre:create-scanner
   (cat "([\\w$]+)" (sp) "\\[" (sp) "([\\w$]+)" (sp)
        "(?:([+-])" (sp) "(0x[0-9a-fA-F]+|[0-9]+))?" (sp) "\\]"))
  "`INDEX_RE`. Captures: the base, the subscript, the sign, the magnitude. The
sign and magnitude are one optional group, so `arr[i]` and `arr[i - 0x10]` are the
same shape with an empty tail — which is why the caller must test the register
index for nil, not just the presence of a match.")

(defparameter +decoder-prefix-re+
  (cl-ppcre:create-scanner
   (cat "\\A" (sp) "(?:var" (sp 2) "[\\w$]+" (sp) "=" (sp) "[\\w$]+" (sp) ";"
        (sp) ")?return" (sp 2) "(?:[\\w$]+" (sp) "=" (sp) ")?\\z"))
  "`PREFIX_RE` with `^`/`$` spelled `\\A`/`\\z`.

The translation is not cosmetic: cl-ppcre's `$` also matches BEFORE a single
trailing newline, so the Rust's `return\\s+$` and cl-ppcre's `$` version disagree
on a body ending `return \\n` — one accepts a malformed decoder, the other
refuses it. `\\z` is absolute end of subject in both engines, which is what the
Rust `$` means here (there is no `(?m)` on this pattern).")

(defparameter +decoder-suffix-tail-re+
  (cl-ppcre:create-scanner (cat (sp) "\\]" (sp) ";?" (sp) "\\z"))
  "`SUFFIX_TAIL_RE`: whatever hangs off the end of the subscript — optional
whitespace, the closing bracket, an optional semicolon. Removed before the tail is
inspected, because the inspection is looking for *statements* there.")

(defparameter +decoder-suffix-bad-re+
  (cl-ppcre:create-scanner
   (cat "[\\w$" +re-unicode-space-chars+ "=]" (sp) ";"))
  "`SUFFIX_BAD_RE`: a statement where only `];` may be. The `\\s` nests inside a
class here, so it is the class body rather than `(sp)`.")

(defparameter +decoder-suffix-only-re+
  (cl-ppcre:create-scanner (cat "\\A" (sp) "\\]" (sp) ";?" (sp) "\\z"))
  "`SUFFIX_ONLY_RE`: the tail in its entirety is just `];`. This is the exemption
that makes the previous pattern's match harmless.")

(defun decoder-decl-patterns (array-id)
  "The two source shapes `find_decoder_decl` accepts, as compiled scanners.

Two shapes because obfuscator.io emits either: the assignment
(`var d = function(a, b) {...};`) and the hoisted declaration
(`function d(a, b) {...}`). Both anchor on the array identifier appearing inside
the body, so a decoder for a different array cannot match. The optional
`var x = ARR;` prefix in each is the local alias real output uses."
  (let* ((needle (regex-escape array-id))
         ;; The declaration, in both shapes. `[^}]*NEEDLE\s*\[[^\]]+\]` is the
         ;; body witness: a lookup INTO this array, which is what makes it a
         ;; decoder rather than any other function that happens to take two
         ;; parameters.
         (body
           (cat "(?:var" (jsp 2) "[\\w$]+" (jsp) "=" (jsp) needle (jsp) ";"
                (jsp) ")?"
                "([^}]*" needle (jsp) "\\[[^\\]]+\\][^}]*)"))
         (assigned
           (cat "(?ms)(?:var|let|const)" (jsp 2) "([\\w$]+)" (jsp) "=" (jsp)
                "function" (jsp) "\\(([^)]*)\\)" (jsp) "\\{" (jsp)
                body "\\}" (jsp) ";"))
         (hoisted
           (cat "(?ms)function" (jsp 2) "([\\w$]+)" (jsp) "\\(([^)]*)\\)" (jsp)
                "\\{" (jsp) body "\\}")))
    ;; `Regex::new(..).ok()?` in the Rust aborts the WHOLE search on a pattern
    ;; that will not compile. Answering NIL for the unbuildable shape does the
    ;; same thing without letting one bad pattern hide the other.
    (loop for pattern in (list assigned hoisted)
          for scanner = (handler-case (cl-ppcre:create-scanner pattern)
                          (error () nil))
          when scanner collect scanner)))

(defun split-params (params-text)
  "`params.split(',').map(trim).filter(non-empty)`."
  (loop for raw in (rust-split params-text ",")
        for trimmed = (rust-trim raw)
        unless (zerop (length trimmed))
          collect trimmed))

(defun find-decoder-decl (source array-id)
  "`find_decoder_decl`: the first decoder for ARRAY-ID, in either source shape.

Answers a `decoder-decl` whose `range` is the WHOLE match — the range matters
later, because a call site inside it must not be counted as a call and the
declaration itself is what gets deleted when every call inlines."
  (dolist (scanner (decoder-decl-patterns array-id))
    (multiple-value-bind (start end reg-starts reg-ends)
        (cl-ppcre:scan scanner source)
      (when start
        (return-from find-decoder-decl
          (make-decoder-decl
           (subseq source (aref reg-starts 0) (aref reg-ends 0))
           (split-params (subseq source (aref reg-starts 1) (aref reg-ends 1)))
           (subseq source (aref reg-starts 2) (aref reg-ends 2))
           (cons start end))))))
  nil)

(defun analyze-decoder-body (body params array-id)
  "`analyze_decoder_body`: the index arithmetic of a static decoder, or NIL.

Read the checks as one sentence: the body must be
`<array-or-alias>[<first parameter> ± k]` behind a bare `return`, with exactly one
`[` in it. Every refusal here is the point — inlining a decoder that does
anything else would replace a call with the wrong string, silently. A
`.split('|')`, a `substr`, a second lookup, a subscript that is not the first
parameter: all refuse, and `transform-string-array` then leaves the source alone."
  (let ((p0 (and params (first params))))
    (unless p0 (return-from analyze-decoder-body nil))
    (when (/= 1 (count #\[ body)) (return-from analyze-decoder-body nil))
    (multiple-value-bind (start end reg-starts reg-ends)
        (cl-ppcre:scan +decoder-index-re+ body)
      (declare (ignore end))
      (unless start (return-from analyze-decoder-body nil))
      (let ((base (subseq body (aref reg-starts 0) (aref reg-ends 0)))
            (subscript (subseq body (aref reg-starts 1) (aref reg-ends 1))))
        ;; A local alias `var x = ARRAY;` is as good as the array itself, and it
        ;; is how every second obfuscator.io build writes the decoder.
        (let* ((alias-pattern
                 (cat "var" (sp 2) "([\\w$]+)" (sp) "=" (sp)
                      (regex-escape array-id) (sp) ";"))
               (alias-scanner (handler-case (cl-ppcre:create-scanner alias-pattern)
                                (error () nil)))
               (alias
                 (and alias-scanner
                      (multiple-value-bind (as ae as-starts as-ends)
                          (cl-ppcre:scan alias-scanner body)
                        (declare (ignore ae))
                        (and as (subseq body (aref as-starts 0) (aref as-ends 0)))))))
          (unless (or (string= base array-id) (and alias (string= alias base)))
            (return-from analyze-decoder-body nil))
          (unless (string= subscript p0)
            (return-from analyze-decoder-body nil))
          (let* ((sign-start (aref reg-starts 2))
                 (magnitude-start (aref reg-starts 3))
                 (offset (if (and magnitude-start (>= magnitude-start 0))
                             (parse-int-literal (subseq body magnitude-start
                                                        (aref reg-ends 3)))
                             0)))
            (when (null offset) (return-from analyze-decoder-body nil))
            ;; A negative offset is refused even though `arr[i - -0x1]` is
            ;; meaningless: the original rejects it, so the refusal is pinned.
            (when (minusp offset) (return-from analyze-decoder-body nil))
            (unless (cl-ppcre:scan +decoder-prefix-re+ (subseq body 0 start))
              (return-from analyze-decoder-body nil))
            (let* ((raw-tail (subseq body (aref reg-ends 0)))
                   (tail (cl-ppcre:regex-replace +decoder-suffix-tail-re+ raw-tail "")))
              (when (and (cl-ppcre:scan +decoder-suffix-bad-re+ tail)
                         (not (cl-ppcre:scan +decoder-suffix-only-re+ raw-tail)))
                (return-from analyze-decoder-body nil)))
            (make-decoder-index
             offset
             (if (and sign-start (>= sign-start 0))
                 (char body sign-start)
                 #\+))))))))

(defstruct (call-site (:constructor make-call-site (range arg)))
  (range nil :read-only t)
  (arg 0 :read-only t))

(defstruct (call-sites (:constructor make-call-sites (sites has-unresolved)))
  (sites '() :read-only t)
  (has-unresolved nil :read-only t))

(defun match-pairs (scanner text)
  "`all-matches` returns a flat (start end start end ...) list; the scanners here
need pairs, and pairing once is clearer than `by #'cddr` destructuring in three
places."
  (loop for (start end) on (cl-ppcre:all-matches scanner text) by #'cddr
        collect (cons start end)))

(defun find-decoder-call-sites (source decoder-name decoder-range)
  "`find_decoder_call_sites`: every `name(<integer literal>)` outside the
declaration.

`has-unresolved` records that a call-LIKE occurrence could not be resolved: a
method call (`obj.name(...)`), a non-literal argument, an unbalanced call, or a
name that never calls. When that flag is set the declaration is kept — one
unresolved call means deleting it would break the program, and a rewriter that
deleted it anyway would ship code that throws."
  (let ((scanner (cl-ppcre:create-scanner (regex-escape decoder-name)))
        (n (length source))
        (sites '())
        (has-unresolved nil))
    (dolist (pair (match-pairs scanner source))
      (let ((start (car pair))
            (end (cdr pair)))
        (cond
          ;; inside the declaration itself: neither a site nor a problem
          ((and (>= start (car decoder-range)) (< start (cdr decoder-range))) nil)
          ;; part of a longer identifier on either side
          ((and (plusp start) (name-char-p (char source (1- start)))) nil)
          ((and (< end n) (name-char-p (char source end))) nil)
          ;; a method call: `obj.name(...)` — the decoder is shadowed, unclear
          ((let ((before (rust-trim-tail (subseq source 0 start))))
             (and (plusp (length before))
                  (char= (char before (1- (length before))) #\.)))
           (setf has-unresolved t))
          (t
           (let ((open end))
             (loop while (and (< open n) (ascii-js-space-p (char source open)))
                   do (incf open))
             (if (or (>= open n) (char/= (char source open) #\())
                 (setf has-unresolved t)
                 (let ((close (1+ open))
                       (depth 1)
                       (closed nil))
                   (loop while (and (< close n) (plusp depth))
                         do (cond ((char= (char source close) #\() (incf depth))
                                  ((char= (char source close) #\)) (decf depth))
                                  (t nil))
                            (when (zerop depth)
                              (setf closed t)
                              (return))
                            (incf close))
                   (if (not closed)
                       (setf has-unresolved t)
                       (let* ((arg-text (rust-trim (subseq source (1+ open) close)))
                              (arg (parse-int-literal arg-text)))
                         (if (null arg)
                             (setf has-unresolved t)
                             (push (make-call-site (cons start (1+ close)) arg)
                                   sites)))))))))))
    (make-call-sites (nreverse sites) has-unresolved)))

(defun current-array-literals (source array-id)
  "`current_array_literals`: the literals of the array as it stands NOW — after
rotation — so the inliner reads post-rotation indices. A declaration whose
identifier changed is NIL, not a stale list."
  (let ((found (find-string-array source)))
    (when (and found (string= (string-array-found-array-id found) array-id))
      (string-array-found-literals found))))

(defun decode-index (call-arg index literals)
  "`decode_index`: the string a call resolves to, or NIL when the index lands
outside the array. The subscript is applied with the decoder's own sign, so
`arr[i - 0x10]` and `arr[i + 0x10]` are never confused."
  (let ((effective (+ call-arg (if (char= (decoder-index-sign index) #\-)
                                   (- (decoder-index-offset index))
                                   (decoder-index-offset index)))))
    (when (or (minusp effective) (>= effective (length literals)))
      (return-from decode-index nil))
    (elt literals effective)))

(defun inline-decoder-calls (source array-id)
  "`inline_decoder_calls`: replace resolvable decoder calls with the string they
would have returned.

The declaration is removed only when it exists, every call resolved, and at least
one call exists — and that removal rides in the SAME sorted event list as the
call rewrites, so the whole transform is one splice and a later site can never be
shifted by an earlier edit."
  (let ((found (find-decoder-decl source array-id)))
    (if (null found)
        source
        (let ((index (analyze-decoder-body (decoder-decl-body found)
                                           (decoder-decl-params found)
                                           array-id)))
          (if (null index)
              source
              (let ((sites (find-decoder-call-sites source
                                                    (decoder-decl-name found)
                                                    (decoder-decl-range found)))
                    (literals (current-array-literals source array-id)))
                (if (null literals)
                    source
                    (let ((events
                            (mapcar (lambda (site)
                                      (list (car (call-site-range site))
                                            (cdr (call-site-range site))
                                            (call-site-arg site)))
                                    (call-sites-sites sites))))
                      (when (and (not (call-sites-has-unresolved sites))
                                 (call-sites-sites sites)
                                 (every (lambda (site)
                                          (decode-index (call-site-arg site)
                                                        index literals))
                                        (call-sites-sites sites)))
                        (push (list (car (decoder-decl-range found))
                                    (cdr (decoder-decl-range found))
                                    :remove)
                              events))
                      ;; Rust's `sort_by_key` is STABLE, and stability is what
                      ;; lets the removal share a sort key with a call site
                      ;; without reordering the two.
                      (setf events (stable-sort events #'< :key #'car))
                      (let ((out (make-string-output-stream))
                            (cursor 0))
                        (dolist (event events)
                          (destructuring-bind (start end arg) event
                            (unless (< start cursor)
                              (write-string (subseq source cursor start) out)
                              (unless (eq arg :remove)
                                (let ((decoded (decode-index arg index literals)))
                                  (if decoded
                                      (progn
                                        (write-char #\' out)
                                        (write-string (js-quote-escape decoded) out)
                                        (write-char #\' out))
                                      (write-string (subseq source start end) out))))
                              (setf cursor end))))
                        (write-string (subseq source cursor) out)
                        (get-output-stream-string out))))))))))

;;; ---------------------------------------------------------------------------
;;; The two gated entry points
;;; ---------------------------------------------------------------------------

(defun transform-string-array (source)
  "`transform_string_array`: rotate + rebuild, then inline the decoder. NIL when
nothing would change, so a caller can distinguish \"rewritten\" from \"no change\"
without diffing two strings."
  (let ((found (find-string-array source)))
    (when found
      (let ((rotator (find-rotator source (string-array-found-array-id found))))
        (when rotator
          (multiple-value-bind (rotated rotations)
              (simulate-rotation (string-array-found-literals found)
                                 (rotator-found-pivot-value rotator))
            (declare (ignore rotations))
            (let* ((rebuilt (rebuild-string-array-source source found rotator rotated))
                   (inlined (inline-decoder-calls rebuilt
                                                  (string-array-found-array-id found))))
              (if (string= inlined source) nil inlined))))))))

(defun detect-string-array (source)
  "`detect_string_array`: a plist of the serde field names — `:array-id`,
`:literals`, `:pivot` — or NIL.

`:literals` is the COUNT of string literals, not of `|`-separated tokens:
`\"4|1|0|2|3\"` is one literal, which is the whole point of a rewriter that
refuses to guess at expressions."
  (let ((found (find-string-array source)))
    (when found
      (let ((rotator (find-rotator source (string-array-found-array-id found))))
        (when rotator
          (list :array-id (string-array-found-array-id found)
                :literals (length (string-array-found-literals found))
                :pivot (rotator-found-pivot-value rotator)))))))
