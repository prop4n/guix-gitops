;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 prop4n <contact@legrandenzo.fr>

(define-module (gitops build reconfigure)
  #:use-module (guix channels)
  #:use-module (guix inferior)
  #:use-module (guix ui)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:export (reconfigure-expression
            reconfigure-locally
            reconfigure-with-channels))

(define* (reconfigure-expression system-file #:key (load-path '()) (options '()))
  "Return an s-expression that reconfigures the running system according to
SYSTEM-FILE and evaluates to an exit status.  The expression only refers to
'guix-system', the public entry point of (guix scripts system), so that it can
be evaluated by any Guix revision."
  `(begin
     (use-modules (guix scripts system))
     (catch #t
       (lambda ()
         (catch 'quit
           (lambda ()
             (apply guix-system
                    (list ,@(append-map (lambda (directory)
                                          (list "-L" directory))
                                        load-path)
                          ,@options
                          "reconfigure" ,system-file))
             0)
           (lambda (key . args)
             (match args
               ((status . _) (if (integer? status) status 0))
               (_ 0)))))
       (lambda (key . args)
         1))))

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
           (lambda _ 1)))
        (match (waitpid pid)
          ((_ . status) (or (status:exit-val status) 1))))))

(define (read-channels file)
  (load* file '((guix channels))))

(define (reconfigure-with-channels channels-file expression)
  "Evaluate EXPRESSION in an inferior pinned to the channels declared in
CHANNELS-FILE.  Return its exit status."
  (let ((inferior (inferior-for-channels (read-channels channels-file))))
    (dynamic-wind
      (const #t)
      (lambda ()
        (match (inferior-eval expression inferior)
          ((? integer? status) status)
          (_ 1)))
      (lambda ()
        (close-inferior inferior)))))
