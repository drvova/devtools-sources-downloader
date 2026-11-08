;;;; transforms.lisp — the peel chain's decoder helpers, ported from transforms.rs.
;;;;
;;;; This file currently holds only the URI-component codec, which is the piece
;;;; scanner/sourcemaps/panel all reach for. The peel chain itself (`peel_text`,
;;;; `collect_eval_payloads`, SOURCE_URL_COMMENT) lands with the pipeline slice,
;;;; because those consume detectors, packers and jsfuck and would be a forward
;;;; dependency until those exist.
;;;;
;;;; ONE DEFINITION. `vovas.engine.text` used to carry a private copy of the
;;;; strict decoder; it now calls this one. Two implementations of a decoder is
;;;; how the panel and the engine end up disagreeing about an archive path.

(in-package :vovas.engine.transforms)

;;; ---------------------------------------------------------------------------
;;; decodeURIComponent
;;; ---------------------------------------------------------------------------

(defun hex-digit-value (c)
  "The value of C as a hex digit, or NIL. Returning NIL rather than 0 for a
non-digit is what makes an invalid escape fail the decode instead of silently
producing a NUL byte."
  (position (char-downcase c) "0123456789abcdef"))

(defun decode-uri-component (text)
  "JS `decodeURIComponent`: strict %XX decoding, `+` is NOT a space, and an
invalid sequence or invalid UTF-8 answers NIL where the JS throws.

Two failure modes the strictness covers, both of which a lenient decoder would
silently accept:
  - a `%` with fewer than two characters after it
  - a `%XX` triple whose bytes are not valid UTF-8 (lone continuation bytes,
    overlong forms, surrogate encodings, truncated tails)
"
  (let* ((n (length text))
         (out (make-array 0 :element-type '(unsigned-byte 8)
                            :adjustable t :fill-pointer 0)))
    (loop with i = 0
          while (< i n)
          do (let ((c (char text i)))
               (if (char= c #\%)
                   (progn
                     ;; needs TWO characters after the '%'
                     (when (> (+ i 2) (1- n))
                       (return-from decode-uri-component nil))
                     (let ((hi (hex-digit-value (char text (1+ i))))
                           (lo (hex-digit-value (char text (+ i 2)))))
                       (unless (and hi lo)
                         (return-from decode-uri-component nil))
                       (vector-push-extend (+ (* 16 hi) lo) out)
                       (incf i 3)))
                   (progn
                     ;; a literal non-ASCII character contributes its UTF-8 bytes;
                     ;; `loop ... across` not `dolist`, which needs a LIST and the
                     ;; octets come back as a vector
                     (loop for b across (sb-ext:string-to-octets (string c)
                                                                 :external-format :utf-8)
                           do (vector-push-extend b out))
                     (incf i)))))
    (utf8-strict-decode out)))

(defun utf8-strict-decode (octets)
  "Decode OCTETS as UTF-8, answering NIL for any malformed sequence.

JavaScript's decodeURIComponent REJECTS overlong forms, encoded surrogates and
truncated tails; it does not substitute U+FFFD. A permissive decoder here would
turn `%ZZ`-adjacent garbage into plausible-looking paths, which is worse than
failing."
  (let ((n (length octets))
        (out (make-string-output-stream)))
    (labels ((at (i) (aref octets i)))
      (loop with i = 0
            while (< i n)
            do (let ((b (at i)))
                 (cond
                   ((< b #x80)
                    (write-char (code-char b) out)
                    (incf i))
                   ((= (logand b #xE0) #xC0)
                    (when (> (+ i 2) n) (return-from utf8-strict-decode nil))
                    (let ((b2 (at (1+ i))))
                      (unless (= (logand b2 #xC0) #x80)
                        (return-from utf8-strict-decode nil))
                      (let ((code (logior (ash (logand b #x1F) 6) (logand b2 #x3F))))
                        (when (< code #x80)
                          (return-from utf8-strict-decode nil))     ; overlong
                        (write-char (code-char code) out))
                      (incf i 2)))
                   ((= (logand b #xF0) #xE0)
                    (when (> (+ i 3) n) (return-from utf8-strict-decode nil))
                    (let ((b2 (at (1+ i))) (b3 (at (+ i 2))))
                      (unless (and (= (logand b2 #xC0) #x80)
                                   (= (logand b3 #xC0) #x80))
                        (return-from utf8-strict-decode nil))
                      (let ((code (logior (ash (logand b #x0F) 12)
                                          (ash (logand b2 #x3F) 6)
                                          (logand b3 #x3F))))
                        (when (or (< code #x800) (<= #xD800 code #xDFFF))
                          (return-from utf8-strict-decode nil))     ; overlong / surrogate
                        (write-char (code-char code) out))
                      (incf i 3)))
                   ((= (logand b #xF8) #xF0)
                    (when (> (+ i 4) n) (return-from utf8-strict-decode nil))
                    (let ((b2 (at (1+ i))) (b3 (at (+ i 2))) (b4 (at (+ i 3))))
                      (unless (and (= (logand b2 #xC0) #x80)
                                   (= (logand b3 #xC0) #x80)
                                   (= (logand b4 #xC0) #x80))
                        (return-from utf8-strict-decode nil))
                      (let ((code (logior (ash (logand b #x07) 18)
                                          (ash (logand b2 #x3F) 12)
                                          (ash (logand b3 #x3F) 6)
                                          (logand b4 #x3F))))
                        (when (or (< code #x10000) (> code #x10FFFF))
                          (return-from utf8-strict-decode nil))
                        (write-char (code-char code) out))
                      (incf i 4)))
                   (t (return-from utf8-strict-decode nil)))))
      (get-output-stream-string out))))

;;; ---------------------------------------------------------------------------
;;; The sourceURL comment pattern
;;;
;;; transforms.rs owns this constant and bundler.rs imports it. It is spelled
;;; ONCE here; bundler.lisp must reference this rather than its own copy. The
;;; bundler gate asserts the two agree, so a divergence fails loudly instead of
;;; quietly changing which module names get written into the archive.
;;; ---------------------------------------------------------------------------

(defparameter *source-url-comment* "//[#@]\\s*sourceURL\\s*=\\s*(\\S+)"
  "The `//# sourceURL=` comment pattern, verbatim from transforms.rs's
SOURCE_URL_COMMENT.")

(defparameter *source-url-scanner*
  (cl-ppcre:create-scanner *source-url-comment*)
  "The compiled form of `*source-url-comment*`. Compiled once, as the Rust keeps a
`LazyLock<Regex>`: `peel-text` asks for a sourceURL on EVERY layer it peels.")

;;; ===========================================================================
;;; The peel chain: eval payloads, the unwrap transforms, refusals, peel_text
;;; ===========================================================================
;;;
;;; LOAD ORDER. This file is compiled BEFORE decoders, scanner, digest, packers
;;; and detectors (vovas-engine.asd lists transforms fourth), so those package
;;; names do not exist yet at READ time and a `pkg:name` form here would abort
;;; the build with "package does not exist". Every call into them therefore goes
;;; through `call-foreign`, which resolves the symbol at RUN time - the same
;;; discipline detectors.lisp uses for its stage seams. Resolution failures
;;; SIGNAL rather than answering NIL: a silently absent dependency would make
;;; `peel-text` report "no layers" for every input, which reads as a clean
;;; result and is the worst possible failure mode here.

(defparameter *foreign-functions* (make-hash-table :test #'equal)
  "Cache of resolved (package-name . symbol-name) -> function. Only HITS are
cached; a miss is the ordinary state while the parallel slices land and caching
it would freeze this module into \"no dependency\" forever.")

(defun foreign-function (package-name symbol-name)
  "The function PACKAGE-NAME::SYMBOL-NAME, or NIL when that module is not loaded."
  (let ((key (cons package-name symbol-name)))
    (multiple-value-bind (cached present-p) (gethash key *foreign-functions*)
      (if present-p
          cached
          (let ((package (find-package package-name)))
            (when package
              (multiple-value-bind (symbol status) (find-symbol symbol-name package)
                (when (and symbol
                           (member status '(:external :internal))
                           (fboundp symbol))
                  (setf (gethash key *foreign-functions*) symbol)))))))))

(defun call-foreign (package-name symbol-name &rest arguments)
  "Call a function another slice owns, or SIGNAL that the slice is absent."
  (let ((function (foreign-function package-name symbol-name)))
    (unless function
      (error "vovas.engine.transforms needs ~a::~a, which is not loaded"
             package-name symbol-name))
    (apply function arguments)))

;;; ---------------------------------------------------------------------------
;;; Small shared helpers
;;; ---------------------------------------------------------------------------

(defparameter *js-s-chars*
  (coerce (list #\Space #\Tab #\Newline (code-char 11) #\Page #\Return) 'string)
  "util.rs `JS_S` as actual characters: space, tab, LF, VT, FF, CR. Written with
`code-char` for VT because a CL string literal neither processes `\\u000b` nor
keeps a raw VT readable in the source.")

(defun split-on-char (text separator)
  "Rust `str::split(SEPARATOR)`. Empty input answers one empty piece, as Rust
does, so a caller's count cannot differ on that edge."
  (let ((parts '())
        (start 0)
        (n (length text)))
    (loop for i from 0 below n
          when (char= (char text i) separator)
            do (push (subseq text start i) parts)
               (setf start (1+ i)))
    (push (subseq text start n) parts)
    (nreverse parts)))

(defparameter *lower-hex-digits* "0123456789abcdef"
  "Lowercase hex, explicitly. `(format nil \"~x\" n)` is not usable here: SBCL's
`~x` case behaviour depends on `*print-case*` and emitted UPPERCASE once already,
which silently changed a digest comparison.")

(defun json-quote (text)
  "`serde_json::to_string` of a string: the JSON string literal, quotes included.

Escapes are serde_json's: the two structural characters, the five short control
escapes, and `\\u00XX` (LOWERCASE digits) for the other C0 controls. Non-ASCII is
emitted literally, because serde_json does not escape it."
  (with-output-to-string (out)
    (write-char #\" out)
    (loop for c across text
          for code = (char-code c)
          do (cond
               ((char= c #\") (write-string "\\\"" out))
               ((char= c #\\) (write-string "\\\\" out))
               ((char= c #\Newline) (write-string "\\n" out))
               ((char= c #\Return) (write-string "\\r" out))
               ((char= c #\Tab) (write-string "\\t" out))
               ((= code 8) (write-string "\\b" out))
               ((= code 12) (write-string "\\f" out))
               ((< code #x20)
                (write-string "\\u00" out)
                (write-char (char *lower-hex-digits* (ash code -4)) out)
                (write-char (char *lower-hex-digits* (logand code #x0F)) out))
               (t (write-char c out))))
    (write-char #\" out)))

(defun code-unit-char (code)
  "A UTF-16 code unit as a character: surrogates degrade to U+FFFD, which is what
`char::from_u32` answers for them (Rust cannot hold a lone surrogate in a `char`)."
  (if (<= #xD800 code #xDFFF)
      (code-char #xFFFD)
      (or (code-char code) (code-char #xFFFD))))

(defun replace-matches (scanner text replacement)
  "Replace every match of SCANNER in TEXT with `(funcall REPLACEMENT match-string)`.

Written by hand rather than through `cl-ppcre:regex-replace-all`'s callback form,
whose callback arity differs from what this needs: the callback here is invoked
with ONE unambiguous argument, the whole match.

The replacement's answer is coerced to a string. A `char`-answering replacement
(a single decoded escape, say) would otherwise reach `write-string` and die with
\"#\\A is not of type VECTOR when binding N-ARRAY\" - a message that names an
internal array and points nowhere near the real mistake."
  (let ((out (make-string-output-stream))
        (pos 0)
        (n (length text)))
    (loop for (match-start match-end) on (cl-ppcre:all-matches scanner text) by #'cddr
          do (write-string text out :start pos :end match-start)
             (write-string (string (funcall replacement
                                            (subseq text match-start match-end)))
                           out)
             (setf pos match-end))
    (write-string text out :start pos :end n)
    (get-output-stream-string out)))

;;; ---------------------------------------------------------------------------
;;; printableRatio / gzip_format / inflate_bytes
;;;
;;; decoders.lisp carries the escape and base64 halves of decoders.rs; the
;;; inflate half never landed with it (its comment says it belongs with the
;;; binary tier). `unwrap_base64` needs exactly these three, so they live here
;;; rather than being reached through `vovas.engine.zip:inflate-raw`, which is
;;; RAW deflate only and refuses both gzip and zlib framing.
;;; ---------------------------------------------------------------------------

(defun printable-ratio (text)
  "decoders.rs `printable_ratio`: the share of CHARACTERS that are tab, LF, CR or
printable ASCII. Measured on characters, not bytes, exactly as the Rust does."
  (let ((total (length text)))
    (if (zerop total)
        0d0
        (let ((printable 0))
          (loop for c across text
                for code = (char-code c)
                do (when (or (= code 9) (= code 10) (= code 13)
                             (and (>= code 32) (/= code 127)))
                     (incf printable)))
          (/ (coerce printable 'double-float) (coerce total 'double-float))))))

(defun gzip-format (bytes)
  "`gzip_format`: :GZIP for the 1f 8b magic, :DEFLATE for a zlib header, else NIL.

The length test is `> 2`, not `>= 2`: a two-byte body cannot carry a header plus
payload, so the Rust refuses to look at it and so does this."
  (let ((n (length bytes)))
    (when (> n 2)
      (let ((b0 (aref bytes 0))
            (b1 (aref bytes 1)))
        (cond
          ((and (= b0 #x1f) (= b1 #x8b)) :gzip)
          ((and (= b0 #x78) (member b1 '(#x01 #x9c #xda))) :deflate)
          (t nil))))))

(defun inflate-bytes (bytes format)
  "`inflate_bytes`: gzip or zlib inflate BYTES, NIL when the stream is corrupt.

The COERCION to a simple octet vector is not optional. `decode-base64-to-bytes`
answers an ADJUSTABLE vector with a fill pointer (it has to - it extends), and
chipz signals \"is not of type (SIMPLE-ARRAY (UNSIGNED-BYTE 8) (*)) when setting
slot CHIPZ::INPUT\" for anything else. That message names a chipz structure slot
and reads as a corrupt stream, which is the wrong diagnosis entirely.

Strict, with no padding-slack trick: the zip reader needs slack because chipz
wants one more read past a raw final block, while a framed gzip/zlib stream
carries its own trailer and inflates from its exact bytes (measured). Slack here
would turn a truncated payload into a plausible short body, which is worse than
the NIL."
  (handler-case
      (chipz:decompress nil
                        (if (eq format :gzip) 'chipz:gzip 'chipz:zlib)
                        (coerce bytes '(simple-array (unsigned-byte 8) (*))))
    (error () nil)))

;;; ---------------------------------------------------------------------------
;;; is_literal_only_arg
;;; ---------------------------------------------------------------------------

(defparameter *string-literal-scanner*
  (cl-ppcre:create-scanner
   (concatenate 'string
                "\"(?:[^\"\\\\]|\\\\.)*\""
                "|'(?:[^'\\\\]|\\\\.)*'"
                "|`(?:[^`\\\\]|\\\\.)*`"))
  "`\"(?:[^\"\\\\]|\\\\.)*\"|'(?:[^'\\\\]|\\\\.)*'|`(?:[^`\\\\]|\\\\.)*``: a whole
string literal of any of the three quote styles. The character classes exclude
their own quote and the backslash so an escaped quote does not end the literal.")

(defparameter *js-space-run-scanner*
  (cl-ppcre:create-scanner (concatenate 'string "[" *js-s-chars* "]+"))
  "`[{JS_S}]+`. Built from the CHARACTERS, so the class contains a real tab, LF,
VT, FF and CR instead of the two-character sequences a naive literal would give.")

(defparameter *argument-punctuation-scanner*
  (cl-ppcre:create-scanner "[+(),]")
  "The punctuation a concatenation of literals may keep: `+`, parens, commas.")

(defun is-literal-only-arg (arg)
  "transforms.rs `is_literal_only_arg`: T when everything left after removing the
string literals is whitespace and `+(),` - i.e. the argument is a concatenation of
literals rather than an expression.

The guard matters because `eval(a + b)` must keep its EXPRESSION as the payload
(the next pass may peel an atob inside it), while `eval(\"a\" + \"b\")` must keep
the JOINED text."
  (let* ((stripped (cl-ppcre:regex-replace-all *string-literal-scanner* arg ""))
         (stripped (cl-ppcre:regex-replace-all *js-space-run-scanner* stripped ""))
         (stripped (cl-ppcre:regex-replace-all *argument-punctuation-scanner*
                                               stripped "")))
    (zerop (length stripped))))

;;; ---------------------------------------------------------------------------
;;; The stage / payload structures
;;;
;;; Plain plists, with the ORACLE's key names: `TextStage` is
;;; `serde(rename_all = "camelCase")`, so `input_bytes` reaches JSON as
;;; `inputBytes` and the keyword is :INPUT-BYTES. The gate compares these plists
;;; field by field, so a renamed key fails instead of being accommodated.
;;; ---------------------------------------------------------------------------

(defun make-text-stage (&key depth tool input-bytes output-bytes digest source-url)
  "`TextStage { depth, tool, input_bytes, output_bytes, digest, source_url }`.
SOURCE-URL is NIL when no `//# sourceURL=` comment was found, which serialises
as JSON null."
  (list :depth depth
        :tool tool
        :input-bytes input-bytes
        :output-bytes output-bytes
        :digest digest
        :source-url source-url))

(defun make-binary-stage (&key depth tool detail)
  "`BinaryStage { depth, tool, detail }` - the binary tier's untagged `Stage`
variant. `peel-text` never emits one; it exists so the binary tier and the report
writer share one shape."
  (list :depth depth :tool tool :detail detail))

(defun make-eval-payload (head code end)
  "`EvalPayload { head, code, end }`: HEAD is the index of the `eval` /
`Function` keyword, CODE the collected payload, END the index just past the
closing paren."
  (list :head head :code code :end end))

(defun eval-payload-head (payload) (getf payload :head))
(defun eval-payload-code (payload) (getf payload :code))
(defun eval-payload-end (payload) (getf payload :end))

(defun make-peel-result (&key stages outputs final refusals)
  "`PeelResult { stages, outputs, final, refusals }`. `final_text` is renamed to
`final` on the wire, hence :FINAL here."
  (list :stages stages :outputs outputs :final final :refusals refusals))

(defun peel-result-stages (result) (getf result :stages))
(defun peel-result-outputs (result) (getf result :outputs))
(defun peel-result-final (result) (getf result :final))
(defun peel-result-refusals (result) (getf result :refusals))

;;; ---------------------------------------------------------------------------
;;; collect_eval_payloads / unwrap_eval
;;; ---------------------------------------------------------------------------

(defun collect-eval-payloads (text)
  "transforms.rs `collect_eval_payloads`: the eval() and Function() payloads of
TEXT, in source order, deduplicated by CODE.

Two payload shapes, and the distinction is the whole function:

  - `eval(\"a\" + \"b\")` / `eval('a','b')` - a literal-only argument. The payload
    is the JOINED literal values, because that is the text the next pass must
    look inside.
  - `eval(<expression>)` - the expression itself, so a nested `atob(...)` or
    `decodeURIComponent(...)` is still there to be recognised.

`Function(...)` takes the LAST string argument as the body, which is where the
code always is; the earlier arguments are parameter names."
  (let ((payloads '())
        (seen (make-hash-table :test #'equal))
        (minimum vovas.engine.util:*limits-min-payload-length*))
    (labels ((push-payload (head code end)
               "Insert unless CODE was already collected. The dedupe is on the
code, not on the head: the same payload reached from two heads is one layer."
               (unless (gethash code seen)
                 (setf (gethash code seen) t)
                 (push (make-eval-payload head code end) payloads))))
      ;; --- eval(...) -----------------------------------------------------
      (dolist (head (call-foreign "VOVAS.ENGINE.DETECTORS" "EVAL-HEADS" text))
        (let ((paren (search "(" text :start2 head)))
          (when paren
            (let ((close (call-foreign "VOVAS.ENGINE.SCANNER" "FIND-BALANCED"
                                       text paren)))
              (when close
                (let* ((arg (subseq text (1+ paren) (1- close)))
                       (parts (call-foreign "VOVAS.ENGINE.SCANNER"
                                            "COLLECT-STRING-LITERALS" arg 0)))
                  (if (and parts (is-literal-only-arg arg))
                      (let ((joined (with-output-to-string (out)
                                      (dolist (part parts)
                                        (write-string (getf part :value) out)))))
                        (when (>= (vovas.engine.util:utf16-length joined) minimum)
                          (push-payload head joined close)))
                      (when (>= (vovas.engine.util:utf16-length arg) minimum)
                        (push-payload head arg close)))))))))
      ;; --- Function(...) -------------------------------------------------
      (dolist (head (call-foreign "VOVAS.ENGINE.DETECTORS" "FUNCTION-HEADS" text))
        (let ((paren (search "(" text :start2 (1- (cdr head)))))
          (when paren
            (let ((close (call-foreign "VOVAS.ENGINE.SCANNER" "FIND-BALANCED"
                                       text paren)))
              (when close
                (let* ((args (call-foreign "VOVAS.ENGINE.SCANNER"
                                           "COLLECT-STRING-LITERALS"
                                           (subseq text (1+ paren) (1- close)) 0))
                       (body (and args (getf (car (last args)) :value))))
                  (when (and body (>= (vovas.engine.util:utf16-length body) minimum))
                    (push-payload (car head) body close))))))))
      ;; HEAD ascending, stable, as the Rust's `sort_by_key(|p| p.head)` is.
      (stable-sort (nreverse payloads)
                   (lambda (a b) (< (eval-payload-head a) (eval-payload-head b)))))))

(defun unwrap-eval (text)
  "`unwrap_eval`: the collected payloads joined with \"\\n;\\n\", or NIL when the
text carries none.

The separator is not cosmetic: several payloads concatenated with nothing would
merge the tail of one script into the head of the next and produce text that
parses as neither. It is written out explicitly rather than left to the reader."
  (let ((payloads (collect-eval-payloads text)))
    (when payloads
      (with-output-to-string (out)
        (loop for payload in payloads
              for first = t then nil
              do (unless first (write-char #\Newline out) (write-char #\; out)
                               (write-char #\Newline out))
                 (write-string (eval-payload-code payload) out))))))

;;; ---------------------------------------------------------------------------
;;; unwrap_base64
;;; ---------------------------------------------------------------------------

(defun unwrap-base64 (text)
  "`unwrap_base64`: the longest base64 literal decoded, or NIL.

Answers `(:text STRING)` for plain text and `(:inflate FORMAT BYTES)` when the
decoded bytes are a gzip/zlib stream - the caller has to inflate, and doing it
here would hide the format from the layer report.

The 0.85 printable gate is what keeps a base64 blob that happens to decode to
random binary from being reported as a text layer: random bytes score about 0.37,
while real JavaScript, JSON or HTML score 1.0."
  (let* ((literal (call-foreign "VOVAS.ENGINE.DETECTORS"
                                "LONGEST-BASE64-LITERAL" text))
         (bytes (and literal
                     (call-foreign "VOVAS.ENGINE.DECODERS"
                                   "DECODE-BASE64-TO-BYTES" literal))))
    (when (and bytes (plusp (length bytes)))
      (let ((format (gzip-format bytes)))
        (if format
            (list :inflate format bytes)
            (let ((decoded (call-foreign "VOVAS.ENGINE.DECODERS"
                                         "BYTES-TO-TEXT" bytes)))
              (when (>= (printable-ratio decoded) 0.85d0)
                (list :text decoded))))))))

;;; ---------------------------------------------------------------------------
;;; unwrap_hex_escapes
;;; ---------------------------------------------------------------------------

(defparameter *x-escape-scanner* (cl-ppcre:create-scanner "\\\\x([0-9a-fA-F]{2})")
  "`\\\\x([0-9a-fA-F]{2})` - a REAL backslash followed by `x` and two hex digits.
The Lisp string has four backslashes so the regex sees `\\\\x`.")

(defparameter *u-escape-scanner* (cl-ppcre:create-scanner "\\\\u([0-9a-fA-F]{4})")
  "`\\\\u([0-9a-fA-F]{4})`, the same shape for the four-digit form.")

(defun hex-escape-replacement (match)
  "The character a `\\xNN` / `\\uNNNN` MATCH stands for.

MATCH is the whole escape, e.g. `\\x41` or `\\u00e9`: the backslash is character
0 and the form letter character 1, so the digits start at 2 and run 2 or 4 wide.
A surrogate code unit degrades to U+FFFD, as `char::from_u32` does."
  (let* ((width (if (char= (char match 1) #\u) 4 2))
         (code (parse-integer match :start 2 :end (+ 2 width) :radix 16)))
    (code-unit-char code)))

(defun unwrap-hex-escapes (text)
  "`unwrap_hex_escapes`: `\\xNN` decoded, then `\\uNNNN` decoded on the result.

Gated on the PRESENCE of a `\\x` escape: a text with only `\\uNNNN` escapes is
the `escape()` family's business (`unwrap_unescape`), and answering it here would
mean two layers claim the same input. NIL when there is no `\\x` at all."
  (unless (cl-ppcre:scan *x-escape-scanner* text)
    (return-from unwrap-hex-escapes nil))
  (let ((stage (replace-matches *x-escape-scanner* text #'hex-escape-replacement)))
    (replace-matches *u-escape-scanner* stage #'hex-escape-replacement)))

;;; ---------------------------------------------------------------------------
;;; percent_encode_utf8 / unwrap_unescape
;;; ---------------------------------------------------------------------------

(defun percent-encode-utf8 (text)
  "`percent_encode_utf8`: every UTF-8 byte as `%XX`, UPPERCASE hex."
  (with-output-to-string (out)
    (loop for byte across (sb-ext:string-to-octets text :external-format :utf-8)
          do (write-char #\% out)
             (write-char (char "0123456789ABCDEF" (ash byte -4)) out)
             (write-char (char "0123456789ABCDEF" (logand byte #x0F)) out))))

(defun unwrap-unescape (text)
  "`unwrap_unescape`: `%uXXXX` rewritten into the `encodeURIComponent` form, then
strictly decoded.

PRESERVED QUIRK, and it is the shipped behaviour rather than a port bug: the
rewrite drops the FIRST character of the percent-encoded replacement, and that
character is the `%` the match already consumed. So `%u0041` becomes `41` and not
`%41`, and a single-byte escape therefore decodes to its literal hex instead of
its character. The Rust does exactly this (`encoded.remove(0)`), the oracle has no
case that reaches it, and inventing the \"fixed\" behaviour here would make this
port disagree with the engine that ships. Reported as an unpinned divergence."
  (let ((windows
          (replace-matches
           (cl-ppcre:create-scanner "%u([0-9a-fA-F]{4})")
           text
           (lambda (match)
             (let* ((code (parse-integer match :start 2 :end 6 :radix 16))
                    (encoded (percent-encode-utf8 (string (code-unit-char code)))))
               (subseq encoded 1))))))
    (decode-uri-component windows)))

;;; ---------------------------------------------------------------------------
;;; js_parse_int / to_uint16 / unwrap_charcode
;;;
;;; `js_parse_int` here is transforms.rs's OWN function, NOT
;;; `Number::parseInt` from number.lisp. They differ and both exist in the Rust:
;;; this one trims, takes an optional sign, then a run of ASCII digits and stops
;;; at the first non-digit - no radix argument, no `0x` handling, no exponent, and
;;; NaN for no digits. Delegating to `vovas.engine.number:parse-int` would import
;;; radix and hex-prefix behaviour this caller must not have.
;;; ---------------------------------------------------------------------------

(defparameter *uint16-modulus* 65536d0
  "2^16 as a double, so the modulo stays in floating point and cannot build a
bignum for a large input.")

(defun transforms-nan ()
  "A quiet NaN built from its bit pattern.

`(/ 0d0 0d0)` is constant-folded by SBCL and the fold SIGNALS
floating-point-invalid-operation, so the arithmetic spelling cannot be used even
through a `let`."
  (sb-kernel:make-double-float #x7ff80000 0))

(defun double-finite-p (value)
  "`f64::is_finite`: neither NaN nor an infinity."
  (and (floatp value)
       (not (sb-ext:float-nan-p value))
       (not (sb-ext:float-infinity-p value))))

(defun js-parse-int (text)
  "transforms.rs `js_parse_int`: JS `parseInt(s, 10)`.

Leading whitespace is trimmed, ONE leading sign is consumed, then the longest run
of ASCII digits; anything after the run stops the parse. No digits at all answers
NaN - the charcode unwrap filters on exactly that, which is how `String.fromCharCode(65,,66)`
loses the empty piece instead of turning it into a NUL."
  (let* ((trimmed (vovas.engine.util:js-trim text))
         (n (length trimmed))
         (i 0)
         (sign 1))
    (when (and (plusp n) (member (char trimmed 0) '(#\- #\+)))
      (when (char= (char trimmed 0) #\-) (setf sign -1))
      (setf i 1))
    (let ((start i)
          (value 0d0))
      (loop while (< i n)
            for code = (char-code (char trimmed i))
            while (<= 48 code 57)
            do (setf value (+ (* value 10d0) (coerce (- code 48) 'double-float)))
               (incf i))
      (if (= i start)
          (transforms-nan)
          (* sign value)))))

(defun to-uint16 (value)
  "JS ToUint16: NaN and the infinities answer 0, everything else is truncated and
wrapped modulo 65536 into 0..65535.

`truncate` then `mod` rather than a type coercion: CL's `mod` FLOORS, so
`(mod -1.0d0 65536.0d0)` is 65535 and the wrap is already the JS one; `rem` would
answer -1 and the character would degrade to U+FFFD instead of wrapping."
  (if (not (double-finite-p value))
      0
      (round (mod (truncate value) *uint16-modulus*))))

(defparameter *charcode-scanner*
  (cl-ppcre:create-scanner "String\\s*\\.\\s*fromCharCode\\s*\\(([\\d\\s,]{7,})\\)")
  "transforms.rs's `String\\s*.\\s*fromCharCode\\s*\\(([\\d\\s,]{7,})\\)`. The
`{7,}` floor is what keeps `String.fromCharCode(10)` - ordinary code - from being
read as an encoded payload.")

(defun unwrap-charcode (text)
  "`unwrap_charcode`: each `String.fromCharCode(a, b, ...)` call replaced by a
JSON-quoted string literal of its characters; NIL when no call changed.

Two details that look like accidents and are the specification:

  - a match whose pieces do not all parse to numbers (fewer than seven finite
    values after filtering) is replaced with the EMPTY STRING, i.e. DELETED from
    the output, and does not count as a change;
  - the replacement is JSON-quoted, so the emitted layer is `\"abc\"` and still
    parses as the JavaScript it is meant to be."
  (let ((changed nil)
        (out (make-string-output-stream))
        (pos 0))
    (loop for (match-start match-end) on (cl-ppcre:all-matches *charcode-scanner* text)
          by #'cddr
          do (write-string text out :start pos :end match-start)
             (let* ((match (subseq text match-start match-end))
                    (open (position #\( match))
                    (close (position #\) match :from-end t))
                    (numbers (subseq match (1+ open) close))
                    (codes (loop for piece in (split-on-char numbers #\,)
                                 for parsed = (js-parse-int (vovas.engine.util:js-trim piece))
                                 when (double-finite-p parsed)
                                   collect parsed)))
               (when (>= (length codes) 7)
                 (setf changed t)
                 (write-string
                  (json-quote (coerce (mapcar (lambda (c) (code-unit-char (to-uint16 c)))
                                              codes)
                                      'string))
                  out)))
             (setf pos match-end))
    (write-string text out :start pos :end (length text))
    (when changed
      (get-output-stream-string out))))

;;; ---------------------------------------------------------------------------
;;; unwrap_reverse
;;; ---------------------------------------------------------------------------

(defun unwrap-reverse (text)
  "`unwrap_reverse`: the text reversed by CHARACTER.

Characters, not UTF-16 units and not bytes, so an astral character stays one
character; the detector that routes here measured the same thing."
  (reverse text))

;;; ---------------------------------------------------------------------------
;;; apply_transform
;;; ---------------------------------------------------------------------------

(defparameter *jsfuck-decode* nil
  "SEAM: `crate::jsfuck::decode_jsfuck`, wired by the integrator once
vovas.engine.jsfuck lands.

While it is NIL the jsfuck branch of `apply-transform` answers NIL, which reads
as \"no transform applied\" and makes `peel-text` skip to the next finding.

TWO ACCEPTABLE RETURN SHAPES, because the two natural spellings both exist and
the seam must not force a copy of one into the other:

  - a STRING or NIL - the decoded text, or \"nothing decoded\";
  - the plist `(:value STRING-OR-NIL :captured BOOLEAN)` that
    `vovas.engine.jsfuck:decode-jsfuck` actually answers. `:value` is taken, and
    a NIL value means no transform regardless of `:captured`.

So `(setf *jsfuck-decode* #'vovas.engine.jsfuck:decode-jsfuck)` is the whole
wiring step, with no adapter function to write or forget.

NOTE the jsfuck oracle case stays stage-free EITHER WAY: the shipped
`decodeJsfuck` answered null for that input (`detectJsfuck` reports purity 100%
but the decode yields no value), so a wired-in decoder produces no layer there
either. That is why this branch cannot be pinned by any of the 17 cases.")

(defparameter *tool-keywords*
  '(("eval-unwrap" . :eval-unwrap)
    ("base64" . :base64)
    ("hex-escape" . :hex-escape)
    ("unescape" . :unescape)
    ("charcode" . :charcode)
    ("reverse" . :reverse)
    ("rot13" . :rot13)
    ("packer" . :packer)
    ("jsfuck" . :jsfuck)
    ("string-array" . :string-array))
  "The wire spelling of a layer -> its keyword. `detect-layers` reports the STRING
(`detectLayers` compares strings on the wire), while this module dispatches on
keywords; keeping the table here means a new layer fails loudly as an unknown
tool instead of falling through a `case` tail as \"no transform\".")

(defun tool-keyword (tool)
  "TOOL as a layer keyword; accepts the wire string or the keyword itself.

A keyword is validated against the table rather than passed through, so a caller
that invents `:base-64` gets the loud unknown-layer error instead of falling into
`apply-transform`'s `case` tail."
  (cond
    ((keywordp tool)
     (if (member tool (mapcar #'cdr *tool-keywords*))
         tool
         (error "unknown layer ~s (known: ~{~a~^ ~})"
                tool (mapcar #'cdr *tool-keywords*))))
    ((stringp tool)
     (or (cdr (assoc tool *tool-keywords* :test #'string=))
         (error "unknown layer ~s (known: ~{~a~^ ~})"
                tool (mapcar #'car *tool-keywords*))))
    (t (error "a layer must be a keyword or a wire string, got ~s" tool))))

(defun jsfuck-decode-value (answer)
  "The decoded TEXT from a jsfuck decoder's ANSWER, or NIL.

Accepts the two shapes `*jsfuck-decode*` documents: a string (or NIL), and the
`(:value STRING-OR-NIL :captured BOOLEAN)` plist that vovas.engine.jsfuck
answers. Anything else SIGNALS rather than being silently discarded: a decoder
returning a number here would otherwise look like \"nothing decoded\" and vanish
from the layer report."
  (cond
    ((null answer) nil)
    ((stringp answer) answer)
    ((and (listp answer) (member :value answer))
     (let ((value (getf answer :value)))
       (unless (or (null value) (stringp value))
         (error "jsfuck decoder answered :value ~s; expected a string or NIL" value))
       value))
    (t (error "jsfuck decoder answered ~s; expected a string, NIL, or a plist with :value"
              answer))))

(defun apply-transform (tool text)
  "`apply_transform`: run the transform for TOOL over TEXT, NIL when the layer
yields no fresh text.

NIL is overloaded on purpose, exactly as in the Rust: \"this tool does not apply\",
\"it applied and produced nothing\", and \"the decoder refused\" all mean the peel
loop should try the next finding. `reverse` and `rot13` are total - they always
produce something - so the loop's `candidate != current` and digest checks are
what stop them from looping."
  (let ((layer (tool-keyword tool)))
    (case layer
      (:eval-unwrap (unwrap-eval text))
      (:base64
       (let ((result (unwrap-base64 text)))
         (when result
           (if (eq (first result) :inflate)
               (let ((inflated (inflate-bytes (third result) (second result))))
                 (and inflated
                      (call-foreign "VOVAS.ENGINE.DECODERS" "BYTES-TO-TEXT" inflated)))
               ;; Even a plain-text decode gets one nested look: the WHOLE text
               ;; trimmed may itself be the base64 blob that decodes to a gzip
               ;; member, which is how a packed config file arrives.
               (let* ((decoded (second result))
                      (as-bytes (call-foreign "VOVAS.ENGINE.DECODERS"
                                              "DECODE-BASE64-TO-BYTES"
                                              (vovas.engine.util:js-trim text)))
                      (nested (and as-bytes (gzip-format as-bytes))))
                 (if nested
                     (let ((inner (inflate-bytes as-bytes nested)))
                       (if inner
                           (call-foreign "VOVAS.ENGINE.DECODERS" "BYTES-TO-TEXT" inner)
                           decoded))
                     decoded))))))
      (:hex-escape (unwrap-hex-escapes text))
      (:unescape (unwrap-unescape text))
      (:charcode (unwrap-charcode text))
      (:reverse (unwrap-reverse text))
      (:rot13 (call-foreign "VOVAS.ENGINE.DETECTORS" "ROT13" text))
      (:packer (call-foreign "VOVAS.ENGINE.PACKERS" "UNPACK-PACKER" text))
      (:string-array (call-foreign "VOVAS.ENGINE.PACKERS"
                                   "TRANSFORM-STRING-ARRAY" text))
      (:jsfuck (and *jsfuck-decode* (jsfuck-decode-value (funcall *jsfuck-decode* text))))
      (t (error "no transform for layer ~s" layer)))))

;;; ---------------------------------------------------------------------------
;;; collect_refusals
;;; ---------------------------------------------------------------------------

(defun collect-refusals (text)
  "`collect_refusals`: the runtime-only shells in TEXT, which are reported and
never decoded because decoding them means EXECUTING them.

Order is the Rust's: aaencode, jjencode, jsfiretruck, then obfuscator-io.

obfuscator-io is reported ONLY when the static string-array pass did not match:
its refusal detail says so, and dropping it when the static pass worked is what
keeps a recoverable file from being labelled unrecoverable."
  (let ((refusals '()))
    (flet ((add (refusal) (when refusal (push refusal refusals))))
      (add (call-foreign "VOVAS.ENGINE.PACKERS" "DETECT-AAENCODE" text))
      (add (call-foreign "VOVAS.ENGINE.PACKERS" "DETECT-JJENCODE" text))
      (add (call-foreign "VOVAS.ENGINE.PACKERS" "DETECT-JSFIRETRUCK" text))
      (let ((obfuscator (call-foreign "VOVAS.ENGINE.PACKERS"
                                      "DETECT-OBFUSCATOR-IO" text)))
        (when obfuscator
          (unless (call-foreign "VOVAS.ENGINE.PACKERS" "DETECT-STRING-ARRAY" text)
            (push (list :tool "obfuscator-io"
                        :detail (format nil "~a (runtime shell; static string-array pass did not match)"
                                        (getf obfuscator :detail))
                        :banner-hits nil
                        :density nil
                        :purity nil
                        :markers nil)
                  refusals)))))
    (nreverse refusals)))

;;; ---------------------------------------------------------------------------
;;; peel_text
;;; ---------------------------------------------------------------------------

(defparameter *max-peel-depth* 8
  "`DEFAULT_MAX_DEPTH`: how many layers one peel walks before it stops. A cap at
all is the point - a transform that produced a fixed point would otherwise spin,
and every iteration costs a detection pass over the whole text.")

(defun source-url-of (text)
  "The `//# sourceURL=` value in TEXT, or NIL."
  (multiple-value-bind (whole groups) (cl-ppcre:scan-to-strings *source-url-scanner* text)
    (declare (ignore whole))
    (when (and groups (plusp (length groups)))
      (let ((capture (aref groups 0)))
        (and capture (copy-seq capture))))))

(defun peel-text (text &optional max-depth)
  "`peel_text`: the detect -> route -> transform -> re-detect loop, ONE layer per
iteration.

MAX-DEPTH follows `util::limit_or`: NIL or 0 means the default of 8, and any
positive value replaces it. `outputs[i]` is the text stage `i` produced and
`stages[i]` is that stage's metadata, so a caller can write real layer artifacts
without inflating the report.

The `seen` digest set is what makes the loop terminate and what makes it correct:
a transform that reproduces a text already produced is NOT a fresh layer, so it is
skipped and the next finding is tried. Without it, `rot13` applied twice returns
the original and every other iteration would peel the same pair forever."
  (let* ((depth-limit (if (and max-depth (plusp max-depth))
                          max-depth
                          *max-peel-depth*))
         (stages '())
         (outputs '())
         (refusals (collect-refusals text))
         (current text)
         (seen (make-hash-table :test #'equal)))
    (flet ((digest-of (string)
             (call-foreign "VOVAS.ENGINE.DIGEST" "SHA256-HEX" string)))
      (setf (gethash (digest-of current) seen) t)
      (loop for depth from 0 below depth-limit
            do (let ((findings (call-foreign "VOVAS.ENGINE.DETECTORS"
                                             "DETECT-LAYERS" current)))
                 (when (null findings) (loop-finish))
                 (let ((produced nil)
                       (used-tool nil))
                   (dolist (finding findings)
                     (let ((candidate (apply-transform (getf finding :tool) current)))
                       (when (and candidate
                                  (plusp (length candidate))
                                  (not (string= candidate current)))
                         (let ((digest (digest-of candidate)))
                           (unless (gethash digest seen)
                             (setf produced candidate
                                   used-tool (getf finding :tool))
                             (setf (gethash digest seen) t)
                             (return))))))
                   (unless produced (loop-finish))
                   (let ((digest (digest-of produced)))
                     (push (make-text-stage
                            :depth (1+ depth)
                            :tool used-tool
                            :input-bytes (vovas.engine.util:utf16-length current)
                            :output-bytes (vovas.engine.util:utf16-length produced)
                            :digest digest
                            :source-url (source-url-of produced))
                           stages)
                     (push produced outputs)
                     (setf current produced)))))
      (make-peel-result :stages (nreverse stages)
                        :outputs (nreverse outputs)
                        :final current
                        :refusals refusals))))
