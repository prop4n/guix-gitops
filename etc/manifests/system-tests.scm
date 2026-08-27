;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2016, 2018-2020, 2022 Ludovic Courtès <ludo@gnu.org>
;;; Copyright © 2026 prop4n <contact@legrandenzo.fr>

;; Adapted from the system tests manifest of Guix proper.

(use-modules (gitops tests)
             ((gnu tests) #:select (system-test system-test-name
                                                system-test-value))
             (gnu packages package-management)
             (guix monads)
             (guix profiles)
             (guix store)
             ((guix git-download) #:select (git-predicate))
             ((guix utils) #:select (current-source-directory))
             (git)
             (ice-9 match))

(define (source-commit directory)
  (let ((repository #f))
    (catch 'git-error
      (lambda ()
        (set! repository (repository-open directory))
        (let* ((head (repository-head repository))
               (commit (oid->string (reference-target head))))
          (repository-close! repository)
          commit))
      (lambda _
        (when repository
          (repository-close! repository))
        #f))))

(define (selected-tests)
  ;; Honor the 'TESTS' environment variable so that one can select a subset of
  ;; tests to run:
  ;;
  ;;   TESTS=gitops-agent guix build -m etc/manifests/system-tests.scm
  (match (getenv "TESTS")
    (#f (all-system-tests))
    ((= string-tokenize (names ...))
     (filter (lambda (test) (member (system-test-name test) names))
             (all-system-tests)))))

(define (tests-for-current-guix-gitops source commit)
  (let ((guix (channel-source->package source #:commit commit)))
    (map (lambda (test)
           (system-test
            (inherit test)
            (value (store-parameterize ((current-guix-package guix))
                     (system-test-value test)))))
         (selected-tests))))

(define (system-test->manifest-entry test)
  (manifest-entry
    (name (string-append "test." (system-test-name test)))
    (version "0")
    (item test)))

(define (system-test-manifest)
  (define source
    (string-append (current-source-directory) "/../.."))

  (define commit
    (source-commit source))

  (let* ((source (local-file source
                             (if commit
                                 (string-append "guix-gitops-"
                                                (string-take commit 7))
                                 "guix-gitops-source")
                             #:recursive? #t
                             #:select? (or (git-predicate source) (const #t))))
         (tests (tests-for-current-guix-gitops source commit)))
    (format (current-error-port) "Selected ~a system tests...~%" (length tests))
    (manifest (map system-test->manifest-entry tests))))

(system-test-manifest)
