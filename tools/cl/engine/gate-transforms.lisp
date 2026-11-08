;;;; gate-transforms.lisp — the peel chain's gate, against the wasm oracle.
;;;;
;;;; The oracle key is `peelText` in text-tier-oracle.json: 17 inputs, each with
;;;; `stages`, `outputs`, `final` and `refusals`. Stages fire in exactly THREE of
;;;; the 17 (evalLayer -> eval-unwrap, packed -> packer, stringArray ->
;;;; string-array), so this gate does two things a plain comparison would not:
;;;;
;;;;   1. It asserts each of those three stage-bearing cases EXPLICITLY, field by
;;;;      field including the digest. A port that produced a stage of the right
;;;;      shape with a wrong digest would otherwise pass a shape-only check.
;;;;
;;;;   2. It asserts the 14 stage-free cases produced NO stage, which is what
;;;;      catches an over-eager transform (a `reverse` or `rot13` branch that
;;;;      fires on ordinary source would add a stage to all of them).
;;;;
;;;; TWO COVERAGE GAPS ARE NAMED HERE RATHER THAN HIDDEN:
;;;;
;;;;   - `refusals` is EMPTY in all 17 cases, so the oracle pins nothing about
;;;;     `collect-refusals`. It is pinned STRUCTURALLY below with real aaencode /
;;;;     jjencode / jsfiretruck / obfuscator.io samples; that is a structural
;;;;     pin, NOT an oracle pin, and the report says so.
;;;;   - the `jsfuck` tool branch of `apply-transform` cannot be pinned until
;;;;     vovas.engine.jsfuck lands. The oracle's own `jsfuck` case has an empty
;;;;     stage list and `decodeJsfuck` answered null for it, so neither engine
;;;;     produces a layer there; the seam is asserted to be NIL-and-harmless.

(in-package :vovas.engine.gate)

;;; ---------------------------------------------------------------------------
;;; Oracle adapters
;;; ---------------------------------------------------------------------------

(defparameter *transforms-stage-fields*
  '((:depth . "depth")
    (:tool . "tool")
    (:input-bytes . "inputBytes")
    (:output-bytes . "outputBytes")
    (:digest . "digest")
    (:source-url . "sourceUrl"))
  "`TextStage` in declaration order. The JSON keys are camelCase because the
struct is `serde(rename_all = \"camelCase\")`, and they are spelled out rather
than derived: `string-downcase` of :INPUT-BYTES answers `input-bytes`, which
would silently compare against a missing key and read as null.")

(defun transforms-stage (value)
  "One oracle stage -> the plist shape the port answers."
  (loop for (field . json-key) in *transforms-stage-fields*
        append (list field (json-null (gethash json-key value)))))

(defun transforms-stage-list (value)
  "The oracle's `stages` array -> a list of stage plists."
  (if (vectorp value)
      (loop for item across value collect (transforms-stage item))
      :not-a-stage-array))

(defun transforms-outputs (value)
  "The oracle's `outputs` array -> a list of strings."
  (if (vectorp value)
      (loop for item across value collect item)
      :not-an-output-array))

(defun transforms-inputs ()
  "text-tier-inputs.json read once per gate run."
  (gethash "sources" (read-json-file (fixture-path "text-tier-inputs.json"))))

(defun transforms-source (name)
  "The input text for NAME. An absent key is a fixture error, not an empty input."
  (let ((sources (transforms-inputs)))
    (multiple-value-bind (value present-p) (gethash name sources)
      (unless present-p
        (error "text-tier-inputs.json has no source named ~s" name))
      value)))

;;; ---------------------------------------------------------------------------
;;; Structural samples for the paths no oracle case reaches
;;; ---------------------------------------------------------------------------

