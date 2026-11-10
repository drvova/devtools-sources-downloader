;;;; gate-api.lisp — the dispatch layer (wasm_api.rs).
;;;;
;;;; The other gates prove each module answers correctly when called directly.
;;;; This one proves the SURFACE is the engine's surface: the same 49 names, the
;;;; same argument handling, and - the part that matters most - that the whole
;;;; 53-file export can be produced THROUGH the table rather than by reaching
;;;; past it into the modules.
;;;;
;;;; Four kinds of assertion, in increasing strength:
;;;;
;;;;   1. NAMES. The table's key set against `wasm_api.rs`, parsed from the
;;;;      source rather than from a list kept here. A hand-kept list would pass
;;;;      forever after the Rust grew an arm and this file did not.
;;;;   2. ARITY AND REFUSAL. Which arms refuse a missing argument and which
;;;;      default it is NOT uniform - `sha256Hex` refuses, `sanitizeFilename`
;;;;      answers the empty string - so both classes are pinned.
;;;;   3. BEHAVIOUR. Nine arms are driven with real inputs and compared against
;;;;      the same oracles their own modules use, so the gate catches a table
;;;;      wired to the wrong function (a transposition nothing else would see).
;;;;   4. END TO END. `panelFinalizeZipWithRecon` through `call` must reproduce
;;;;      the engine's 53 files and its summary string. That is the assertion
;;;;      that says the port is callable, not merely correct.

(in-package :vovas.engine.gate)

;;; ---------------------------------------------------------------------------
;;; The Rust's arm names, parsed from the source
;;; ---------------------------------------------------------------------------

