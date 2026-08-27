;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 prop4n <contact@legrandenzo.fr>

(use-modules (srfi srfi-64)
             (ice-9 match))

(add-to-load-path (dirname (dirname (current-filename))))

(define %failures 0)

(define runner
  (let ((runner (test-runner-simple)))
    (test-runner-on-test-end! runner
      (let ((previous (test-runner-on-test-end runner)))
        (lambda (runner)
          (match (test-result-kind runner)
            ((or 'fail 'xpass) (set! %failures (+ 1 %failures)))
            (_ #t))
          (previous runner))))
    runner))

(test-runner-current runner)

(for-each (lambda (name)
            (resolve-module `(tests ,name)))
          '(state decision reconfigure runtime health))

(exit (zero? %failures))
