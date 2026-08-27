;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 prop4n <contact@legrandenzo.fr>

(define-module (gitops build health)
  #:use-module (gitops build journal)
  #:use-module (gitops build json)
  #:use-module (gitops build state)
  #:use-module (ice-9 match)
  #:export (reboot-needed?
            parse-uptime
            health-report
            history-report))

(define (or-null value)
  (if value value json-null))

(define (reboot-needed? booted-system current-system)
  "Return true when the running system is not the one that was booted, which
is how Guix says that a reconfiguration has landed but is not fully in effect.
Both arguments are the targets of /run/booted-system and /run/current-system."
  (and (string? booted-system)
       (string? current-system)
       (not (string=? booted-system current-system))))

(define (parse-uptime contents)
  "Return the number of whole seconds the machine has been up, read from the
contents of /proc/uptime, or #f when it cannot be made sense of."
  (and (string? contents)
       (match (string-tokenize contents)
         ((seconds . _)
          (let ((seconds (string->number seconds)))
            (and (real? seconds) (>= seconds 0) (inexact->exact (round seconds)))))
         (_ #f))))

(define* (health-report state #:key booted-system current-system (now #f)
                        (uptime #f))
  "Return the health of the agent as an association list, ready to be
serialized.  It is built from STATE alone, so it can be reported by a process
other than the agent -- including when the agent is no longer running, which
is exactly when it is worth asking."
  (let ((applied (state-applied-commit state))
        (failed (state-failed-commit state)))
    `((url . ,(or-null (state-url state)))
      (applied . ,(or-null applied))
      (applied-time . ,(or-null (and applied (state-applied-time state))))
      (observed . ,(or-null (state-observed-commit state)))
      (observed-time . ,(or-null (and (state-observed-commit state)
                                      (state-observed-time state))))
      (up-to-date . ,(and applied
                          (equal? applied (state-observed-commit state))))
      (failed . ,(or-null failed))
      (attempts . ,(if failed (state-attempts state) 0))
      (next-attempt . ,(or-null (and failed (state-next-attempt state))))
      (booted-system . ,(or-null booted-system))
      (current-system . ,(or-null current-system))
      (reboot-needed . ,(reboot-needed? booted-system current-system))
      (uptime . ,(or-null uptime))
      (booted-at . ,(or-null (and uptime now (- now uptime))))
      ,@(if now `((now . ,now)) '()))))

(define (entry->report entry)
  `((time . ,(or-null (entry-time entry)))
    (url . ,(or-null (entry-url entry)))
    (commit . ,(or-null (entry-commit entry)))
    (outcome . ,(or-null (entry-outcome entry)))
    (generation . ,(or-null (entry-generation entry)))))

(define (history-report journal)
  "Return JOURNAL as a list of association lists, newest first."
  (map entry->report journal))
