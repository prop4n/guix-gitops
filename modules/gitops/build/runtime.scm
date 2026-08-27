;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 prop4n <contact@legrandenzo.fr>

(define-module (gitops build runtime)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:export (%runtime-fields
            validate-runtime-configuration
            read-runtime-configuration
            runtime-ref
            effective-introduction))

(define (string-value? value)
  (and (string? value) (not (string-null? value))))

(define (list-of-strings? value)
  (and (list? value) (every string? value)))

(define (introduction-value? value)
  (match value
    (((? string-value?) . (? string-value?)) #t)
    (_ #f)))

(define %runtime-fields
  ;; Fields a runtime configuration file may set, and the predicate each value
  ;; must satisfy.  Anything else is ignored: this file comes from outside the
  ;; store, so it is treated as untrusted input.
  `((url . ,string-value?)
    (branch . ,string-value?)
    (system-file . ,string-value?)
    (channels-file . ,string-value?)
    (extra-load-path . ,list-of-strings?)
    (introduction . ,introduction-value?)))

(define (relative-file-name? value)
  (and (string-value? value) (not (string-prefix? "/" value))))

(define (acceptable? key value)
  (and (match (assq key %runtime-fields)
         ((_ . predicate) (predicate value))
         (_ #f))
       ;; Names of files inside the configuration repository must stay inside
       ;; it, whoever wrote them.
       (match key
         ((or 'system-file 'channels-file) (relative-file-name? value))
         ('extra-load-path (every relative-file-name? value))
         (_ #t))))

(define* (validate-runtime-configuration alist #:key (warn (const #t)))
  "Return the subset of ALIST that names a known field and carries a value of
the right shape.  Call WARN with a key and a value for every entry rejected."
  (if (list? alist)
      (filter-map (match-lambda
                    (((? symbol? key) . value)
                     (cond ((acceptable? key value) (cons key value))
                           (else (warn key value) #f)))
                    (entry (warn entry #f) #f))
                  alist)
      (begin (warn alist #f) '())))

(define* (read-runtime-configuration file #:key (warn (const #t)))
  "Read a runtime configuration from FILE.  Return the empty list when FILE is
missing, unreadable or malformed, so that a bad file leaves the declared
configuration in force rather than stopping the agent."
  (catch #t
    (lambda ()
      (call-with-input-file file
        (lambda (port)
          (validate-runtime-configuration (read port) #:warn warn))))
    (lambda (key . args)
      (unless (and (eq? key 'system-error)
                   (match args
                     ((_ _ _ (2)) #t)          ;ENOENT: simply absent
                     (_ #f)))
        (warn file (cons key args)))
      '())))

(define (runtime-ref configuration key default)
  "Return the value KEY is bound to in CONFIGURATION, or DEFAULT."
  (match (assq key configuration)
    ((_ . value) value)
    (_ default)))

(define (effective-introduction configuration declared-commit declared-signer)
  "Return the introduction to authenticate the configuration repository with,
as two values.  A runtime configuration may introduce an anchor of trust where
none was declared, but it may never replace or remove one: the fingerprint
baked into the system stays in force, so that a machine which is told to
follow another repository still only accepts commits signed by the key its
owner chose."
  (if declared-commit
      (values declared-commit declared-signer)
      (match (runtime-ref configuration 'introduction #f)
        ((commit . signer) (values commit signer))
        (_ (values #f #f)))))
