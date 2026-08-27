;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 prop4n <contact@legrandenzo.fr>

(define-module (gitops build json)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:export (json-null
            json-null?
            scm->json-string))

;; Deliberately small: this writes the handful of shapes the health endpoint
;; reports, and nothing else.  Keeping it here rather than reaching for
;; guile-json means the whole reporting path stays testable under plain Guile,
;; escaping included.

(define json-null 'null)

(define (json-null? value)
  (eq? value json-null))

(define (write-json-string string port)
  (display #\" port)
  (string-for-each
   (lambda (character)
     (match character
       (#\" (display "\\\"" port))
       (#\\ (display "\\\\" port))
       (#\newline (display "\\n" port))
       (#\return (display "\\r" port))
       (#\tab (display "\\t" port))
       (_
        (if (char<? character #\space)
            (format port "\\u~4,'0x" (char->integer character))
            (display character port)))))
   string)
  (display #\" port))

(define (alist? value)
  (and (list? value)
       (every (match-lambda
                (((? symbol?) . _) #t)
                (_ #f))
              value)))

(define (write-json value port)
  (match value
    ((? json-null?) (display "null" port))
    (#t (display "true" port))
    (#f (display "false" port))
    ((? string? string) (write-json-string string port))
    ((? symbol? symbol) (write-json-string (symbol->string symbol) port))
    ((? exact-integer? integer) (display integer port))
    ((? real? real) (display (exact->inexact real) port))
    ;; The empty list is both a list and an association list; an empty
    ;; collection is always meant as an array here.
    (() (display "[]" port))
    ((? alist? alist)
     (display #\{ port)
     (fold (lambda (entry first?)
             (unless first? (display #\, port))
             (match entry
               ((key . value)
                (write-json-string (symbol->string key) port)
                (display #\: port)
                (write-json value port)))
             #f)
           #t
           alist)
     (display #\} port))
    ((? list? list)
     (display #\[ port)
     (fold (lambda (item first?)
             (unless first? (display #\, port))
             (write-json item port)
             #f)
           #t
           list)
     (display #\] port))
    (_ (write-json-string (object->string value) port))))

(define (scm->json-string value)
  (call-with-output-string
    (lambda (port) (write-json value port))))
