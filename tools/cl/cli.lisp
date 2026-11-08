;;;; cli.lisp — the native CLI over the engine, i.e. the "native path" the
;;;; engine's own README promises and the tree did not have.
;;;;
;;;; Two commands, and they exist for different reasons:
;;;;
;;;;   vovas engine <name> [json-args]   one dispatch arm, called directly.
;;;;       This is the REPL-shaped tool: it lets you re-run a single function
;;;;       against a fixture and read the answer, instead of cargo test -> wasm
;;;;       build -> reload the extension.
;;;;
;;;;   vovas unpack <capture.json> [--out DIR]
;;;;       the PRODUCT path: a captured page snapshot goes in, an unpacked file
;;;;       tree comes out - the same 53-artifact export the extension produces,
;;;;       through `panelFinalizeZipWithRecon` and no other route.
;;;;
;;;; THE JSON SEAM. The toolchain's JSON layer (`vovas.tools.util`) converts
;;;; objects to PLISTS because that is what the rest of the CLI wants. The engine
;;;; speaks HASH TABLES, because that is what JZON hands it and what the wire
;;;; shape needs for key ORDER on the report. So this file owns the conversion in
;;;; one place (`wire->engine`), rather than letting either side change dialect.
;;;; A plist cannot represent an object with duplicate keys and cannot distinguish
;;;; "absent" from "null"; a hash table can, and the engine's accessors depend on
;;;; that distinction.

(in-package :vovas.tools)

;;; ---------------------------------------------------------------------------
;;; The JSON seam
;;; ---------------------------------------------------------------------------
;;;
;;; JZON's own parse output IS the engine's dialect: objects are equal
;;; hash tables with the camelCase keys the JSON had, arrays are vectors, and
;;; `null` is the symbol CL:NULL. That is why the engine's arms read `gethash`
;;; with literal camelCase keys and never normalise anything.
;;;
;;; The toolchain's `vovas.tools.util:json-decode` is a DIFFERENT dialect: it
;;; lowercases camelCase to kebab (`jsAssets` -> `:js-assets`) and collapses
;;; null and false into NIL, because the rest of the CLI asks "is it there".
;;; Feeding that to the engine is what produced a 25-file export claiming
;;; "0 of 0 scripts": every asset lookup missed and the batch ran empty. The
;;; conversion belongs HERE, as a direct JZON read, not as a translation back
;;; from the lossy form - camelCase cannot be recovered from kebab once
;;; `jsAssets` and `js_assets` have both become `:js-assets`.

