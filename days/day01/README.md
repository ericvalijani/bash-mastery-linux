# Day 01 — systemd and the boot path

> Follow a Linux machine from power-on to a running service, and write a unit that survives a reboot.

| | |
|---|---|
| **Phase** | The host |
| **Runs on** | VM: control |
| **Memory** | ~1 GB (one VM) |
| **Verified by** | lint + your lab |

## Why this day exists

Every later day ends with "make it persist", and on this family of distros that always means a unit file. Start where the machine starts.

## What you will work with

- `systemctl list-units --failed` - every unit that tried to start and did not. On a healthy machine this prints nothing, which is why it is the first thing to run when something is wrong.
- `systemctl cat sshd.service` - shows the real unit file systemd is using, including any drop-in overrides, so you read what is in effect rather than what you think you installed.
- `systemd-analyze blame` - each unit and how long it took to start, slowest first. Answers "why is this boot slow".
- `systemd-analyze critical-chain` - the dependency path that actually determined boot time. Slower than `blame` at first glance but more honest: a unit can be slow and still not hold anything up.
- `journalctl -b -p err` - errors only, from this boot only. The fastest way to see what the kernel and services complained about since power-on.
- `/etc/systemd/system/` - where your own units and overrides live. Anything here wins over the packaged units in `/usr/lib/systemd/system/`, which is the whole reason you edit here and never there.

## Verify

Checked automatically:

- [ ] a custom unit is installed and enabled
- [ ] that unit is running
- [ ] the machine boots with no failed units
- [ ] the unit restarts itself after being killed

Only you can confirm:

- [ ] you can read systemd-analyze critical-chain and name the slowest unit

Run the automatic checks with:

```bash
./days/day01/verify.sh
```

**Run it on control, not on your laptop.** Nothing inside `verify.sh` checks which machine you are on, so on your laptop it runs anyway and reports `FAIL` for `lab-demo.service` — a service that was never meant to exist there. Red on the wrong machine means "wrong machine", not "wrong work". Watch the third check too: `the machine boots with no failed units` will report `PASS` about *your laptop's* boot, which proves nothing about this day. The only results that mean anything are the ones from a shell on the VM.

CI can only lint this day. Nothing on a GitHub runner has SELinux, firewalld, systemd units you control, or a second host to reach over SSH — so the checks below are proven by running `verify.sh` on your own lab, and nowhere else.

## Scripts for today

| Script | What it does | Root? |
|---|---|---|
| `lab-demo.sh` | The service payload. Long-running, prints to the journal, traps SIGTERM. | no |
| `setup.sh` | Installs the payload and writes, enables and starts `lab-demo.service`. Idempotent. | yes |
| `explore-boot.sh` | Read-only guided tour: boot timing, blame, critical chain, failed units, cgroup. | no |
| `break-and-fix.sh` | Kills the service to watch `Restart=always` work. `--hard` also breaks the unit file, then repairs it. | yes |
| `teardown.sh` | Removes everything `setup.sh` installed, and proves it is gone. | yes |

Read them before you run them. They are commented as teaching material rather than production code — the comments are half the day.

## Run it on the lab

### 1. On your laptop, bring up one VM

Run these one at a time, from the top of the repository. **Do not paste all four
at once**: `check` is a gate, and the three after it are pointless until it is
clean.

```bash
./lab/lab.sh check          # first time only: does this machine have KVM?
```

On a fresh Ubuntu machine `check` will report missing tools, because qemu,
libvirt and `virt-install` are not installed by default. It prints the exact
commands; they are also here:

```bash
sudo apt-get install -y qemu-system-x86 libvirt-daemon-system libvirt-clients libvirt-daemon-config-network virtinst acl
```

Then, once, so the hypervisor can reach the lab's disks:

```bash
sudo install -d -o "$(id -un)" -g "$(id -gn)" /var/lib/libvirt/images/bash-mastery-linux
```

- VM disks cannot live under your home directory on Ubuntu. AppArmor
  confines the `libvirt-qemu` process to a list of paths that excludes
  `/home`, so qemu is denied the disk even when its permissions are right.
  `lab.sh` picks this directory up automatically once it exists.

Two things about that line, because both bite people:

- **There is no `qemu-kvm` package on Debian or Ubuntu any more.** It is a
  virtual package with no installation candidate, so apt refuses and installs
  *nothing at all* - which is why a follow-up `systemctl enable --now libvirtd`
  then says the unit does not exist. That is not a second fault, it is the same
  one. The real package is `qemu-system-x86`.
- **Do not use plain `qemu-system`.** The QEMU website suggests it, but that
  metapackage installs emulators for every CPU architecture - hundreds of
  megabytes you will never boot. KVM only runs the host architecture.

Now start the daemon. Recent libvirt splits `libvirtd` into modular daemons and
may not ship `libvirtd.service` at all, so use whichever exists:

```bash
sudo systemctl enable --now libvirtd 2>/dev/null \
  || sudo systemctl enable --now virtqemud.socket virtnetworkd.socket
sudo usermod -aG kvm,libvirt "$USER"    # log out and back in after this
```

If `check` then still says the `default` network is not defined:

