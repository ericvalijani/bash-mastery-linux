# Day 14 - Ansible fundamentals

> Replace one day of manual work with a playbook that is safe to run twice.

| | |
|---|---|
| **Phase** | Hardening and configuration management |
| **Runs on** | control -> node1 |
| **Memory** | ~3 GB (two VMs) |
| **Verified by** | lint + your lab |

## Why this day exists

You have now configured hosts by hand for thirteen days. This is the day that work becomes repeatable, and idempotency stops being a buzzword.

The word means one thing in practice: **run it twice and the second run reports no changes.** That single measurement is what separates configuration management from a shell script in YAML. A playbook that changes something on every run cannot tell you whether a host has drifted, because it always says yes - and a fleet you cannot ask "is anything different?" is a fleet you do not actually manage.

Everything else today serves that idea. Modules describe a state instead of running a command. `--check` predicts. Handlers restart a service only when its configuration moved. Variables live in files next to the play instead of in your shell history.

Ansible itself is deliberately boring: no agent, no daemon, no port. It is SSH, Python on the far side, and YAML on yours. If `ssh lab@node1` does not work, nothing in this day will - which is why `setup.sh` settles that before it writes a single line of inventory.

## What you will work with

- **`ansible.cfg` and `ansible-config dump --only-changed`** - Ansible reads `ANSIBLE_CONFIG`, then `./ansible.cfg`, then `~/.ansible.cfg`, then `/etc/ansible/ansible.cfg`, and **stops at the first one it finds**. They are not merged, so a forgotten file in your home directory silently changes every run. `--only-changed` prints exactly what a project's config did, which is the shortest honest description of its opinions.
- **Inventory, in INI and in YAML** - `inventory/hosts.ini` and `inventory/hosts.yml` describe the same hosts, and you will compare them with `ansible-inventory --graph`. INI is terse and has one nasty habit: a typo in a `[group:vars]` header becomes a host named `[group:vars`. YAML is verbose and exact.
- **`ansible-inventory --graph` and `--host node1`** - the tree, and then one host with **every variable already merged**. Never work out precedence in your head: `host_vars` beats a named group, which beats `group_vars/all.yml`, and `-e` on the command line beats all of it.
- **`ansible -m ping`** - not ICMP. It opens SSH, runs Python on the far side and gets a pong back, so a pass means the entire transport works and a failure is almost always SSH or Python rather than Ansible.
- **`package`, `service`, `copy`, `template`, `user`, `file`, `lineinfile`** - the modules that make up most real playbooks. Each takes a **state** rather than an action, which is what makes a second run quiet. `copy` and `template` compare checksums, so "changed" from them always means the host drifted.
- **`lineinfile` and its `regexp`** - the module people misuse most. Without a `regexp` it is idempotent for the exact line you wrote and appends a new one as soon as the value changes. For a file you own entirely, use `template` instead; `lineinfile` is for files that belong to a package.
- **One file, one owner.** Point `lineinfile` at a file that `copy` or `template` also manages and both tasks report `changed` on every run, forever: `copy` restores its checksum, `lineinfile` puts its line back, and neither is wrong. `site.yml` shows the split deliberately - `copy` owns `lab-day14.txt`, `template` owns `lab-info.conf`, and `lineinfile` owns only its own line in `settings.conf`. If a second run will not go quiet, look for two tasks fighting over one path before you suspect the module.
- **`--syntax-check`, `--list-tasks`, `--check --diff`** - parse, then read the blast radius, then see the prediction. All three are free and read-only. They also have a limit worth knowing: `command` and `shell` tasks are skipped in check mode, so a dry run of a play built from shell commands predicts nothing at all.
- **`notify` and handlers** - a handler runs once, at the end, and **only if the notifying task reported changed**. That is the feature: services restart when their configuration moves and not otherwise. A failed play drops pending handlers, which is how a host ends up with new config on disk and an old process running.
- **`become`** - privilege per task, not per run. The project starts with `become = false` on purpose, so reading the playbook tells you which steps touch the system. `become` is `sudo`, so a run that hangs in silence is usually sudo waiting for a password nobody typed.

