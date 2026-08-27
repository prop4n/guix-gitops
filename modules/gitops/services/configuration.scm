;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 prop4n <contact@legrandenzo.fr>

(define-module (gitops services configuration)
  #:use-module (guix diagnostics)
  #:use-module (guix gexp)
  #:use-module (guix i18n)
  #:use-module (srfi srfi-35)
  #:export (positive-integer?
            gexp-or-string?
            sanitize-url
            sanitize-relative-file-name))

(define (positive-integer? value)
  (and (integer? value) (positive? value)))

(define (gexp-or-string? value)
  (or (gexp? value) (file-like? value) (string? value)))

(define (sanitize-url value)
  (cond ((and (string? value) (not (string-null? value))) value)
        ((or (gexp? value) (file-like? value)) value)
        (else
         (raise
          (formatted-message
           (G_ "the 'url' field requires a non-empty Git URL, a gexp or a \
file-like object but ~s was found")
           value)))))

(define (sanitize-relative-file-name value)
  (if (and (string? value)
           (not (string-null? value))
           (not (string-prefix? "/" value)))
      value
      (raise
       (formatted-message
        (G_ "file names inside the configuration repository must be relative \
but ~s was found")
        value))))
