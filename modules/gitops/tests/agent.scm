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

          (test-assert "the repository is cached"
            (wait-for-file "/var/cache/guix-gitops/checkout/system.scm"
                           marionette))

          (test-assert "the state file is written"
            (wait-for-file "/var/lib/guix-gitops/state.scm" marionette))

          (test-assert "the observed commit is a commit id"
            (let loop ((attempts 20))
              (let ((commit (state-field 'observed-commit)))
                (cond ((and (string? commit) (= 40 (string-length commit))) #t)
                      ((zero? attempts) #f)
                      (else (sleep 1) (loop (- attempts 1)))))))

          (test-equal "nothing was applied in dry-run mode"
            #f
            (state-field 'applied-commit))

          (test-end))))

  (gexp->derivation "gitops-agent-test" test))

(define %test-gitops-agent
  (system-test
   (name "gitops-agent")
   (description "Run the guix-gitops agent against a local repository and
check that it observes its head commit without reconfiguring the system.")
   (value (run-gitops-agent-test))))
