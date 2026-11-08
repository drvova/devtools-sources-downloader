(require :asdf)
(load "C:/Users/bigmo/quicklisp/setup.lisp")
(ql:quickload '("cl-ppcre" "com.inuoe.jzon" "ironclad" "babel" "chipz" "salza2" "cl-unicode") :silent t)
(dolist (f '("package" "util" "number" "transforms" "decoders" "scanner" "digest"
             "bundler" "text" "beautify" "detectors" "sourcemaps" "packers"
             "wasm" "jscbytecode" "v8codecache" "zip" "jsfuck" "pipeline" "assets"))
  (load (compile-file (format nil "tools/cl/engine/~a.lisp" f)
                      :output-file (format nil "C:/Users/bigmo/AppData/Local/Temp/la-~a.fasl" f))))
(format t "~&LOADED~%")
