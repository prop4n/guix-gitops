;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 prop4n <contact@legrandenzo.fr>

(define-module (gitops build reconfigure)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:export (exit-status-expression
            reconfigure-expression
            reconfigure-locally))

(define (exit-status-expression body)
  "Wrap BODY, an s-expression, so that it evaluates to an exit status whether
it returns normally or calls 'exit'.  The expression must not rely on anything
beyond the core bindings, since it is evaluated in a fresh user module or in
an inferior."
  `(catch 'quit
     (lambda () ,body 0)
     (lambda (key . args)
       (let ((value (if (pair? args) (car args) #t)))
         (cond ((integer? value) value)
               (value 0)
               (else 1))))))

(define* (reconfigure-expression system-file #:key (load-path '()) (options '()))
  "Return an s-expression that reconfigures the running system according to
SYSTEM-FILE and evaluates to an exit status.  It only refers to 'guix-system',
the public entry point of (guix scripts system), so that any Guix revision can
evaluate it.

Everything 'guix-system' would print is sent to the error port.  This is not
cosmetic: when the expression runs in an inferior, standard output carries the
REPL protocol, and a single line of build progress written there corrupts it
and takes the inferior down."
  `(begin
     (use-modules (guix scripts system))
     ,(exit-status-expression
       `(parameterize ((current-output-port (current-error-port)))
          (apply guix-system
                 (list ,@(append-map (lambda (directory)
                                       (list "-L" directory))
                                     load-path)
                       ,@options
                       "reconfigure" ,system-file))))))

(define (report-exception key args)
  (format (current-error-port) "guix-gitops: reconfiguration raised ~a ~s~%"
          key args)
  (force-output (current-error-port)))

(define (reconfigure-locally expression)
  "Evaluate EXPRESSION in a child process using the Guix revision this agent
was built with.  Return its exit status."
  (let ((pid (primitive-fork)))
    (if (zero? pid)
        (primitive-_exit
         (catch #t
           (lambda ()
             (match (eval expression (make-fresh-user-module))
               ((? integer? status) status)
               (_ 1)))
           (lambda (key . args)
             (report-exception key args)
             1)
           (lambda (key . args)
             (false-if-exception
              (display-backtrace (make-stack #t) (current-error-port))))))
        (match (waitpid pid)
          ((_ . status) (or (status:exit-val status) 1))))))
