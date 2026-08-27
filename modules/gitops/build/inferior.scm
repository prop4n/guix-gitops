;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 prop4n <contact@legrandenzo.fr>

(define-module (gitops build inferior)
  #:use-module (guix inferior)
  #:use-module (guix ui)
  #:use-module (ice-9 match)
  #:export (reconfigure-with-channels))

(define (read-channels file)
  (load* file '((guix channels))))

(define (reconfigure-with-channels channels-file expression)
  "Evaluate EXPRESSION in an inferior pinned to the channels declared in
CHANNELS-FILE.  Return its exit status."
  (let ((inferior (inferior-for-channels (read-channels channels-file))))
    (dynamic-wind
      (const #t)
      (lambda ()
        (catch #t
          (lambda ()
            (match (inferior-eval expression inferior)
              ((? integer? status) status)
              (_ 1)))
          (lambda (key . args)
            (format (current-error-port)
                    "guix-gitops: inferior raised ~a ~s~%" key args)
            (force-output (current-error-port))
            1)))
      (lambda ()
        (close-inferior inferior)))))
