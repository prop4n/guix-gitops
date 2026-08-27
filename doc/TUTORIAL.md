# Tutorial: from an empty repository to a self-converging machine

This walks through setting up one machine end to end, including signed
commits. Every step is safe to abandon halfway.

## 1. Create the configuration repository

The repository the agent watches is an ordinary Git repository. Start with the
configuration the machine already runs:

```
mkdir infrastructure && cd infrastructure
git init --initial-branch=main
mkdir systems
cp /run/current-system/configuration.scm systems/tower.scm
git add . && git commit -m "Initial configuration"
```

Push it somewhere the machine can reach.

## 2. Add the channel

In `~/.config/guix/channels.scm`:

```scheme
(cons (channel
       (name 'guix-gitops)
       (url "https://github.com/prop4n/guix-gitops.git")
       (branch "main"))
      %default-channels)
```

```
guix pull
```

## 3. Declare the service in dry-run mode

Add this to `systems/tower.scm`, and note that the machine will end up
managing the very file that declares it:

```scheme
(use-modules (gitops services agent))

;; inside your operating-system's services field:
(service gitops-agent-service-type
         (gitops-agent-configuration
          (url "https://github.com/you/infrastructure.git")
          (system-file "systems/tower.scm")
          (interval 300)
          (dry-run? #t)))
```

Commit, push, then install the agent by hand once:

```
sudo guix system reconfigure systems/tower.scm
```

## 4. Watch it decide

```
sudo tail -f /var/log/guix-gitops.log
```

You should see the agent report the branch head and say it would apply it.
Nothing has been reconfigured. Push another commit and watch the observed
commit change.

When you are satisfied, drop `(dry-run? #t)`, commit, push — and reconfigure
by hand one last time to apply the change. From then on the machine follows
the repository on its own.

## 5. Pin your channels

Record the revisions your machine should build against:

```
guix describe -f channels > channels.scm
git add channels.scm && git commit -m "Pin channels"
```

Point the agent at it:

```scheme
(channels-file "channels.scm")
```

From now on, upgrading the machine means regenerating `channels.scm` and
pushing. That includes upgrading guix-gitops itself — though the new agent
only takes over after a reboot or a `herd restart gitops-agent`, since Guix
never restarts a service whose definition just changed.

## 6. Sign your commits

Without this, anyone who can write to the repository can change what your
machine runs.

Create a key if you do not have one:

```
gpg --quick-generate-key "you <you@example.org>" ed25519 sign,cert 0
gpg --fingerprint
```

Tell Git to use it:

```
git config user.signingkey <FINGERPRINT>
git config commit.gpgsign true
```

Publish your public key on a `keyring` branch — the same convention Guix
channels use:

```
git checkout --orphan keyring
git rm -rf .
gpg --export --armor <FINGERPRINT> > $(gpg --fingerprint --with-colons \
    <FINGERPRINT> | awk -F: '/^fpr:/ {print $10; exit}').key
git add *.key && git commit -m "Add keyring"
git checkout main
```

List authorized signers in `.guix-authorizations` on `main`:

```scheme
(authorizations
 (version 0)
 (("AAAA BBBB CCCC DDDD EEEE  FFFF 0000 1111 2222 3333"
   (name "you"))))
```

Commit that — signed. This commit is your *introduction*: note its hash.

```scheme
(introduction
 (gitops-introduction
  (commit "<hash of the signed commit>")
  (signer "AAAA BBBB CCCC DDDD EEEE  FFFF 0000 1111 2222 3333")))
```

From that commit onwards, the agent refuses to evaluate anything in the
repository unless the whole history since the introduction is signed by an
authorized key.

## 7. Add more machines

Give each machine its own file under `systems/`, and its own `system-file` in
its agent configuration. One repository, one branch, many machines.

## 8. Building one image for many machines

Steps 1 to 7 bake the repository into the system, which means one image per
repository. If you provision machines from a single image — a Proxmox
template, a cloud image — declare a runtime configuration file instead:

```scheme
(service gitops-agent-service-type
         (gitops-agent-configuration
          (url "https://github.com/you/infrastructure.git")
          (runtime-config-file "/etc/guix-gitops/runtime.scm")
          (introduction
           (gitops-introduction
            (commit "<hash>")
            (signer "AAAA BBBB ...")))))
```

Then, on each machine, write what makes it that machine:

```scheme
;; /etc/guix-gitops/runtime.scm
((system-file . "systems/web01.scm"))
```

The agent picks it up on the next cycle. Nothing else changes: same image,
same signing key, different file.

Anything can write that file — your hands, a provisioning script, a reader for
whatever metadata your host exposes at boot. Keep the `introduction` in the
system declaration rather than in the file: the machine can then be pointed at
any of *your* repositories, but never at someone else's.

To move a machine to a different repository, edit the file. The next cycle
follows the new one, and the agent forgets what it had applied from the old
one. No restart, no reconfiguration.

## Recovering from a bad commit

Push a fixed commit. The agent gives up on a failing commit after
`max-attempts` tries and waits for a new one, so a fix is picked up on the
next cycle. The machine has been running its previous generation the whole
time.

If the agent itself is broken — the one case Git cannot fix — reconfigure by
hand from a known-good file, exactly as you did in step 3.
