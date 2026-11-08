;;;; gate-beautify.lisp — oracle and invariant gate for the beautify module.
;;;;
;;;; TWO STANDARDS, STATED PLAINLY BECAUSE THEY DIFFER.
;;;;
;;;;   `looks-minified-p` is BYTE-PINNED BY THE SHARED ORACLE.
;;;;   text-tier-oracle.json carries `looksMinified` for all 17 source texts,
;;;;   captured from dist/js/engine.wasm. All 17 are asserted, then ~90 probes
;;;;   isolate the individual rules: word-set membership, the asymmetric `\b`
;;;;   after the four dot-terminated keywords, the 500-BYTE longest-line limit,
;;;;   the 220-UTF-16-units-per-line average, the 3-line short circuit, and the
;;;;   200000-unit probe window.
;;;;
;;;;   `beautify-js` is BYTE-PINNED AGAINST A TABLE CAPTURED AT PORT TIME.
;;;;   text-tier-oracle.json has no `beautifyJs` key, so the 21 expectations in
;;;;   *beautify-golden* were produced by calling beautifyJs on the SHIPPED
;;;;   engine over the 17 fixture sources plus four budget cases, and pasted
;;;;   verbatim — nothing in them was typed by hand. That is byte-pinning, not
;;;;   structural pinning; the weaker standard was not needed. Regenerate with
;;;;   unpack-rs/scripts/beautify-oracle.mjs if the engine moves.
;;;;
;;;; THREE THINGS THE BRIEF ASSERTED THAT THE SHIPPED ENGINE CONTRADICTS.
;;;; Found by asking the engine rather than trusting the brief, and pinned here
;;;; as the engine actually behaves, with a note on each:
;;;;
;;;;   1. "the pretty input is stable under re-beautify" — FALSE. Re-beautify
;;;;      ADDS blank lines every time (68 -> 81 -> 94 -> 107 ...): the formatter
;;;;      emits a newline after `;` and after `}` without checking whether one
;;;;      is already there. There is no non-trivial fixed point except text with
;;;;      no braces or semicolons at all. Asserted as monotone growth.
;;;;
;;;;   2. "max_bytes smaller than input length truncates to <= max_bytes" —
;;;;      FALSE, and backwards. The budget is a REFUSAL: over the limit the
;;;;      input comes back UNCHANGED and byte-identical, so the result is
;;;;      LONGER than max-bytes (51 bytes returned for a budget of 20).
;;;;
;;;;   3. "NIL max_bytes means no truncation" — nothing ever truncates. NIL
;;;;      only means "use the default budget"; a 2.4 MB input under that budget
;;;;      is still refused, not shortened.
;;;;
;;;; What the brief got right and is pinned as asked: beautifying `minified`
;;;; introduces newlines and indentation and is not equal to its input, and its
;;;; output is longer than its input.

(in-package :vovas.engine.gate)

;;; ---------------------------------------------------------------------------
;;; The beautify-js golden table
;;; ---------------------------------------------------------------------------

(defparameter *beautify-golden*
  (list
   '("plain" nil
     "var a = 1;

// a comment
var s = \"hello world, a string here\";

/* block
 comment */
var t = 'another one';
")
   '("template" nil
     "const x = `outer ${inner} tail`;

const y = 2;
")
   '("regex" nil
     "var re = /ab+c/gi, s = \"a/b/c\";

var d = a / b / c;

var q = /=+/;
")
   '("escapes" nil
     "var s = \"a\\\"b\\\\c\\nd\\u00e9\";
")
   '("minified" nil
     "function a(b) {
  return b+1
}
var c=a(1);
console.log(c);
")
   '("pretty" nil
     "function add(a, b) {
  
    return a + b;
  
}


module.exports = {
   add 
}
;

")
   '("evalLayer" nil
     "eval(function(p,a,c,k,e,d){return p}(\"payload\",62,1,0,0,0));
")
   '("functionLayer" nil
     "var f = new Function(\"a\", \"return a * 2\");
")
   '("packed" nil
     "eval(function(p,a,c,k,e,d){e=function(c){return c};if(!''.replace(/^/,String)){while(c--){d[c]=k[c]||c}k=[function(e){return d[e]}];e=function(){return'\\\\w+'};c=1};while(c--){if(k[c]){p=p.replace(new RegExp('\\\\b'+e(c)+'\\\\b','g'),k[c])}}return p}('0 1(\"2 3\");',4,4,'console|log|packed|ok'.split('|'),0,{}))
