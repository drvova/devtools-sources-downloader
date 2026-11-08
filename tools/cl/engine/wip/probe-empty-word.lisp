;;;; probe-empty-word.lisp — settle the empty-word question against the engine.
;;;;
;;;; packers.rs's unpack_with:
;;;;
;;;;   if idx >= 0 && (idx as usize) < words.len() && !words[idx as usize].is_empty()
;;;;       words[idx].clone()  else  token
;;;;
;;;; So an EMPTY word leaves the TOKEN in place: "0 1" with words ("a" "") must
;;;; answer "a 1".
;;;;
;;;; This loads the modules DIRECTLY rather than through vovas-engine, because a
;;;; parallel agent's gate file currently does not read (unbalanced parens) and
;;;; would abort the whole system load. A probe that cannot run because of an
;;;; unrelated file is not evidence, so it bypasses it.

(require :asdf)
(load "C:/Users/bigmo/quicklisp/setup.lisp")
(ql:quickload '("cl-ppcre" "com.inuoe.jzon" "ironclad" "babel" "cl-unicode") :silent t)

(dolist (f '("package" "util" "number" "transforms" "decoders" "scanner"
             "digest" "bundler" "text" "beautify" "packers"))
  (load (compile-file (format nil "tools/cl/engine/~a.lisp" f))))

(flet ((show (label payload base words expected)
         (let ((got (vovas.engine.packers::unpack-with payload base words)))
           (format t "~&~a~%  payload ~s base ~a words ~s~%  got      ~s~%  expected ~s~%  ~a~%"
                   label payload base words got expected
                   (if (equal got expected) "MATCH" "*** MISMATCH ***")))))
  (show "empty word keeps the token" "0 1" 4 '("a" "") "a 1")
  (show "normal substitution" "0 1" 4 '("a" "b") "a b")
  (show "index past the end" "10 3" 4 '("a" "b" "c" "d") "10 d")
  (show "single token" "0" 4 '("a" "b") "a"))

(finish-output)
