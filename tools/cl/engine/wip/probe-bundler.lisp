;;;; probe-bundler.lisp — ad-hoc evidence for extract-bundle-modules.
;;;;
;;;; Lives in the repo rather than /tmp because `fixture-path` resolves the
;;;; checkout root from the file's own location, so a probe outside the tree
;;;; cannot find the fixtures.

(require :asdf)
(load "C:/Users/bigmo/quicklisp/setup.lisp")
(asdf:load-asd (truename "tools/cl/vovas-engine.asd"))
(asdf:load-system :vovas-engine)

(let* ((inputs (vovas.engine.gate::read-json-file
                (vovas.engine.gate::fixture-path "text-tier-inputs.json")))
       (oracle (vovas.engine.gate::read-json-file
                (vovas.engine.gate::fixture-path "text-tier-oracle.json")))
       (src (gethash "bundle" (gethash "sources" inputs)))
       (want (gethash "bundle" (gethash "extractBundleModules" oracle)))
       (got (vovas.engine.bundler:extract-bundle-modules src)))
  (format t "~&got count:  ~a~%want count: ~a~%" (length got) (length want))
  (loop for m in got
        for i from 0
        do (format t "  [~a] id=~s params=~s code-len=~a~%"
                   i
                   (vovas.engine.bundler:bundle-module-id m)
                   (vovas.engine.bundler:bundle-module-params m)
                   (length (vovas.engine.bundler:bundle-module-code m))))
  (format t "~&oracle:~%")
  (loop for w across want
        do (format t "  id=~s params=~s code-len=~a~%"
                   (gethash "id" w) (gethash "params" w)
                   (length (gethash "code" w)))))
(finish-output)
