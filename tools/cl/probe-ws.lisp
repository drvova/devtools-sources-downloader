;;;; probe-ws.lisp - ad-hoc workspace probes.
(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(asdf:load-asd (merge-pathnames "tools/cl/vovas-engine.asd" (uiop:getcwd)))
(asdf:load-system :vovas-engine)

(in-package :vovas.engine.gate)

(defun pdiff (got want &optional (path ""))
  (cond
    ((and (hash-table-p got) (hash-table-p want))
     (dolist (k (sort (remove-duplicates
                       (append (loop for x being the hash-keys of got collect x)
                               (loop for x being the hash-keys of want collect x))
                       :test #'string=)
                      #'string<))
       (multiple-value-bind (gv gp) (gethash k got)
         (multiple-value-bind (wv wp) (gethash k want)
           (cond ((and gp wp) (pdiff gv wv (format nil "~a.~a" path k)))
                 ((and (not gp) wp) (format t "~&  ~a.~a: MISSING (want ~s)~%" path k wv))
                 ((and gp (not wp)) (format t "~&  ~a.~a: EXTRA (got ~s)~%" path k gv)))))))
    ((and (or (vectorp got) (listp got)) (or (vectorp want) (listp want)))
     (let ((g (coerce got 'list)) (w (coerce want 'list)))
       (unless (= (length g) (length w))
         (format t "~&  ~a: LENGTH got=~a want=~a~%" path (length g) (length w)))
       (loop for i below (min (length g) (length w))
             do (pdiff (nth i g) (nth i w) (format nil "~a[~a]" path i)))))
    ((not (equal got want))
     (format t "~&  ~a: got=~s want=~s~%" path got want))))

(let* ((fx (read-json-file (fixture-path "panel/boundary-oracle.json")))
       (exp (gethash "expected" fx))
       (analysis (gate-analysis-fixture)))
  (format t "~&===== framework state workspace~%")
  (let ((ws (list (vovas.engine.panel.workspace:build-boundary-workspace
                   "bootstrap" analysis))))
    (pdiff (vovas.engine.panel.workspace:build-framework-state-workspace analysis ws)
           (gethash "buildFrameworkStateWorkspace" exp))))
