;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 prop4n <contact@legrandenzo.fr>

(define-module (tests health)
  #:use-module (gitops build health)
  #:use-module (gitops build journal)
  #:use-module (gitops build json)
  #:use-module (gitops build state)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-64))

(define %a "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
(define %b "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
(define %url "https://example.org/infra.git")

(define (field report key)
  (assq-ref report key))

(define (report-of state)
  (health-report state
                 #:booted-system "/gnu/store/aaa-system"
                 #:current-system "/gnu/store/aaa-system"))

(test-begin "json")

(test-equal "strings are quoted"
  "\"hello\""
  (scm->json-string "hello"))

(test-equal "quotes and backslashes are escaped"
  "\"a\\\"b\\\\c\""
  (scm->json-string "a\"b\\c"))

(test-equal "control characters are escaped"
  "\"a\\nb\\tc\""
  (scm->json-string "a\nb\tc"))

(test-equal "booleans and null"
  "[true,false,null]"
  (scm->json-string (list #t #f json-null)))

(test-equal "an association list is an object"
  "{\"a\":1,\"b\":\"x\"}"
  (scm->json-string '((a . 1) (b . "x"))))

;; The empty list is both a list and an association list in Scheme; an empty
;; history must not be reported as an empty object.
(test-equal "the empty list is an array"
  "[]"
  (scm->json-string '()))

(test-equal "a list of objects stays an array"
  "[{\"a\":1},{\"a\":2}]"
  (scm->json-string '(((a . 1)) ((a . 2)))))

(test-end "json")

(test-begin "health")

(test-equal "a reboot is needed when the running system is not the booted one"
  #t
  (reboot-needed? "/gnu/store/aaa-system" "/gnu/store/bbb-system"))

(test-equal "no reboot is needed when they agree"
  #f
  (reboot-needed? "/gnu/store/aaa-system" "/gnu/store/aaa-system"))

(test-equal "an unreadable link means no claim"
  #f
  (reboot-needed? #f "/gnu/store/aaa-system"))

(test-equal "a fresh agent reports nothing applied"
  'null
  (field (report-of %empty-state) 'applied))

(test-equal "a fresh agent is not up to date"
  #f
  (field (report-of %empty-state) 'up-to-date))

(test-equal "an applied commit is reported"
  %a
  (field (report-of (record-success %empty-state %a 100)) 'applied))

(test-equal "a machine that applied what it observed is up to date"
  #t
  (let* ((state (record-observation %empty-state %a 100))
         (state (record-success state %a 100)))
    (field (report-of state) 'up-to-date)))

(test-equal "a machine behind its repository is not up to date"
  #f
  (let* ((state (record-success %empty-state %a 100))
         (state (record-observation state %b 200)))
    (field (report-of state) 'up-to-date)))

(test-equal "a failing commit is reported with its attempts"
  (list %b 2)
  (let* ((state (record-failure %empty-state %b 0 60 3600))
         (state (record-failure state %b 100 60 3600))
         (report (report-of state)))
    (list (field report 'failed) (field report 'attempts))))

(test-equal "no failure means no attempts"
  0
  (field (report-of (record-success %empty-state %a 100)) 'attempts))

(test-equal "the repository is reported"
  %url
  (field (report-of (state-for-repository %empty-state %url)) 'url))

(test-assert "a report serializes to JSON"
  (string-prefix? "{" (scm->json-string (report-of %empty-state))))

;;; Uptime.

(test-equal "uptime is the first field of /proc/uptime, rounded"
  663
  (parse-uptime "662.98 9623.43"))

(test-equal "a whole number of seconds is fine too"
  1000
  (parse-uptime "1000 2000"))

(test-equal "a machine up for no time at all"
  0
  (parse-uptime "0.00 0.00"))

(test-equal "garbage is not an uptime"
  #f
  (parse-uptime "not a number"))

(test-equal "an empty file is not an uptime"
  #f
  (parse-uptime ""))

(test-equal "a missing file is not an uptime"
  #f
  (parse-uptime #f))

(test-equal "a negative uptime is refused"
  #f
  (parse-uptime "-5.0 10.0"))

(test-equal "the boot time is derived from the uptime"
  1787831092
  (assq-ref (health-report %empty-state #:now 1787831755 #:uptime 663)
            'booted-at))

(test-equal "without an uptime there is no boot time"
  'null
  (assq-ref (health-report %empty-state #:now 1787831755) 'booted-at))

(test-equal "without a clock there is no boot time either"
  'null
  (assq-ref (health-report %empty-state #:uptime 663) 'booted-at))

(test-end "health")

(test-begin "journal")

(test-equal "an entry keeps what it was given"
  (list 100 %url %a 'applied 42)
  (let ((entry (journal-entry 100 %url %a 'applied #:generation 42)))
    (list (entry-time entry) (entry-url entry) (entry-commit entry)
          (entry-outcome entry) (entry-generation entry))))

(test-equal "an entry without a generation is still an entry"
  #f
  (entry-generation (journal-entry 100 %url %a 'failed)))

(test-equal "the newest entry comes first"
  (list %b %a)
  (let* ((journal (record-in-journal '() (journal-entry 1 %url %a 'applied)))
         (journal (record-in-journal journal
                                     (journal-entry 2 %url %b 'applied))))
    (map entry-commit journal)))

(test-equal "the journal is bounded"
  3
  (length
   (fold (lambda (n journal)
           (record-in-journal journal (journal-entry n %url %a 'applied)
                              #:max-entries 3))
         '()
         (iota 20))))

(test-equal "the oldest entries are the ones dropped"
  '(19 18 17)
  (map entry-time
       (fold (lambda (n journal)
               (record-in-journal journal (journal-entry n %url %a 'applied)
                                  #:max-entries 3))
             '()
             (iota 20))))

(test-equal "a missing journal is empty, not an error"
  '()
  (read-journal "/nonexistent/guix-gitops/journal.scm"))

(test-equal "history of an empty journal is an empty array"
  "[]"
  (scm->json-string (history-report '())))

(test-equal "history reports every entry"
  2
  (length (history-report
           (list (journal-entry 2 %url %b 'failed)
                 (journal-entry 1 %url %a 'applied)))))

(test-end "journal")
