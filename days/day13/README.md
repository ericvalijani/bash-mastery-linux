# Day 13 - SELinux: contexts, booleans and denial triage

> Serve content from a non-default path with SELinux still enforcing.

| | |
|---|---|
| **Phase** | Hardening and configuration management |
| **Runs on** | VM: node1 |
| **Memory** | ~2 GB (one VM) |
| **Verified by** | lint + your lab |

## Why this day exists

This is the day that separates operators from people who type `setenforce 0`.

The reason that command is so tempting is that it always works. The service comes back, the alert clears, and the ticket closes. What it never does is explain anything - and because the fix is invisible in every configuration file, the same outage returns after the next reboot or the next package update, usually to somebody else.

Denial triage is a procedure, not a talent. Six commands, in a fixed order, and the answer is always one of four things: the mode, a file label, a port label, or a boolean. Once you have run the procedure a few times, SELinux stops being an obstacle and becomes the thing that tells you precisely which access your service was missing.

The work here is deliberately the realistic case: content in `/srv/www` instead of `/usr/share/nginx/html`. Correct owner, correct mode, 403 anyway.

## What you will work with

- **`getenforce`, `sestatus`, `setenforce`** - read the mode before anything else, because every other answer depends on it. `setenforce` changes only the running kernel; `/etc/selinux/config` decides what comes back after a reboot, which is the same runtime-versus-permanent split you met in firewalld on Day 11.
- **`ls -Z`, `ps -Z`, `id -Z`** - see the label on a file, a process and yourself. Contexts are `user:role:type:level`, and for almost all troubleshooting only the **type** matters: nginx runs as `httpd_t`, and the question is always whether `httpd_t` may touch the type on the other object.
- **`semanage fcontext -a -t` and `restorecon`** - record what a path's label *should* be, then apply that rule to the files. This pair is the centre of the day: the rule is the reason, and `restorecon` is the enforcement of the reason.
- **`chcon` versus `semanage`** - `chcon` writes a label straight onto the inode and policy never learns about it, so the next relabel silently undoes your fix. Being able to explain that difference out loud is most of what this day is for.
- **`semanage port`** - ports carry labels too. A valid config on a free port can still fail to bind, and nothing in `nginx -t` or the service log will mention SELinux.
- **`getsebool -a`, `setsebool -P`, `semanage boolean -l -C`** - booleans are switches the policy author left for you, which makes them always preferable to a custom module. Without `-P` the change is runtime only; `-C` lists exactly what somebody changed on this machine, which is the first thing to read on a host you did not build.
- **`ausearch -m avc -ts recent`, `audit2allow`, `sesearch`** - the denial record, the rule generator, and the way to ask "is this allowed" without testing it in production. `audit2allow` is a suggestion engine, not an authority: read every rule it writes before loading it.

## Verify

Checked automatically:

- [ ] SELinux is enforcing
- [ ] the web root carries a web content label
- [ ] the label rule is permanent, not just a chcon
- [ ] restorecon is a no-op, so labels match policy
- [ ] nginx actually serves the content
- [ ] a boolean you set survives, recorded as permanent
- [ ] a custom policy module is loaded

Only you can confirm:

- [ ] you fixed a denial by relabelling, not by disabling SELinux
- [ ] you built a module from a real AVC with audit2allow and read it before loading

Run the automatic checks with:

```bash
sudo ./days/day13/verify.sh
```

CI can only lint this day. Nothing on a GitHub runner has SELinux, a policy store, or a service whose labels you control - so the checks above are proven by running `verify.sh` on your own lab, and nowhere else.

## Scripts for today

| Script | What it does | Root? |
|---|---|---|
| `setup.sh` | Refuses to continue unless SELinux is enforcing, creates `/srv/www`, adds the **fcontext rule** and then applies it with `restorecon`, serves it with nginx on 8080, sets one boolean with `-P`, and builds the `lab_selinux` module from source it prints before loading. Idempotent. | yes |
| `lab-se.sh` | The payload. Mode, the three labels that must agree (file, process, port), every local change someone made to policy, recent denials, and a closing section that names the mismatch. With a path argument it answers "what does SELinux know about this file". Installed as `/usr/local/bin/lab-se`. | yes |
| `explore-selinux.sh` | Twelve read-only stops: mode now versus after reboot, contexts on files and processes, policy's opinion versus the disk, the rule behind a label, port labels, booleans and their descriptions, `sesearch`, the denial log, and the service end to end. | yes |
| `break-and-fix.sh` | Four failures and their proper repairs: a `chcon` that a relabel reverts, an httpd type that still cannot be read, an unlabelled port that refuses a valid bind, and a boolean that was off. `--hard` describes the two that are not demonstrations: `setenforce 0` as an incident fix, and a full filesystem relabel. | yes |
| `lab_selinux.te` | The policy module in source form. Read the comments before `setup.sh` loads it - the `require` block is the list of everything the rule touches, and the permissions are named one by one for a reason. | - |
| `teardown.sh` | Stops the service before removing the policy that let it run, unloads the module, removes the local port rule, returns the boolean to its default, removes the fcontext rule **before** the directory, and leaves SELinux enforcing. | yes |

