;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 prop4n <contact@legrandenzo.fr>

(define-module (tests reconfigure)
  #:use-module (gitops build reconfigure)
  #:use-module (srfi srfi-64))

(define (status-of body)
  (reconfigure-locally (exit-status-expression body)))

(test-begin "reconfigure")

(test-equal "a body that returns normally succeeds"
  0
  (status-of '(+ 1 2)))

;; The expression is evaluated in a fresh user module, which binds far less
;; than this file does.  Anything the handler needs must be a core binding.
(test-equal "'exit 0' is a success, not a failure"
  0
  (status-of '(exit 0)))

(test-equal "'exit' with a status propagates it"
  5
  (status-of '(exit 5)))

(test-equal "'exit #t' is a success"
  0
  (status-of '(exit #t)))

(test-equal "'exit #f' is a failure"
  1
  (status-of '(exit #f)))

(test-assert "a raised exception is a failure"
  (not (zero? (status-of '(error "boom")))))

(test-assert "an unbound variable is a failure"
  (not (zero? (status-of '(this-is-not-bound)))))

(test-equal "a non-integer result is a failure"
  1
  (reconfigure-locally '"not a status"))

(test-assert "the generated expression mentions the system file"
  (let ((expression (reconfigure-expression "/repo/system.scm")))
    (string-contains (object->string expression) "/repo/system.scm")))

(test-assert "extra load paths become -L options"
  (let ((expression (reconfigure-expression "/repo/system.scm"
                                            #:load-path '("/repo/modules"))))
    (string-contains (object->string expression) "\"-L\" \"/repo/modules\"")))

(test-assert "options are passed through"
  (let ((expression (reconfigure-expression "/repo/system.scm"
                                            #:options '("--allow-downgrades"))))
    (string-contains (object->string expression) "--allow-downgrades")))

(test-end "reconfigure")
