;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 prop4n <contact@legrandenzo.fr>

;; A bootable demonstration: a virtual machine that keeps itself in sync with
;; this very repository.  Build it with
;;
;;   guix system image -t qcow2 --image-size=20G -L modules examples/vm.scm
;;
;; then boot the result under QEMU.  The agent inside authenticates this
;; repository, evaluates this file, and reconfigures the machine to match it.

(use-modules (gnu)
             (gnu system image)
             (gitops services agent))
(use-service-modules base networking)
(use-package-modules python)

(operating-system
  (host-name "gitops-converged")
  (timezone "Etc/UTC")
  (locale "en_US.utf8")

  (packages (cons python-3.11 %base-packages))

  (bootloader
   (bootloader-configuration
    (bootloader grub-bootloader)
    (targets '("/dev/vda"))
    (terminal-outputs '(console))))

  (kernel-arguments '("console=ttyS0,115200"))

  (file-systems
   (cons (file-system
           (mount-point "/")
           (device (file-system-label root-label))
           (type "ext4"))
         %base-file-systems))

  (services
   (cons* (service agetty-service-type
                   (agetty-configuration
                    (tty "ttyS0")
                    (baud-rate "115200")
                    (term "vt100")
                    (auto-login "root")))
          (service dhcpcd-service-type)
          (service gitops-agent-service-type
                   (gitops-agent-configuration
                    (url "https://github.com/prop4n/guix-gitops.git")
                    (branch "main")
                    (system-file "examples/vm.scm")
                    (extra-load-path '("modules"))
                    (interval 60)
                    (log-file "/dev/console")
                    (introduction
                     (gitops-introduction
                      (commit "09fc5082f184bdecde93dfa742bedf5ff8c587ac")
                      (signer
                       "90C8 D92A 6D65 856C 0F84  EAE2 7E1F FB95 9BB3 3640")))))
          %base-services)))
