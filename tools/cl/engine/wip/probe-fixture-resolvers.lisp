;;;; probe-fixture-resolvers.lisp — prove the unified resolvers pick the right file.
;;;;
;;;; Two directories, disjoint contents. A resolver that silently served the
;;;; wrong one would let a gate compare against a file it was never meant to
;;;; read, and every case would still "pass" against the wrong expectations.
;;;; So this asserts both directions, plus the subpath case and the binary read.

(require :asdf)
(load "C:/Users/bigmo/quicklisp/setup.lisp")
(asdf:load-asd (truename "tools/cl/vovas-engine.asd"))
(asdf:load-system :vovas-engine)

(let ((ok t))
  (flet ((check (label got want)
           (let ((match (equal (uiop:native-namestring got)
                               (uiop:native-namestring want))))
             (unless match (setf ok nil))
             (format t "~&  ~a ~a~%    got  ~a~%    want ~a~%"
                     (if match "ok  " "FAIL") label got want))))
    ;; JSON fixture lives in tests/ (plural)
    (check "json fixture resolves to tests/"
           (vovas.engine.gate::fixture-path "text-tier-oracle.json")
           (merge-pathnames "unpack-rs/tests/fixtures/text-tier-oracle.json"
                            (vovas.engine.gate::repo-root)))
    ;; a subpath under tests/ must work (panel/ exists)
    (check "subpath fixture resolves to tests/panel/"
           (vovas.engine.gate::fixture-path "panel/parity-oracle.json")
           (merge-pathnames "unpack-rs/tests/fixtures/panel/parity-oracle.json"
                            (vovas.engine.gate::repo-root)))
    ;; binary fixture lives in test/ (singular)
    (check "binary fixture resolves to test/"
           (vovas.engine.gate::binary-fixture-path "wasm-named.wasm")
           (merge-pathnames "unpack-rs/test/fixtures/wasm-named.wasm"
                            (vovas.engine.gate::repo-root))))
  ;; the binary read must produce bytes, not characters
  (let ((bytes (vovas.engine.gate::binary-fixture-bytes "wasm-named.wasm")))
    (let ((magic (subseq bytes 0 4)))
      (let ((is-wasm (equalp magic #(0 97 115 109))))
        (unless is-wasm (setf ok nil))
        (format t "~&  ~a wasm magic bytes ~s (want #(0 97 115 109) = \\0asm)~%"
                (if is-wasm "ok  " "FAIL") magic)))
    (format t "    length ~a, element-type ~a~%"
            (length bytes) (array-element-type bytes)))
  (format t "~&~%resolver probe: ~a~%" (if ok "every resolver is correct" "FAILURES"))
  (sb-ext:exit :code (if ok 0 1)))
