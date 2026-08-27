;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 prop4n <contact@legrandenzo.fr>

(define-module (gitops tests)
  #:use-module (guix discovery)
  #:use-module ((guix ui) #:select (warn-about-load-error))
  #:use-module ((gnu tests) #:select (system-test?))
  #:export (all-system-tests))

(define (test-modules)
  (scheme-modules
   (dirname
    (dirname (dirname (search-path %load-path "gitops/services/agent.scm"))))
   "gitops/tests"
   #:warn warn-about-load-error))

(define (all-system-tests)
  (reverse
   (fold-module-public-variables (lambda (object result)
                                   (if (system-test? object)
                                       (cons object result)
                                       result))
                                 '()
                                 (test-modules))))
