;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 prop4n <contact@legrandenzo.fr>

(define-module (gitops tests agent)
  #:use-module (gitops services agent)
  #:use-module (gnu packages version-control)
  #:use-module (gnu services)
  #:use-module (gnu services networking)
  #:use-module (gnu system vm)
  #:use-module (gnu tests)
  #:use-module (guix gexp)
  #:export (%test-gitops-agent))

(define %configuration-repository
  (computed-file
   "gitops-configuration-repository"
   (with-imported-modules '((guix build utils))
     #~(begin
         (use-modules (guix build utils))
         (setenv "GIT_CONFIG_NOSYSTEM" "1")
         (setenv "GIT_CONFIG_GLOBAL" "/dev/null")
         (setenv "GIT_AUTHOR_NAME" "guix-gitops")
         (setenv "GIT_AUTHOR_EMAIL" "gitops@localhost")
         (setenv "GIT_COMMITTER_NAME" "guix-gitops")
         (setenv "GIT_COMMITTER_EMAIL" "gitops@localhost")
         (setenv "GIT_AUTHOR_DATE" "@0 +0000")
         (setenv "GIT_COMMITTER_DATE" "@0 +0000")
         (let ((git #$(file-append git "/bin/git")))
           (mkdir-p #$output)
           (with-directory-excursion #$output
             (call-with-output-file "system.scm"
               (lambda (port)
                 (write '(begin
                           (use-modules (gnu))
                           (operating-system
                             (host-name "converged")
                             (timezone "Etc/UTC")
                             (bootloader
                              (bootloader-configuration
                               (bootloader grub-bootloader)
                               (targets '("/dev/vda"))))
                             (file-systems %base-file-systems)))
                        port)))
             (invoke git "init" "--initial-branch=main" ".")
             (invoke git "add" "system.scm")
             (invoke git "commit" "-m" "Initial commit")))))))

(define %gitops-agent-os
  (simple-operating-system
   (service dhcpcd-service-type)
   (service gitops-agent-service-type
            (gitops-agent-configuration
             (url #~(string-append "file://" #$%configuration-repository))
             (branch "main")
             (system-file "system.scm")
             (interval 5)
             (health (gitops-health-configuration (port 9902)))
             (dry-run? #t)))))

(define (run-gitops-agent-test)
  (define os
    (marionette-operating-system
     %gitops-agent-os
     #:imported-modules '((gnu services herd))))

  (define test
    (with-imported-modules '((gnu build marionette))
      #~(begin
          (use-modules (gnu build marionette)
                       (srfi srfi-64))

          (define marionette (make-marionette (list #$(virtual-machine os))))

          (define (state-field key)
            (marionette-eval
             `(begin
                (use-modules (ice-9 match))
                (call-with-input-file "/var/lib/guix-gitops/state.scm"
                  (lambda (port)
                    (match (assq ',key (read port))
                      ((_ . value) value)
                      (_ #f)))))
             marionette))

          (test-runner-current (system-test-runner #$output))
          (test-begin "gitops-agent")

          (test-assert "service is running"
            (marionette-eval
             '(begin
                (use-modules (gnu services herd))
                (and (wait-for-service 'gitops-agent) #t))
             marionette))

          ;; Each repository is cached under a directory derived from its URL,
          ;; so that pointing the agent elsewhere cannot reuse a stale remote.
          (test-assert "the repository is cached under its own directory"
            (marionette-eval
             '(begin
                (use-modules (ice-9 ftw) (srfi srfi-1))
                (let loop ((attempts 30))
                  (define checkouts
                    (or (scandir "/var/cache/guix-gitops"
                                 (lambda (name)
                                   (not (member name '("." "..")))))
                        '()))
                  (cond ((any (lambda (directory)
                                (file-exists?
                                 (string-append "/var/cache/guix-gitops/"
                                                directory "/system.scm")))
                              checkouts)
                         #t)
                        ((zero? attempts) #f)
                        (else (sleep 1) (loop (- attempts 1))))))
             marionette))

          (test-assert "the state file is written"
            (wait-for-file "/var/lib/guix-gitops/state.scm" marionette))

          (test-assert "the observed commit is a commit id"
            (let loop ((attempts 20))
              (let ((commit (state-field 'observed-commit)))
                (cond ((and (string? commit) (= 40 (string-length commit))) #t)
                      ((zero? attempts) #f)
                      (else (sleep 1) (loop (- attempts 1)))))))

          (test-assert "the state records which repository it describes"
            (string-prefix? "file://" (or (state-field 'url) "")))

          (test-equal "nothing was applied in dry-run mode"
            #f
            (state-field 'applied-commit))

          ;; The reporting service must answer on its own, without the agent
          ;; having to be healthy.
          (test-assert "the health service is running"
            (marionette-eval
             '(begin
                (use-modules (gnu services herd))
                (and (wait-for-service 'gitops-health) #t))
             marionette))

          (test-assert "/health answers with the observed commit"
            (marionette-eval
             '(begin
                (use-modules (web client) (ice-9 receive))
                (let loop ((attempts 30))
                  (define answer
                    (false-if-exception
                     (receive (response body)
                         (http-get "http://127.0.0.1:9902/health"
                                   #:decode-body? #t)
                       body)))
                  (cond ((and (string? answer)
                              (string-contains answer "\"observed\":\"")
                              (string-contains answer "\"uptime\":"))
                         #t)
                        ((zero? attempts) #f)
                        (else (sleep 1) (loop (- attempts 1))))))
             marionette))

          (test-assert "/history is an array"
            (marionette-eval
             '(begin
                (use-modules (web client) (ice-9 receive))
                (receive (response body)
                    (http-get "http://127.0.0.1:9902/history" #:decode-body? #t)
                  (string-prefix? "[" body)))
             marionette))

          (test-end))))

  (gexp->derivation "gitops-agent-test" test))

(define %test-gitops-agent
  (system-test
   (name "gitops-agent")
   (description "Run the guix-gitops agent against a local repository and
check that it observes its head commit without reconfiguring the system.")
   (value (run-gitops-agent-test))))
