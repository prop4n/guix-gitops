;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 prop4n <contact@legrandenzo.fr>

(define-module (gitops self)
  #:use-module (ice-9 match)
  #:export (gitops-module-name?))

(define (gitops-module-name? name)
  "Return true if NAME (a list of symbols) denotes a guix-gitops module.  Guix
modules are deliberately excluded: they reach the agent through the 'guix'
package added as a G-Expression extension, not as imported source."
  (match name
    (('gitops _ ...) #t)
    (_ #f)))
