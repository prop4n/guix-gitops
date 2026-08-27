;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 prop4n <contact@legrandenzo.fr>

;; Read every Scheme file in the repository without evaluating it.  This
;; catches unbalanced parentheses and malformed literals in the modules that
;; cannot be loaded without Guix.

(use-modules (ice-9 ftw)
             (ice-9 match)
             (srfi srfi-1))

;; Teach the reader about G-Expression syntax, which is normally provided by
;; (guix gexp).  The results are discarded; only the shape matters here.
(define (read-prefixed tag)
  (lambda (character port)
    (if (eqv? #\@ (peek-char port))
        (begin
          (read-char port)
          (list (symbol-append tag '-splicing) (read port)))
        (list tag (read port)))))

(for-each (match-lambda
            ((character . tag)
             (read-hash-extend character (read-prefixed tag))))
          '((#\~ . gexp)
            (#\$ . ungexp)
            (#\+ . ungexp-native)))

(define (scheme-files directory)
  (let ((files '()))
    (ftw directory
         (lambda (name statinfo flag)
           (when (and (eq? flag 'regular) (string-suffix? ".scm" name))
             (set! files (cons name files)))
           #t))
    (sort files string<?)))

(define (check file)
  (catch #t
    (lambda ()
      (call-with-input-file file
        (lambda (port)
          (let loop ()
            (unless (eof-object? (read port))
              (loop)))))
      #t)
    (lambda (key . args)
      (format (current-error-port) "~a: ~a ~s~%" file key args)
      #f)))

(let* ((files (scheme-files (if (defined? 'command-line)
                                (match (command-line)
                                  ((_ directory _ ...) directory)
                                  (_ "."))
                                ".")))
       (bad (remove check files)))
  (format #t "checked ~a Scheme files~%" (length files))
  (unless (null? bad)
    (format (current-error-port) "~a file(s) failed to parse~%" (length bad)))
  (exit (null? bad)))
