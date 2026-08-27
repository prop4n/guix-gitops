;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2026 prop4n <contact@legrandenzo.fr>

(use-modules (gitops services agent)
             (gnu)
             (gnu services networking))

(operating-system
  (host-name "gitops-example")
  (timezone "Etc/UTC")
  (locale "en_US.utf8")

  (bootloader
   (bootloader-configuration
    (bootloader grub-bootloader)
    (targets '("/dev/vda"))))

  (file-systems
   (cons (file-system
           (device (file-system-label "root"))
           (mount-point "/")
           (type "ext4"))
         %base-file-systems))

  (services
   (cons* (service dhcpcd-service-type)
          (service gitops-agent-service-type
                   (gitops-agent-configuration
                    (url "https://github.com/prop4n/infrastructure.git")
                    (branch "main")
                    (system-file "systems/gitops-example.scm")
                    (channels-file "channels.scm")
                    (interval 600)
                    (introduction
                     (gitops-introduction
                      (commit "0000000000000000000000000000000000000000")
                      (signer "AAAA BBBB CCCC DDDD EEEE  FFFF 0000 1111 2222 3333")))))
          %base-services)))
