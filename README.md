# guix-gitops

A pull-based GitOps agent for Guix System, distributed as a Guix channel.

Each machine watches a Git repository, works out which `operating-system` it
should be running, and reconfigures itself when that declaration changes.
There is no central server pushing anything: the machines pull. Your Git
repository is the source of truth, and the fleet converges towards it.

## Why

Deploying a Guix configuration to several machines usually means logging into
each of them and running `guix system reconfigure`, or driving them from a
workstation with `guix deploy`. Both need something to reach *into* the
machine. This reverses the direction: push a commit, and every machine picks
it up on its own schedule.

Everything the agent does, it does in Scheme, using Guix's own libraries:
`(guix git)` to fetch, `(guix git-authenticate)` to verify signatures,
`(guix inferior)` to evaluate your configuration against pinned channels, and
`(guix scripts system)` to reconfigure.

## Adding the channel

Add this to `~/.config/guix/channels.scm`:

```scheme
(cons (channel
       (name 'guix-gitops)
       (url "https://github.com/prop4n/guix-gitops.git")
       (branch "main")
       (introduction
        (make-channel-introduction
         "09fc5082f184bdecde93dfa742bedf5ff8c587ac"
         (openpgp-fingerprint
          "90C8 D92A 6D65 856C 0F84  EAE2 7E1F FB95 9BB3 3640"))))
      %default-channels)
```

Then run `guix pull`. The introduction makes Guix verify that every commit
since `09fc5082` is signed by an authorized key before running any of this
code — worth keeping, given what this channel does.

## Using the service

```scheme
(use-modules (gitops services agent)
             (gnu))

(operating-system
  ;; ...
  (services
   (cons (service gitops-agent-service-type
                  (gitops-agent-configuration
                   (url "https://github.com/you/infrastructure.git")
                   (branch "main")
                   (system-file "systems/tower.scm")
                   (channels-file "channels.scm")
                   (interval 600)))
         %base-services)))
```

Reconfigure once by hand to install the agent. From then on the machine
follows the repository.

`herd restart gitops-agent` forces an immediate check; the agent always runs a
cycle at startup.

## What the repository looks like

The repository the agent watches is a plain Git repository — it is *not* a
channel. It holds at least the file named by `system-file`, which must
evaluate to an `operating-system` record:

```
infrastructure/
├── channels.scm          ; optional, see below
└── systems/
    ├── tower.scm         ; evaluates to an <operating-system>
    └── laptop.scm
```

Each machine points at its own `system-file`, so one repository can drive a
whole fleet.

## Pinning channels

The agent is a program built from a particular Guix revision. Left alone, it
would evaluate your configuration with *that* revision forever, and your
machines would never see a package update.

Set `channels-file` to fix this. It names a file in your repository holding a
list of channels, exactly like `~/.config/guix/channels.scm`:

```scheme
(list (channel
       (name 'guix)
       (url "https://git.savannah.gnu.org/git/guix.git")
       (commit "8fbc32e2c72e0fc31eb0e1f2b0a5b0e0e0e0e0e0"))
      (channel
       (name 'guix-gitops)
       (url "https://github.com/prop4n/guix-gitops.git")
       (commit "a91c4d2c72e0fc31eb0e1f2b0a5b0e0e0e0e0e0e")))
```

The agent then builds an inferior for those channels and evaluates your
system file inside it — the same thing `guix time-machine -C channels.scm --
system reconfigure` does. Updating a machine becomes a commit that bumps a
revision, which is also how the agent updates itself.

See `examples/channels.scm`.

## Authenticating the repository

The agent reconfigures the system, so whoever can write to the repository can
change what the machine runs. Set `introduction` to require signed commits:

```scheme
(gitops-agent-configuration
 (url "https://github.com/you/infrastructure.git")
 (introduction
  (gitops-introduction
   (commit "5b1a0e9c0d0f2a3b4c5d6e7f8a9b0c1d2e3f4a5b")
   (signer "AAAA BBBB CCCC DDDD EEEE  FFFF 0000 1111 2222 3333"))))
```

`commit` is the first commit of the repository you signed, and `signer` is the
fingerprint of the key that signed it. The repository must also carry a
`keyring` branch containing the `.key` files of authorized signers, and a
`.guix-authorizations` file listing them — the same convention Guix channels
use, implemented by the same code. Authentication runs *before* anything in
the repository is evaluated. See `doc/TUTORIAL.md`.

## What happens when a configuration is broken

The agent never retries a broken commit in a loop:

