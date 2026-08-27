;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 prop4n <contact@legrandenzo.fr>

(define-module (gitops build state)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:export (%state-version
            %empty-state

            state-applied-commit
            state-applied-time
            state-observed-commit
            state-observed-time
            state-failed-commit
            state-attempts
            state-next-attempt

            read-state
            write-state

            %initial-retry-delay
            backoff-delay
            retry-delay
            record-observation
            record-success
            record-failure
            next-action))

(define %state-version 1)

(define %empty-state
  `((version . ,%state-version)))

(define (field state key default)
  (match (assq key state)
    ((_ . value) value)
    (_ default)))

(define (state-applied-commit state) (field state 'applied-commit #f))
(define (state-applied-time state) (field state 'applied-time 0))
(define (state-observed-commit state) (field state 'observed-commit #f))
(define (state-observed-time state) (field state 'observed-time 0))
(define (state-failed-commit state) (field state 'failed-commit #f))
(define (state-attempts state) (field state 'attempts 0))
(define (state-next-attempt state) (field state 'next-attempt 0))

(define (remove-fields state keys)
  (fold (lambda (key result) (alist-delete key result eq?)) state keys))

(define (set-fields state alist)
  (fold (lambda (pair result)
          (cons pair (alist-delete (car pair) result eq?)))
        state
        alist))

(define (read-state file)
  "Read the agent state from FILE.  Return %EMPTY-STATE when FILE is missing,
unreadable, malformed or written by an incompatible version."
  (catch #t
    (lambda ()
      (call-with-input-file file
        (lambda (port)
          (match (read port)
            ((? list? state)
             (if (eqv? %state-version (field state 'version #f))
                 state
                 %empty-state))
            (_ %empty-state)))))
    (lambda _ %empty-state)))

(define (write-state state file)
  "Atomically write STATE to FILE.  Return STATE."
  (let ((temporary (string-append file ".tmp")))
    (call-with-output-file temporary
      (lambda (port)
        (write state port)
        (newline port)))
    (rename-file temporary file)
    state))

(define %initial-retry-delay 5)

(define (backoff-delay attempts interval maximum)
  (min maximum (* interval (expt 2 (max 0 (- attempts 1))))))

(define (retry-delay failures interval)
  "Return how long to wait before retrying a cycle that failed outright, as
opposed to one that reached a commit and failed to apply it.  Such failures are
usually transient -- no network yet, no DNS yet -- so come back quickly at
first, and no later than INTERVAL once it is clear the problem persists."
  (backoff-delay failures %initial-retry-delay interval))

(define (record-observation state commit now)
  (if (equal? commit (state-observed-commit state))
      state
      (set-fields state `((observed-commit . ,commit)
                          (observed-time . ,now)))))

(define (record-success state commit now)
  (set-fields (remove-fields state '(failed-commit attempts next-attempt))
              `((applied-commit . ,commit)
                (applied-time . ,now))))

(define (record-failure state commit now interval maximum)
  (let ((attempts (if (equal? commit (state-failed-commit state))
                      (+ 1 (state-attempts state))
                      1)))
    (set-fields state
                `((failed-commit . ,commit)
                  (attempts . ,attempts)
                  (next-attempt . ,(+ now (backoff-delay attempts interval
                                                         maximum)))))))

(define (next-action state commit now max-attempts)
  "Decide what to do about COMMIT given STATE at time NOW.  Return 'up-to-date
when COMMIT is already deployed, 'apply when it should be deployed, 'backoff
when a previous attempt failed and the retry delay has not elapsed, and
'abandoned when COMMIT failed MAX-ATTEMPTS times."
  (cond ((equal? commit (state-applied-commit state)) 'up-to-date)
        ((not (equal? commit (state-failed-commit state))) 'apply)
        ((>= (state-attempts state) max-attempts) 'abandoned)
        ((< now (state-next-attempt state)) 'backoff)
        (else 'apply)))
