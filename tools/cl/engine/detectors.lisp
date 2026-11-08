;;;; detectors.lisp — which obfuscation layers a text actually carries.
;;;;
;;;; Ported from `unpack-rs/src/detectors.rs`. The Rust module answers a list of
;;;; `Finding { tool, score, detail }`, sorted by score, and that list is the
;;;; whole wire contract: `detectLayers` in the oracle is exactly this vector
;;;; serialised. So a finding here is a PLIST `(:tool :score :detail)` in that
;;;; key order, holding the wire strings the Rust `Tool::as_str` produces.
;;;;
;;;; INDEX UNITS. The Rust walks BYTES (`m.start()`, `rfind`, `.len()`) over
;;;; UTF-8. This port indexes CHARACTERS. The two agree on every position this
;;;; module reports because every delimiter it searches for is ASCII and no
;;;; character is a fragment of another - the same reasoning scanner.lisp
;;;; documents for its indices. The one place `.len()` is a real byte count,
;;;; `lit.len()` on the base64 literal, is safe for a stronger reason: the
;;;; literal is restricted to `[A-Za-z0-9+/=_-]`, which is pure ASCII, so byte
;;;; length and character length cannot diverge.
;;;;
;;;; WHAT IS NOT PORTED HERE, AND WHY IT IS VISIBLE. `detect_layers` in the
;;;; Rust also calls three modules this port does not own yet:
;;;;
;;;;   crate::transforms::collect_eval_payloads   -> the eval-unwrap score/count
;;;;   crate::packers::detect_packer              -> the "packer" finding
;;;;   crate::packers::detect_string_array        -> the "string-array" finding
;;;;   crate::jsfuck::detect_jsfuck               -> the "jsfuck" finding
;;;;
;;;; Copying any of them into this file would create a second source of truth
;;;; for a module another slice is porting, and the two would drift. So those
;;;; four calls are STAGE SEAMS: named slots (`*stage-providers*`) that the
;;;; integrator points at the real modules once they exist. `resolve-provider`
;;;; looks the natural name up in the natural package, so when the other
;;;; systems are loaded the wiring is automatic and this file needs no edit.
;;;; Until then `missing-stages` names exactly what is absent, and
;;;; `run-detectors-gate` reports those inputs as GAPS rather than bending the
;;;; expectation to match a half port.
;;;;
;;;; The seams are never silently ignored: a provider that answers the wrong
;;;; SHAPE signals a descriptive error instead of being coerced, because a
;;;; quietly mis-read provider would produce a plausible score for the wrong
;;;; text - the exact failure mode a gate exists to catch.