## Verify

Checked automatically:

- [ ] you are running this as yourself, not as root
- [ ] the inventory parses
- [ ] node1 answers a ping module
- [ ] the playbook has valid syntax
- [ ] a first run completes with no failures
- [ ] a second run changes nothing

Only you can confirm:

- [ ] --check predicted the same changes the real run made
- [ ] you can explain which module was not idempotent and why

Run the automatic checks with:

```bash
./days/day14/verify.sh
```

**Without `sudo`.** Every other lab day wants root; this one refuses it. As root, `~/.ssh` is `/root/.ssh`, the key named in the inventory is not there, and all five checks fail as `UNREACHABLE` for a reason that has nothing to do with your work. The first check exists to catch exactly that.

CI can only lint this day. Nothing on a GitHub runner has SELinux, firewalld, systemd units you control, or a second host to reach over SSH - so the checks above are proven by running `verify.sh` on your own lab, and nowhere else.

## Scripts for today

| Script | What it does | Root? |
|---|---|---|
| `setup.sh` | **Refuses to run as root**, installs the pushed SSH key with mode 0600, proves plain `ssh` to node1 works before writing any inventory, then builds `~/ansible-lab`: config, both inventory formats, `group_vars`, `host_vars`, files, templates, `site.yml` and `not-idempotent.yml`. Ends by running the play twice and showing you `changed=0`. Idempotent. | no |
| `lab-ansible.sh` | The payload. Which config won, the inventory as a tree, both formats side by side, reachability, variables as resolved rather than as written, and a closing section naming the three places the answers disagree. `lab-ansible node1` for one host; `lab-ansible drift` for a check run. Installed as `/usr/local/bin/lab-ansible`. | no |
| `explore-ansible.sh` | Twelve read-only stops, ending with the six-command order to use on a project you have just inherited. Safe against an estate you do not understand yet. | no |
| `break-and-fix.sh` | Four failures with their fixes: `command` instead of a module, `lineinfile` with no `regexp`, handler expectations, and a missing `become`. `--hard` describes the two that teach nothing by happening: an ad-hoc `shell` against `all`, and `become: true` everywhere. Writes its broken plays to `/tmp`, never into your project. | no |
| `teardown.sh` | The undo, written as a playbook with every state inverted - which is the argument for configuration management in one script. Dry run first, then apply, then prove each removal. Leaves `rsyslog` alone because Rocky shipped it. `--all` also deletes the project. | no |

Read them before you run them. They are commented as teaching material rather than production code - the comments are half the day.

## Run it on the lab

This is the first day since Day 05 that genuinely needs two VMs: `control` runs Ansible, `node1` is managed. Together they are about 3 GB.

### 1. On your laptop, bring up both VMs

```bash
./lab/lab.sh status              # what is already running?
./lab/lab.sh up control node1    # ~3 GB total, a minute or two
```

`node1` can be the same one Days 11-13 used; nothing here conflicts with it. A rebuilt `node1` is also fine - this day installs everything it needs.

### 2. Copy the repo and the key onto control

```bash
./lab/lab.sh push control        # carries days/ and lab/
./lab/lab.sh push control ~/.ssh/id_ed25519
```

That second line is the one people miss. `control` can reach `node1` over the network, but it holds no credential for it, and Ansible has no way to authenticate that SSH could not already do. `setup.sh` moves the pushed key into `~/.ssh/id_ed25519` with mode 0600 and deletes the copy from `~/lab`.

Be clear-eyed about what that is: a private key on a control node means whoever owns the control node owns every managed host. Real estates use a key generated on the control node and authorised on the fleet, an SSH agent with forwarding, or short-lived certificates. Here it is one throwaway VM reaching another.

