;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 prop4n <contact@legrandenzo.fr>

(define-module (gitops build server)
  #:use-module (gitops build health)
  #:use-module (gitops build journal)
  #:use-module (gitops build json)
  #:use-module (gitops build state)
  #:use-module (ice-9 match)
  #:use-module (ice-9 rdelim)
  #:use-module (web request)
  #:use-module (web response)
  #:use-module (web server)
  #:use-module (web uri)
  #:export (handle-request
            run-health-server))

(define (read-link file)
  (catch 'system-error
    (lambda () (readlink file))
    (const #f)))

(define (read-first-line file)
  (catch #t
    (lambda ()
      (call-with-input-file file
        (lambda (port)
          (match (read-line port)
            ((? string? line) line)
            (_ #f)))))
    (const #f)))

(define %json-headers
  '((content-type . (application/json (charset . "utf-8")))
    (cache-control . (no-store))))

(define (respond code payload)
  (values (build-response #:code code #:headers %json-headers)
          (scm->json-string payload)))

(define* (handle-request path #:key state-file journal-file
                         (booted-system "/run/booted-system")
                         (current-system "/run/current-system")
                         (uptime-file "/proc/uptime"))
  "Answer a request for PATH.  Everything is read from disk on each request:
the state file is written atomically, and reading it afresh is what lets this
run in a process of its own."
  (match path
    ((or "/health" "/")
     (respond 200
              (health-report (read-state state-file)
                             #:booted-system (read-link booted-system)
                             #:current-system (read-link current-system)
                             #:uptime (parse-uptime
                                       (read-first-line uptime-file))
                             #:now (current-time))))
    ("/history"
     (respond 200 (history-report (read-journal journal-file))))
    (_
     (respond 404 `((error . "not found")
                    (paths . ("/health" "/history")))))))

(define* (run-health-server #:key host port state-file journal-file)
  (format (current-output-port) "guix-gitops: serving health on ~a:~a~%"
          host port)
  (force-output (current-output-port))
  (run-server (lambda (request body)
                (handle-request (uri-path (request-uri request))
                                #:state-file state-file
                                #:journal-file journal-file))
              'http
              `(#:host ,host #:port ,port)))