")
   '("base64" nil
     "var payload = \"aGVsbG8gd29ybGQgdGhpcyBpcyBhIHRlc3Q=\";
")
   '("jsfuck" nil
     "[][(![]+[])[+[]]+([![]]+[][[]])[+!+[]+[+[]]]+(![]+[])[!+[]+!+[]]+(!![]+[])[+[]]][([][(![]+[])[+[]]+([![]]+[][[]])[+!+[]+[+[]]]+(![]+[])[!+[]+!+[]]+(!![]+[])[+[]]]+[])[!+[]+!+[]+!+[]]+(![]+[])[+!+[]]+(![]+[])[!+[]+!+[]]]()
")
   '("sourceMapRef" nil
     "var a=1;

//# sourceMappingURL=app.js.map
")
   '("inlineMap" nil
     "var a=1;

//# sourceMappingURL=data:application/json;base64,eyJ2ZXJzaW9uIjozLCJzb3VyY2VzIjpbImEudHMiXSwic291cmNlc0NvbnRlbnQiOlsiY29uc3QgYTogbnVtYmVyID0gMTsiXX0=
")
   '("bundle" nil
     "var __webpack_modules__ = {
  
  42: function (module, exports, __webpack_require__) {
    
    module.exports = 42;
    
    }
  ,
  7: (a, b) => {
    
    return a + b;
    
    }
  ,

}
;

//# sourceURL=webpack://app/./src/add.js
")
   '("stringArray" nil
     "var _0x5e6f = [\"4|1|0|2|3\", \"log\", \"Hello\", \"world\", \"console\"];

(function(_0x2d3e, _0x4c5d) {
  var _0x1f8a = function(_0x5a1b) {
    while (true) {
      if (parseInt(_0x2d3e[0], 16) === _0x4c5d) break;
      _0x2d3e[\"push\"](_0x2d3e[\"shift\"]());
    }
  };
  _0x1f8a(++_0x4c5d);
}(_0x5e6f, 0x4));

var _0x7b9c = function(i, n) {
  
  i = i - 0x0;
  
  return _0x5e6f[i];
  
}
;

console[_0x7b9c(\"0x1\")](_0x7b9c(\"0x2\") + _0x7b9c(\"0x3\"));
")
   '("empty" nil
     "
")
   '("whitespace" nil
     "   
	  
")
   '("minified" 51
     "function a(b) {
  return b+1
}
var c=a(1);
console.log(c);
")
   '("minified" 50
     "function a(b){return b+1}var c=a(1);console.log(c);")
   '("minified" 20
     "function a(b){return b+1}var c=a(1);console.log(c);")
   '("minified" 0
     "function a(b) {
  return b+1
}
var c=a(1);
console.log(c);
")
   )
  "Golden `beautify-js` answers, captured from dist/js/engine.wasm and pasted
verbatim. Each entry is `(source-name max-bytes expected)`.")

