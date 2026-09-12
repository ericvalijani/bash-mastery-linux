# Day 02 — Users, sudo, permissions and ACLs

> Give a service account exactly the access it needs and nothing else.

| | |
|---|---|
| **Phase** | The host |
| **Runs on** | VM: node1 |
| **Memory** | ~2 GB (one VM) |
| **Verified by** | lint + your lab |

## Why this day exists

"It works when I run it as root" is where most security incidents begin. Least privilege is a habit you build with your hands.

Today builds one small, complete example of it: a service account with no shell, one directory it shares with humans, one command it may run as root, and a running service that breaks the moment any of that is wrong. Then you break each piece on purpose and read the failure.

## What you will work with

- `useradd --system --shell /sbin/nologin` - a service account. The system UID is a convention that tells a human "not a person"; the `nologin` shell is the part that actually stops a login, and it is why `su - appsvc` fails while `sudo -u appsvc <cmd>` works.
- `visudo -cf <file>` - parses a sudoers file without installing it. A syntax error under `/etc/sudoers.d/` makes `sudo` refuse to run *at all*, on a machine where `sudo` is how you become root. Build, check, install - never edit in place.
- `sudo -l -U <user>` - what sudo will really allow, aliases expanded. This is the authority, not the file you think you wrote. Needs root to ask about someone else.
- **setgid directories** (`chmod 2770`) - files created inside inherit the *directory's* group instead of the creating user's primary group. Without it, two members of the same group create files each other cannot edit, which is the most common cause of "but we are both in the group". Nothing fails on the day you lose the bit; it fails later.
- `setfacl` / `getfacl` - Unix modes have exactly three slots: owner, group, everyone. There is no fourth slot for "and also this one account". An ACL is that fourth slot, scoped to the object rather than granted machine-wide like a group. `setfacl -d` sets a *default* ACL, which is not an access rule but a template inherited by new files.
- `umask` - the permission bits removed from anything you create. Files start at 666 and directories at 777, which is why a 022 umask gives 644 and 755.
- `ls -ld` versus `getfacl` - a `+` on the end of the mode is the *only* hint `ls` gives that an ACL exists. On a machine that uses ACLs, `ls -l` is not a complete answer and never says so.

## Verify

Checked automatically:

- [ ] a system account appsvc exists with no login shell
- [ ] appsvc may restart one service and nothing else
- [ ] appsvc cannot become root
- [ ] the shared directory is setgid
- [ ] an ACL grants appsvc access without changing the owner

Only you can confirm:

- [ ] you can explain every line of sudo -l -U appsvc

Run the automatic checks with:

```bash
sudo ./days/day02/verify.sh
```

Root is needed: asking sudo about another user's privileges is itself privileged, and the ACL check reads a `2770` directory. Without it every check reports `SKIP`, which is not a pass.

**Run it on node1, not on your laptop.** Nothing inside `verify.sh` checks which machine you are on. Without `sudo` you get the honest `SKIP` list and the line `This day runs elsewhere`, but that is only because this day needs root — run it *with* `sudo` on your laptop and it will report `FAIL` for an `appsvc` account that was never meant to exist there. Red on the wrong machine means "wrong machine", not "wrong work". The only results that mean anything are the ones from a shell on the VM.

CI can only lint this day. Nothing on a GitHub runner has SELinux, firewalld, systemd units you control, or a second host to reach over SSH — so the checks below are proven by running `verify.sh` on your own lab, and nowhere else.

## Scripts for today

| Script | What it does | Root? |
|---|---|---|
| `lab-app.sh` | The service payload. Runs as `appsvc` and appends to `/srv/shared/lab-app.log`, so a permission mistake makes it die rather than lie. | no |
| `setup.sh` | Creates the `appdata` group, the `appsvc` account, `/srv/shared` (setgid + ACLs), the one-command sudo rule, and `lab-app.service`. Idempotent. | yes |
| `explore-perms.sh` | Read-only guided tour: identity, the account, `sudo -l`, the three mechanisms stacked on one directory, setgid, umask. | no |
| `break-and-fix.sh` | Three permission failures, each repaired: a refused sudo command, a removed ACL, a removed setgid bit. `--hard` also breaks sudo itself and recovers. | yes |
| `teardown.sh` | Removes the user, group, directory, sudo rule and unit, then proves each is gone. | yes |

Read them before you run them. They are commented as teaching material rather than production code — the comments are half the day.

## Run it on the lab

Day 02 runs on **`node1`**, not `control`. Day 01 was `control`; from here on the day page names the machine and you should check `hostname` before typing anything that changes state. Every script that changes state refuses to run anywhere that is not a lab VM, but it cannot tell you that you are on the *wrong* lab VM.

### 1. On your laptop, bring up node1

From the top of the repository:

```bash
./lab/lab.sh status              # what is already running?
./lab/lab.sh up node1            # 2 GB, about a minute
./lab/lab.sh status              # wait until node1 has an IP address
```

If you still have `control` up from Day 01 and your laptop is tight on memory, give it back first — nothing today needs it:

```bash
./lab/lab.sh down control
```

