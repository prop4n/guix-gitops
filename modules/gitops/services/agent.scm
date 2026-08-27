;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 prop4n <contact@legrandenzo.fr>

(define-module (gitops services agent)
  #:use-module (gitops self)
  #:use-module (gitops services configuration)
  #:use-module (gnu packages guile)
  #:use-module (gnu packages package-management)
  #:use-module (gnu packages version-control)
  #:use-module (gnu services)
  #:use-module (gnu services configuration)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix modules)
  #:use-module (guix packages)
  #:use-module (guix records)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:export (gitops-introduction
            gitops-introduction?
            gitops-introduction-commit
            gitops-introduction-signer

            gitops-agent-configuration
            gitops-agent-configuration?
            gitops-agent-configuration-url
            gitops-agent-configuration-branch
            gitops-agent-configuration-system-file
            gitops-agent-configuration-channels-file
            gitops-agent-configuration-interval
            gitops-agent-configuration-introduction
            gitops-agent-configuration-keyring-reference
            gitops-agent-configuration-checkout-directory
            gitops-agent-configuration-state-file
            gitops-agent-configuration-lock-file
            gitops-agent-configuration-runtime-config-file
            gitops-agent-configuration-journal-file
            gitops-agent-configuration-journal-length
            gitops-agent-configuration-health
            gitops-agent-configuration-log-file

            gitops-health-configuration
            gitops-health-configuration?
            gitops-health-configuration-host
            gitops-health-configuration-port
            gitops-agent-configuration-max-attempts
            gitops-agent-configuration-max-backoff
            gitops-agent-configuration-allow-downgrades?
            gitops-agent-configuration-dry-run?
            gitops-agent-configuration-extra-load-path

            gitops-agent-program
            gitops-health-program
            gitops-agent-shepherd-services
            gitops-agent-service-type))

(define-record-type* <gitops-introduction>
  gitops-introduction make-gitops-introduction
  gitops-introduction?
  (commit gitops-introduction-commit)
  (signer gitops-introduction-signer))

