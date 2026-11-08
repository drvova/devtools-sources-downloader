(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(asdf:load-asd (merge-pathnames "tools/cl/vovas-engine.asd" (uiop:getcwd)))
(asdf:load-system :vovas-engine :force :all)
;; serde renders empty containers COMPACT: {} and [].
;; Check JZON agrees, and check a nested-empty object too.
(let ((empty-obj (make-hash-table :test #'equal))
      (outer (make-hash-table :test #'equal)))
  (setf (gethash "a" outer) empty-obj
        (gethash "b" outer) #())
  (format t "~&EMPTY-OBJ>>>~a<<<" (com.inuoe.jzon:stringify empty-obj :pretty t))
  (format t "~&NESTED>>>~a<<<" (com.inuoe.jzon:stringify outer :pretty t)))
