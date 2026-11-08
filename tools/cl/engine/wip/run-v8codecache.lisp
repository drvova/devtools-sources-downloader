;;;; run-v8codecache.lisp — run the V8 code-cache gate, exit 0 on pass.
;;;;
;;;; Each form is top-level and separate: LOAD reads one form at a time, so a
;;;; form naming `vovas.engine.gate::...` must come after the form that loads the
;;;; system, or the reader fails with "package does not exist" before anything
;;;; runs. That is why the `uiop:quit` form is separate from the run too.
;;;;
;;;; TWO asd files are loaded, in this order. `vovas-engine.asd` defines the base
;;;; system this slice depends on; without it ASDF reports
;;;; `Component "vovas-engine" not found, required by #<SYSTEM
;;;; "vovas-engine.v8codecache">`, which reads like a broken slice rather than a
;;;; missing search path.

(require :asdf)

(load "C:/Users/bigmo/quicklisp/setup.lisp")

(asdf:load-asd (truename "C:/Users/bigmo/Downloads/vovas-devtools-soruce-downloader/tools/cl/vovas-engine.asd"))

(asdf:load-asd (truename "C:/Users/bigmo/Downloads/vovas-devtools-soruce-downloader/tools/cl/engine/v8codecache.asd"))

(asdf:load-system :vovas-engine.v8codecache)

(let ((ok (vovas.engine.gate::run-v8codecache-gate)))
  (format t "~&result: ~:[FAIL~;PASS~]~%" ok)
  (finish-output)
  (uiop:quit (if ok 0 1)))