You also need node1's address, from the same `status` output:

```bash
./lab/lab.sh status              # note node1's address, on the node1 line
./lab/lab.sh ssh control
```

Every address in this README is an example. libvirt hands out leases in
whatever order the VMs booted, and they move when a VM is rebuilt, so read
yours from `status` every time. `setup.sh` checks the address before it builds
anything: it refuses an address that belongs to `control` itself, and when
nothing answers it tells you whether that was no route, a refused connection,
or a rejected key - three different problems that look identical from the
`ansible` command line, where they all arrive as `UNREACHABLE`.

### 3. Work through the day on control

```bash
hostname                         # must print: control
sudo dnf install -y ansible-core
cd ~/lab/days/day14
```

`ansible-core` is the whole dependency. It pulls Python and nothing else, and the managed host needs no agent - only the Python that Rocky already ships.

In this order:

```bash
less scripts/setup.sh                    # 1. read it BEFORE running it
./scripts/setup.sh 192.168.122.42        # 2. EXAMPLE address - use your own
lab-ansible                              # 3. the whole picture in one screen
lab-ansible node1                        # 4. one host, variables and facts
lab-ansible drift                        # 5. what a run would change now
./scripts/explore-ansible.sh             # 6. the twelve stops
./scripts/break-and-fix.sh               # 7. four failures, four fixes
./scripts/break-and-fix.sh --hard        # 8. the two that are described only
./verify.sh                              # 9. six checks, two for you
```

Note what is missing from every line above: `sudo`.

Then do the manual half, because it is the half that transfers. Prove `--check` tells the truth by breaking one thing on the host by hand and asking Ansible about it before fixing it:

```bash
cd ~/ansible-lab
ansible node1 -b -m shell -a 'echo broken >> /etc/lab-day14/lab-day14.txt'
ansible-playbook site.yml --check --diff        # predicts exactly one change
ansible-playbook site.yml                       # makes exactly that change
ansible-playbook site.yml                       # changed=0 again
```

That is drift detection, and it is only possible because every task describes a state. Now watch the same idea fail:

```bash
ansible-playbook not-idempotent.yml --check     # predicts nothing
ansible-playbook not-idempotent.yml             # changed=3
ansible-playbook not-idempotent.yml             # changed=3, forever
ansible node1 -b -m command -a 'cat /etc/lab-day14/lab-day14.txt'
ansible-playbook site.yml                       # copy puts the file back
```

The second `YOU` item is that comparison in your own words: which task was not idempotent, and why the module version is.

### 4. Clean up

```bash
./scripts/teardown.sh            # a playbook with every state inverted
```

Keep `~/ansible-lab` - Day 15 turns `site.yml` into a role. Pass `--all` only if you want to start from nothing.

```bash
exit
./lab/lab.sh down control node1  # frees ~3 GB; takes both disks with it
```

## Notes

The order to use on a playbook you did not write:

1. **`ansible --version`** - which config file is in play.
2. **`ansible-config dump --only-changed`** - what it changed.
3. **`ansible-inventory --graph`** - which hosts, in which groups.
4. **`ansible-inventory --host <one>`** - the variables, already merged.
5. **`ansible-playbook <play> --list-tasks`** - what it would do.
6. **`ansible-playbook <play> --check --diff`** - what it would change today.

All six are read-only and take under a minute. They are the difference between applying a playbook and detonating one.

Three things worth keeping. A second run that reports `changed=0` is the only honest test of a play, so run everything twice before you believe it. `--check` is a prediction, not a guarantee, and it is worthless for `command` and `shell` tasks because those are skipped entirely - a play built from shell commands has no dry run. And privilege belongs on tasks rather than plays: `become: true` everywhere works right up until a typo in a path, and then it is an incident instead of a permission error.

Keep your own notes here. What broke, what the error actually said, and what fixed it - that is the part you will come back for.

---

Next up: **Day 15 - Ansible roles: your hardening baseline.**