(defpackage :vovas.engine.detectors
  (:use :cl)
  (:import-from :vovas.engine.util #:utf16-length)
  (:export
   ;; the layer vocabulary
   #:tool-name
   #:make-finding
   ;; detectors ported from detectors.rs
   #:gain
   #:longest-base64-literal
   #:eval-heads
   #:function-heads
   #:rot13
   #:detect-layers
   ;; stage seams for the modules owned by other slices
   #:install-provider
   #:resolve-provider
   #:forget-providers
   #:missing-stages))

(in-package :vovas.engine.detectors)

;;; ---------------------------------------------------------------------------
;;; The layer vocabulary
;;; ---------------------------------------------------------------------------

(defparameter *tool-names*
  '((:eval-unwrap . "eval-unwrap")
    (:base64 . "base64")
    (:hex-escape . "hex-escape")
    (:unescape . "unescape")
    (:charcode . "charcode")
    (:reverse . "reverse")
    (:rot13 . "rot13")
    (:packer . "packer")
    (:jsfuck . "jsfuck")
    (:string-array . "string-array"))
  "The single definition of a layer's wire spelling.

The Rust gets this safety from the `Tool` enum: renaming a variant is a compile
error at every use, so a detector can never fall through a `_ => None` tail and
stop routing. Lisp has no such check, so `tool-name` SIGNALS on an unknown
keyword rather than answering NIL - a silent NIL would be a finding that
vanishes from the output with nothing to show for it.")

(defun tool-name (tool)
  "The wire spelling of TOOL. Signals when TOOL is not a known layer."
  (or (cdr (assoc tool *tool-names*))
      (error "unknown layer ~s (known: ~{~s~^ ~})"
             tool (mapcar #'car *tool-names*))))

(defun make-finding (tool score detail)
  "A finding, as the plist `detectLayers` serialises: key order is fixed
because the gate compares findings with `equal`, and a reordered plist would
read as a different finding."
  (list :tool (tool-name tool) :score score :detail detail))

;;; ---------------------------------------------------------------------------
;;; Patterns
;;; ---------------------------------------------------------------------------
;;;
;;; Compiled once at load. The Rust keeps these in `LazyLock` for the same
;;; reason: `create-scanner` compiles a matcher, and doing it per call would
;;; turn a linear scan into a per-input compile.

(defparameter *gain-scanner*
  (cl-ppcre:create-scanner
   "(?:function|return|var |let |const |window\\.|document\\.|prototype|undefined|null|true|false)")
  "The keyword gain counter. Note the trailing spaces on `var `/`let `/`const `:
the original JavaScript pattern has them, so `variable` does NOT count as a
keyword and `var x` does. Narrowing or widening this class changes the reverse
and rot13 thresholds for every input, which is why it is one definition.")

(defparameter *base64-scanner*
  (cl-ppcre:create-scanner
   "(?:atob\\s*\\(\\s*)?[\"']([A-Za-z0-9+/=_-]{40,})[\"']")
  "A base64-ish literal, optionally wrapped in `atob(`. The 40 character floor
is what keeps `\"hello\"` from being reported as an encoded payload; `=` and the
URL-safe `-`/`_` are in the class because both alphabets appear in the wild.")

(defparameter *hex-escape-scanner*
  (cl-ppcre:create-scanner "\\\\x[0-9a-fA-F]{2}")
  "`\\xNN` in the SOURCE TEXT, i.e. a backslash the text really contains. The
Lisp string has four backslashes so that the regex sees `\\\\x` - a literal
backslash followed by `x` - and not an escape of the pattern itself.")

(defparameter *unicode-percent-scanner*
  (cl-ppcre:create-scanner "%u[0-9a-fA-F]{4}")
  "The `escape()`-family `%uXXXX` form.")

(defparameter *charcode-scanner*
  (cl-ppcre:create-scanner "String\\s*\\.\\s*fromCharCode\\s*\\(([\\d\\s,]{7,})\\)")
  "A `String.fromCharCode(...)` list. The `[\\d\\s,]{7,}` body is the original's
guard against `String.fromCharCode()` and one-digit calls, which are ordinary
code rather than an obfuscated payload.")

(defparameter *eval-head-scanner*
  (cl-ppcre:create-scanner "(?:^|[^\\w$.])eval\\s*\\(")
  "`eval(` not preceded by an identifier character or `.`/`$`. The boundary is
the point: `myeval(` and `obj.eval(` are NOT the global eval, and treating them
as such would route a payload that does not exist.")

(defparameter *function-head-scanner*
  (cl-ppcre:create-scanner "(?:^|[^\\w$.])(?:new\\s+)?Function\\s*\\(")
  "`Function(` or `new Function(`, with the same boundary.")

;;; ---------------------------------------------------------------------------
;;; Counting and gain
;;; ---------------------------------------------------------------------------

(defun count-matches (scanner text)
  "How many non-overlapping matches SCANNER finds in TEXT.

`cl-ppcre:all-matches` answers a flat list of start/end pairs, so `length`
there is twice the match count; counting through `do-matches` keeps the number
the Rust gets from `find_iter(..).count()`."
  (let ((count 0))
    (cl-ppcre:do-matches (start end scanner text)
      (declare (ignore start end))
      (incf count))
    count))

(defun gain (text)
  "How many keyword-ish tokens TEXT carries (`function`, `return`, `var `, ...).

This is the yardstick for the reverse and rot13 detectors: an encoded source is
one whose DECODING contains more of these than the source does."
  (count-matches *gain-scanner* text))

;;; ---------------------------------------------------------------------------
;;; The individual detectors
;;; ---------------------------------------------------------------------------

(defun longest-base64-literal (text)
  "The longest base64-alphabet literal in TEXT, or NIL.

Longest, not first: a bundle's tail often holds a short token before the real
payload, and answering the first match would decode the wrong thing. Ties keep
the EARLIER literal, which is what `lit.len() > best.len()` (strict) does in the
Rust - a `>=` there would silently prefer the later of two equal literals."
  (let ((best nil))
    (cl-ppcre:do-register-groups (literal) (*base64-scanner* text)
      (when (or (null best) (> (length literal) (length best)))
        (setf best literal)))
    best))

(defun eval-heads (text)
  "The character index of every `eval` in an `eval(` head.

The match includes its boundary character (`x.eval(`, a leading space), so the
answer is the match start PLUS the position of `eval` inside the match - the
Rust spells this `m.start() + m.as_str().rfind(\"eval\")`. `rfind` from the end
because the boundary character itself can be anything, including a letter that
starts a longer word."
  (let ((heads '()))
    (cl-ppcre:do-matches (start end *eval-head-scanner* text)
      (let* ((matched (subseq text start end))
             (offset (search "eval" matched :from-end t)))
        (when offset (push (+ start offset) heads))))
    (nreverse heads)))

(defun function-heads (text)
  "Every `(start . end)` of a `Function(` / `new Function(` head.

`end` is exclusive, matching the Rust `m.end()`: the caller slices and searches
from it, and an inclusive end would re-read the `(`."
  (let ((heads '()))
    (cl-ppcre:do-matches (start end *function-head-scanner* text)
      (push (cons start end) heads))
    (nreverse heads)))

(defun rot13 (text)
  "JS rot13: ASCII letters rotate by 13, everything else is untouched.

Character-based, not byte-based, which is a documented quirk of the Rust port:
a multi-byte character passes through unchanged rather than being scrambled.
Non-ASCII letters are deliberately NOT rotated - `é` is not in `A-Za-z`, and
rotating it would make this transform disagree with every JS implementation of
rot13 the obfuscators use."
  (map 'string
       (lambda (c)
         (let ((code (char-code c)))
           (cond
             ((<= (char-code #\A) code (char-code #\Z))
              (code-char (+ (char-code #\A)
                            (mod (+ (- code (char-code #\A)) 13) 26))))
             ((<= (char-code #\a) code (char-code #\z))
              (code-char (+ (char-code #\a)
                            (mod (+ (- code (char-code #\a)) 13) 26))))
             (t c))))
       text))

;;; ---------------------------------------------------------------------------
;;; Stage seams: the four calls owned by other modules
;;; ---------------------------------------------------------------------------

(defparameter *provider-sources*
  '((:eval-payloads "VOVAS.ENGINE.TRANSFORMS" "COLLECT-EVAL-PAYLOADS")
    (:packer "VOVAS.ENGINE.PACKERS" "DETECT-PACKER")
    (:jsfuck "VOVAS.ENGINE.JSFUCK" "DETECT-JSFUCK")
    (:string-array "VOVAS.ENGINE.PACKERS" "DETECT-STRING-ARRAY"))
  "Where each seam's real implementation lives, as (key package symbol).

These are the natural names the other slices are porting, so resolution is
automatic once their systems are loaded: `detect-layers` then produces the
finding the oracle captured, with no edit here and no second copy of their
logic.")

(defparameter *stage-providers* '()
  "Explicit overrides: an alist of (key . function). A key present with a NIL
cdr is an explicit \"not available\", which suppresses default resolution - that
is how a test can pin the gap list without uninstalling the other systems.")

(defparameter *resolved-providers* '()
  "Cache of SUCCESSFUL resolutions only.

Deliberately not a cache of misses. A miss is the ordinary state while the
parallel slices land, and caching it would freeze the port into \"no packer\"
forever if this system happened to load before `vovas-engine.packers` - a
failure that looks like a wrong detector rather than a stale cache. A hit is
worth caching because it costs a package walk per call; a miss costs the same
walk and is worth re-asking every time.")

(defun default-provider (key)
  "The symbol implementing KEY, if its module is loaded.

`find-package` first, and that order is not cosmetic: `find-symbol` on a package
name that does not exist SIGNALS `PACKAGE-DOES-NOT-EXIST`, so a slice loading
before its dependencies would abort the whole `detect-layers` call instead of
reporting a missing stage. A missing package is an ordinary state here - that is
what the seam is for."
  (let ((entry (assoc key *provider-sources*)))
    (when entry
      (destructuring-bind (package name) (rest entry)
        (let ((package (find-package package)))
          (when package
            (multiple-value-bind (symbol status) (find-symbol name package)
              (when (and symbol
                         (member status '(:external :internal))
                         (fboundp symbol))
                symbol))))))))

(defun resolve-provider (key)
  "The function serving KEY, or NIL when that stage has no port yet.

Resolution order: an explicit entry in `*stage-providers*` (including an
explicit NIL, which is how a caller pins \"absent\"), then the cache of hits,
then the live package walk."
  (let ((explicit (assoc key *stage-providers*)))
    (if explicit
        (cdr explicit)
        (let ((cached (assoc key *resolved-providers*)))
          (if cached
              (cdr cached)
              (let ((function (default-provider key)))
                (when function
                  (push (cons key function) *resolved-providers*))
                function))))))

(defun install-provider (key function)
  "Point seam KEY at FUNCTION, or at nothing when FUNCTION is NIL.

Kept public because it is the wiring point for the integrator and the hook the
gate uses to exercise a seam that has no port behind it yet."
  (setf *stage-providers*
        (acons key function (remove key *stage-providers* :key #'car)))
  function)

(defun forget-providers ()
  "Drop the default-resolution cache so a newly loaded module is picked up."
  (setf *resolved-providers* '())
  t)

(defun missing-stages ()
  "The wire names of the layers whose stage has no implementation available.

This is the honest answer to \"what is this port not reporting\", and the gate
uses it to name gaps instead of lowering expectations."
  (let ((missing '()))
    (unless (resolve-provider :eval-payloads) (push "eval-unwrap" missing))
    (unless (resolve-provider :packer) (push "packer" missing))
    (unless (resolve-provider :jsfuck) (push "jsfuck" missing))
    (unless (resolve-provider :string-array) (push "string-array" missing))
    (nreverse missing)))

;;; ---------------------------------------------------------------------------
;;; Provider adapters
;;; ---------------------------------------------------------------------------
;;;
;;; Each adapter validates SHAPE and signals otherwise. A provider answering a
;;; vector where a list was expected, or a plist without `:base`, would
;;; otherwise be coerced into a plausible wrong score - the kind of number a
;;; human reads as "the detector is slightly off" and never finds.

(defun provider-call (key text)
  (let ((function (resolve-provider key)))
    (when function (funcall function text))))

(defun eval-payload-count (text)
  "How many distinct eval/Function payloads the transforms module collects.

This is the only thing `detect_layers` needs from it: the eval-unwrap score and
detail are both functions of the counts, and the counts already come from
`eval-heads`/`function-heads` above."
  (let ((answer (provider-call :eval-payloads text)))
    (unless (or (null answer) (listp answer) (vectorp answer))
      (error "eval-payloads provider answered ~s; expected a sequence of payloads"
             answer))
    (length answer)))

(defun packer-info (text)
  "The packer description as a plist `(:base N :words SEQ)`, or NIL."
  (let ((answer (provider-call :packer text)))
    (when answer
      (unless (and (listp answer)
                   (integerp (getf answer :base))
                   (typep (getf answer :words) 'sequence))
        (error "packer provider answered ~s; expected a plist with :base and :words"
               answer)))
    answer))

(defun jsfuck-info (text)
  "The jsfuck description as a plist `(:detected BOOLEAN :purity NUMBER)`, or NIL."
  (let ((answer (provider-call :jsfuck text)))
    (when answer
      (unless (and (listp answer)
                   (member :detected answer)
                   (realp (getf answer :purity)))
        (error "jsfuck provider answered ~s; expected a plist with :detected and :purity"
               answer)))
    answer))

(defun string-array-info (text)
  "The string-array description as `(:array-id STRING :literals INTEGER)`, or NIL."
  (let ((answer (provider-call :string-array text)))
    (when answer
      (unless (and (listp answer)
                   (stringp (getf answer :array-id))
                   (integerp (getf answer :literals)))
        (error "string-array provider answered ~s; expected :array-id and :literals"
               answer)))
    answer))

;;; ---------------------------------------------------------------------------
;;; detect_layers
;;; ---------------------------------------------------------------------------

(defun detect-layers (text)
  "Every obfuscation layer TEXT carries, highest score first.

Insertion order is the Rust's push order (eval-unwrap, base64, hex-escape,
unescape, charcode, reverse, rot13, packer, jsfuck, string-array) and the sort
must PRESERVE it for equal scores, because the Rust's `sort_by` is a stable sort
and two layers can score the same (`hex-escape` and `unescape` are both 0.6).

`stable-sort` is used because the COMMON LISP standard does not require `sort`
to be stable, not because SBCL's is visibly unstable: measured on this SBCL, the
two agree for every list size this module produces, so the swap is currently
unobservable and a mutation harness cannot distinguish them. The guarantee is
what is being bought - a conforming implementation may reorder, and the oracle
compares finding ORDER, not just the set."
  (let ((findings '())
        (eval-count (count-matches *eval-head-scanner* text))
        (fn-count (count-matches *function-head-scanner* text)))
    ;; eval-unwrap first, exactly as the Rust. The Rust guards the collector
    ;; call with `eval_count > 0 || fn_count > 0` so a text with neither head
    ;; never pays for a scan it cannot answer from; the same guard here also
    ;; keeps `missing-stages` from mattering on 14 of the 17 oracle inputs.
    (when (or (plusp eval-count) (plusp fn-count))
      (let ((payloads (eval-payload-count text)))
        (when (plusp payloads)
          (push (make-finding
                 :eval-unwrap
                 (+ 0.7d0 (min (/ (float payloads 1d0) 20d0) 0.3d0))
                 (format nil "~a eval() / ~a Function() call(s)"
                         eval-count fn-count))
                findings))))
    (let ((literal (longest-base64-literal text)))
      (when literal
        (let ((len (vovas.engine.util:utf16-length literal)))
          (push (make-finding
                 :base64
                 (+ 0.5d0 (min (/ (float len 1d0) 4000d0) 0.3d0))
                 (format nil "~a char literal" len))
                findings))))
    ;; The escape detector is a RATIO as well as a count: eight `\xNN` in a
    ;; 3000 character bundle are ordinary string content, while the same eight
    ;; in 40 characters are the encoding itself. `* 4` because each escape
    ;; costs four source characters, so the ratio compares encoded bytes to
    ;; text length, not escape count to character count.
    (let ((hex-escapes (count-matches *hex-escape-scanner* text)))
      (when (and (> hex-escapes 8)
                 (> (float (* hex-escapes 4) 1d0)
                    (* (float (vovas.engine.util:utf16-length text) 1d0) 0.15d0)))
        (push (make-finding :hex-escape 0.6d0
                            (format nil "~a \\x escapes" hex-escapes))
              findings)))
    (when (> (count-matches *unicode-percent-scanner* text) 8)
      (push (make-finding :unescape 0.6d0 "%uXXXX encoding") findings))
    (when (cl-ppcre:scan *charcode-scanner* text)
      (push (make-finding :charcode 0.65d0 "String.fromCharCode list") findings))
    ;; Reverse and rot13 both ask "does decoding this by X produce more
    ;; JavaScript than the source already had". The `+ 2` is a margin: one
    ;; keyword can appear by coincidence in reversed text (`var ` reversed is
    ;; ` rav`, which never matches, but `null` reversed is `llun`), and a
    ;; one-keyword improvement is not evidence of an encoded layer.
    (when (> (gain (reverse text)) (+ (gain text) 2))
      (push (make-finding :reverse 0.45d0 "reversed source") findings))
    (when (> (gain (rot13 text)) (+ (gain text) 2))
      (push (make-finding :rot13 0.42d0 "rot13 source") findings))
    (let ((packer (packer-info text)))
      (when packer
        (push (make-finding :packer 0.9d0
                            (format nil "Dean Edwards packer, base ~a, ~a words"
                                    (getf packer :base)
                                    (length (getf packer :words))))
              findings)))
    (let ((jsfuck (jsfuck-info text)))
      (when (and jsfuck (getf jsfuck :detected))
        (push (make-finding :jsfuck 0.95d0
                            (format nil "jsfuck, purity ~,1f%"
                                    (* (float (getf jsfuck :purity) 1d0) 100d0)))
              findings)))
    (let ((string-array (string-array-info text)))
      (when string-array
        (push (make-finding :string-array 0.8d0
                            (format nil "string array ~a, ~a literals"
                                    (getf string-array :array-id)
                                    (getf string-array :literals)))
              findings)))
    ;; Descending by score, stable. `>` rather than a difference test keeps a
    ;; NaN (which `>` answers NIL for) in place instead of raising.
    (stable-sort (nreverse findings)
                 (lambda (a b) (> (getf a :score) (getf b :score))))))
