;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 prop4n <contact@legrandenzo.fr>

;; Drop a file like this one at the root of your configuration repository and
;; point the agent at it with the 'channels-file' field.  Bumping a commit
;; here is how a machine gets package updates: the agent evaluates your system
;; file with exactly these revisions.

(list (channel
       (name 'guix)
       (url "https://git.savannah.gnu.org/git/guix.git")
       (branch "master")
       (commit "0000000000000000000000000000000000000000")
       (introduction
        (make-channel-introduction
         "9edb3f66fd807b096b48283debdcddccfea34bad"
         (openpgp-fingerprint
          "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA"))))
      (channel
       (name 'guix-gitops)
       (url "https://github.com/prop4n/guix-gitops.git")
       (branch "main")
       (commit "0000000000000000000000000000000000000000")))