(defparameter *adv-beautify-cases*
  (list
   (cons "mojibake-bare"
         "var é=1;{y();}")
   (cons "mojibake-string"
         "var s=\"é\";{y();}")
   (cons "emoji-bare"
         "var 😀=\"x\";{y();}")
   (cons "emoji-template"
         "x(`😀`);{y();}")
   (cons "nbsp-before-brace"
         "var a=1; {b();}")
   (cons "bom-before-brace"
         "var a=1;﻿{b();}")
   (cons "stray-closers"
         "}}")
   (cons "unclosed-string"
         "var s=\"abc;{y();}")
   (cons "unclosed-template"
         "var s=`abc;{y();}")
   (cons "crlf"
         "a();
b();")
   (cons "cr-alone"
         "a();b();")
   (cons "unclosed-block-comment"
         "a();/*x{b();}")
   (cons "regex-vs-div"
         "var r=/a{2}/;var q=x/y;")
   (cons "nested-parens"
         "f(function(){a();});")
   (cons "tab-sep"
         "a();	b();")
   (cons "astral-ident"
         "var 𝐀=1;{y();}")
   (cons "combining"
         "var é=1;{y();}")
   (cons "line-sep-2028"
         "a(); {b();}")
   (cons "empty"
         "")
   (cons "brace-first"
         "{a();}")
  ))

(defparameter *adv-beautify-expect*
  (list
   (cons "mojibake-bare"
         "var Ã©=1;
{
  y();
  }
")
   (cons "mojibake-string"
         "var s=\"é\";
{
  y();
  }
")
   (cons "emoji-bare"
         "var ð=\"x\";
{
  y();
  }
")
   (cons "emoji-template"
         "x(`😀`);
{
  y();
  }
")
   (cons "nbsp-before-brace"
         "var a=1;
Â {
  b();
  }
")
   (cons "bom-before-brace"
         "var a=1;
ï»¿ {
  b();
  }
")
   (cons "stray-closers"
         "}
}
")
   (cons "unclosed-string"
         "var s=\"abc;{y();}
")
   (cons "unclosed-template"
         "var s=`abc;{y();}
")
   (cons "crlf"
         "a();

b();
")
   (cons "cr-alone"
         "a();
b();
")
   (cons "unclosed-block-comment"
         "a();
/*x{b();}
")
   (cons "regex-vs-div"
         "var r=/a{2}/;
var q=x/y;
")
   (cons "nested-parens"
         "f(function(){a();});
")
   (cons "tab-sep"
         "a();
	b();
")
   (cons "astral-ident"
         "var ð=1;
{
  y();
  }
")
   (cons "combining"
         "var eÌ=1;
{
  y();
  }
")
   (cons "line-sep-2028"
         "a();
â¨ {
  b();
  }
")
   (cons "empty"
         "
")
   (cons "brace-first"
         "{
  a();
  }
")
  )
  "Golden beautifyJs answers for *adv-cases*, captured from the shipped
engine. Each input was also run through the Rust SOURCE in examples/ during
port verification and produced identical bytes, so these expectations pin
source, binary and port at once.")

;;; ---------------------------------------------------------------------------
;;; looks-minified-p probes
;;; ---------------------------------------------------------------------------

(defun expand-fill (fill)
  "A FILL is a string, or `(:rep STRING COUNT)` meaning STRING repeated COUNT
times. The second form exists so the average cases can have a line of an exact
length without 289 characters of literal in this file — and it is evaluated
HERE, not by the CL reader, because at READ time a `(format nil ...)` inside the
quoted table would simply be an unevaluated form."
  (if (stringp fill)
      fill
      (destructuring-bind (marker text count) fill
        (assert (eq marker :rep) () "unknown fill form ~s" fill)
        (with-output-to-string (s)
          (dotimes (k count) (write-string text s))))))

(defun unescape-probe-text (text)
  "Resolve `\\n` and `\\t` inside a probe FORM's string argument.

Common Lisp's reader does NOT process `\\n`: both characters are kept verbatim,
so a literal newline in a probe form would have to be a real newline in the
source, which breaks the table's one-row-per-line shape and made an earlier
version of this file unreadable. Probe rows therefore spell their line breaks as
`\\n` and this function resolves them. Only these two escapes are supported;
anything else is left alone so a stray backslash cannot silently vanish."
  (with-output-to-string (s)
    (loop with i = 0
          while (< i (length text))
          do (let ((c (char text i)))
               (cond
                 ((and (char= c #\\) (< (1+ i) (length text)))
                  (let ((next (char text (1+ i))))
                    (case next
                      (#\n (write-char #\Newline s) (incf i 2))
                      (#\t (write-char #\Tab s) (incf i 2))
                      (t (write-char c s) (incf i)))))
                 (t (write-char c s) (incf i)))))))

(defun expand-minified-probe (form)
  "Expand a probe's input form into a string.

Most probes are plain literals, which pass through untouched. Two generated
shapes keep a 500-byte line out of the source file:

  (:repeat PREFIX FILL COUNT [:then SUFFIX])
  (:repeat PREFIX FILL COUNT :join SEP)

FILL is repeated COUNT times after PREFIX, optionally separated by SEP. FILL may
itself be `(:rep STRING N)` — see `expand-fill`. Every string argument goes
through `unescape-probe-text`."
  (cond
    ((stringp form) form)
    ((and (consp form) (eq (first form) :repeat))
     (destructuring-bind (prefix fill count &key then (join nil joinp)) (rest form)
       (let ((prefix (unescape-probe-text prefix))
             (unit (unescape-probe-text (expand-fill fill)))
             (join (and joinp (unescape-probe-text join)))
             (then (and then (unescape-probe-text then))))
         (with-output-to-string (s)
           (write-string prefix s)
           (dotimes (k count)
             (when (and joinp (plusp k)) (write-string join s))
             (write-string unit s))
           (when then (write-string then s))))))
    (t (error "unknown probe form ~s" form))))

(defparameter *minified-probes*
  '(
    ("kw-function" "function" t)
    ("kw-function-suffixed" "functionz" nil)
    ("kw-return" "return" t)
    ("kw-return-suffixed" "returnz" nil)
    ("kw-var" "var" t)
    ("kw-var-suffixed" "varz" nil)
    ("kw-let" "let" t)
    ("kw-let-suffixed" "letz" nil)
    ("kw-const" "const" t)
    ("kw-const-suffixed" "constz" nil)
    ("kw-class" "class" t)
    ("kw-class-suffixed" "classz" nil)
    ("kw-new" "new" t)
    ("kw-new-suffixed" "newz" nil)
    ("kw-typeof" "typeof" t)
    ("kw-typeof-suffixed" "typeofz" nil)
    ("kw-window" "window." nil)
    ("kw-window-suffixed" "window.z" t)
    ("kw-document" "document." nil)
    ("kw-document-suffixed" "document.z" t)
    ("kw-moduleexports" "module.exports" t)
    ("kw-moduleexports-suffixed" "module.exportsz" nil)
    ("kw-exports" "exports." nil)
    ("kw-exports-suffixed" "exports.z" t)
    ("kw-prototype" "prototype" t)
    ("kw-prototype-suffixed" "prototypez" nil)
    ("sig-77-69-6e-64-6f-77-2e-78" "window.x" t)
    ("sig-64-6f-63-75-6d-65-6e-74-2e-78" "document.x" t)
    ("sig-6d-6f-64-75-6c-65-2e-65-78-70-6f-72-74-73-2e-78" "module.exports.x" t)
    ("sig-65-78-70-6f-72-74-73-2e-78" "exports.x" t)
    ("sig-70-72-6f-74-6f-74-79-70-65-2e-78" "prototype.x" t)
    ("sig-77-69-6e-64-6f-77-2e-20-78" "window. x" nil)
    ("sig-77-69-6e-64-6f-77-2e-1f600" "window.😀" nil)
    ("sig-77-69-6e-64-6f-77-2e-e9" "window.é" t)
    ("sig-65-78-70-6f-72-74-73-2e-e9" "exports.é" t)
    ("sig-6d-6f-64-75-6c-65-2e-65-78-70-6f-72-74-73-e9" "module.exportsé" nil)
    ("sig-70-72-6f-74-6f-74-79-70-65-e9" "prototypeé" nil)
    ("sig-70-72-6f-74-6f-74-79-70-65-65e5" "prototype日" nil)
    ("sig-70-72-6f-74-6f-74-79-70-65-5f" "prototype_" nil)
    ("sig-70-72-6f-74-6f-74-79-70-65-39" "prototype9" nil)
    ("sig-70-72-6f-74-6f-74-79-70-65-24" "prototype$" t)
    ("sig-6d-79-76-61-72-20-61" "myvar a" nil)
    ("sig-5f-76-61-72-20-61" "_var a" nil)
    ("sig-24-76-61-72-20-61" "$var a" nil)
    ("sig-78-56-61-72-20-61" "xVar a" nil)
    ("sig-3d-3e" "=>" t)
    ("sig-61-3d-3e-62" "a=>b" t)
    ("sig-61-20-3d-3e-20-62" "a => b" t)
    ("sig-78-3d-3e" "x=>" t)
    ("sig-66-75-6e-63-74-69-6f-6e-61-6c-69-74-79" "functionality" nil)
    ("sig-76-61-72-69-61-62-6c-65-73" "variables" nil)
    ("sig-6e-65-77-65-72" "newer" nil)
    ("sig-63-6c-61-73-73-65-73" "classes" nil)
    ("sig-72-65-74-75-72-6e-65-64" "returned" nil)
    ("sig-63-6f-6e-73-74-72-75-63-74-6f-72" "constructor" nil)
    ("sig-74-79-70-65-6f-66-78" "typeofx" nil)
    ("sig-64-6f-63-75-6d-65-6e-74-61-74-69-6f-6e" "documentation" nil)
    ("sig-6c-65-74-74-65-72" "letter" nil)
    ("sig-76-61-72-5f" "var_" nil)
    ("sig-76-61-72-24" "var$" t)
    ("sig-6d-6f-64-75-6c-65-2e-65-78-70-6f-72-74-73-2e" "module.exports." t)
    ("uni-e9-76-61-72-20-61" "évar a" nil)
    ("uni-f1-76-61-72-20-61" "ñvar a" nil)
    ("uni-65e5-76-61-72-20-61" "日var a" nil)
    ("uni-661-76-61-72-20-61" "١var a" nil)
    ("uni-301-76-61-72-20-61" "́var a" nil)
    ("uni-20-76-61-72-20-61" " var a" t)
    ("uni-2e-76-61-72-20-61" ".var a" t)
    ("uni-78-200b-76-61-72-20-61" "x​var a" t)
    ("uni-200c-76-61-72-20-61" "‌var a" nil)
    ("uni-200d-76-61-72-20-61" "‍var a" nil)
    ("uni-feff-76-61-72-20-61" "﻿var a" t)
    ("uni-61-200d-76-61-72-20-61" "a‍var a" nil)
    ("uni-2160-76-61-72-20-61" "Ⅰvar a" nil)
    ("uni-24b6-76-61-72-20-61" "Ⓐvar a" nil)
    ("uni-b2-76-61-72-20-61" "²var a" t)
    ("uni-b5-76-61-72-20-61" "µvar a" nil)
    ("uni-2b0-76-61-72-20-61" "ʰvar a" nil)
    ("uni-9e6-76-61-72-20-61" "০var a" nil)
    ("uni-66e-76-61-72-20-61" "ٮvar a" nil)
    ("lines-1" "var a=1" t)
    ("lines-2" "var a=1
" t)
    ("lines-3" "var a=1

" t)
    ("lines-4" "var a=1


" nil)
    ("lines-5" "var a=1



" nil)
    ("longest-ascii-499" (:repeat "var a=1;\\n" "x" 499 :then "\\n\\n") nil)
    ("longest-ascii-500" (:repeat "var a=1;\\n" "x" 500 :then "\\n\\n") nil)
    ("longest-ascii-501" (:repeat "var a=1;\\n" "x" 501 :then "\\n\\n") t)
    ("longest-eacute-249" (:repeat "var é=1;\\n" "é" 249 :then "\\n\\n") nil)
    ("longest-eacute-250" (:repeat "var é=1;\\n" "é" 250 :then "\\n\\n") nil)
    ("longest-eacute-251" (:repeat "var é=1;\\n" "é" 251 :then "\\n\\n") t)
    ("avg-linesize-289" (:repeat "var a=1;\\n" (:rep "x" 289) 3 :join "\\n") nil)
    ("avg-linesize-290" (:repeat "var a=1;\\n" (:rep "x" 290) 3 :join "\\n") t)
    ("avg-linesize-291" (:repeat "var a=1;\\n" (:rep "x" 291) 3 :join "\\n") t)
    ("longest-dominates" (:repeat "var a=1;\\n" "x" 501 :then "\\n\\ny\\n") t)
    ("window-signal-after" (:repeat "" "x" 200001 :then "var a=1;\\n\\n") nil)
    ("window-signal-inside" (:repeat "var a=1;\\n\\n" "x" 200001) t)
    ("window-arrow-after" (:repeat "" "x" 200001 :then "=>") nil)
    ))

(defun minified-probe-input (form)
  "The string a probe feeds to looks-minified-p. `:repeat` with COUNT 0 still
needs its FILL, so the shape is uniform."
  (expand-minified-probe form))

(defun table-carriage-returns ()
  "Every string in the two tables that contains a carriage return.

This exists because a `.asd`-driven run once reported 19 beautify-js failures
where `want` and `got` printed IDENTICALLY. The cause was the gate file being
saved with CRLF line endings, so every newline inside a golden string literal
was really `\\r\\n` while the port produced `\\n`. Two strings that differ by one
invisible byte print the same and read as a port bug.

The tables are checked explicitly rather than by normalising at load time: a
silent `\\r`-strip would hide the same class of mistake in a future edit, and a
loud failure here costs one line of output."
  (let ((bad '()))
    (flet ((scan (label s)
             (when (and (stringp s) (find #\Return s))
               (push label bad))))
      (dolist (row *beautify-golden*) (scan (first row) (third row)))
      (dolist (row *minified-probes*) (scan (first row) (second row))))
    (nreverse bad)))

;;; ---------------------------------------------------------------------------
;;; The gate
;;; ---------------------------------------------------------------------------

(defun gate-beautify-self-test-p ()
  "Prove this gate's own comparison path can fail. Runs one trivially-correct
and one deliberately-wrong pair and requires the harness to record exactly one
failure, so a gate that silently stopped comparing cannot report success."
  (let ((result (make-gate-result)))
    (check result "self-test-good" "" "abc" "abc")
    (check result "self-test-bad" "" "abc" "abd")
    (and (= 2 (gate-result-total result))
         (= 1 (gate-result-passed result))
         (= 1 (length (gate-result-failures result)))
         (equal "self-test-bad"
                (getf (first (gate-result-failures result)) :label)))))

(defun run-beautify-gate (&key (verbose t))
  "Compare the beautify port against the shipped wasm engine's answers, then
check the structural invariants, then prove plausible wrong implementations are
not what the port produces. Returns T when everything holds."
  (let ((result (make-gate-result))
        (oracle-cases 0)
        (golden-cases 0)
        (probe-cases 0)
        (invariant-cases 0)
        (adv-cases 0)
        (mutation-cases 0))

    (unless (gate-beautify-self-test-p)
      (when verbose (format t "~&beautify gate: self-test FAILED~%"))
      (return-from run-beautify-gate nil))

    ;; A CR inside a table string means the file's line endings leaked into a
    ;; literal; every comparison against it then fails while printing identical
    ;; text. Checked first so the failure names its cause.
    (let ((cr (table-carriage-returns)))
      (when cr
        (when verbose
          (format t "~&beautify gate: gate-beautify.lisp has CRLF line endings~%~
                       in table entries: ~s~%" cr))
        (return-from run-beautify-gate nil)))

    (let* ((oracle (read-json-file (fixture-path "text-tier-oracle.json")))
           (inputs (read-json-file (fixture-path "text-tier-inputs.json")))
           (sources (gethash "sources" inputs))
           (source-keys (loop for k being the hash-keys of sources collect k)))

      ;; ---- 1. looksMinified, every case in the shared oracle --------------
      ;; This is the pinned part of the brief. Sorted keys so a failure report
      ;; reads in the same order twice.
      ;;
      ;; `gethash`'s second value, not `(when want ...)`. Seven of the 17 oracle
      ;; answers are `false`, so testing the value for truthiness silently
      ;; skipped them and the section reported 10 cases while LOOKING complete -
      ;; every false case went unasserted. The presence flag is the only way to
      ;; tell "the oracle says false" from "this key is not in the oracle".
      (let ((cases (gethash "looksMinified" oracle)))
        (dolist (name (sort (copy-list source-keys) #'string<))
          (multiple-value-bind (want present) (gethash name cases)
            ;; JZON gives T/NIL for JSON true/false, so no json-null needed here;
            ;; but a missing key is a fixture problem worth failing on, not
            ;; skipping.
            (if present
                (progn
                  (incf oracle-cases)
                  (check result (format nil "looksMinified/~a" name) name
                         (vovas.engine.beautify:looks-minified-p
                          (gethash name sources))
                         want))
                (progn
                  (incf oracle-cases)
                  (record result nil (format nil "looksMinified/~a" name) name
                          :missing-oracle-case :present))))))

      ;; ---- 2. looksMinified, the rule-isolating probes -------------------
      (dolist (probe *minified-probes*)
        (destructuring-bind (label form want) probe
          (incf probe-cases)
          (check result (format nil "probe/~a" label) label
                 (vovas.engine.beautify:looks-minified-p
                  (minified-probe-input form))
                 want)))

      ;; ---- 2b. beautifyJs on the adversarial set -------------------------
      ;; These 20 inputs exist to probe where the Rust SOURCE and the shipped
      ;; WASM could plausibly part ways: byte-level mojibake, CRLF vs bare CR,
      ;; unterminated literals, signed paren_depth, BOM/NBSP/U+2028 as
      ;; whitespace. All 20 were shown identical across source, binary and this
      ;; port, which is why the expectations are captured rather than derived.
      (dolist (pair *adv-beautify-cases*)
        (destructuring-bind (name . text) pair
          (incf adv-cases)
          (check result (format nil "adv/~a" name) name
                 (vovas.engine.beautify:beautify-js text nil)
                 (cdr (assoc name *adv-beautify-expect* :test #'string=)))))

      ;; ---- 3. beautifyJs, the 21 golden answers --------------------------
      (dolist (row *beautify-golden*)
        (destructuring-bind (name max want) row
          (let ((source (gethash name sources)))
            (assert source () "no fixture source named ~a" name)
            (incf golden-cases)
            (check result (format nil "beautifyJs/~a/~a" name max) name
                   (vovas.engine.beautify:beautify-js source max)
                   want))))

      ;; ---- 4. structural invariants the brief asked for ------------------
      ;; Each of these is stated against the SHIPPED behaviour, which differs
      ;; from the brief in the three ways documented in the file header.
      (let ((minified (gethash "minified" sources))
            (pretty (gethash "pretty" sources)))
        (labels ((invariant (label ok)
                   (incf invariant-cases)
                   (record result ok label :invariant (if ok t :failed) t)))

          ;; (a) the minified source is actually reformatted, not echoed
          (let ((out (vovas.engine.beautify:beautify-js minified nil)))
            (invariant "minified-changed" (not (equal out minified)))
            (invariant "minified-gained-newlines"
                       (> (count #\Newline out) (count #\Newline minified)))
            (invariant "minified-gained-indentation"
                       (search (format nil "~%~a" "  ") out))
            (invariant "minified-grew" (> (length out) (length minified)))
            ;; the specific shape, because "gained newlines" alone would pass
            ;; for a formatter that inserted one anywhere
            (invariant "minified-open-brace-spaced"
                       (search "function a(b) {" out))
            (invariant "minified-body-indented"
                       (search (format nil "~%  return b+1") out))
            (invariant "minified-ends-with-newline"
                       (char= #\Newline (char out (1- (length out))))))

          ;; (b) THE BUDGET IS A REFUSAL, NOT A TRUNCATION.
          ;; Over the limit: byte-identical input, LONGER than the budget.
          (let* ((out (vovas.engine.beautify:beautify-js minified 20)))
            (invariant "over-budget-is-input-verbatim" (equal out minified))
            (invariant "over-budget-can-exceed-budget"
                       (> (length out) 20))
            ;; the brief's claim, stated so its falseness is explicit:
            ;; "truncates to <= max_bytes" is NOT what happens
            (invariant "over-budget-does-not-truncate"
                       (not (<= (length out) 20))))
          ;; At the limit: reformatted. One unit over: refused. This is the
          ;; exact edge, and it is why the golden table carries 50 and 51.
          (let ((at (vovas.engine.beautify:beautify-js minified 51))
                (over (vovas.engine.beautify:beautify-js minified 50)))
            (invariant "at-budget-reformats" (not (equal at minified)))
            (invariant "over-budget-refuses" (equal over minified)))

          ;; (c) NIL and 0 both mean "default budget", so both reformat
          (let ((nil-budget (vovas.engine.beautify:beautify-js minified nil))
                (zero-budget (vovas.engine.beautify:beautify-js minified 0)))
            (invariant "nil-budget-uses-default" (not (equal nil-budget minified)))
            (invariant "zero-budget-uses-default" (equal nil-budget zero-budget))
            (invariant "effective-limit-nil"
                       (= vovas.engine.beautify:*max-beautify-bytes*
                          (vovas.engine.beautify:effective-limit nil)))
            (invariant "effective-limit-zero"
                       (= vovas.engine.beautify:*max-beautify-bytes*
                          (vovas.engine.beautify:effective-limit 0)))
            (invariant "effective-limit-passthrough"
                       (= 7 (vovas.engine.beautify:effective-limit 7))))

          ;; (d) RE-BEAUTIFY IS NOT IDEMPOTENT. The brief claimed the pretty
          ;; input was stable; the shipped engine adds blank lines every pass.
          ;; Asserted as: growth on every pass, for at least 4 passes, for both
          ;; the pretty and the minified source.
          (dolist (pair (list (cons "pretty" pretty) (cons "minified" minified)))
            (let* ((name (car pair))
                   (text (cdr pair))
                   (lengths (list (length text)))
                   (grew-every-time t))
              (dotimes (k 4)
                (setf text (vovas.engine.beautify:beautify-js text nil))
                (let ((prev (car lengths)))
                  (push (length text) lengths)
                  (unless (> (length text) prev)
                    (setf grew-every-time nil))))
              (invariant (format nil "~a-rebeautify-grows-monotonically" name)
                         grew-every-time)))

          ;; there IS a fixed point, but only for text with no brace and no
          ;; semicolon: the formatter appends exactly one newline and stops
          (let* ((once (vovas.engine.beautify:beautify-js "abc" nil))
                 (twice (vovas.engine.beautify:beautify-js once nil)))
            (invariant "trivial-text-reaches-fixed-point" (equal once twice))
            (invariant "trivial-text-gains-one-newline"
                       (equal once (format nil "abc~%"))))

          ;; (e) empty input answers a single newline, not the empty string:
          ;; end_with_newline applies when there is nothing at all just as much
          ;; as when there is something
          (invariant "empty-input-is-newline"
                     (equal (vovas.engine.beautify:beautify-js "" nil)
                            (format nil "~%")))))

      ;; ---- 5. mutation probes: plausible wrong ports must be wrong --------
      ;; Each names a wrong implementation that would look right on most inputs
      ;; and requires the port NOT to be it.
      (let ((minified (gethash "minified" sources))
            (plain (gethash "plain" sources)))
        (labels ((mutation (label ok)
                   (incf mutation-cases)
                   (record result ok label :mutation (if ok t :failed) t)))

          ;; (i) "beautify is the identity function" — returns its input
          (mutation "not-identity-on-minified"
                    (not (equal (vovas.engine.beautify:beautify-js minified nil)
                                minified)))
          ;; (ii) "beautify is identity when a budget is set" — treats the
          ;; budget as a no-op flag rather than a refusal threshold
          (mutation "budget-is-not-a-no-op-flag"
                    (not (equal (vovas.engine.beautify:beautify-js minified 51)
                                minified)))
          ;; (iii) "the budget truncates" — the natural misreading, which would
          ;; return a short prefix and corrupt any file it touched
          (mutation "budget-does-not-truncate"
                    (let ((out (vovas.engine.beautify:beautify-js minified 20)))
                      (not (and (< (length out) (length minified))
                                (eql 0 (search out minified))))))
          ;; (iv) "`\b` is symmetric" — a port that treats the boundary as
          ;; one-sided would report `window. x` as minified (the shipped engine
          ;; says NIL, because `.` and space are both non-word)
          (mutation "word-boundary-is-symmetric"
                    (null (vovas.engine.beautify:looks-minified-p "window. x")))
          ;; (v) "`\w` is ASCII" — JavaScript's `\w`, which is the reading the
          ;; Rust prose invites. Under it `prototypeé` IS minified, because é
          ;; is not a word character and so `\b` fires after `prototype`.
          (mutation "word-set-is-not-ascii"
                    (null (vovas.engine.beautify:looks-minified-p "prototypeé")))
          ;; (vi) "the longest line is measured in characters" — under that
          ;; reading 254 `é` is 254 characters and stays under the limit; the
          ;; shipped engine counts 508 bytes and trips it
          (mutation "longest-line-is-bytes-not-chars"
                    (vovas.engine.beautify:looks-minified-p
                     (concatenate 'string "var é=1;" (string #\Newline)
                                  (make-string 254 :initial-element (code-char #xe9))
                                  (format nil "~%~%"))))
          ;; (vii) "the limits are checked before the line count" — a natural
          ;; tidy-up that would report a 3-line 600-byte input as NIL, where the
          ;; short circuit answers T
          (mutation "short-circuit-precedes-limits"
                    (vovas.engine.beautify:looks-minified-p
                     (concatenate 'string "var a=1;" (string #\Newline)
                                  (make-string 600 :initial-element #\x)
                                  (string #\Newline))))
          ;; (viii) "comments count as code" — under that reading `a();/*c*/{`
          ;; would put the brace on its own line; the shipped engine keeps it on
          ;; the comment's line, which is observable in the output
          (mutation "comment-is-not-code"
                    (equal (vovas.engine.beautify:beautify-js "a();/*c*/{b();}" nil)
                           (format nil "a();~%/*c*/ {~%  b();~%  }~%")))
          ;; (ix) "indent is one space per level" — a plausible off-by-one that
          ;; every golden case would already catch, kept because it is the
          ;; cheapest independent check that the golden table is being read
          (mutation "indent-is-two-spaces"
                    (search (format nil "~%~a" "  return")
                            (vovas.engine.beautify:beautify-js "function a(b){return b+1}" nil)))))

      (when verbose
        (format t "~&beautify gate: ~a/~a cases match~%"
                (gate-result-passed result) (gate-result-total result))
        (format t "  looksMinified oracle: ~a  probes: ~a  beautifyJs golden: ~a~%"
                oracle-cases probe-cases golden-cases)
        (format t "  structural invariants: ~a  adversarial: ~a  mutation probes: ~a~%"
                invariant-cases adv-cases mutation-cases)
        (report-failures result))

      ;; every section must have contributed, or a mis-read fixture would let a
      ;; whole area of the gate vanish while still reporting success
      (and (= (gate-result-passed result) (gate-result-total result))
           (plusp oracle-cases)
           (>= oracle-cases 17)
           (plusp probe-cases)
           (plusp golden-cases)
           (>= golden-cases 21)
           (>= invariant-cases 15)
           (>= adv-cases 20)
           (>= mutation-cases 3)))))
