;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 prop4n <contact@legrandenzo.fr>

;; A machine that is told which configuration to follow after it boots, rather
;; than being built for one.  Build the image once
;;
;;   guix system image -t qcow2 --image-size=20G -L modules examples/vm-generic.scm
;;
;; then give each machine a thin copy of it and write, inside that machine,
;;
;;   /etc/guix-gitops/runtime.scm
;;   ((system-file . "systems/web01.scm"))
;;
;; The agent reads that file on its next cycle.  Note that the introduction
;; stays declared here: a machine may be pointed at another repository, but
;; every commit it applies must still be signed by the key below.

(use-modules (gnu)
             (gnu system image)
             (gitops services agent))
(use-service-modules base networking ssh)

(operating-system
  (host-name "gitops-node")
  (timezone "Etc/UTC")
  (locale "en_US.utf8")

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
          (service openssh-service-type
                   (openssh-configuration
                    (permit-root-login 'prohibit-password)
                    (password-authentication? #f)))
          (service gitops-agent-service-type
                   (gitops-agent-configuration
                    (url "https://github.com/prop4n/guix-gitops.git")
                    (branch "main")
                    (system-file "examples/vm-generic.scm")
                    (extra-load-path '("modules"))
                    (runtime-config-file "/etc/guix-gitops/runtime.scm")
                    (health (gitops-health-configuration (port 9902)))
                    (interval 300)
                    (log-file "/dev/console")
                    (introduction
                     (gitops-introduction
                      (commit "09fc5082f184bdecde93dfa742bedf5ff8c587ac")
                      (signer
                       "90C8 D92A 6D65 856C 0F84  EAE2 7E1F FB95 9BB3 3640")))))
          %base-services)))
