;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 prop4n <contact@legrandenzo.fr>

(define-module (gitops build git)
  #:use-module (git)
  #:use-module (guix base16)
  #:use-module (guix git)
  #:use-module (guix git-authenticate)
  #:use-module (srfi srfi-14)
  #:export (fetch-configuration
            authenticate-checkout))

(define (fingerprint->bytevector fingerprint)
  (base16-string->bytevector
   (string-downcase (string-filter char-set:graphic fingerprint))))

(define* (fetch-configuration url #:key branch cache-directory starting-commit
                              (log-port (current-output-port)))
  "Update the checkout of BRANCH of URL under CACHE-DIRECTORY.  Return three
values: the checkout directory, the commit it was reset to, and the relation
of STARTING-COMMIT to that commit.  Each URL gets its own subdirectory, so
that pointing the agent at another repository cannot make it fetch the old one
through a stale remote."
  (update-cached-checkout url
                          #:ref `(branch . ,branch)
                          #:cache-directory
                          (url-cache-directory url cache-directory)
                          #:starting-commit starting-commit
                          #:log-port log-port))

(define* (authenticate-checkout directory introduction-commit signer
                                #:key (keyring-reference "keyring"))
  "Authenticate the commit history of the repository at DIRECTORY, up to its
current head, starting from INTRODUCTION-COMMIT which must be signed by the
OpenPGP key whose fingerprint is SIGNER.  Raise an exception when a commit is
unsigned or signed by an unauthorized key."
  (with-repository directory repository
    (authenticate-repository repository
                             (string->oid introduction-commit)
                             (fingerprint->bytevector signer)
                             #:keyring-reference
                             (string-append "origin/" keyring-reference))))
