;;;; beautify.lisp — minified-source detection and the scanner-aware reformatter.
;;;; Ported from unpack-rs/src/beautify.rs (143 lines).
;;;;
;;;; Two functions that live together because the pipeline uses them together —
;;;; `if looks_minified(current) { beautified = beautify_js(current, limit) }` —
;;;; and because they are the only two places in the engine that decide what
;;;; "readable JavaScript" means.
;;;;
;;;; THE REFORMATTER IS NOT js-beautify. The original routes through the external
;;;; js-beautify bundle when the panel loads it; the Rust carries a simplified
;;;; structural formatter instead (a divergence documented in PORTING.md). This
;;;; port reproduces the Rust, and the Rust is what ships inside
;;;; dist/js/engine.wasm — so the byte-level answers here were checked against
;;;; that binary, not only against the Rust source.
;;;;
;;;; ===========================================================================
;;;; FOUR THINGS THE RUST SOURCE DOES NOT SAY OUT LOUD
;;;; ===========================================================================
;;;;
;;;; 1. `looks_minified` MIXES UNITS. `longest` is `&str::len()` — the UTF-8
;;;;    BYTE length of the longest line — while the average divides `utf16_len`
;;;;    (UTF-16 code units) by the line COUNT. The shipped engine agrees with
;;;;    the byte reading: 254 `é` on one line (508 bytes, 254 characters)
;;;;    reports minified; 500 ASCII characters on one line does not. Both are
;;;;    asserted in the gate, so a "cleaner" port that used characters
;;;;    everywhere fails loudly instead of drifting.
;;;;
;;;; 2. `CODE_SIGNAL` uses the REGEX CRATE's `\w`, which is Unicode-aware
;;;;    (UTS#18: Alphabetic, marks, Nd, Pc, Join_Control), while the surrounding
;;;;    prose reads like JavaScript's ASCII-only `\w`. The shipped engine
;;;;    settles it: `prototypeé` is NOT minified (é is a word character, so `\b`
;;;;    never fires) and neither is `évar a`, but `exports.é` IS (a boundary
;;;;    between `.` and `é`). cl-ppcre's `\w` disagrees with the regex crate on
;;;;    combining marks, so the word set is written out explicitly.
;;;;
;;;; 3. `beautify_js` WALKS BYTES, not characters. Every non-ASCII byte reaching
;;;;    the catch-all is pushed with `byte as char`, re-encoding one UTF-8 byte
;;;;    as its own code point: `é` (C3 A9) comes out `Ã©`, an emoji comes out as
;;;;    four Latin-1 code points. Regions skipped as strings/comments/regexes
;;;;    are sliced as `&str` and survive intact, so the damage is confined to
;;;;    bare identifiers and to whitespace between statements. This is a real
;;;;    defect in the shipped engine. The port reproduces it because the port's
;;;;    job is equality with the binary, and the gate pins it so a future
;;;;    "cleanup" cannot silently diverge.
;;;;
;;;; 4. THE BUDGET IS A REFUSAL, NOT A TRUNCATION. Over the limit the function
;;;;    returns the text UNCHANGED — the whole thing, not a prefix. The result
;;;;    may therefore be longer than `max-bytes`. Most misreadable line in the
;;;;    file; the gate asserts it directly.

(defpackage :vovas.engine.beautify
  (:use :cl)
  (:import-from :vovas.engine.util
                #:utf16-length
                #:utf16-prefix)
  (:import-from :vovas.engine.scanner
                #:skip-quoted
                #:skip-template
                #:skip-line-comment
                #:skip-block-comment
                #:regex-start-p
                #:skip-regex)
  ;; cl-unicode is required for ONE predicate: the `Alphabetic` property, whose
  ;; `Other_Alphabetic` component includes non-mark characters like U+24B6
  ;; CIRCLED LATIN CAPITAL LETTER A that the regex crate counts as `\\w` and
  ;; SBCL's general categories do not expose. Imported as a symbol so the module
  ;; compiles without the package being read via a qualified name at load time,
  ;; and declared as a dependency in beautify.asd so it is present first.
  (:import-from :cl-unicode
                #:has-property)
  (:export
   ;; `looks-minified-p` carries the JS name's meaning with the Lisp predicate
   ;; suffix, matching `js-whitespace-p` / `regex-start-p` elsewhere in the tree.
   #:looks-minified-p
   #:beautify-js
   ;; exposed for the gate: the budget policy and the probe width are values a
   ;; test needs to name, not magic numbers to retype
   #:*max-beautify-bytes*
   #:effective-limit))

(in-package :vovas.engine.beautify)

;;; ---------------------------------------------------------------------------
;;; The budget
;;; ---------------------------------------------------------------------------

(defparameter *max-beautify-bytes* (ash 2 20)
  "JS `LIMITS.maxBeautifyBytes` (2 << 20 = 2097152). A defparameter rather than
a defconstant so a REPL can rebind it and so a reload never signals
DEFCONSTANT-UNEQL (contract rule 2).")

(defun effective-limit (max-bytes)
  "JS `opts.x || DEFAULT`, via Rust's `limit_or`.

NIL means \"unset\" and so does 0: the JS idiom treats a zero budget as absent,
and the Rust encodes that as `Some(0) | None => default`. A caller passing 0
asking for an empty result gets the default budget instead. Pinned in the gate
because it is exactly the sort of thing a port silently tidies up."
  (if (or (null max-bytes) (eql max-bytes 0))
      *max-beautify-bytes*
      max-bytes))

;;; ---------------------------------------------------------------------------
;;; UTF-8 byte lengths — the unit the formatter and the line test both use
;;; ---------------------------------------------------------------------------

(declaim (inline utf8-width))
(defun utf8-width (code)
  "The number of UTF-8 bytes CODE occupies (1-4)."
  (cond ((< code #x80) 1)
        ((< code #x800) 2)
        ((< code #x10000) 3)
        (t 4)))

(defun utf8-byte-length (text)
  "Rust `&str::len()`. Not `(length text)`: for `é` this answers 2, not 1, and
`looks-minified-p` compares this number against 500."
  (loop for c across text sum (utf8-width (char-code c))))

;;; ---------------------------------------------------------------------------
;;; Rust's `char::is_whitespace` (the Unicode White_Space property)
;;; ---------------------------------------------------------------------------

(defun rust-whitespace-code-p (code)
  "Unicode White_Space, which is what `char::is_whitespace` tests.

Deliberately NOT `vovas.engine.util:js-whitespace-p`: that one is the ECMAScript
`\\s` set and includes U+FEFF, which White_Space does not. The difference is
observable — a BOM before a `{` inserts a space under the Rust rule and would
not under the JS rule. U+0085 (NEL) and U+00A0 (NBSP) are the two members below
U+0100 that a bare `(<= 9 code 13)` test misses."
  (or (<= #x09 code #x0D)
      (= code #x20)
      (= code #x85)
      (= code #xA0)
      (= code #x1680)
      (<= #x2000 code #x200A)
      (= code #x2028)
      (= code #x2029)
      (= code #x202F)
      (= code #x205F)
      (= code #x3000)))

(declaim (inline byte-whitespace-p))
(defun byte-whitespace-p (byte)
  "The same predicate restricted to a byte. The formatter asks about bytes
because it walks bytes, and `(code-char byte)` is always <= U+00FF, so the
restriction is exact rather than approximate."
  (rust-whitespace-code-p byte))

;;; ---------------------------------------------------------------------------
;;; The code signal: the regex crate's `\w` and `\b`, written out
;;; ---------------------------------------------------------------------------

(declaim (inline word-char-p))
(defun word-char-p (c)
  "Rust regex `\\w` = UTS#18 word characters = Alphabetic | M* | Nd | Pc |
Join_Control.

Answers a STRICT boolean, and that is load-bearing rather than stylistic.
`member` returns the tail of its list, so an earlier version of this function
answered `(:LL ...)` or `(:ND ...)` depending on which category matched, and
`boundary-after-p` then compared two of those with `eql` — which on lists is
IDENTITY, not structure. `prototype9` therefore reported a boundary because the
tail starting at :LL is a different object from the tail starting at :ND, and the
whole code-signal test said T where the engine says NIL.

Three sources, because no single CL predicate is right:

  - L* and Nl                         the letter part of Alphabetic
  - Mn Mc Me                          the M* term of the word definition
  - Nd                                decimal digits
  - Pc                                connector punctuation, i.e. `_`
  - ZWNJ ZWJ                          Join_Control
  - OTHER_ALPHABETIC                  the rest of Alphabetic, which is mostly
                                      marks already covered above but ALSO
                                      contains non-marks like U+24B6 CIRCLED
                                      LATIN CAPITAL LETTER A (`So`). Missing
                                      this made `Ⓐvar a` report NIL where the
                                      engine reports T.

SBCL's own predicates are each wrong in a different direction: `alpha-char-p` is
NIL for U+2160 ROMAN NUMERAL ONE (`Nl`) and for combining marks, while
`alphanumericp` is T for U+00B2 SUPERSCRIPT TWO (`No`), which the regex crate
rejects. All of these are pinned in the gate.

`$` is absent deliberately: it is a word character to JavaScript but not to the
regex crate, and the pattern spells `[^\\w$]` precisely so that `$var` — a legal
identifier start — is not treated as a boundary."
  (let ((code (char-code c)))
    (if (or (= code #x200C)                ; ZWNJ, Join_Control
            (= code #x200D)                ; ZWJ,  Join_Control
            (member (sb-unicode:general-category c)
                    '(:lu :ll :lt :lm :lo :nl     ; letters
                      :mn :mc :me                 ; marks
                      :nd                         ; decimal digits
                      :pc)                        ; connector punctuation
                    :test #'eq)
            ;; OTHER_ALPHABETIC lives only in cl-unicode's property tables.
            ;; `has-property` answers T or a property symbol, so the `and`
            ;; normalises it to a boolean like the other branches.
            (and (has-property c "Alphabetic") t))
        t
        nil)))

(defparameter *code-signal-arrow* "=>"
  "The one alternative of CODE_SIGNAL that is not keyword-plus-boundary: an
arrow needs no boundary test, it is its own syntax. A parameter so the gate
names the same string the matcher uses instead of a copy.")

(defparameter *code-signal-keywords*
  '("function" "return" "var" "let" "const" "class" "new" "typeof"
    "window." "document." "module.exports" "exports." "prototype")
  "The keyword alternatives of CODE_SIGNAL, in the Rust's order.

Four of them end in `.` — `window.`, `document.`, `module.exports`, `exports.` —
and `.` is not a word character, so the trailing `\\b` after those demands a word
character FOLLOWING the dot. That is why `window.document` matches, `window.😀`
does not, and `exports.é` does. `boundary-after-p` reasons over the keyword's own
last character for exactly this reason; assuming \"a keyword ends in a word
character\" would get those four wrong.")

(defun boundary-after-p (probe position)
  "Regex `\\b` at POSITION in PROBE: a word/non-word transition, or the end of
the haystack when the preceding character is a word character.

The start-of-haystack case cannot arise here — every keyword is non-empty, so
POSITION >= 1 — which is why only the end needs a branch."
  (let ((n (length probe)))
    (if (>= position n)
        (word-char-p (char probe (1- position)))
        (not (eql (word-char-p (char probe (1- position)))
                  (word-char-p (char probe position)))))))

(defun keyword-match-at-p (probe position keyword)
  "Whether KEYWORD sits at POSITION with the pattern's `\\b` after it."
  (let ((end (+ position (length keyword))))
    (and (<= end (length probe))
         (string= keyword probe :start2 position :end2 end)
         (boundary-after-p probe end))))

(defun code-signal-p (probe)
  "Whether CODE_SIGNAL matches PROBE — whether this head looks like source at
all, rather than a base64 blob or JSON.

A scan rather than a regex, on purpose. Two pieces — Unicode `\\w` and the
asymmetric `\\b` after the four dot-terminated keywords — are precisely where
cl-ppcre and the regex crate disagree, and both are cheaper to state correctly
here than to smuggle into a pattern. Match ORDER is irrelevant because the
answer is boolean: \"does any start position match\" is the whole test.

Written with an explicit `return-from` rather than LOOP's `thereis`: `thereis`
is a main clause and is rejected inside a `when` conditional, which is why the
first draft of this function failed to compile at all."
  (block scan
    (when (search *code-signal-arrow* probe :test #'char=)
      (return-from scan t))
    (let ((n (length probe)))
      (dotimes (i n)
        ;; the pattern's `(?:^|[^\w$])`: start of haystack, or one preceding
        ;; non-word, non-$ character
        (when (or (zerop i)
                  (let ((prev (char probe (1- i))))
                    (and (not (word-char-p prev))
                         (char/= prev #\$))))
          (dolist (keyword *code-signal-keywords*)
            (when (keyword-match-at-p probe i keyword)
              (return-from scan t))))))
    nil))

;;; ---------------------------------------------------------------------------
;;; The line statistics
;;; ---------------------------------------------------------------------------

(defparameter *probe-units* 200000
  "The `200000` in `utf16_prefix(text, 200000)`. Only the first 200k UTF-16
units are inspected: this is a cheap heuristic on the head of a file, and
minified bundles put their giveaway tokens near the top. The gate pins that a
signal past that window does not count, because a port that scanned the whole
text would answer T there and look correct on every realistic input.")

(defparameter *longest-line-limit* 500
  "`longest > 500`, in BYTES. Strictly greater — 500 does not trip it.")

(defparameter *average-line-limit* 220d0
  "`avg > 220.0`, in UTF-16 units per line. Strictly greater, and compared in
double float because Rust compares f64; a port using rationals would agree on
every exact case and differ only at the tie, which is the one place it matters.")

(defun longest-line-bytes (probe)
  "The maximum UTF-8 byte length over PROBE's `\\n`-separated lines.

One pass, no split: splitting would allocate a string per line, and minified
input is exactly the case of few lines, each enormous. A newline closes the
running line; the final partial line is compared after the loop, which matches
`lines.iter().map(|l| l.len()).max()` — on `\"\"` there is one empty line and the
answer is 0."
  (let ((longest 0)
        (current 0))
    (loop for c across probe
          do (if (char= c #\Newline)
                 (progn (when (> current longest) (setf longest current))
                        (setf current 0))
                 (incf current (utf8-width (char-code c)))))
    (max longest current)))

;;; ---------------------------------------------------------------------------
;;; looks_minified
;;; ---------------------------------------------------------------------------

(defun looks-minified-p (text)
  "Rust `looks_minified`. T when TEXT looks like minified JavaScript.

The test, in order:

  1. truncate to 200000 UTF-16 units;
  2. if that head carries no code keyword and no `=>`, answer NIL — this is what
     keeps base64 payloads, JSON and plain prose from being reformatted;
  3. fewer than 4 `\\n`-separated lines answers T outright: minified source is
     usually one enormous line, and a one-liner that mentions `var` is minified
     far more often than not;
  4. otherwise minified means one line over 500 BYTES, or an average over 220
     UTF-16 units per line.

Step 3 short-circuits before either limit is consulted, so both limits are only
reachable at 4+ lines. The gate pins both sides of that boundary, since a port
that checked the limits first would answer differently on a 3-line 600-byte
input."
  (let ((probe (utf16-prefix text *probe-units*)))
    (unless (code-signal-p probe)
      (return-from looks-minified-p nil))
    (let ((line-count (1+ (count #\Newline probe))))
      (when (< line-count 4)
        (return-from looks-minified-p t))
      (or (> (longest-line-bytes probe) *longest-line-limit*)
          (> (/ (float (utf16-length probe) 1d0)
                (float line-count 1d0))
             *average-line-limit*)))))

;;; ---------------------------------------------------------------------------
;;; Byte <-> character index bridges
;;; ---------------------------------------------------------------------------

(defun byte-to-char-index (text)
  "A vector mapping UTF-8 BYTE offset to CHARACTER index, plus a trailing entry
for the end.

The formatter walks bytes (see the file header) while the scanner module walks
characters — it is shared with string-literal collection, where character
indexes are the natural unit. Rather than maintain a second scanner, the byte
loop converts at the four call sites. The conversion is total and exact because
every byte the loop can start a construct at is ASCII (`\"`, `'`, `` ` ``, `/`,
`{`, `}`, `;`, `(`, `)`, `[`, `]`) and no ASCII byte occurs inside a multi-byte
sequence, so those offsets always land on a character boundary."
  (let ((expected (utf8-byte-length text))
        (map (make-array 0 :adjustable t :fill-pointer 0)))
    (loop for c across text
          for char-index from 0
          do (vector-push-extend char-index map)
             (loop repeat (1- (utf8-width (char-code c)))
                   do (vector-push-extend char-index map)))
    (vector-push-extend (length text) map)
    (assert (= (fill-pointer map) (1+ expected)) ()
            "byte->char map has ~a entries, expected ~a for ~a bytes"
            (fill-pointer map) (1+ expected) expected)
    (coerce map 'simple-vector)))

(defun char-to-byte-index (text)
  "A vector mapping CHARACTER index to UTF-8 BYTE offset, plus a trailing entry
for the end — the inverse of `byte-to-char-index`. Needed because a scanner skip
answers a character index and the main loop must resume at a byte."
  (let ((map (make-array 0 :adjustable t :fill-pointer 0))
        (offset 0))
    (loop for c across text
          do (vector-push-extend offset map)
             (incf offset (utf8-width (char-code c))))
    (vector-push-extend offset map)
    (coerce map 'simple-vector)))

;;; ---------------------------------------------------------------------------
;;; beautify_js
;;; ---------------------------------------------------------------------------

(defun indent-spaces (indent)
  "`\" \".repeat(indent * 2)` — two spaces per level.

Returns a string, and an empty one at depth 0. Not `format`: this runs once per
brace and once per statement, so `format nil` here is the hot path of the whole
function."
  (let ((n (* 2 indent)))
    (if (zerop n) "" (make-string n :initial-element #\Space))))

(defun beautify-js (text &optional max-bytes)
  "Rust `beautify_js(text, max_bytes)` with NIL MAX-BYTES meaning no budget.
Returns a fresh string.

A structural reformatter, not a parser: brace blocks get one statement per line
with two-space indent, content inside brackets stays inline, and strings,
templates, comments and regexes pass through untouched.

THE OUTPUT ALWAYS ENDS IN A NEWLINE — js-beautify's `end_with_newline` default
that the original relied on — so empty input answers `\"\\n\"`, not `\"\"`.

Unit notes, each load-bearing:

  - The loop walks BYTES. A byte that is not structural falls to the catch-all
    and is emitted as `(code-char byte)`, so a multi-byte character outside a
    string/comment/regex is split into one Latin-1 code point per byte. That is
    the shipped engine's behaviour; reproducing it is deliberate (header, note 3).
  - `line-has-code` decides whether a closing `}` needs a newline first. Strings
    and regexes SET it; COMMENTS DO NOT — which is why `a();//x\\n{b()}` and
    `a();/*c*/{b()}` both open the brace on the comment's line.
  - `paren-depth` may go negative (`)` with no `(`) and every test is `<= 0`, so
    a stray closer is treated as top level rather than as an error. It is a
    signed integer, not a natural.
  - An inline `{` clears `line-has-code` too: the Rust assignment sits after the
    if/else, not inside the top-level branch."
  (let ((limit (effective-limit max-bytes)))
    (when (> (utf16-length text) limit)
      ;; the refusal path — the caller compares the result with the input to
      ;; decide whether a beautified file is worth writing at all, so returning
      ;; a truncated prefix would corrupt it
      (return-from beautify-js (copy-seq text))))
  (let* ((text (string text))
         (octets (sb-ext:string-to-octets text :external-format :utf-8))
         (nbytes (length octets))
         (b->c (byte-to-char-index text))
         (c->b (char-to-byte-index text))
         (out (make-array 0 :element-type 'character
                            :adjustable t :fill-pointer 0))
         (indent 0)
         (paren-depth 0)
         (line-has-code nil))
    (assert (= nbytes (utf8-byte-length text)) ()
            "octet count ~a disagrees with utf8-byte-length ~a"
            nbytes (utf8-byte-length text))

    (labels
        ((emit (c) (vector-push-extend c out))
         (emit-string (s) (loop for c across s do (vector-push-extend c out)))
         (ends-with-newline-p ()
           (and (plusp (fill-pointer out))
                (char= (char out (1- (fill-pointer out))) #\Newline)))
         (ends-with-non-whitespace-p ()
           "`out.ends_with(|c: char| !c.is_whitespace())`. Empty OUT answers NIL,
so a `{` as the very first character does not get a leading space."
           (and (plusp (fill-pointer out))
                (not (rust-whitespace-code-p
                      (char-code (char out (1- (fill-pointer out))))))))
         ;; copy a construct verbatim: the Rust slices `text[i..end]` as &str, so
         ;; a literal or comment is reproduced exactly, multi-byte characters
         ;; included — the mojibake only affects the byte-at-a-time path
         (copy-span (byte-start byte-end)
           (emit-string (subseq text (aref b->c byte-start) (aref b->c byte-end)))))

      (let ((i 0))
        (loop while (< i nbytes)
              do (let ((ch (aref octets i)))
                   (cond
                     ;; ---- literals: quote, backtick ----------------------
                     ((or (= ch 34) (= ch 39) (= ch 96))        ; " ' `
                      (let* ((start (aref b->c i))
                             (end-char (if (= ch 96)
                                           (skip-template text start)
                                           (skip-quoted text start (code-char ch))))
                             (end (aref c->b end-char)))
                        (copy-span i end)
                        ;; a literal IS code: it is what makes `= {...}` and
                        ;; `x = \"a\"` count as content before a brace
                        (setf line-has-code t)
                        (setf i end)))
                     ;; ---- comments: copied, but NOT code -----------------
                     ((and (= ch 47) (< (1+ i) nbytes) (= (aref octets (1+ i)) 47))
                      (let* ((start (aref b->c i))
                             (end-char (skip-line-comment text start))
                             (end (aref c->b end-char)))
                        (copy-span i end)
                        (setf i end)))
                     ((and (= ch 47) (< (1+ i) nbytes) (= (aref octets (1+ i)) 42))
                      (let* ((start (aref b->c i))
                             (end-char (skip-block-comment text start))
                             (end (aref c->b end-char)))
                        (copy-span i end)
                        (setf i end)))
                     ;; ---- regex literals ---------------------------------
                     ((and (= ch 47) (regex-start-p text (aref b->c i)))
                      (let* ((start (aref b->c i))
                             (end-char (skip-regex text start))
                             (end (aref c->b end-char)))
                        (copy-span i end)
                        (setf line-has-code t)
                        (setf i end)))
                     ;; ---- bracket depth: never broken across lines ------
                     ((or (= ch 40) (= ch 91))                  ; ( [
                      (incf paren-depth)
                      (emit (code-char ch))
                      (incf i))
                     ((or (= ch 41) (= ch 93))                  ; ) ]
                      (decf paren-depth)
                      (emit (code-char ch))
                      (incf i))
                     ;; ---- open brace ------------------------------------
                     ((= ch 123)                                ; {
                      (if (<= paren-depth 0)
                          (progn
                            ;; `){` becomes `) {`; a `{` opening an object
                            ;; literal inside brackets stays inline instead
                            (when (ends-with-non-whitespace-p)
                              (emit #\Space))
                            (emit #\{)
                            (emit #\Newline)
                            (incf indent)
                            (emit-string (indent-spaces indent)))
                          (emit #\{))
                      ;; cleared for BOTH branches — the Rust assignment is
                      ;; after the if/else, so an inline `{` clears it as well
                      (setf line-has-code nil)
                      (incf i))
                     ;; ---- close brace -----------------------------------
                     ((= ch 125)                                ; }
                      (if (<= paren-depth 0)
                          (progn
                            (when line-has-code (emit #\Newline))
                            ;; saturating_sub: a `}` with no open block must not
                            ;; wrap `indent` around to a huge number
                            (setf indent (max 0 (1- indent)))
                            (emit-string (indent-spaces indent))
                            (emit #\})
                            (emit #\Newline)
                            (emit-string (indent-spaces indent))
                            (setf line-has-code nil))
                          (emit #\}))
                      (incf i))
                     ;; ---- statement terminator --------------------------
                     ((= ch 59)                                 ; ;
                      (emit #\;)
                      (if (<= paren-depth 0)
                          (progn
                            (emit #\Newline)
                            (emit-string (indent-spaces indent))
                            (setf line-has-code nil))
                          ;; inside brackets a `;` only separates inline content,
                          ;; so it counts as code seen on this line
                          (setf line-has-code t))
                      (incf i))
                     ;; ---- everything else -------------------------------
                     (t
                      (unless (byte-whitespace-p ch)
                        (setf line-has-code t))
                     ;; `byte as char`: a byte above #x7F becomes its own code
                     ;; point, which is how `é` (C3 A9) turns into `Ã©`
                     (emit (code-char ch))
                     (incf i)))))            ; incf, t-clause, cond, ch-let, loop

        ;; js-beautify's `end_with_newline` default
        (unless (ends-with-newline-p)
          (emit #\Newline)))
      (coerce out 'string))))
