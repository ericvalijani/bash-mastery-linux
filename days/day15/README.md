# Day 15 — Ansible roles: your hardening baseline

**Phase:** Hardening and configuration management
**Runs on:** `control` -> `node1` + `node2`
**Time:** about two hours

Day 14 put every task in one playbook. That works until the playbook is four
hundred lines and two people are editing it. Today you take Days 11, 12 and 13
— firewalld, sshd, fail2ban, SELinux — and turn them into a role: a directory
with a layout everybody already knows, variables a user can override without
editing your code, and handlers that reload the right daemon once.

Then you point it at `node2`, a machine you have never logged into, and it
comes out matching `node1`.

The part worth your attention is not the YAML. It is that a role has four
places a variable can come from, three of them beat your defaults, and a role
can report `changed=0` on a host it never touched.

## What you will work with

- `ansible-galaxy init` and the role layout every role on earth uses:
  `defaults/`, `vars/`, `tasks/`, `handlers/`, `templates/`, `files/`, `meta/`
- `defaults/main.yml` as the role's public API — the lowest precedence in
  Ansible, and therefore the only safe place for a value someone may change
- `vars/main.yml` for the role's internals — near the top of the precedence
  list, so inventory cannot quietly repoint a path your handlers depend on
- `import_tasks` with tags, so one role can be run one area at a time
- handlers, and the two cases where they do not fire: a failed play, and
  `--check`
- `ansible-vault` with a password file, `group_vars/lab/` as a directory, and
  the `vault_` naming convention that makes secrets greppable
- `--tags`, `--skip-tags`, `--limit`, `--list-tasks`, `--list-tags`
- drift: `--check --diff` against a host somebody edited by hand
- `ansible-inventory --host`, the only honest answer to "which value won"

No collections. `ansible-core` ships none, so there is no `ansible.posix`
`selinux` module and no `community.general` `firewalld` module here. SELinux is
`lineinfile` plus `getenforce`/`setenforce` with a `when:`; firewalld is
`firewall-cmd --query`/`--add` with a reload handler. Slightly longer, and you
see exactly what a module does: read the state, decide, write, report.

## Three VMs, and the memory

Today is the only day that needs all three, and it is the peak of the course:

| VM | Memory | Why |
|---|---|---|
| `control` | 1536 MB | runs Ansible, nothing else |
| `node1` | 2048 MB | already hardened by hand on Days 11–13 |
| `node2` | 2048 MB | clean host — the one the role has to fix |

About **5.5 GB** in total. Nothing in this lab is below 1536 MB, which is the
minimum Rocky 9 recommends and the number `virt-install` warns about. Below it,
`dnf` gets killed by the OOM killer and prints a bare `Killed` with no
explanation.

On an 8 GB laptop, close the browser first. If it is tight, bring `node1` up
after the role has been applied to `node2` — `--limit` exists for exactly this.

## Scripts

| Script | What it does |
|---|---|
| `scripts/setup.sh [node1-addr] [node2-addr]` | checks ssh to both nodes, writes the inventory, the vault, the role and `hardening.yml`, then runs it twice |
| `scripts/lab-harden.sh` | installed as `lab-harden`. Policy, per-host data, and what the hosts actually report |
| `scripts/explore-roles.sh` | twelve read-only stops through the role you just built |
| `scripts/break-and-fix.sh` | five ways a role reports success and delivers nothing. `--hard` describes two lock-outs rather than causing them |
| `scripts/teardown.sh` | the inverse play. `--all` also deletes the role and playbook |
| `verify.sh` | eight automatic checks, two for you to judge |

## Run it

On your laptop, in the repository:

```bash
./lab/lab.sh up control node1 node2     # ~5.5 GB
./lab/lab.sh status                     # read BOTH addresses
./lab/lab.sh push control               # carries days/ and lab/
./lab/lab.sh push control ~/.ssh/id_ed25519
./lab/lab.sh ssh control
```

Both push lines, in that order. `push control` with no path copies the
repository; `push control <path>` copies **only** that one file. Give it the
key and skip the first line and `~/lab` on `control` holds a key and nothing
else, which is a confusing way to discover that `~/lab/days/day15` does not
exist.

The key is the second line for Day 14's reason: `control` can reach the nodes
over the network but holds no credential for them, and Ansible cannot
authenticate where plain `ssh` could not. `setup.sh` moves the pushed copy to
`~/.ssh/id_ed25519` at mode 0600 and deletes it from `~/lab`.

