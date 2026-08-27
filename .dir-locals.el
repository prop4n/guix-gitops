;;; Directory Local Variables         -*- no-byte-compile: t -*-

((scheme-mode
  . ((indent-tabs-mode . nil)
     (eval . (put 'match-record 'scheme-indent-function 2))
     (eval . (put 'with-repository 'scheme-indent-function 2))
     (eval . (put 'call-with-lock 'scheme-indent-function 1))
     (eval . (put 'modify-services 'scheme-indent-function 1)))))