(defun read-json-for-engine (text)
  "TEXT parsed into the engine's dialect - JZON's own output.

`*read-default-float-format*` is bound to DOUBLE-FLOAT for the same reason the
gate binds it: JZON builds numbers by reading their text, so without the binding
a large exponent becomes a SINGLE float and the reader errors on a value it
cannot represent."
  (let ((*read-default-float-format* 'double-float))
    (com.inuoe.jzon:parse text)))

(defun read-capture-file (path)
  "The capture document at PATH in the engine's dialect."
  (with-open-file (in path :direction :input :external-format :utf-8)
    (read-json-for-engine
     (with-output-to-string (out)
       (loop for line = (read-line in nil :eof)
             until (eq line :eof)
             do (write-string line out)
                (write-char #\Newline out))))))

(defun engine->value (value)
  "VALUE converted from the engine's dialect into what `json-encode` accepts.

Hash tables become plists, vectors become lists, and CL:NULL - JZON's spelling
of JSON null - passes through untouched, because `lisp->json` knows that symbol.
An engine-side NIL becomes NIL, which this project encodes as `false`; the
engine does not produce NIL where it means null, so the two do not collide."
  (cond
    ((eq value 'null) 'null)
    ((null value) nil)
    ((hash-table-p value)
     (let ((pairs '()))
       (maphash (lambda (k v) (push (cons k v) pairs)) value)
       (loop for (key . val) in (sort pairs (lambda (a b) (string< (car a) (car b))))
             nconc (list (intern (string-upcase key) :keyword)
                         (engine->value val)))))
    ((and (vectorp value) (not (stringp value)))
     (coerce (loop for v across value collect (engine->value v)) 'list))
    (t value)))

;;; ---------------------------------------------------------------------------
;;; vovas engine
;;; ---------------------------------------------------------------------------

(defun engine-command (args)
  "`vovas engine [name] [json-args]`.

With no NAME, list every arm so the surface is discoverable from the shell
rather than only from the source. With a name, dispatch it and print the answer
as JSON - `(:ok ...)` prints the value, `(:error ...)` prints the refusal text
and exits 1, which is what makes this usable in a pipeline."
  (let ((name (first args))
        (raw (second args)))
    (cond
      ((null name)
       (format t "~&~a callable engine functions:~%" (length (vovas.engine.panel.api:arm-names)))
       (dolist (arm (vovas.engine.panel.api:arm-names))
         (format t "  ~a~%" arm))
       (format t "~&usage: vovas engine <name> ['[args...]']~%")
       0)
      ((not (vovas.engine.panel.api:arm-name-p name))
       (format t "~&no engine function named ~a~%" name)
       (format t "run `vovas engine` for the list~%")
       1)
      (t
       (let* ((decoded (if raw (read-json-for-engine raw) #()))
              (args-vector (cond ((vectorp decoded) decoded)
                                 ((null decoded) #())
                                 (t (vector decoded))))
              (byte-arm (nth-value 1 (gethash name
                                              vovas.engine.panel.api::*byte-arms*)))
              (outcome (if byte-arm
                           (vovas.engine.panel.api:dispatch-bytes name args-vector)
                           (vovas.engine.panel.api:dispatch name args-vector))))
         (case (first outcome)
           (:ok
            (if byte-arm
                ;; Bytes are not JSON. Report the length and the first bytes so
                ;; the answer is checkable without a hex dump of an archive.
                (let ((bytes (second outcome)))
                  (format t "~&bytes ~a~%" (length bytes))
                  (when (plusp (length bytes))
                    (format t "head ~s~%"
                            (map 'string #'code-char
                                 (subseq bytes 0 (min 8 (length bytes))))))
                  0)
                (progn
                  (format t "~&~a~%"
                          (vovas.tools.util:json-encode
                           (engine->value (second outcome))))
                  0)))
           (:error
            (format t "~&error: ~a~%" (second outcome))
            1)))))))

;;; ---------------------------------------------------------------------------
;;; vovas unpack
;;; ---------------------------------------------------------------------------

(defun unpack-input-file (path)
  "The capture document at PATH, in the engine's dialect.

Accepts the shape the export arm takes - an object with `jsAssets`, `reconData`,
`runtimePayloads` and optional `options` - because that IS the arm's contract,
and inventing a second input format here would mean two ways to describe one
capture."
  (let ((decoded (read-capture-file path)))
    (unless (hash-table-p decoded)
      (error "~a is not a capture object" path))
    decoded))

(defun unpack-write (out-dir files)
  "Write FILES into OUT-DIR, answering how many were written.

A file with `content` is text; one with `base64` is binary and is decoded. Both
cases keep the archive's own relative path, and the parent directories are
created as needed, because the export writes into nested prefixes."
  (let ((count 0))
    (loop for file across files
          for path = (gethash "path" file)
          for content = (gethash "content" file)
          for b64 = (gethash "base64" file)
          do (let ((target (merge-pathnames (substitute #\/ #\\ path)
                                            (uiop:ensure-directory-pathname out-dir))))
               (ensure-directories-exist target)
               (if b64
                   (with-open-file (stream target :direction :output
                                                  :element-type '(unsigned-byte 8)
                                                  :if-exists :supersede)
                     (write-sequence (vovas.engine.decoders:decode-base64-to-bytes b64)
                                     stream))
                   (with-open-file (stream target :direction :output
                                                  :element-type 'character
                                                  :if-exists :supersede
                                                  :external-format :utf-8)
                     (write-string (or content "") stream)))
               (incf count)))
    count))

(defun unpack-command (args)
  "`vovas unpack <capture.json> [--out DIR]`.

Runs the product path through the dispatch table - `panelFinalizeZipWithRecon`
and nothing else - then writes the artifacts under OUT-DIR. Prints the engine's
own summary line, so a run is comparable to what the panel shows."
  (let ((path (first args))
        (out nil))
    (loop for (arg . rest) on args
          when (string= arg "--out") do (setf out (first rest)))
    (cond
      ((null path)
       (format t "~&usage: vovas unpack <capture.json> [--out DIR]~%")
       2)
      ((not (probe-file path))
       (format t "~&no such capture: ~a~%" path)
       1)
      (t
       (let* ((capture (unpack-input-file path))
              (options (gethash "options" capture))
              (answer (vovas.engine.panel.api:call
                       "panelFinalizeZipWithRecon"
                       (vector (gethash "jsAssets" capture)
                               (gethash "reconData" capture)
                               (gethash "pageSnapshot" capture)
                               (or (gethash "runtimePayloads" capture) #())
                               (or options (make-hash-table :test #'equal)))))
              (files (gethash "files" answer))
              (summary (gethash "summary" answer))
              (dir (or out "unpacked")))
         (format t "~&~a~%" summary)
         (format t "files   ~a~%" (length files))
         (format t "written ~a to ~a~%" (unpack-write dir files) dir)
         0)))))