Read them before you run them. They are commented as teaching material rather than production code - the comments are half the day.

## Run it on the lab

### 1. On your laptop, bring up node1

```bash
./lab/lab.sh status              # what is already running?
./lab/lab.sh up node1            # 2 GB, about a minute
```

Day 12 left `node1` running; reuse it. A rebuilt `node1` is also fine - this day needs nothing from Day 12.

### 2. Copy the repo onto the VM

```bash
./lab/lab.sh push node1          # carries both days/ and lab/
./lab/lab.sh ssh node1
```

`push` is the step people skip. Editing a file on your laptop changes nothing on the VM until this runs.

### 3. Work through the day on the VM

```bash
hostname                         # must print: node1
cd ~/lab/days/day13
```

The tools live in four different packages, which is the usual reason a triage session stalls before it starts:

```bash
sudo dnf install -y nginx policycoreutils policycoreutils-python-utils \
                    checkpolicy setools-console audit curl
```

Before you change anything, read what is already there:

```bash
sestatus
ls -Zd /srv /usr/share/nginx/html
semanage fcontext -l -C          # what has anyone changed here before?
```

That second command is the day in one line: `/usr/share/nginx/html` is already labelled for the web server, and `/srv` is not. Nothing about ownership or mode differs.

In this order:

```bash
less scripts/setup.sh            # 1. read it BEFORE running it
sudo ./scripts/setup.sh          # 2. enforcing, label rule, nginx, boolean, module
sudo lab-se                      # 3. the whole picture in one screen
sudo lab-se /srv/www             # 4. everything about one path
sudo ./scripts/explore-selinux.sh # 5. the twelve stops
sudo ./scripts/break-and-fix.sh  # 6. four failures, four proper fixes
sudo ./scripts/break-and-fix.sh --hard   # 7. the two that are described only
sudo ./verify.sh                 # 8. seven checks, two for you
```

Do the manual half properly, because it is the half that transfers. Cause a real denial, then fix it by relabelling:

```bash
sudo chcon -R -t var_t /srv/www
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/   # 403
sudo ausearch -m avc -ts recent | tail -5                         # the reason
sudo restorecon -RFv /srv/www                                     # the fix
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/   # 200
```

Then build a module the real way and read it before loading anything:

```bash
sudo ausearch -m avc -ts recent | audit2allow -m lab_candidate    # READ this
sudo ausearch -m avc -ts recent | audit2allow -M lab_candidate    # then build
sudo semodule -i lab_candidate.pp
sudo semodule -r lab_candidate                                    # and remove it
```

If `audit2allow` suggests a rule for a denial that a boolean already covers, use the boolean. A module is a permanent exception nobody reviews; a boolean is a documented, supported switch.

### 4. Clean up

```bash
sudo ./scripts/teardown.sh       # leaves SELinux enforcing, on purpose
```

```bash
exit
./lab/lab.sh down node1          # frees the memory; takes the disk with it
```

## Notes

The procedure, which is the only thing worth memorising:

1. **Is it enforcing?** `getenforce`. If it is permissive, SELinux is not your problem.
2. **Was anything denied?** `ausearch -m avc -ts recent`. An empty result is an answer: the fault is elsewhere, so stop guessing.
3. **Who and what?** In the AVC: `scontext` is the process, `tcontext` is the object, `tclass` and the permission in `{ }` are the operation.
4. **Is there a boolean?** `semanage boolean -l | grep <service>`. Check before writing policy.
5. **Is it a label?** `ls -Z` the object, `matchpathcon` it, and compare. Different answers mean a relabel, not an exception.
6. **Fix the cause:** `semanage fcontext` + `restorecon`, `semanage port -a`, `setsebool -P`, or a module you read first.

Three things worth keeping. A 403 with correct ownership and correct mode is almost always a label, because Unix permissions and SELinux are two independent checks and both must pass. `chcon` is a debugging tool, not a fix - if you cannot point at the `semanage fcontext` rule that keeps a label in place, the label is temporary. And ports and booleans are labelled objects just like files, which is why "it is not a file, so it cannot be SELinux" is wrong so often.

The difference between someone who runs SELinux confidently and someone who disables it on first contact is not knowledge of the type names. It is the habit of reading the denial before changing anything.

Keep your own notes here. What broke, what the error actually said, and what fixed it - that is the part you will come back for.

---

Next up: **Day 14 - Ansible fundamentals.**
