;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 prop4n <contact@legrandenzo.fr>

(define-module (gitops build agent)
  #:use-module (gitops build git)
  #:use-module (gitops build inferior)
  #:use-module (gitops build journal)
  #:use-module (gitops build reconfigure)
  #:use-module (gitops build runtime)
  #:use-module (gitops build state)
  #:use-module ((guix config) #:select (%state-directory))
  #:use-module ((guix profiles) #:select (generation-number))
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

(define (current-system-generation)
  "Return the number of the current system generation, or #f.  Note that this
reads the system profile rather than /run/current-system: the latter points
into the store, where there is no generation number to be found."
  (catch #t
    (lambda ()
      (match (generation-number
              (string-append %state-directory "/profiles/system"))
        (0 #f)
        (number number)))
    (const #f)))

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
                    checkout-directory state-file lock-file runtime-config-file
                    journal-file (journal-length %default-journal-length)
                    introduction-commit signer (keyring-reference "keyring")
                    (max-attempts 3) (max-backoff 3600)
                    allow-downgrades? dry-run? (extra-load-path '()))
  (define (record-outcome url commit outcome)
    (when journal-file
      (catch #t
        (lambda ()
          (write-journal
           (record-in-journal (read-journal journal-file)
                              (journal-entry (current-time) url commit outcome
                                             #:generation
                                             (current-system-generation))
                              #:max-entries journal-length)
           journal-file))
        (lambda (key . args)
          (log-message "could not record ~a in ~a: ~a ~s"
                       outcome journal-file key args)))))

  (define (runtime-configuration)
    (if runtime-config-file
        (read-runtime-configuration runtime-config-file
                                    #:warn
                                    (lambda (key value)
                                      (log-message "ignoring ~s ~s from ~a"
                                                   key value
                                                   runtime-config-file)))
        '()))

  (define (authenticated? checkout commit commit-of-introduction signer)
    (cond ((not commit-of-introduction) #t)
          (else
           (catch #t
             (lambda ()
               (authenticate-checkout checkout commit-of-introduction signer
                                      #:keyring-reference keyring-reference)
               (log-message "authenticated ~a" commit)
               #t)
             (lambda (key . args)
               (log-message "authentication of ~a failed: ~a ~s" commit key args)
               #f)))))

  (define (reconfigure checkout system-file channels-file extra-load-path)
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

  (define (apply-commit state url checkout commit now reconfigure!)
    (log-message "applying ~a" commit)
    (if dry-run?
        (log-message "dry run: ~a not applied" commit)
        (let ((status (reconfigure!)))
          (if (zero? status)
              (begin
                (log-message "applied ~a" commit)
                (write-state (record-success state commit now) state-file)
                (record-outcome url commit 'applied))
              (begin
                (log-message "commit ~a failed with status ~a" commit status)
                (write-state (record-failure state commit now interval
                                             max-backoff)
                             state-file)
                (record-outcome url commit 'failed))))))

  (define (run-cycle)
    (let* ((runtime (runtime-configuration))
           (url (runtime-ref runtime 'url url))
           (branch (runtime-ref runtime 'branch branch))
           (system-file (runtime-ref runtime 'system-file system-file))
           (channels-file (runtime-ref runtime 'channels-file channels-file))
           (extra-load-path
            (runtime-ref runtime 'extra-load-path extra-load-path))
           (state (let* ((recorded (read-state state-file))
                         (state (state-for-target recorded url system-file)))
                    (unless (eq? state recorded)
                      (log-message "following ~a in ~a on branch ~a"
                                   system-file url branch)
                      (write-state state state-file))
                    state)))
      (let*-values (((commit-of-introduction signer)
                     (effective-introduction runtime introduction-commit signer))
                    ((checkout commit relation)
                     (fetch-configuration url
                                          #:branch branch
                                          #:cache-directory checkout-directory
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
             (if (authenticated? checkout commit commit-of-introduction signer)
                 (apply-commit state url checkout commit now
                               (lambda ()
                                 (reconfigure checkout system-file
                                              channels-file extra-load-path)))
                 (begin
                   (write-state (record-failure state commit now interval
                                                max-backoff)
                                state-file)
                   (record-outcome url commit 'rejected)))))))))

  (define (run-cycle/caught)
    (catch #t
      (lambda () (run-cycle) #t)
      (lambda (key . args)
        (log-message "cycle failed: ~a ~s" key args)
        #f)))

  (call-with-lock lock-file
    (lambda ()
      (log-message "checking every ~a s" interval)
      (when runtime-config-file
        (log-message "runtime configuration read from ~a" runtime-config-file))
      (when dry-run?
        (log-message "dry run: the system will never be reconfigured"))
      (let loop ((failures 0))
        (if (run-cycle/caught)
            (begin
              (sleep interval)
              (loop 0))
            ;; The cycle itself failed, which usually means the network is not
            ;; ready yet -- at boot, the agent may well start before DNS does.
            ;; Come back quickly instead of idling for a whole interval.
            (let ((delay (retry-delay (+ failures 1) interval)))
              (log-message "retrying in ~a s" delay)
              (sleep delay)
              (loop (+ failures 1))))))))
