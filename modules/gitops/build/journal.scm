;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 prop4n <contact@legrandenzo.fr>

(define-module (gitops build journal)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:export (%default-journal-length

            journal-entry
            entry-time
            entry-url
            entry-commit
            entry-outcome
            entry-generation

            read-journal
            write-journal
            record-in-journal))

(define %default-journal-length 50)

(define* (journal-entry time url commit outcome #:key generation)
  "Return an entry recording that COMMIT of URL met OUTCOME at TIME, having
produced system generation GENERATION when it was applied."
  `((time . ,time)
    (url . ,url)
    (commit . ,commit)
    (outcome . ,outcome)
    ,@(if generation `((generation . ,generation)) '())))

(define (field entry key default)
  (match (assq key entry)
    ((_ . value) value)
    (_ default)))

(define (entry-time entry) (field entry 'time 0))
(define (entry-url entry) (field entry 'url #f))
(define (entry-commit entry) (field entry 'commit #f))
(define (entry-outcome entry) (field entry 'outcome #f))
(define (entry-generation entry) (field entry 'generation #f))

(define (entry? value)
  (and (list? value)
       (pair? value)
       (every (match-lambda
                (((? symbol?) . _) #t)
                (_ #f))
              value)))

(define (read-journal file)
  "Read the journal held in FILE, newest entry first.  Return the empty list
when FILE is missing or unreadable: losing the history must never keep the
agent from converging."
  (catch #t
    (lambda ()
      (call-with-input-file file
        (lambda (port)
          (match (read port)
            ((? list? entries) (filter entry? entries))
            (_ '())))))
    (lambda _ '())))

(define (write-journal journal file)
  "Atomically write JOURNAL to FILE.  Return JOURNAL."
  (let ((temporary (string-append file ".tmp")))
    (call-with-output-file temporary
      (lambda (port)
        (write journal port)
        (newline port)))
    (rename-file temporary file)
    journal))

(define* (record-in-journal journal entry
                            #:key (max-entries %default-journal-length))
  "Return JOURNAL with ENTRY at its head, keeping at most MAX-ENTRIES of them.
The history is bounded on purpose: it lives on machines nobody watches, and an
unbounded file there eventually becomes an outage."
  (let ((journal (cons entry journal)))
    (if (> (length journal) max-entries)
        (take journal max-entries)
        journal)))