(defparameter *gzip-payload-base64*
  "H4sIAAAAAAAC/0vOzyvOz0nVy8lP1zDUtAYAPe4jIA8AAAA="
  "base64 of gzip(\"console.log(1);\"), captured with python's gzip at mtime 0.
Used to pin the `unwrap_base64` -> inflate route, which no oracle case reaches:
the oracle's `base64` input decodes to plain text and produces no stage at all,
so a port that never inflated anything would still pass all 17 cases.")

(defparameter *control-byte-base64*
  "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJw=="
  "base64 of the bytes 0..39: all C0 controls, so `printable_ratio` is ~0 and the
0.85 gate must refuse the decode. Pins the gate no oracle case reaches.")

(defun kaomoji-shell-sample ()
  "A minimal aaencode shell: >= 80 trimmed characters, a real banner, and a
kaomoji density far above the 5% floor. Built from CODE POINTS so the file's own
encoding cannot turn one glyph into another."
  (let ((face (coerce (mapcar #'code-char (list #xFF9F #x03C9 #xFF89)) 'string)))
    (with-output-to-string (out)
      (dotimes (i 30) (write-string face out)))))

(defun jjencode-shell-sample ()
  "A jjencode shell: >= 80 characters plus both markers the detector requires."
  (concatenate 'string
               "var $ = ~[]; $ = {___:++$, $$$$: (![] + '')[+[]]}; "
               "if ($ =~[]) { $ = $.toString().split(''); }"
               "function f(){return $} f();"))

(defun jsfiretruck-shell-sample ()
  "A jsfiretruck shell: >= 256 characters of `[]()!+./` with plenty of dots and
slashes, which are the two the dot-density gate needs."
  (with-output-to-string (out)
    (dotimes (i 44) (write-string "[]()!+./" out))))

;;; ---------------------------------------------------------------------------
;;; Structural assertions: the transforms no oracle case exercises
;;;
;;; Every one of these was written because a mutation survived without it. They
;;; are separate from the oracle loop so the report can say which is which: the
;;; 17 cases pin `peel-text` end to end, these pin the individual decoders.
;;; ---------------------------------------------------------------------------

(defun run-transforms-structural (result)
  "Check the unwrap transforms directly. Returns the number of assertions."
  (let ((n 0))
    (flet ((case-of (label input got want)
             (incf n)
             (check result label input got want)))

      ;; --- hex escapes: BOTH passes, and the \x gate -----------------------
      (case-of "hex-escapes/x-then-u" "\\x41\\x42\\u0043"
               (vovas.engine.transforms:unwrap-hex-escapes "\\x41\\x42\\u0043")
               "ABC")
      (case-of "hex-escapes/no-x-escape-refuses" "\\u0041"
               (vovas.engine.transforms:unwrap-hex-escapes "\\u0041")
               nil)
      (case-of "hex-escapes/surrogate-becomes-replacement" "\\uD800"
               (vovas.engine.transforms:unwrap-hex-escapes "\\x41\\uD800")
               (format nil "A~c" (code-char #xFFFD)))
      (case-of "hex-escapes/uppercase-hex" "\\xFF"
               (vovas.engine.transforms:unwrap-hex-escapes "\\xFF")
               (string (code-char #xFF)))

      ;; --- base64: the inflate route and the printable gate ----------------
      (case-of "base64/gzip-inflates-through-apply-transform" "gzip payload"
               (vovas.engine.transforms:apply-transform
                :base64 (format nil "var p = \"~a\";" *gzip-payload-base64*))
               "console.log(1);")
      (case-of "base64/unwrap-answers-inflate-tag" "gzip payload"
               (let ((result* (vovas.engine.transforms:unwrap-base64
                               (format nil "var p = \"~a\";" *gzip-payload-base64*))))
                 (and result* (eq (first result*) :inflate)))
               t)
      (case-of "base64/control-bytes-refused" "control payload"
               (vovas.engine.transforms:apply-transform
                :base64 (format nil "var p = \"~a\";" *control-byte-base64*))
               nil)
      (case-of "base64/plain-text-decode" "text payload"
               (vovas.engine.transforms:apply-transform
                :base64 "var p = \"VGhlIHF1aWNrIGJyb3duIGZveCBqdW1wcyBvdmVyIHRoZSBsYXp5IGRvZyEh\";")
               "The quick brown fox jumps over the lazy dog!!")

      ;; --- unescape: the %uXXXX rewrite, quirk preserved -------------------
      (case-of "unescape/strictly-decodes-after-rewrite" "a%20b"
               (vovas.engine.transforms:unwrap-unescape "a%20b")
               "a b")
      (case-of "unescape/single-byte-quirk" "%u0041"
               (vovas.engine.transforms:unwrap-unescape "%u0041")
               "41")
      (case-of "percent-encode-utf8/uppercase-and-multibyte" "aé"
               (vovas.engine.transforms:percent-encode-utf8 (format nil "a~c" (code-char #xE9)))
               "%61%C3%A9")

      ;; --- charcode -------------------------------------------------------
      (case-of "charcode/decodes-to-json-quoted-string"
               "String.fromCharCode(72,101,108,108,111,33,33)"
               (vovas.engine.transforms:unwrap-charcode
                "var s = String.fromCharCode(72,101,108,108,111,33,33);")
               "var s = \"Hello!!\";")
      (case-of "charcode/too-few-numbers-refuses" "String.fromCharCode(65,66)"
               (vovas.engine.transforms:unwrap-charcode
                "var s = String.fromCharCode(65,66);")
               nil)
      (case-of "charcode/json-quote-escapes" "\" and \\"
               (vovas.engine.transforms:json-quote (format nil "a\"b~cc" #\\))
               (format nil "\"a\\\"b~c~cc\"" #\\ #\\))

      ;; --- reverse / rot13 -------------------------------------------------
      (case-of "reverse/by-character" "abcé"
               (vovas.engine.transforms:unwrap-reverse (format nil "abc~c" (code-char #xE9)))
               (format nil "~ccba" (code-char #xE9)))
      (case-of "rot13/round-trip-and-nonletters" "Hello, World!"
               (vovas.engine.detectors:rot13 (vovas.engine.detectors:rot13 "Hello, World!"))
               "Hello, World!")

      ;; --- eval payloads: order, dedupe, minimum length --------------------
      (let* ((a "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
             (text (format nil "eval(\"~a\");eval(\"~a\");eval(\"~a\");" a a a))
             (payloads (vovas.engine.transforms:collect-eval-payloads text)))
        (case-of "eval-payloads/dedupes-by-code" text (length payloads) 1))
      (let* ((a "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
             (b "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
             (text (format nil "eval(\"~a\");eval(\"~a\");" b a))
             (payloads (vovas.engine.transforms:collect-eval-payloads text)))
        (case-of "eval-payloads/sorted-by-head" text
                 (mapcar #'vovas.engine.transforms:eval-payload-code payloads)
                 (list b a)))
      (case-of "eval-payloads/short-payload-skipped" "eval(\"short\")"
               (vovas.engine.transforms:collect-eval-payloads "eval(\"short\");")
               nil)
      (case-of "eval-payloads/function-body-is-last-arg" "new Function"
               (let ((payloads (vovas.engine.transforms:collect-eval-payloads
                                (format nil "new Function(\"a\", \"~a\");"
                                        "return a * 2 + 1000000000000;"))))
                 (and payloads (vovas.engine.transforms:eval-payload-code (first payloads))))
               "return a * 2 + 1000000000000;")

      ;; --- sourceURL capture on a PRODUCED layer ---------------------------
      ;;
      ;; The oracle's `sourceUrl` is null in all 17 cases because no case produces
      ;; a layer carrying the comment. This does: the eval payload IS the comment.
      (let* ((text "eval(\"var a=1;//# sourceURL=webpack://app/./src/x.js\");")
             (stages (vovas.engine.transforms:peel-result-stages
                      (vovas.engine.transforms:peel-text text))))
        (case-of "source-url/captured-on-produced-layer" text
                 (and stages (getf (first stages) :source-url))
                 "webpack://app/./src/x.js"))
      (case-of "source-url/absent-is-nil" "evalLayer"
               (getf (first (vovas.engine.transforms:peel-result-stages
                             (vovas.engine.transforms:peel-text
                              (transforms-source "evalLayer"))))
                     :source-url)
               nil)

      ;; --- peel-text limits ------------------------------------------------
      ;;
      ;; `util::limit_or`: NIL and 0 both mean "use the default". The oracle
      ;; never varies the depth, so this is where the rule is pinned.
      (let* ((text (transforms-source "packed"))
             (r1 (vovas.engine.transforms:peel-text text))
             (r0 (vovas.engine.transforms:peel-text text 0))
             (rnil (vovas.engine.transforms:peel-text text nil)))
        (case-of "peel-text/zero-depth-means-default" "packed"
                 (list (length (vovas.engine.transforms:peel-result-stages r0))
                       (length (vovas.engine.transforms:peel-result-stages r1))
                       (length (vovas.engine.transforms:peel-result-stages rnil)))
                 (list 1 1 1)))
      ;; an empty input produces no stage and answers itself as `final`
      (let ((r (vovas.engine.transforms:peel-text "")))
        (case-of "peel-text/empty-input" ""
                 (list (vovas.engine.transforms:peel-result-stages r)
                       (vovas.engine.transforms:peel-result-final r))
                 (list nil "")))
      ;; outputs[i] is the text of stage i, so their lengths must agree
      (let ((r (vovas.engine.transforms:peel-text (transforms-source "stringArray"))))
        (case-of "peel-text/outputs-and-stages-align" "stringArray"
                 (list (length (vovas.engine.transforms:peel-result-outputs r))
                       (length (vovas.engine.transforms:peel-result-stages r))
                       (mapcar #'vovas.engine.util:utf16-length
                               (vovas.engine.transforms:peel-result-outputs r)))
                 (list 1 1 '(193))))
      ;; `final` is always the last output, or the input when nothing peeled
      (dolist (name '("packed" "plain" "empty"))
        (let* ((text (transforms-source name))
               (r (vovas.engine.transforms:peel-text text)))
          (case-of "peel-text/final-is-last-output" name
                   (vovas.engine.transforms:peel-result-final r)
                   (or (car (last (vovas.engine.transforms:peel-result-outputs r)))
                       text))))

      ;; --- the digest dedupe -----------------------------------------------
      ;;
      ;; No real transform cycles today (reverse and rot13 win the gain test in
      ;; one direction only), so the `seen` set is unpinned by any input the
      ;; oracle carries. It is pinned HERE by forcing a 2-cycle: a jsfuck
      ;; provider that always detects, plus a decoder that maps a <-> b. Without
      ;; the dedupe the loop would run to the depth limit (8 stages); with it,
      ;; exactly one stage and then a stop. Both the seam and the detector
      ;; override are removed afterwards, and that removal is asserted.
      (unwind-protect
           (progn
             (vovas.engine.detectors:install-provider
              :jsfuck (lambda (text)
                        (declare (ignore text))
                        (list :detected t :purity 1d0)))
             (setf vovas.engine.transforms:*jsfuck-decode*
                   (lambda (text) (if (string= text "cycle-a") "cycle-b" "cycle-a")))
             (let ((stages (vovas.engine.transforms:peel-result-stages
                            (vovas.engine.transforms:peel-text "cycle-a"))))
               (case-of "peel-text/digest-dedupe-stops-a-cycle" "cycle-a"
                        (list (length stages) (getf (first stages) :depth))
                        '(1 1))))
        (vovas.engine.detectors:install-provider :jsfuck nil)
        (setf vovas.engine.transforms:*jsfuck-decode* nil))
      (case-of "peel-text/seam-restored-after-cycle" "jsfuck"
               (list vovas.engine.transforms:*jsfuck-decode*
                     (vovas.engine.detectors:resolve-provider :jsfuck))
               (list nil nil))

      ;; --- every stage's digest is the digest of its output ----------------
      (dolist (name '("evalLayer" "packed" "stringArray"))
        (let* ((r (vovas.engine.transforms:peel-text (transforms-source name)))
               (stage (first (vovas.engine.transforms:peel-result-stages r)))
               (output (first (vovas.engine.transforms:peel-result-outputs r))))
          (case-of "stage/digest-matches-its-output" name
                   (getf stage :digest) (vovas.engine.digest:sha256-hex output))))

      n)))

;;; ---------------------------------------------------------------------------
;;; Wrong-implementation probes
;;;
;;; Each names a plausible-but-wrong reading of transforms.rs and requires the
;;; port to DISAGREE with it. All five below are implementations the Rust's own
;;; shape invites, so they are the mistakes a port actually makes rather than
;;; invented strawmen.
;;; ---------------------------------------------------------------------------

(defun probe-eval-join-separator (result)
  "`unwrap_eval` joins payloads with \"\\n;\\n\", not \"\\n\" and not \"\".
Two payloads make the separator observable; one payload cannot."
  (let* ((a "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
         (b "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
         (text (format nil "eval(\"~a\");eval(\"~a\");" a b))
         (joined (vovas.engine.transforms:unwrap-eval text)))
    (check result "probe/eval-join-is-semicolon-newline" text
           joined
           (format nil "~a~c~c~c~a" a #\Newline #\; #\Newline b))))

(defun probe-literal-only-vs-expression (result)
  "`eval(\"literal\" + b)` keeps the EXPRESSION, it does not join the literals. A
port that joined unconditionally would answer the bare literal and lose the `+b`
the next peel needs."
  (let* ((literal "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")   ; 30 chars, over the 24 floor
         (arg (format nil "\"~a\" + b" literal))
         (payloads (vovas.engine.transforms:collect-eval-payloads
                    (format nil "eval(~a);" arg)))
         (code (and payloads
                    (vovas.engine.transforms:eval-payload-code (first payloads)))))
    (check result "probe/expression-arg-kept-whole" arg code arg)
    (check result "probe/expression-is-not-literal-only" arg
           (vovas.engine.transforms:is-literal-only-arg arg) nil)
    ;; and the literal-only path must JOIN, across both `+` and a comma
    (let ((joined (vovas.engine.transforms:collect-eval-payloads
                   (format nil "eval(\"~a\" + \"ccccc\");" literal))))
      (check result "probe/literal-only-arg-joined" literal
             (and joined (vovas.engine.transforms:eval-payload-code (first joined)))
             (format nil "~accccc" literal)))))

(defun probe-printable-ratio-units (result)
  "`printable_ratio` counts CHARACTERS. The units only separate when a string
mixes a NON-printable character with a MULTI-BYTE one: `a\\x01é` is 3 characters
of which 2 are printable (2/3) but 4 bytes of which 3 are (0.75), so a
byte-counting implementation answers a different number. A pure-ASCII control
character does NOT separate them - both spellings answer 2/3."
  (check result "probe/printable-ratio-non-ascii-is-one" "ünïcode"
         (vovas.engine.transforms:printable-ratio "ünïcode") 1d0)
  (let ((mixed (format nil "a~cb" (code-char 1))))
    (check result "probe/printable-ratio-control" mixed
           (vovas.engine.transforms:printable-ratio mixed)
           (/ 2d0 3d0)))
  (let ((mixed (format nil "a~c~a" (code-char 1) (code-char #xE9))))
    (check result "probe/printable-ratio-counts-units-not-bytes" mixed
           (vovas.engine.transforms:printable-ratio mixed)
           (/ 2d0 3d0))))

(defun probe-gzip-magic-length (result)
  "`gzip_format` requires `len > 2`, not `len >= 2`. A two-byte body can carry a
header and no payload, so the port must answer NIL where a `>=` reading answers
:gzip."
  (check result "probe/gzip-format-needs-three-bytes" "1f 8b"
         (vovas.engine.transforms:gzip-format
          (make-array 2 :element-type '(unsigned-byte 8) :initial-contents '(#x1f #x8b)))
         nil)
  (check result "probe/gzip-format-three-bytes" "1f 8b 08"
         (vovas.engine.transforms:gzip-format
          (make-array 3 :element-type '(unsigned-byte 8) :initial-contents '(#x1f #x8b 8)))
         :gzip)
  (check result "probe/gzip-format-rejects-unknown-zlib-flg" "78 9c ok / 78 5e no"
         (list (vovas.engine.transforms:gzip-format
                (make-array 3 :element-type '(unsigned-byte 8) :initial-contents '(#x78 #x9c 0)))
               (vovas.engine.transforms:gzip-format
                (make-array 3 :element-type '(unsigned-byte 8) :initial-contents '(#x78 #x5e 0))))
         (list :deflate nil)))

(defun probe-to-uint16-wrap (result)
  "JS ToUint16 WRAPS modulo 65536 with `mod`, not `rem`. -1 answers 65535; a
`rem` spelling answers -1 and the character degrades to U+FFFD."
  (check result "probe/to-uint16-negative-wraps" "-1"
         (vovas.engine.transforms:to-uint16 -1d0) 65535)
  (check result "probe/to-uint16-nan-is-zero" "nan"
         (vovas.engine.transforms:to-uint16 (sb-kernel:make-double-float #x7ff80000 0))
         0)
  (check result "probe/to-uint16-modulus" "65537"
         (vovas.engine.transforms:to-uint16 65537d0) 1)
  (check result "probe/to-uint16-truncates" "65.9"
         (vovas.engine.transforms:to-uint16 65.9d0) 65))

(defun probe-js-parse-int-is-not-number-parse-int (result)
  "transforms.rs's `js_parse_int` is NOT `Number::parseInt`: it takes no radix,
does not understand `0x`, and stops at the first non-digit. `0x41` answers 0
here and 65 through number.lisp's `parse-int`. Pinning the difference is what
keeps a later \"simplification\" from importing the wrong semantics."
  (check result "probe/js-parse-int-rejects-hex-prefix" "0x41"
         (vovas.engine.transforms:js-parse-int "0x41") 0d0)
  (check result "probe/js-parse-int-sign-then-digits" "  +55abc"
         (vovas.engine.transforms:js-parse-int "  +55abc") 55d0)
  (check result "probe/js-parse-int-no-digits-is-nan" "abc"
         (sb-ext:float-nan-p (vovas.engine.transforms:js-parse-int "abc")) t)
  (check result "probe/js-parse-int-negative" "-12"
         (vovas.engine.transforms:js-parse-int "-12") -12d0))

(defparameter *transforms-wrong-implementations*
  '(("eval join uses a bare newline or nothing"
     . probe-eval-join-separator)
    ("literal-only detection joins an expression argument"
     . probe-literal-only-vs-expression)
    ("printable ratio counts bytes, not characters"
     . probe-printable-ratio-units)
    ("gzip format accepts a two-byte body"
     . probe-gzip-magic-length)
    ("ToUint16 uses rem instead of mod"
     . probe-to-uint16-wrap)
    ("js_parse_int delegates to Number::parseInt"
     . probe-js-parse-int-is-not-number-parse-int))
  "Named wrong implementations. The gate requires the port to DISAGREE with each,
and the count is printed so a silently-skipped probe shows up.")

;;; ---------------------------------------------------------------------------
;;; The gate
;;; ---------------------------------------------------------------------------

(defun run-transforms-gate (&key (verbose t))
  "Assert the peel chain against the wasm oracle's `peelText`, over all 17 inputs.

Returns T when every assertion holds, the case count is positive, every
wrong-implementation probe disagrees with the port, and the structural refusals
sample is non-empty. The gaps this gate does NOT cover are printed as GAP lines
so a green run cannot be read as full coverage."
  (let* ((oracle (read-json-file (fixture-path "text-tier-oracle.json")))
         (cases (gethash "peelText" oracle))
         (result (make-gate-result))
         (count 0)
         (stage-bearing '("evalLayer" "packed" "stringArray")))

    (unless (hash-table-p cases)
      (error "text-tier-oracle.json has no peelText object"))

    ;; --- every case, four independent comparisons ------------------------
    ;;
    ;; Split rather than one `equal` on the whole result: a wrong digest and a
    ;; wrong output list are different bugs, and collapsing them into one
    ;; failure would hide which.
    (dolist (name (sort (loop for k being the hash-keys of cases collect k) #'string<))
      (let* ((want (gethash name cases))
             (text (transforms-source name))
             (got (vovas.engine.transforms:peel-text text)))
        (incf count)
        (check result "peelText/stages" name
               (vovas.engine.transforms:peel-result-stages got)
               (transforms-stage-list (gethash "stages" want)))
        (incf count)
        (check result "peelText/outputs" name
               (vovas.engine.transforms:peel-result-outputs got)
               (transforms-outputs (gethash "outputs" want)))
        (incf count)
        (check result "peelText/final" name
               (vovas.engine.transforms:peel-result-final got)
               (gethash "final" want))
        (incf count)
        (check result "peelText/refusals" name
               (vovas.engine.transforms:peel-result-refusals got)
               (transforms-outputs (gethash "refusals" want)))
        ;; The stage-free 14 must stay stage-free; this is the assertion that
        ;; catches an over-eager transform adding a layer everywhere.
        (unless (member name stage-bearing :test #'string=)
          (incf count)
          (check result "peelText/no-spurious-stage" name
                 (vovas.engine.transforms:peel-result-stages got)
                 nil))))

    ;; --- the three stage-bearing cases, field by field -------------------
    ;;
    ;; The measured facts the brief records, asserted explicitly so a future
    ;; edit that changed a byte count or a tool name fails by NAME.
    (flet ((first-stage (name)
             (first (vovas.engine.transforms:peel-result-stages
                     (vovas.engine.transforms:peel-text (transforms-source name))))))
      (let ((stage (first-stage "evalLayer")))
        (incf count)
        (check result "stage/evalLayer-tool" "evalLayer" (getf stage :tool) "eval-unwrap")
        (incf count)
        (check result "stage/evalLayer-bytes" "evalLayer"
               (list (getf stage :input-bytes) (getf stage :output-bytes)) '(60 53))
        (incf count)
        (check result "stage/evalLayer-digest" "evalLayer"
               (getf stage :digest)
               "ec9c55abee2ecc01b0e7324ee9728cfed28572939b8239e80e1d730556c60c1e"))
      (let ((stage (first-stage "packed")))
        (incf count)
        (check result "stage/packed-tool" "packed" (getf stage :tool) "packer")
        (incf count)
        (check result "stage/packed-bytes" "packed"
               (list (getf stage :input-bytes) (getf stage :output-bytes)) '(305 25))
        (incf count)
        (check result "stage/packed-digest" "packed"
               (getf stage :digest)
               "86838aafd68060c2fb92a8166975cb07e180ef0c3a053e1e1815073481ffdcfc"))
      (let ((stage (first-stage "stringArray")))
        (incf count)
        (check result "stage/stringArray-tool" "stringArray"
               (getf stage :tool) "string-array")
        (incf count)
        (check result "stage/stringArray-bytes" "stringArray"
               (list (getf stage :input-bytes) (getf stage :output-bytes)) '(426 193))
        (incf count)
        (check result "stage/stringArray-digest" "stringArray"
               (getf stage :digest)
               "8c18d7145f3e04cfa6b40976b48fb27812250bb4e5fc1edce8bcc95196b5621c")))

    ;; --- depth is 1 on every firing stage --------------------------------
    (incf count)
    (check result "stage/depths" "all"
           (mapcar (lambda (name)
                     (getf (first (vovas.engine.transforms:peel-result-stages
                                   (vovas.engine.transforms:peel-text
                                    (transforms-source name))))
                           :depth))
                   stage-bearing)
           '(1 1 1))

    ;; --- collect-refusals, STRUCTURALLY (no oracle case reaches it) ------
    ;;
    ;; Stated plainly: `refusals` is [] in all 17 oracle cases, so this is NOT
    ;; an oracle pin. It pins the four detectors plumb through, that the plist
    ;; carries the wire field names, and that ordinary source refuses nothing.
    (dolist (sample (list (cons "aaencode" (kaomoji-shell-sample))
                          (cons "jjencode" (jjencode-shell-sample))
                          (cons "jsfiretruck" (jsfiretruck-shell-sample))))
      (let* ((refusals (vovas.engine.transforms:collect-refusals (cdr sample)))
             (hit (find (car sample) refusals :test #'string= :key (lambda (r) (getf r :tool)))))
        (incf count)
        (check result "refusals/structural-tool" (car sample) (and hit t) t)
        (incf count)
        (check result "refusals/structural-keys" (car sample)
               (and hit (list (and (stringp (getf hit :detail)) t)
                              (not (null (member :banner-hits hit)))
                              (not (null (member :density hit)))
                              (not (null (member :purity hit)))
                              (not (null (member :markers hit)))))
               '(t t t t t))))
    ;; obfuscator.io, and the "static pass did not match" suffix on its detail
    (incf count)
    (let* ((text "var a = 1; // obfuscator.io")
           (refusals (vovas.engine.transforms:collect-refusals text))
           (hit (find "obfuscator-io" refusals :test #'string= :key (lambda (r) (getf r :tool)))))
      (check result "refusals/obfuscator-suffix" text
             (and hit (not (null (search "(runtime shell" (getf hit :detail)))))
             t))
    ;; and NOTHING fires on the oracle's ordinary sources
    (dolist (name '("plain" "packed" "stringArray" "minified" "bundle" "evalLayer"))
      (incf count)
      (check result "refusals/quiet-on-real-source" name
             (vovas.engine.transforms:collect-refusals (transforms-source name))
             nil))

    ;; --- the jsfuck seam ------------------------------------------------
    ;;
    ;; GAP, asserted as a gap: with the seam unset the branch answers NIL, which
    ;; reads as "no transform applied". The seam is then exercised in BOTH shapes
    ;; it documents - a bare string and the `(:value ... :captured ...)` plist
    ;; that vovas.engine.jsfuck:decode-jsfuck actually answers - so the wiring
    ;; step cannot silently mismatch once the integrator sets it.
    (incf count)
    (check result "seam/jsfuck-unset-answers-nil" "jsfuck branch"
           (if (null vovas.engine.transforms:*jsfuck-decode*)
               (vovas.engine.transforms:apply-transform :jsfuck "[][![]+[]]")
               :wired)
           nil)
    (unwind-protect
         (progn
           (setf vovas.engine.transforms:*jsfuck-decode*
                 (lambda (text) (declare (ignore text)) "decoded-text"))
           (incf count)
           (check result "seam/jsfuck-accepts-a-string" "string shape"
                  (vovas.engine.transforms:apply-transform :jsfuck "x") "decoded-text")
           (setf vovas.engine.transforms:*jsfuck-decode*
                 (lambda (text) (declare (ignore text))
                   (list :value "plist-text" :captured nil)))
           (incf count)
           (check result "seam/jsfuck-accepts-a-value-plist" "plist shape"
                  (vovas.engine.transforms:apply-transform :jsfuck "x") "plist-text")
           (setf vovas.engine.transforms:*jsfuck-decode*
                 (lambda (text) (declare (ignore text))
                   (list :value nil :captured t)))
           (incf count)
           (check result "seam/jsfuck-null-value-is-no-transform" "plist null"
                  (vovas.engine.transforms:apply-transform :jsfuck "x") nil))
      (setf vovas.engine.transforms:*jsfuck-decode* nil))
    ;; and, if the sibling module happens to be loaded, the REAL decoder through
    ;; the seam. Skipped (as a GAP note) when it is not: the point of the seam is
    ;; that this file does not depend on it.
    (incf count)
    (let ((real (and (find-package "VOVAS.ENGINE.JSFUCK")
                     (multiple-value-bind (sym status)
                         (find-symbol "DECODE-JSFUCK" "VOVAS.ENGINE.JSFUCK")
                       (and sym (member status '(:external :internal)) (fboundp sym) sym)))))
      (if real
          (unwind-protect
               (progn
                 (setf vovas.engine.transforms:*jsfuck-decode* (symbol-function real))
                 (check result "seam/real-jsfuck-decoder-wired" "jsfuck oracle input"
                        (vovas.engine.transforms:apply-transform
                         :jsfuck (transforms-source "jsfuck"))
                        nil))
            (setf vovas.engine.transforms:*jsfuck-decode* nil))
          (record result t "seam/real-jsfuck-not-loaded" "module absent" :skipped :skipped)))

    ;; --- structural assertions for the paths the oracle never reaches ----
    (let ((structural (run-transforms-structural result)))
      (incf count structural)
      (when verbose
        (format t "~&  structural assertions (no oracle case reaches these): ~a~%"
                structural)))

    ;; --- non-vacuity by count -------------------------------------------
    (incf count)
    (check result "oracle/non-empty" "case count > 0" (plusp count) t)
    (incf count)
    (check result "oracle/17-cases" "peelText case count"
           (hash-table-count cases) 17)

    ;; --- the wrong implementations ---------------------------------------
    (let ((probe-result (make-gate-result)))
      (dolist (probe *transforms-wrong-implementations*)
        (funcall (cdr probe) probe-result))
      (when verbose
        (format t "~&  wrong-implementation probes (~a):~%"
                (length *transforms-wrong-implementations*))
        (dolist (probe *transforms-wrong-implementations*)
          (format t "    - ~a~%" (car probe)))
        (report-failures probe-result))
      (let ((total (+ (gate-result-total result) (gate-result-total probe-result)))
            (passed (+ (gate-result-passed result) (gate-result-passed probe-result))))        (when verbose
          (format t "~&transforms gate: ~a/~a cases match, ~a wrong-implementation probes~%"
                  passed total (length *transforms-wrong-implementations*))
          (report-failures result))
        (when verbose
          (format t "~&  GAP refusals: structurally pinned only - `refusals` is [] in all 17 oracle cases~%")
          (format t "~&  GAP jsfuck: no oracle case produces a jsfuck stage (decodeJsfuck answered null),~%")
          (format t "~&             so the branch is pinned through the seam shapes, not end to end~%")
          (format t "~&  GAP peel-depth: no oracle case reaches max_depth (every firing case stops at depth 1)~%"))
        (and (= passed total)
             (plusp count)
             ;; a mis-read oracle would make the 17-case loops run zero times;
             ;; the four assertions per case alone are 68, so a floor of 100
             ;; catches the empty-table failure without pinning an exact count
             ;; that every new assertion would have to be taught.
             (>= count 100))))))
