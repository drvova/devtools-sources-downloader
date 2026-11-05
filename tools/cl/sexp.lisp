;;;; sexp.lisp — the toolchain's own data files are Lisp forms.
;;;;
;;;; A sexp file holds symbols, strings, numbers, and nested lists. That is the
;;;; whole format: no schema, no braces, no reader macros. Reading binds
;;;; *READ-EVAL* to NIL so a data file can never execute code, and reads in the
;;;; VOVAS.SEXP package (which USEs CL) so `t` and `nil` are the real booleans and
;;;; bare symbols intern somewhere harmless instead of polluting a real package.
;;;;
;;;; Every symbol in a data file must be a KEYWORD, T, or NIL. A bare symbol is
;;;; refused because it is a collision waiting to happen: reading `step` in a
;;;; package that uses CL silently yields CL:STEP, and the data would compare
;;;; unequal to :STEP for no visible reason. Keywords cannot collide.
;;;;
;;;; JSON stays only where the wire demands it: the DevTools Protocol and the
;;;; extension's manifest.json, both of which Chrome defines. Everything this
;;;; toolchain reads or writes for itself is a sexp file.

(in-package :vovas.tools.util)

(define-condition sexp-error (error)
  ((message :initarg :message :reader sexp-error-message))
  (:report (lambda (c s) (format s "sexp: ~a" (sexp-error-message c)))))

(defun sexp-error (format-control &rest args)
  (error 'sexp-error :message (apply #'format nil format-control args)))

;;; ---------- reading ----------

(defun check-sexp-symbols (form source)
  "Refuse any symbol that is not a keyword, T, or NIL."
  (cond ((keywordp form) nil)
        ((or (eq form t) (null form)) nil)
        ((symbolp form)
         (sexp-error "~a: ~s is a bare symbol; write it as :~(~a~)"
                     source form (symbol-name form)))
        ((consp form)
         (check-sexp-symbols (car form) source)
         (check-sexp-symbols (cdr form) source))
        (t nil)))

(defun read-sexp (string &key (source "<string>"))
  "Read the single form in STRING, in the VOVAS.SEXP package.
Signals SEXP-ERROR when the text is empty, malformed, or holds more than one form."
  (with-input-from-string (in string)
    (let ((*read-eval* nil)
          (*package* (find-package :vovas.sexp)))
      (let ((form (handler-case (read in nil :eof)
                    (error (e) (sexp-error "~a: ~a" source e)))))
        (when (eq form :eof)
          (sexp-error "~a: no form" source))
        ;; a second form is a mistake in a data file, never a second value
        (let ((extra (handler-case (read in nil :eof) (error () :eof))))
          (unless (eq extra :eof)
            (sexp-error "~a: more than one form" source)))
        (check-sexp-symbols form source)
        form))))

(defun read-sexp-file (path)
  "Read one form from PATH. Signals SEXP-ERROR naming the file on any problem."
  (let ((true (or (probe-file path) (sexp-error "no such file: ~a" path))))
    (read-sexp (uiop:read-file-string true) :source (namestring true))))

;;; ---------- writing ----------

(defun sexp-string-literal (s)
  "Escape only what CL's reader needs: the quote and the backslash. A literal
newline inside the string round-trips, so it is left alone."
  (with-output-to-string (out)
    (write-char #\" out)
    (loop for ch across s
          do (case ch
               (#\" (write-string "\\\"" out))
               (#\\ (write-string "\\\\" out))
               (t (write-char ch out))))
    (write-char #\" out)))

(defun sexp-token (x)
  "Printed form of an atom. Keywords keep their colon, so what is written is
exactly what reads back; a bare symbol is refused, matching the reader."
  (cond ((null x) "nil")
        ((eq x t) "t")
        ((keywordp x) (format nil ":~(~a~)" (symbol-name x)))
        ((symbolp x)
         (sexp-error "~s is a bare symbol; write it as :~(~a~)"
                     x (symbol-name x)))
        ((stringp x) (sexp-string-literal x))
        ((characterp x) (sexp-string-literal (string x)))
        ((numberp x) (princ-to-string x))
        (t (sexp-error "cannot write ~s (only symbols, strings, numbers, lists)"
                       x))))

(defun sexp-flat-p (list &optional (limit 72))
  "True when every element is an atom and the one-line form fits within LIMIT."
  (and (every #'atom list)
       (<= (length (format nil "(~{~a~^ ~})" (mapcar #'sexp-token list))) limit)))

(defun sexp-string (form &optional (indent 0))
  "Render FORM as an indented sexp. Atom-only lists stay on one line; anything
nested breaks one element per line, indented under the opening paren."
  (cond
    ((atom form) (sexp-token form))
    ((sexp-flat-p form) (format nil "(~{~a~^ ~})" (mapcar #'sexp-token form)))
    (t (with-output-to-string (out)
         (write-char #\( out)
         (loop for item in form
               for i from 0
               do (if (zerop i)
                      (write-string (sexp-string item (1+ indent)) out)
                      (progn
                        (terpri out)
                        (loop repeat (1+ indent) do (write-char #\Space out))
                        (write-string (sexp-string item (1+ indent)) out))))
         (write-char #\) out)))))

(defun write-sexp-file (path form)
  "Write FORM to PATH as a sexp file, creating parent directories."
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output :if-exists :supersede
                            :if-does-not-exist :create
                            :external-format :utf-8)
    (write-string (sexp-string form) out)
    (terpri out))
  path)

;;; ---------- selftest ----------

(defparameter *sexp-selftest-form*
  '(:gate
    (:step "lint+format (rs check)" :npm ("run" "check") :fast t)
    (:step "clippy" :cargo ("clippy" "--all-targets" "--" "-D" "warnings"))
    (:numbers 1 -2 3.5 0)
    (:flags t nil)
    (:nested (:deeper (:deepest "quotes \" and \\ backslash and
a literal newline"))))
  "A form using every type the format allows, including the two escapes and an
embedded newline, so the round trip proves the reader and the writer together.")

(defun sexp-selftest ()
  "Round-trip the widest form the format allows. Signals SEXP-ERROR on a
mismatch, so a broken reader can never silently misread a data file."
  (let* ((text (sexp-string *sexp-selftest-form*))
         (back (read-sexp text :source "<selftest>")))
    (unless (equal back *sexp-selftest-form*)
      (sexp-error "round trip changed the form~%wrote: ~a~%read:  ~s" text back))
    t))
