(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(asdf:load-asd (merge-pathnames "tools/cl/vovas-engine.asd" (uiop:getcwd)))
(asdf:load-system :vovas-engine :force :all)
(dolist (pair '(("a" "A") ("aB" "Ab") ("Ab" "aB") ("a" "b") ("A" "a")))
  (format t "~&LOC ~s vs ~s -> ~s~%"
          (first pair) (second pair)
          (vovas.engine.text:locale-compare (first pair) (second pair))))
