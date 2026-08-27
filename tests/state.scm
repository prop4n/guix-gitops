;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 prop4n <contact@legrandenzo.fr>

(define-module (tests state)
  #:use-module (gitops build state)
  #:use-module (srfi srfi-64))

(define %a "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
(define %b "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")

(define (call-with-temporary-file proc)
  (let ((file (string-append (or (getenv "TMPDIR") "/tmp")
                             "/guix-gitops-test-"
                             (number->string (getpid))
                             "-"
                             (number->string (random 100000)))))
    (dynamic-wind
      (const #t)
      (lambda () (proc file))
      (lambda ()
        (when (file-exists? file) (delete-file file))))))

(test-begin "state")

(test-equal "read-state on a missing file"
  %empty-state
  (read-state "/nonexistent/guix-gitops/state.scm"))

(test-equal "read-state on garbage"
  %empty-state
  (call-with-temporary-file
   (lambda (file)
     (call-with-output-file file
       (lambda (port) (display "not a state" port)))
     (read-state file))))

(test-equal "read-state on an incompatible version"
  %empty-state
  (call-with-temporary-file
   (lambda (file)
     (call-with-output-file file
       (lambda (port) (write '((version . 999) (applied-commit . "x")) port)))
     (read-state file))))

(test-equal "write-state then read-state round-trips"
  %a
  (call-with-temporary-file
   (lambda (file)
     (write-state (record-success %empty-state %a 42) file)
     (state-applied-commit (read-state file)))))

(test-assert "write-state leaves no temporary file behind"
  (call-with-temporary-file
   (lambda (file)
     (write-state (record-success %empty-state %a 42) file)
     (not (file-exists? (string-append file ".tmp"))))))

(test-equal "record-success clears the failure bookkeeping"
  '(#f 0 0)
  (let* ((failed (record-failure %empty-state %a 100 60 3600))
         (state (record-success failed %a 200)))
    (list (state-failed-commit state)
          (state-attempts state)
          (state-next-attempt state))))

(test-equal "record-observation is a no-op for a known commit"
  #t
  (let ((state (record-observation %empty-state %a 10)))
    (eq? state (record-observation state %a 20))))

(test-equal "record-observation records a new commit"
  (list %b 20)
  (let* ((state (record-observation %empty-state %a 10))
         (state (record-observation state %b 20)))
    (list (state-observed-commit state) (state-observed-time state))))

(test-equal "record-failure counts attempts on the same commit"
  3
  (let* ((state (record-failure %empty-state %a 0 60 3600))
         (state (record-failure state %a 100 60 3600))
         (state (record-failure state %a 200 60 3600)))
    (state-attempts state)))

(test-equal "record-failure resets attempts on a different commit"
  1
  (let* ((state (record-failure %empty-state %a 0 60 3600))
         (state (record-failure state %a 100 60 3600))
         (state (record-failure state %b 200 60 3600)))
    (state-attempts state)))

(test-equal "record-failure preserves the applied commit"
  %a
  (let* ((state (record-success %empty-state %a 0))
         (state (record-failure state %b 100 60 3600)))
    (state-applied-commit state)))

(test-end "state")