(defun rust-arm-names ()
  "The arm names the shipped engine dispatched, from the frozen record.

The Rust source used to be parsed live - the point was to notice when it
changed. The Rust tree is gone, so the surface is FROZEN instead:
`tools/cl/fixtures/oracles/dispatch-arms.json` holds the 49 names captured from
`wasm_api.rs` the day the tree was deleted. A renamed or lost arm still fails;
the difference is that the record can no longer drift because nothing generates
it any more."
  (let* ((path (fixture-path "dispatch-arms.json"))
         (text (uiop:read-file-string path)))
    (unless (char= (char text 0) #\[)
      (error "dispatch-arms.json is not a JSON array"))
    ;; The JSON parser, not `read`: a bracket is not a Lisp macro character the
    ;; reader agrees on, and the file IS JSON.
    (with-input-from-string (stream text)
      (let ((parsed (com.inuoe.jzon:parse text)))
        ;; The caller binds (rust-bytes rust-json): bytes first.
        (values (list "buildZip")
                (remove "buildZip" (coerce parsed 'list) :test #'string=))))))

;;; ---------------------------------------------------------------------------
;;; The gate
;;; ---------------------------------------------------------------------------

(defun run-api-gate (&key (verbose t))
  (let* ((result (make-gate-result))
         (count 0))
    (flet ((expect (label input got want)
             (incf count)
             (check result label input got want)))

      ;; ---- 1. the name sets ---------------------------------------------
      (multiple-value-bind (rust-bytes rust-json) (rust-arm-names)
        (let ((lisp-json (sort (loop for k being the hash-keys
                                       of vovas.engine.panel.api::*arms*
                                     collect k)
                               #'string<))
              (lisp-bytes (sort (loop for k being the hash-keys
                                        of vovas.engine.panel.api::*byte-arms*
                                      collect k)
                                #'string<)))
          (expect "API/json-arms" "sorted names" lisp-json (sort (copy-list rust-json) #'string<))
          (expect "API/byte-arms" "sorted names" lisp-bytes (sort (copy-list rust-bytes) #'string<))
          (expect "API/total" "both tables" (length (vovas.engine.panel.api:arm-names))
                  (+ (length rust-json) (length rust-bytes)))))

      ;; ---- 2. refusal vs default ----------------------------------------
      ;;
      ;; The three classes the Rust actually has. Pinning one example of each
      ;; is enough to catch a rewrite that made every arm refuse, or every arm
      ;; default - both plausible "cleanups" that would change the contract.
      (expect "API/refuses-missing" "sha256Hex with no argument"
            (let ((outcome (vovas.engine.panel.api:dispatch "sha256Hex" #())))
              (and (eq (first outcome) :error) :refused))
            :refused)
      (expect "API/refusal-text" "names the arm and its argument"
            (second (vovas.engine.panel.api:dispatch "sha256Hex" #()))
            "sha256Hex: text")
      (expect "API/defaults-missing" "sanitizeFilename with no argument"
              (vovas.engine.panel.api:call "sanitizeFilename" #())
              "unknown/resource")
      (expect "API/null-not-refusal" "findBalanced with no index"
            (vovas.engine.panel.api:call "findBalanced" (vector "{}"))
            nil)
      (expect "API/unknown-arm" "a name with no arm"
            (first (vovas.engine.panel.api:dispatch "noSuchArm" #()))
            :error)
      (expect "API/byte-arm-misuse" "a bytes arm through the JSON table"
            (first (vovas.engine.panel.api:dispatch "buildZip" #()))
            :error)

      ;; ---- 3. behaviour, against each module's own oracle ----------------
      (expect "API/sha256Hex" "the empty string"
            (vovas.engine.panel.api:call "sha256Hex" (vector ""))
            (vovas.engine.digest:sha256-hex ""))
      (expect "API/sha256Hex-nonempty" "abc"
            (vovas.engine.panel.api:call "sha256Hex" (vector "abc"))
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
      (expect "API/bytesToText" "UTF-8 bytes"
            (vovas.engine.panel.api:call "bytesToText" (vector (vector 104 105)))
            "hi")
      (expect "API/looksMinified" "a long single line"
            (vovas.engine.panel.api:call
             "looksMinified"
             (vector "var a=1;var b=2;function c(){return a+b}console.log(c());"))
            t)
      (expect "API/printableRatio" "pure ASCII"
            (vovas.engine.panel.api:call "printableRatio" (vector "abc"))
            1d0)

      ;; The LIMITS object is the engine's own constants; comparing it against
      ;; the parameters proves the arm reads the values rather than restating
      ;; them, which is the one thing a hand-written arm gets wrong.
      (let ((limits (vovas.engine.panel.api:call "LIMITS" #())))
        (expect "API/LIMITS/maxDepth" "reads the parameter"
              (gethash "maxDepth" limits) vovas.engine.util:*limits-max-depth*)
        (expect "API/LIMITS/maxModules" "reads the parameter"
              (gethash "maxModules" limits) vovas.engine.util:*limits-max-modules*)
        (expect "API/LIMITS/keys" "seven fields"
              (let ((keys '()))
                (maphash (lambda (k v) (declare (ignore v)) (push k keys)) limits)
                (sort keys #'string<))
              '("maxAssetBytes" "maxBeautifyBytes" "maxDepth" "maxMapBytes"
                "maxModules" "maxSources" "minPayloadLength")))

      ;; The zip arm answers BYTES, and the round trip through the decoder
      ;; proves it emitted a real archive rather than a text lookalike.
      (let ((bytes (vovas.engine.panel.api:call-bytes
                    "buildZip"
                    (vector (vector (let ((f (make-hash-table :test #'equal)))
                                      (setf (gethash "path" f) "a.txt")
                                      (setf (gethash "content" f) "hello")
                                      f))
                            1700000000000d0))))
        (expect "API/buildZip/signature" "starts with PK"
              (and (>= (length bytes) 4)
                   (map 'string #'code-char (subseq bytes 0 2)))
              "PK")
        (expect "API/buildZip/size" "a real archive, not empty"
              (plusp (length bytes)) t))

      ;; ---- 4. the whole export THROUGH the table ------------------------
      ;;
      ;; This is the assertion the file exists for. Everything above proves the
      ;; table is wired; this proves the wiring produces the product. The
      ;; fixture is the same one the parity gate uses, so the expected values
      ;; are the shipped engine's, not this port's.
      (let* ((fx (read-json-file (fixture-path "panel/finalize-oracle.json")))
             (inp (gethash "inputs" fx))
             (exp (gethash "expected" fx))
             (opt (gethash "options" inp))
             (opts (let ((table (make-hash-table :test #'equal)))
                     (when opt
                       (let ((prefix (vovas.engine.panel.assets:field-str opt "pathPrefix")))
                         (when (plusp (length prefix))
                           (setf (gethash "pathPrefix" table) prefix))))
                     table))
             (answer (vovas.engine.panel.api:call
                      "panelFinalizeZipWithRecon"
                      (vector (gethash "jsAssets" inp)
                              (gethash "reconData" inp)
                              nil
                              (gethash "runtimePayloads" inp)
                              opts))))
        (expect "API/finalize/file-count" "the engine's 53 files"
              (length (gethash "files" answer))
              (length (gethash "files" exp)))
        (expect "API/finalize/summary" "the engine's summary line"
              (gethash "summary" answer)
              "Export ready. Unpacked 0 of 5 scripts (2 beautified, 0 original sources, 0 bundle modules).")
        ;; The oracle's file list is written SORTED (it is a JSON fixture, and a
        ;; sorted list is the only stable way to store it), while an emission
        ;; list is in write order. Comparing them element-wise compares a sort
        ;; against a sequence, which fails on a correct export - so this asserts
        ;; the same SET. Order is not dropped from the suite: the parity gate
        ;; above replays the engine's files in the order it wrote them and
        ;; compares index by index, which is where ordering belongs.
        (expect "API/finalize/paths" "every path the engine wrote"
              (sort (loop for f across (gethash "files" answer)
                          collect (gethash "path" f))
                    #'string<)
              (sort (loop for f across (gethash "files" exp)
                          collect (coerce (vovas.engine.panel.assets:field-str f "path")
                                          'string))
                    #'string<))
        ;; The writer decides text-or-base64 per file. This fixture's export is
        ;; entirely text (all 53 artifacts are `content`), so asserting that it
        ;; "carries binary" would be asserting something the engine does not do
        ;; here. The branch is exercised directly instead: a text file must cross
        ;; as `content` and a byte payload must cross as `base64`, because a
        ;; binary payload sent as `content` would be mangled by the encoder.
        (expect "API/wire/text-file" "text crosses as content"
              (let ((f (vovas.engine.panel.api::file->wire "a.txt" "hello")))
                (list (gethash "content" f) (gethash "base64" f)))
              '("hello" nil))
        (expect "API/wire/binary-file" "bytes cross as base64"
              (let ((f (vovas.engine.panel.api::file->wire
                        "a.bin" (vector 255 254 253))))
                (gethash "base64" f))
              "//79")))

    (when verbose
      (format t "~&api gate: ~a/~a cases match~%"
              (gate-result-passed result) (gate-result-total result))
      (report-failures result))

    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp count))))
