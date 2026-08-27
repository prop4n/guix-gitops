;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 prop4n <contact@legrandenzo.fr>

(define-module (tests decision)
  #:use-module (gitops build state)
  #:use-module (srfi srfi-64))

(define %a "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
(define %b "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")

(test-begin "decision")

(test-equal "backoff grows exponentially"
  '(60 120 240 480)
  (map (lambda (attempts) (backoff-delay attempts 60 3600))
       '(1 2 3 4)))

(test-equal "backoff is clamped"
  '(3600 3600)
  (map (lambda (attempts) (backoff-delay attempts 60 3600))
       '(10 20)))

(test-equal "backoff of a first attempt is one interval"
  60
  (backoff-delay 1 60 3600))

(test-equal "a fresh agent applies"
  'apply
  (next-action %empty-state %a 0 3))

(test-equal "an already applied commit is up to date"
  'up-to-date
  (next-action (record-success %empty-state %a 0) %a 100 3))

(test-equal "a new commit is applied over an applied one"
  'apply
  (next-action (record-success %empty-state %a 0) %b 100 3))

(test-equal "a just-failed commit backs off"
  'backoff
  (next-action (record-failure %empty-state %a 0 60 3600) %a 30 3))

(test-equal "a failed commit is retried once the delay elapsed"
  'apply
  (next-action (record-failure %empty-state %a 0 60 3600) %a 60 3))

(test-equal "a commit failing too often is abandoned"
  'abandoned
  (let* ((state (record-failure %empty-state %a 0 60 3600))
         (state (record-failure state %a 100 60 3600))
         (state (record-failure state %a 300 60 3600)))
    (next-action state %a 100000 3)))

(test-equal "a new commit is applied after an abandoned one"
  'apply
  (let* ((state (record-failure %empty-state %a 0 60 3600))
         (state (record-failure state %a 100 60 3600))
         (state (record-failure state %a 300 60 3600)))
    (next-action state %b 100000 3)))

(test-equal "a failing commit that got applied is up to date"
  'up-to-date
  (let* ((state (record-failure %empty-state %a 0 60 3600))
         (state (record-success state %a 100)))
    (next-action state %a 200 3)))

(test-end "decision")
