;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 prop4n <contact@legrandenzo.fr>

(define-module (gitops build agent)
  #:use-module (gitops build git)
  #:use-module (gitops build reconfigure)
  #:use-module (gitops build state)
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-11)
  #:export (call-with-lock
            run-agent))

(define (log-message format-string . arguments)
  (format (current-output-port) "~a ~a~%"
          (strftime "%Y-%m-%dT%H:%M:%S%z" (localtime (current-time)))
          (apply format #f format-string arguments))
  (force-output (current-output-port)))

(define (call-with-lock file thunk)
  "Call THUNK while holding an exclusive lock on FILE.  Raise an exception
when the lock is already held by another process."
  (let ((port (open-file file "a")))
    (catch 'system-error
      (lambda ()
        (flock port (logior LOCK_EX LOCK_NB)))
      (lambda _
        (close-port port)
        (error "another guix-gitops agent already holds" file)))
    (dynamic-wind
      (const #t)
      thunk
      (lambda ()
        (flock port LOCK_UN)
        (close-port port)))))

(define* (run-agent #:key url branch system-file channels-file
                    (interval 900)
                    checkout-directory state-file lock-file
                    introduction-commit signer (keyring-reference "keyring")
                    (max-attempts 3) (max-backoff 3600)
                    allow-downgrades? dry-run? (extra-load-path '()))
  (define repository-directory
    (in-vicinity checkout-directory "checkout"))

  (define (authenticated? checkout commit)
    (cond ((not introduction-commit) #t)
          (else
           (catch #t
             (lambda ()
               (authenticate-checkout checkout introduction-commit signer
                                      #:keyring-reference keyring-reference)
               (log-message "authenticated ~a" commit)
               #t)
             (lambda (key . args)
               (log-message "authentication of ~a failed: ~a ~s" commit key args)
               #f)))))

  (define (reconfigure checkout)
    (let ((expression
           (reconfigure-expression (in-vicinity checkout system-file)
                                   #:load-path
                                   (map (lambda (directory)
                                          (in-vicinity checkout directory))
                                        extra-load-path)
                                   #:options
                                   (if allow-downgrades?
                                       '("--allow-downgrades")
                                       '()))))
      (if channels-file
          (reconfigure-with-channels (in-vicinity checkout channels-file)
                                     expression)
          (reconfigure-locally expression))))

  (define (apply-commit state checkout commit now)
    (log-message "applying ~a" commit)
    (if dry-run?
        (log-message "dry run: ~a not applied" commit)
        (let ((status (reconfigure checkout)))
          (if (zero? status)
              (begin
                (log-message "applied ~a" commit)
                (write-state (record-success state commit now) state-file))
              (begin
                (log-message "commit ~a failed with status ~a" commit status)
                (write-state (record-failure state commit now interval
                                             max-backoff)
                             state-file))))))

  (define (run-cycle)
    (let*-values (((state) (read-state state-file))
                  ((checkout commit relation)
                   (fetch-configuration url
                                        #:branch branch
                                        #:cache-directory repository-directory
                                        #:starting-commit
                                        (state-applied-commit state))))
      (let* ((now (current-time))
             (state (let ((observed (record-observation state commit now)))
                      (if (eq? observed state)
                          state
                          (begin
                            (log-message "~a is at ~a (~a)" branch commit
                                         (or relation 'unknown))
                            (write-state observed state-file))))))
        (cond ((not (authenticated? checkout commit))
               (write-state (record-failure state commit now interval
                                            max-backoff)
                            state-file))
              (else
               (match (next-action state commit now max-attempts)
                 ('up-to-date
                  (log-message "already at ~a" commit))
                 ('backoff
                  (log-message "commit ~a failed ~a time(s); next attempt at ~a"
                               commit (state-attempts state)
                               (strftime "%Y-%m-%dT%H:%M:%S%z"
                                         (localtime (state-next-attempt state)))))
                 ('abandoned
                  (log-message "commit ~a abandoned after ~a attempt(s); \
waiting for a new commit"
                               commit (state-attempts state)))
                 ('apply
                  (apply-commit state checkout commit now))))))))

  (call-with-lock lock-file
    (lambda ()
      (log-message "watching ~a on branch ~a every ~a s" url branch interval)
      (when dry-run?
        (log-message "dry run: the system will never be reconfigured"))
      (let loop ()
        (catch #t
          run-cycle
          (lambda (key . args)
            (log-message "cycle failed: ~a ~s" key args)))
        (sleep interval)
        (loop)))))
