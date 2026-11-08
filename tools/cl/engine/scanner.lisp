;;;; scanner.lisp — one string/comment-aware walker, ported from scanner.rs.
;;;;
;;;; This is the hinge of the text tier: literal extraction, balanced-region
;;;; slicing and module splitting all walk JavaScript source the same way, and
;;;; they must agree. One walker, three consumers.
;;;;
;;;; INDEX UNITS. The Rust walks BYTES over UTF-8 and relies on the fact that
;;;; multi-byte sequences never contain the ASCII delimiters it looks for, so
;;;; every delimiter-driven position lands on a char boundary. Lisp `aref`
;;;; indexes CHARACTERS, where the same property holds trivially and more
;;;; strongly: a delimiter is a character, and no character is a fragment of
;;;; another. So this port indexes characters throughout, and every returned
;;;; index is a CHARACTER index.
;;;;
;;;; That is a real, visible difference from the Rust for non-ASCII input: the
;;;; Rust would answer a byte offset. Nothing in the archive compares indices
;;;; across the two (they are used to slice the same string they came from), and
;;;; the oracle's inputs include `ünïcode` precisely so a mismatch surfaces here
;;;; rather than downstream.

(in-package :vovas.engine.scanner)

;;; ---------------------------------------------------------------------------
;;; The skip primitives: given an opening position, answer the position just past
;;; the construct. Each answers a position in the same units as the index given.
;;; ---------------------------------------------------------------------------

(declaim (inline char-at))
(defun char-at (text i)
  (and (< i (length text)) (char text i)))