```bash
sudo virsh net-start default && sudo virsh net-autostart default
```

Log out and back in, then run `check` again.

Only once `check` ends in `ready` do you continue:

```bash
./lab/lab.sh image          # first time only: ~900 MB download, cached
./lab/lab.sh up control     # ~1 GB of RAM, about a minute
./lab/lab.sh status         # wait until control has an IP address
```

The VM has a screen as well as a serial console. `virsh vncdisplay control`
prints something like `127.0.0.1:0`; open that in any VNC viewer to watch it
boot. If it never gets an address, `./lab/lab.sh diagnose control` collects
everything worth knowing in one go.

### 2. Copy the repo onto the VM

Everything from here happens **on the VM**. The day installs a unit, kills
processes and breaks a service on purpose; none of that belongs on your own
machine. `setup.sh` and `break-and-fix.sh` now refuse to run anywhere that is
not a lab VM, and your shell prompt showing `[lab@control ~]$` is the
confirmation to look for.

```bash
./lab/lab.sh push control
```

That lands `days/` and `lab/` in `~/lab` on the VM. Both are needed: every
`verify.sh` sources `lab/verify-lib.sh`, so pushing `days/` alone gives you a
day that cannot check itself.

Re-run `push` whenever you edit anything on the host. It overwrites, so it is
safe to run as often as you like.

### 3. Work through the day on the VM

```bash
./lab/lab.sh ssh control
cd ~/lab/days/day01
```

Then, in this order:

```bash
less scripts/setup.sh              # 1. read it BEFORE running it
sudo ./scripts/setup.sh            # 2. install the service
```

```bash
systemctl status lab-demo          # 3. look at your own work
journalctl -u lab-demo -f          #    ctrl-c when you have seen enough
systemctl cat lab-demo
```

```bash
./scripts/explore-boot.sh          # 4. the tour. no root needed
```

Do not skim this one. It prints the command it is about to run before each
block, and the reason you are looking at the output. Stop at anything you
cannot explain and go read `man systemd.service` or `man journalctl` on the
VM - both are installed.

```bash
sudo ./scripts/break-and-fix.sh          # 5. crash it, watch it come back
sudo ./scripts/break-and-fix.sh --hard   # 6. now break the unit file itself
```

Step 6 is the important one. A crashed process and a broken unit file are two
different failures with two different signatures, and the whole skill is
telling them apart from `systemctl status` alone.

### 4. Check yourself

```bash
sudo ./verify.sh
echo "exit: $?"
```

Expected on a healthy Day 01: **4 PASS, 1 YOU, exit 0.** The `YOU` line is the
critical-chain question - nothing can grade that but you.

Root is needed because the checks read `/etc/systemd/system/` and query unit
state. Without it the run exits 0 with everything skipped, which is not a pass.

| If you see | It means | Do this |
|---|---|---|
| `FAIL a custom unit is installed and enabled` | `setup.sh` did not finish, or you ran it in the wrong directory | `cd ~/lab/days/day01 && sudo ./scripts/setup.sh` |
| `FAIL that unit is running` | it started and then died | `journalctl -u lab-demo -n 30` |
| `FAIL the machine boots with no failed units` | something unrelated is broken on the VM - a genuine finding, not a bug in the day | `systemctl list-units --failed`, then fix it and write down what it was |
| `SKIP missing root` | you forgot `sudo` | run it again with `sudo` |

### 5. Prove it survives a reboot

This is the actual objective of the day, and no script can do it for you.
**Reboot the VM, not your laptop.** Run this while logged in over
`./lab/lab.sh ssh control`, so the shell you type it into belongs to the VM:

```bash
hostname                         # must print: control
sudo reboot                      # your ssh session will drop - that is the point
```

If `hostname` prints your laptop name instead, you are in the wrong shell and
`sudo reboot` would restart your own machine. On a desktop it will usually
refuse with `Operation inhibited by ... user session inhibited`, which is a
useful accident: it is systemd-inhibit protecting a logged-in graphical
session, and it is the clearest sign you are on the wrong host.

You can also power-cycle it from the laptop without logging in:

```bash
virsh reboot control
```

Then from the host, once it is back (about 20 seconds):

```bash
./lab/lab.sh ssh control
systemctl is-active lab-demo     # active
systemctl is-enabled lab-demo    # enabled
systemd-analyze critical-chain   # does your service appear? why not?
```

If `is-enabled` says `enabled` but `is-active` says `inactive`, you have found
the difference between the two words the hard way - which is the best way.

### 6. Optional cleanup

```bash
sudo ./scripts/teardown.sh
```

You do not have to. Nothing in Days 02-20 conflicts with `lab-demo`, and
leaving it running gives you a harmless service to practise on later. Run the
teardown if you want to do the whole install-inspect-remove loop again from
scratch.

To give the RAM back to your laptop when you are done for the day:

```bash
./lab/lab.sh down control        # deletes the VM and its disk
```

The base image stays cached, so `up` next time takes a minute, not a download.

## Notes

Keep your own notes here. What broke, what the error actually said, and what fixed it — that is the part you will come back for.

---

Next up: **Day 02 — Users, sudo, permissions and ACLs.**