(define-configuration/no-serialization gitops-health-configuration
  (host
   (string "127.0.0.1")
   "The address the health endpoint listens on.  It reports which repository
and commit the machine follows, so it is bound to the loopback interface until
you decide otherwise.")
  (port
   (positive-integer 9902)
   "The port the health endpoint listens on."))

(define-maybe/no-serialization gitops-introduction)
(define-maybe/no-serialization gitops-health-configuration)
(define-maybe/no-serialization string)

(define-configuration/no-serialization gitops-agent-configuration
  (url
   (gexp-or-string)
   "The URL of the Git repository holding the system configuration."
   (sanitizer sanitize-url))
  (branch
   (string "main")
   "The branch of @code{url} to track.")
  (system-file
   (string "system.scm")
   "The name, relative to the root of the repository, of the file evaluating
to the @code{operating-system} record this machine must converge to."
   (sanitizer sanitize-relative-file-name))
  (channels-file
   (maybe-string)
   "The name, relative to the root of the repository, of a file evaluating to
a list of channels.  When set, @code{system-file} is evaluated by an inferior
pinned to those channels, so that both the package set and the agent itself
are driven by Git.  When unset, the Guix revision this agent was built with is
used instead.")
  (runtime-config-file
   (maybe-string)
   "The name of a file, read at the start of every cycle, holding an
association list that overrides @code{url}, @code{branch}, @code{system-file},
@code{channels-file} and @code{extra-load-path}.  It lets one system image
serve many machines: write the file by hand, or have something else write it
at boot from whatever your host tells you.  A missing or malformed file leaves
the fields declared here in force.  When @code{introduction} is set here, the
file may not weaken it; when it is not, the file may supply one.")
  (interval
   (positive-integer 900)
   "The number of seconds between two checks of the repository.")
  (introduction
   (maybe-gitops-introduction)
   "A @code{gitops-introduction} record.  When set, the commit history of the
repository is authenticated before anything it contains is evaluated.")
  (keyring-reference
   (string "keyring")
   "The name of the branch holding the OpenPGP keyring used to authenticate
commits.  Ignored when @code{introduction} is unset.")
  (checkout-directory
   (string "/var/cache/guix-gitops")
   "The directory where the repository is cached.")
  (state-file
   (string "/var/lib/guix-gitops/state.scm")
   "The file where the agent records which commits it observed, applied and
failed to apply.")
  (lock-file
   (string "/var/lib/guix-gitops/lock")
   "The file used to guarantee that a single agent runs at a time.")
  (journal-file
   (string "/var/lib/guix-gitops/journal.scm")
   "The file recording which commits were applied, rejected or failed, and
which system generation each produced.  Cross-referenced with @command{guix
system list-generations}, it tells you what a machine has been running and
what it can be rolled back to.")
  (journal-length
   (positive-integer 50)
   "How many entries the journal keeps.  It is bounded on purpose: it lives on
machines nobody watches.")
  (health
   (maybe-gitops-health-configuration)
   "A @code{gitops-health-configuration} record.  When set, a second service
serves @code{/health} and @code{/history} over HTTP.  It runs in a process of
its own and reads the same files as the agent, so it still answers when the
agent is wedged or gone -- which is when the answer matters most.")
  (log-file
   (string "/var/log/guix-gitops.log")
   "The file the agent logs to.")
  (max-attempts
   (positive-integer 3)
   "How many times a failing commit is retried before the agent gives up on it
and waits for a new one.")
  (max-backoff
   (positive-integer 3600)
   "The upper bound, in seconds, of the delay between two attempts at the same
failing commit.")
  (allow-downgrades?
   (boolean #f)
   "Whether to reconfigure even when the target channels are older than the
ones the running system was built from.")
  (dry-run?
   (boolean #f)
   "When true, fetch, authenticate and decide, but never reconfigure the
system.")
  (extra-load-path
   (list-of-strings '())
   "Directories, relative to the root of the repository, added to the Guile
load path when evaluating @code{system-file}."))

(define (input-packages inputs)
  (filter-map (match-lambda
                ((? package? package) package)
                ((_ (? package? package) . _) package)
                (_ #f))
              inputs))

(define (guix-extensions)
  "Return GUIX and every Guile library it propagates, so that (guix git),
(guix inferior) and (guix scripts system) resolve both when the agent is
compiled and when it runs."
  (cons guix (input-packages (package-transitive-propagated-inputs guix))))

(define (guix-guile)
  "Return the Guile GUIX itself is built with.  Compiling the agent with any
other Guile would produce bytecode incompatible with the '.go' files shipped
by GUIX, forcing it to interpret the whole of Guix at every start."
  (or (find (lambda (package) (string=? "guile" (package-name package)))
            (append (input-packages (package-native-inputs guix))
                    (input-packages (package-inputs guix))))
      guile-3.0-latest))

(define (gitops-agent-program config)
  (match-record config <gitops-agent-configuration>
                (url branch system-file channels-file interval introduction
                 keyring-reference checkout-directory state-file lock-file
                 runtime-config-file journal-file journal-length max-attempts
                 max-backoff allow-downgrades? dry-run? extra-load-path)
    (let* ((channels-file (and (maybe-value-set? channels-file) channels-file))
           (introduction (and (maybe-value-set? introduction) introduction))
           (runtime-config-file (and (maybe-value-set? runtime-config-file)
                                     runtime-config-file))
           (entry-point
            (with-extensions (guix-extensions)
              (with-imported-modules (source-module-closure
                                      '((gitops build agent))
                                      #:select? gitops-module-name?)
                #~(begin
                    (use-modules (gitops build agent))
                    (run-agent #:url #$url
                               #:branch #$branch
                               #:system-file #$system-file
                               #:channels-file #$channels-file
                               #:interval #$interval
                               #:checkout-directory #$checkout-directory
                               #:state-file #$state-file
                               #:lock-file #$lock-file
                               #:runtime-config-file #$runtime-config-file
                               #:journal-file #$journal-file
                               #:journal-length #$journal-length
                               #:introduction-commit
                               #$(and introduction
                                      (gitops-introduction-commit introduction))
                               #:signer
                               #$(and introduction
                                      (gitops-introduction-signer introduction))
                               #:keyring-reference #$keyring-reference
                               #:max-attempts #$max-attempts
                               #:max-backoff #$max-backoff
                               #:allow-downgrades? #$allow-downgrades?
                               #:dry-run? #$dry-run?
                               #:extra-load-path '#$extra-load-path))))))
      (program-file "gitops-agent" entry-point #:guile (guix-guile)))))

(define (gitops-health-program config)
  (match-record config <gitops-agent-configuration>
                (state-file journal-file health)
    (let ((entry-point
           (with-extensions (guix-extensions)
             (with-imported-modules (source-module-closure
                                     '((gitops build server))
                                     #:select? gitops-module-name?)
               #~(begin
                   (use-modules (gitops build server))
                   (run-health-server
                    #:host #$(gitops-health-configuration-host health)
                    #:port #$(gitops-health-configuration-port health)
                    #:state-file #$state-file
                    #:journal-file #$journal-file))))))
      (program-file "gitops-health" entry-point #:guile (guix-guile)))))

(define (gitops-agent-shepherd-services config)
  (match-record config <gitops-agent-configuration> (log-file health)
    (cons (shepherd-service
           (documentation "Converge the system towards a Git repository.")
           (provision '(gitops-agent))
           (requirement '(user-processes networking guix-daemon))
           (start #~(make-forkexec-constructor
                     (list #$(gitops-agent-program config))
                     #:log-file #$log-file
                     #:environment-variables
                     (list "HOME=/root"
                           "SSL_CERT_DIR=/etc/ssl/certs"
                           "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
                           "GIT_SSL_CAINFO=/etc/ssl/certs/ca-certificates.crt"
                           (string-append "PATH=" #$(file-append git "/bin")))))
           (stop #~(make-kill-destructor))
           (respawn? #t))
          (if (maybe-value-set? health)
              ;; Deliberately not required by 'gitops-agent': reporting must
              ;; survive the thing it reports on.
              (list (shepherd-service
                     (documentation "Report what the guix-gitops agent is doing.")
                     (provision '(gitops-health))
                     (requirement '(user-processes networking))
                     (start #~(make-forkexec-constructor
                               (list #$(gitops-health-program config))
                               #:log-file #$log-file))
                     (stop #~(make-kill-destructor))
                     (respawn? #t)))
              '()))))

(define (gitops-agent-activation config)
  (match-record config <gitops-agent-configuration>
                (checkout-directory state-file lock-file journal-file
                 runtime-config-file)
    #~(for-each (lambda (directory)
                  (mkdir-p directory)
                  (chmod directory #o700))
                (list #$checkout-directory
                      (dirname #$state-file)
                      (dirname #$lock-file)
                      (dirname #$journal-file)
                      #$@(if (maybe-value-set? runtime-config-file)
                             (list #~(dirname #$runtime-config-file))
                             '())))))

(define gitops-agent-service-type
  (service-type
   (name 'gitops-agent)
   (extensions
    (list (service-extension shepherd-root-service-type
                             gitops-agent-shepherd-services)
          (service-extension activation-service-type
                             gitops-agent-activation)))
   (description "Run the guix-gitops agent, which periodically fetches a Git
repository and reconfigures the system to match the @code{operating-system} it
declares.")))