If `node1` never gets an address, `./lab/lab.sh diagnose node1` collects everything worth knowing in one go, and `virsh vncdisplay node1` gives you a screen to watch it boot.

### 2. Copy the repo onto the VM

```bash
./lab/lab.sh push node1
```

That lands `days/` and `lab/` in `~/lab` on the VM. Both are needed: `verify.sh` sources `lab/verify-lib.sh` and the day scripts source `lab/on-lab-vm.sh`, so pushing `days/` alone gives you a day that can neither guard nor check itself.

Re-run `push` whenever you edit anything on the host. It overwrites, so run it as often as you like.

### 3. Work through the day on the VM

```bash
./lab/lab.sh ssh node1
hostname                         # must print: node1
cd ~/lab/days/day02
```

Then, in this order:

```bash
less scripts/setup.sh                    # 1. read it BEFORE running it
sudo ./scripts/setup.sh                  # 2. build the least-privilege setup
```

It prints each thing it creates and refuses to finish if the service did not manage to write its log — because a service that starts and then cannot write is exactly the failure this day is about.

```bash
sudo -l -U appsvc                        # 3. look at your own work
getfacl -p /srv/shared
ls -ld /srv/shared                       #    note the trailing '+'
journalctl -u lab-app -f                 #    ctrl-c when you have seen enough
```

```bash
sudo ./scripts/explore-perms.sh          # 4. the tour
```

It works without root but two of its commands need it, so run it with `sudo` the first time and read every block. Stop at anything you cannot explain and read `man 5 sudoers`, `man setfacl` or `man 7 acl` on the VM — all three are installed.

```bash
sudo ./scripts/break-and-fix.sh          # 5. three failures, three fixes
sudo ./scripts/break-and-fix.sh --hard   # 6. now break sudo itself
```

Step 5 is the one to slow down on. Removing the ACL produces a service that fails with `Permission denied` while `ls -l` shows a directory whose owner, group and mode are all correct — the failure with no visible cause. Step 6 is the one that stops you locking yourself out of a real machine one day: it shows a *valid* sudoers file being silently ignored because its mode is `0644` instead of `0440`.

### 4. Check yourself

```bash
sudo ./verify.sh
echo "exit: $?"
```

Expected on a healthy Day 02: **5 PASS, 1 YOU, exit 0.** The `YOU` line is the `sudo -l -U appsvc` question — read the output line by line and say what each permits. If you cannot, you have a rule you do not understand on a machine you administer.

| If you see | It means | Do this |
|---|---|---|
| `SKIP` on everything | no root, or `acl` is not installed | `sudo ./verify.sh`; if it still skips, `sudo dnf install -y acl` |
| `FAIL a system account appsvc exists...` | `setup.sh` did not finish | `cd ~/lab/days/day02 && sudo ./scripts/setup.sh` |
| `FAIL appsvc may restart one service...` | the sudo rule is missing **or** being ignored | `visudo -cf /etc/sudoers.d/appsvc`, then `ls -l` it — it must be `0440 root:root` |
| `FAIL appsvc cannot become root` | a rule somewhere grants `(ALL) ALL` | `sudo -l -U appsvc`, then find which file: `grep -r appsvc /etc/sudoers /etc/sudoers.d/` |
| `FAIL the shared directory is setgid` | you ran `break-and-fix.sh` and it was interrupted before the repair | `sudo chmod 2770 /srv/shared` |
| `FAIL an ACL grants appsvc access...` | same, at the ACL step | `sudo setfacl -m u:appsvc:rwx /srv/shared` |

### 5. Prove it holds across a reboot

Users, groups, modes and ACLs live on disk, so they survive by nature — but the *service* running as an unprivileged user is the part that tends to break, because a unit that works when you start it by hand can still fail at boot.

```bash
hostname                         # must print: node1
sudo reboot                      # your ssh session will drop - that is the point
```

If `hostname` prints your laptop's name, you are in the wrong shell and this would restart your own machine. You can also power-cycle it from the laptop: `virsh reboot node1`.

Then, once it is back:

```bash
./lab/lab.sh ssh node1
systemctl is-active lab-app      # active
tail -3 /srv/shared/lab-app.log  # timestamps from after the reboot
ls -l /srv/shared                # group is still appdata
getfacl -p /srv/shared           # the ACL is still there
id -Gn                           # NOW your shell has appdata
```

That last one is the point worth having: `setup.sh` added your account to `appdata`, but supplementary groups are read at login, so the shell you ran it in never had it. A reboot is one way to notice. `newgrp appdata` is the other.

### 6. Optional cleanup

```bash
sudo ./scripts/teardown.sh
```

You do not have to. Nothing in Days 03-20 conflicts with `appsvc`, `/srv/shared` or `lab-app`, and leaving them gives you a real service account to practise on — Day 03 constrains a process, and an unprivileged one is a better subject than root.

To give the RAM back to your laptop when you are done for the day:

```bash
./lab/lab.sh down node1          # deletes the VM and its disk
```

The base image stays cached, so `up` next time takes a minute, not a download.

## Notes

Keep your own notes here. What broke, what the error actually said, and what fixed it — that is the part you will come back for.

---

Next up: **Day 03 — Processes, signals, cgroups v2 and limits.**