`lab.sh status` prints something like:

```
node1   running   192.168.122.75      # 1. EXAMPLE address — use your own
node2   running   192.168.122.61      # 2. EXAMPLE address — use your own
```

Those two addresses are examples. DHCP leases move every time a VM is
rebuilt, so read them yourself each session rather than copying them from here.

### Do you need Day 14's setup first?

No. `setup.sh` writes its own `ansible.cfg` if `~/ansible-lab` does not have
one, which is what happens on a freshly rebuilt `control` VM — the project
lives in the VM's home directory, not in the repository, so `lab.sh down`
followed by `up` takes it with it.

If Day 14's project *is* still there, today extends it and leaves `site.yml`
alone, so Day 14's `verify.sh` keeps passing.

If you want Day 14's playbook back as well — not needed for anything today:

```bash
cd ~/lab/days/day14 && ./scripts/setup.sh <node1-addr>
```

Run that one first if you run it at all; Day 15 then adds the vault line to the
config it wrote rather than writing its own.

Then on `control`, as the `lab` user and **without `sudo`**:

```bash
cd ~/lab/days/day15
./scripts/setup.sh 192.168.122.75 192.168.122.61    # your addresses
```

Run with no arguments after the first time and it reuses what is already in
the inventory.

`setup.sh` stops at the first thing that is wrong and tells you which thing.
SSH before Ansible, as on Day 14: a failing `ssh` is a failing `ansible`, and
Ansible's `UNREACHABLE` looks identical whether the host is down, the port is
shut or the key is wrong.

Then, in order:

```bash
lab-harden                           # both hosts, side by side
lab-harden node2                     # one host, in detail
lab-harden drift                     # what a run would change now
./scripts/explore-roles.sh           # read the role you just built
./scripts/break-and-fix.sh           # five failures that look like success
./verify.sh
```

## What to actually look at

**The playbook is six lines.** Three days of manual hardening, applied to any
number of hosts, readable by somebody who has never opened the role. That is
the entire argument for roles.

**`node1` opens port 8080 and `node2` does not.** Same role, different data.
The port is in `group_vars/webservers.yml` because Day 13 put nginx there; the
role's default is an empty list. Nothing was edited to make that happen.

**Editing `defaults/main.yml` does not change `node1`'s ports.** Defaults are
the lowest precedence in Ansible, and `group_vars` beats them. No error, no
warning, no effect — the second failure in `break-and-fix.sh`, and the one you
will meet in a real repository first.

**`ansible-inventory --host node1` is the answer.** Do not work precedence out
in your head. Ask.

**Order in `tasks/main.yml` is a safety property.** The `labssh` group exists
and your account is in it *before* `sshd` is told `AllowGroups labssh`. Reverse
those two and `sshd -t` still validates the file happily — a group does not
have to exist for the config to parse — the reload succeeds, and the next
connection is refused. Including Ansible's own.

**`--limit node-2` exits 0.** `skipping: no hosts matched`, green tick, nothing
deployed. Set `host_pattern_mismatch = error` in `ansible.cfg` and a typo fails
the run instead of passing it.

**The secret is ciphertext in git.** `group_vars/lab/vault.yml` starts with
`$ANSIBLE_VAULT`, the password lives in `~/.vault-pass-lab` at `0600` outside
the project, and the role reads `hardening_alert_token`, which points at
`vault_hardening_alert_token`. Grep for `vault_` and you have found every
secret the project reads. The cost: a diff of the vault file tells you nothing.

**A `--check` run on a clean host reports failures.** Tasks that read a file an
earlier task was supposed to create have nothing to read in a dry run. Check
mode being honest, not a bug — and the reason `--check` is a hint, not a
contract.

## Teardown

```bash
./scripts/teardown.sh          # undo the role on node2 only
./scripts/teardown.sh --all    # node1 too, and delete the role and playbook
```

The inverse of a play is a play, not `rm` on the host. The teardown leaves
SELinux enforcing, leaves `firewalld` installed, and leaves the `labssh` group
alone — read the comments in the generated playbook for why each of those is
deliberate.

Then, on your laptop:

```bash
./lab/lab.sh down control node1 node2
```

Day 16 needs two VMs again.

## Done when

`./verify.sh` prints **8 passed, 0 failed** and you can say, without looking it
up, why a value in `group_vars` beats the same value in `defaults/main.yml` —
and what `--limit` does when it matches nothing.