1. The failing commit is recorded in the state file.
2. It is retried with an exponential backoff — `interval`, then twice that,
   and so on, capped at `max-backoff`.
3. After `max-attempts` failures the agent gives up on that commit and waits
   for a different one.

Meanwhile the machine keeps running its current generation, and the previous
generation stays bootable, as always with Guix. Nothing is rolled back
automatically.

Two reconfigurations can never overlap: the agent holds an exclusive lock and
runs each reconfiguration in a child process, one cycle at a time.

## Updating the agent itself

When a commit changes the agent's own configuration — or bumps the
`guix-gitops` revision in `channels.scm` — the reconfiguration installs the new
definition, but the *running* agent keeps executing its old code. This is not
an oversight: `guix system reconfigure` never restarts a service whose
definition changed, which is exactly what you want from a process that is in
the middle of reconfiguring the system.

The new agent takes over at the next reboot, or immediately if you run:

```
sudo herd restart gitops-agent
```

Until then the old agent keeps converging the machine, so nothing is stuck.

## Trying it safely

Set `dry-run?` to `#t` for the first deployment. The agent fetches,
authenticates and decides, logging what it *would* do, and never touches the
system. Watch `/var/log/guix-gitops.log`, then turn it off.

## Seeing it work in a VM

`examples/vm.scm` is a bootable machine that follows *this* repository:

```
guix system image -t qcow2 --image-size=20G -L modules examples/vm.scm
qemu-system-x86_64 -enable-kvm -m 4096 -smp 4 -nographic \
  -drive file=vm.qcow2,if=virtio,format=qcow2 \
  -netdev user,id=net0 -device virtio-net-pci,netdev=net0
```

The agent inside authenticates this repository, evaluates `examples/vm.scm`
and reconfigures the machine to match it. Push a commit that changes the VM's
`host-name` and watch it converge on the serial console. `extra-load-path`
points at this repository's own `modules/`, which is what lets the VM's Guix
resolve `(gitops services agent)` without pulling the channel.

## Configuration reference

| Field | Default | Meaning |
| --- | --- | --- |
| `url` | *required* | Git URL of the configuration repository |
| `branch` | `"main"` | Branch to track |
| `system-file` | `"system.scm"` | Path in the repository to the `operating-system` declaration |
| `channels-file` | unset | Path in the repository to a list of channels |
| `interval` | `900` | Seconds between checks |
| `introduction` | unset | `gitops-introduction` enabling commit authentication |
| `keyring-reference` | `"keyring"` | Branch holding the OpenPGP keyring |
| `checkout-directory` | `"/var/cache/guix-gitops"` | Where the repository is cached |
| `state-file` | `"/var/lib/guix-gitops/state.scm"` | Persisted agent state |
| `lock-file` | `"/var/lib/guix-gitops/lock"` | Mutual exclusion |
| `log-file` | `"/var/log/guix-gitops.log"` | Log destination |
| `max-attempts` | `3` | Attempts on a failing commit before giving up |
| `max-backoff` | `3600` | Cap on the retry delay, in seconds |
| `allow-downgrades?` | `#f` | Permit reconfiguring to older channels |
| `dry-run?` | `#f` | Decide and log, never reconfigure |
| `extra-load-path` | `'()` | Repository directories added to the Guile load path |

## Inspecting the agent

`/var/log/guix-gitops.log` records every cycle. The state file is a readable
alist:

```scheme
((applied-time . 1787818573)
 (applied-commit . "f94ff849dd6bf7627f41abf88cfe4166e5c18643")
 (observed-time . 1787818573)
 (observed-commit . "f94ff849dd6bf7627f41abf88cfe4166e5c18643")
 (version . 1))
```

## Hacking

The fast checks need nothing but Guile — the decision logic in
`(gitops build state)` has no Guix dependency, which is what makes it easy to
test:

```
guile etc/check-syntax.scm .                    # every file parses
guile -L modules -L . tests/run-tests.scm       # unit tests
```

The rest needs Guix, and is slow enough to be worth running deliberately:

```
guix build -L modules -e '((@ (gitops services agent) gitops-agent-program)
                           ((@ (gitops services agent) gitops-agent-configuration)
                            (url "https://example.org/infrastructure.git")))'
guix system build -d -L modules examples/system.scm       # the service composes
guix build -L modules -m etc/manifests/system-tests.scm   # marionette system tests
```

CI runs only the first pair on every push. The Guix jobs live in a separate
workflow you trigger by hand.

## License

GPL-3.0-or-later.
