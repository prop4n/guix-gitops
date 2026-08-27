;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 prop4n <contact@legrandenzo.fr>

(define-module (tests runtime)
  #:use-module (gitops build runtime)
  #:use-module (srfi srfi-64))

(define (valid alist)
  (validate-runtime-configuration alist))

(define (call-with-runtime-file content proc)
  (let ((file (string-append (or (getenv "TMPDIR") "/tmp")
                             "/guix-gitops-runtime-"
                             (number->string (getpid))
                             "-"
                             (number->string (random 100000)))))
    (dynamic-wind
      (const #t)
      (lambda ()
        (call-with-output-file file
          (lambda (port) (display content port)))
        (proc file))
      (lambda ()
        (when (file-exists? file) (delete-file file))))))

(test-begin "runtime")

(test-equal "a well-formed configuration passes through"
  '((url . "https://example.org/infra.git")
    (branch . "production")
    (system-file . "systems/web01.scm"))
  (valid '((url . "https://example.org/infra.git")
           (branch . "production")
           (system-file . "systems/web01.scm"))))

(test-equal "unknown keys are dropped"
  '((url . "https://example.org/infra.git"))
  (valid '((url . "https://example.org/infra.git")
           (interval . 5)
           (dry-run? . #f)
           (lock-file . "/tmp/lock"))))

(test-equal "values of the wrong type are dropped"
  '()
  (valid '((url . 42) (branch . #t) (extra-load-path . "modules"))))

(test-equal "empty strings are dropped"
  '()
  (valid '((url . "") (branch . ""))))

;; A runtime file is written by whatever provisioned the machine.  It must not
;; be able to reach outside the configuration repository.
(test-equal "absolute paths inside the repository are refused"
  '()
  (valid '((system-file . "/etc/shadow")
           (channels-file . "/etc/passwd"))))

(test-equal "an absolute entry poisons the whole load path"
  '()
  (valid '((extra-load-path . ("modules" "/gnu/store")))))

(test-equal "a relative load path is accepted"
  '((extra-load-path . ("modules" "lib")))
  (valid '((extra-load-path . ("modules" "lib")))))

(test-equal "garbage is not a configuration"
  '()
  (valid "this is not an alist"))

(test-equal "stray entries are dropped, good ones survive"
  '((branch . "main"))
  (valid '("junk" (branch . "main") 42)))

(test-equal "rejected entries are reported"
  '(url interval)
  (let ((seen '()))
    (validate-runtime-configuration '((url . 42) (branch . "main")
                                      (interval . 5))
                                    #:warn (lambda (key value)
                                             (set! seen (cons key seen))))
    (reverse seen)))

(test-equal "a missing file yields no overrides"
  '()
  (read-runtime-configuration "/nonexistent/guix-gitops/runtime.scm"))

(test-assert "a missing file is not reported as an error"
  (let ((warned #f))
    (read-runtime-configuration "/nonexistent/guix-gitops/runtime.scm"
                                #:warn (lambda _ (set! warned #t)))
    (not warned)))

(test-equal "a file is read and validated"
  '((url . "https://example.org/infra.git") (branch . "main"))
  (call-with-runtime-file
   "((url . \"https://example.org/infra.git\") (branch . \"main\"))"
   read-runtime-configuration))

(test-equal "an unreadable file yields no overrides"
  '()
  (call-with-runtime-file "((url . \"unterminated" read-runtime-configuration))

(test-assert "an unreadable file is reported"
  (let ((warned #f))
    (call-with-runtime-file
     "((url . \"unterminated"
     (lambda (file)
       (read-runtime-configuration file #:warn (lambda _ (set! warned #t)))))
    warned))

(test-equal "runtime-ref falls back to the declared value"
  "main"
  (runtime-ref '((url . "https://example.org/x.git")) 'branch "main"))

(test-equal "runtime-ref prefers the runtime value"
  "production"
  (runtime-ref '((branch . "production")) 'branch "main"))

;;; The trust anchor.

(test-equal "a declared introduction wins over the runtime one"
  '("declared" "declared-signer")
  (call-with-values
      (lambda ()
        (effective-introduction '((introduction . ("runtime" . "runtime-signer")))
                                "declared" "declared-signer"))
    list))

(test-equal "a runtime introduction applies when none was declared"
  '("runtime" "runtime-signer")
  (call-with-values
      (lambda ()
        (effective-introduction '((introduction . ("runtime" . "runtime-signer")))
                                #f #f))
    list))

(test-equal "no introduction anywhere means no authentication"
  '(#f #f)
  (call-with-values
      (lambda () (effective-introduction '() #f #f))
    list))

(test-equal "a malformed runtime introduction is ignored"
  '(#f #f)
  (call-with-values
      (lambda ()
        (effective-introduction (valid '((introduction . "not-a-pair"))) #f #f))
    list))

(test-end "runtime")