(defun skip-quoted (text index quote)
  "Skip a '...' or \"...\" literal starting at INDEX (which is the quote).
Answers the position just past the closing quote, or the position of the
newline that terminated it (an unterminated single-quoted string ends at the
line), or the end of the text.

A backslash consumes TWO characters, which is the whole reason this cannot be a
`position` call."
  (let ((n (length text))
        (j (1+ index)))
    (loop while (< j n)
          do (let ((ch (char text j)))
               (cond
                 ((char= ch #\\) (incf j 2))
                 ((char= ch quote) (return-from skip-quoted (1+ j)))
                 ;; a raw newline closes a '...' / "..." literal (the JS
                 ;; grammar forbids it inside, and the original stops there)
                 ((and (char= ch #\Newline) (char/= quote #\`))
                  (return-from skip-quoted j))
                 (t (incf j)))))
    n))

(defun skip-template (text index)
  "Skip a `...` template literal, honouring `${...}` interpolations, which may
nest arbitrarily. Answers the position just past the closing backtick."
  (let ((n (length text))
        (j (1+ index)))
    (loop while (< j n)
          do (let ((ch (char text j)))
               (cond
                 ((char= ch #\\) (incf j 2))
                 ((char= ch #\`)
                  (return-from skip-template (1+ j)))
                 ((and (char= ch #\$)
                       (< (1+ j) n)
                       (char= (char text (1+ j)) #\{))
                  ;; the interpolation body is a balanced region starting at the
                  ;; brace; find-balanced answers past its close
                  (let ((close (find-balanced text (1+ j))))
                    (setf j (if (and close (> close 0)) close (+ j 2)))))
                 (t (incf j)))))
    n))

(defun skip-line-comment (text index)
  "Skip `// ...` to just past the newline (or to the end)."
  (let ((nl (position #\Newline text :start index)))
    (if nl (1+ nl) (length text))))

(defun skip-block-comment (text index)
  "Skip `/* ... */` to just past the terminator (or to the end)."
  (let ((close (search "*/" text :start2 (+ index 2))))
    (if close (+ close 2) (length text))))

(defun regex-start-p (text index)
  "Whether a `/` at INDEX begins a regex literal rather than a division.

The test is the previous non-whitespace character: after an identifier, a
number, `)`, `]` or `_`/`$` a slash divides; anywhere else it starts a regex."
  (let ((j (1- index)))
    (loop while (and (>= j 0) (vovas.engine.util:js-whitespace-p (char text j)))
          do (decf j))
    (if (minusp j)
        t                                   ; start of input: a regex
        (let ((c (char text j)))
          (not (or (alphanumericp c)
                   (char= c #\_)
                   (char= c #\$)
                   (char= c #\))
                   (char= c #\])))))))

(defun skip-regex (text index)
  "Skip a /.../flags literal. Answers the position past the flags, or INDEX+1
when the slash turned out not to start a regex (an unterminated literal is not
a regex, and the caller then advances one character)."
  (let ((n (length text))
        (j (1+ index))
        (in-class nil))
    (loop while (< j n)
          do (let ((ch (char text j)))
               (cond
                 ((char= ch #\\) (incf j 2))
                 ((char= ch #\Newline) (return-from skip-regex (1+ index)))
                 ((char= ch #\[) (setf in-class t) (incf j))
                 ((char= ch #\])
                  (setf in-class nil)
                  (incf j))
                 ((and (char= ch #\/) (not in-class))
                  (incf j)
                  (loop while (and (< j n) (alpha-char-p (char text j)))
                        do (incf j))
                  (return-from skip-regex j))
                 (t (incf j)))))
    (1+ index)))

;;; ---------------------------------------------------------------------------
;;; find-balanced
;;; ---------------------------------------------------------------------------

(defun find-balanced (text open-index)
  "JS `findBalanced(text, openIndex)`: the index just past the bracket that
closes the one at OPEN-INDEX, or NIL when it never closes.

Strings, templates, comments and regexes are skipped rather than counted, which
is what lets `a(\")\")b` close at the right place. `mismatch` in the oracle -
`a[b)c]` - closes at 6, because the `)` is not the bracket being counted and
the `]` at 5 is."
  (let ((open (char-at text open-index)))
    (let ((close (cond ((eql open #\{) #\})
                       ((eql open #\[) #\])
                       ((eql open #\() #\))
                       (t nil))))
      (unless close (return-from find-balanced nil))
      (let ((n (length text))
            (depth 0)
            (i open-index))
        (loop while (< i n)
              do (let ((ch (char text i)))
                   (cond
                     ((or (char= ch #\") (char= ch #\') (char= ch #\`))
                      (setf i (if (char= ch #\`)
                                  (skip-template text i)
                                  (skip-quoted text i ch))))
                     ((and (char= ch #\/)
                           (< (1+ i) n)
                           (char= (char text (1+ i)) #\/))
                      (setf i (skip-line-comment text i)))
                     ((and (char= ch #\/)
                           (< (1+ i) n)
                           (char= (char text (1+ i)) #\*))
                      (setf i (skip-block-comment text i)))
                     ((and (char= ch #\/) (regex-start-p text i))
                      (setf i (skip-regex text i)))
                     ((char= ch open)
                      (incf depth)
                      (incf i))
                     ((char= ch close)
                      (decf depth)
                      (if (zerop depth)
                          ;; return-from, not return: LOOP binds its own block
                          ;; NIL, so a plain `return` would exit only the loop and
                          ;; the trailing nil below would discard the answer -
                          ;; every call answered NIL, including "(ab)".
                          (return-from find-balanced (1+ i))
                          (incf i)))
                     (t (incf i)))))
        nil))))

;;; ---------------------------------------------------------------------------
;;; collectStringLiterals
;;; ---------------------------------------------------------------------------

(defun collect-string-literals (text &optional (min-length 0))
  "JS `collectStringLiterals(text, {minLength})`.

Answers a list of plists `(:start :end :quote :raw :value)` in source order.
`raw` is the text between the quotes (escapes intact), `value` is that text
decoded. MIN-LENGTH filters on the decoded value's UTF-16 length, which is the
JavaScript `length` - not the character count."
  (let ((n (length text))
        (out '()))
    (loop with i = 0
          while (< i n)
          do (let ((ch (char text i)))
               (cond
                 ((or (char= ch #\") (char= ch #\') (char= ch #\`))
                  (let* ((end (if (char= ch #\`)
                                  (skip-template text i)
                                  (skip-quoted text i ch)))
                         ;; the literal's body excludes both quotes; a
                         ;; newline-terminated unterminated string has no
                         ;; closing quote, so the slice stops before the
                         ;; terminator rather than eating a character
                         (body-end (if (and (plusp end)
                                            (< (1- end) n)
                                            (char= (char text (1- end)) ch))
                                       (1- end)
                                       end))
                         (raw (subseq text (1+ i) (max (1+ i) body-end)))
                         (decoded (vovas.engine.decoders:decode-escapes raw)))
                    (when (>= (vovas.engine.util:utf16-length decoded) min-length)
                      (push (list :start i :end end :quote ch :raw raw :value decoded)
                            out))
                    (setf i end)))
                 ((and (char= ch #\/)
                       (< (1+ i) n)
                       (char= (char text (1+ i)) #\/))
                  (setf i (skip-line-comment text i)))
                 ((and (char= ch #\/)
                       (< (1+ i) n)
                       (char= (char text (1+ i)) #\*))
                  (setf i (skip-block-comment text i)))
                 ((and (char= ch #\/) (regex-start-p text i))
                  (setf i (skip-regex text i)))
                 (t (incf i)))))
    (nreverse out)))
