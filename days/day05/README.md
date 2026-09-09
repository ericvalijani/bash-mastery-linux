# Day 05 — Logs and time: journald, logrotate and chrony

> Make logs persistent, bounded, and correctly timestamped.

| | |
|---|---|
| **Phase** | The host |
| **Runs on** | VM: node1 |
| **Memory** | ~1 GB (one VM) |
| **Verified by** | lint + your lab |

## Why this day exists

Every diagnosis in Days 06-20 is log reading. If the logs are not there, or the timestamps lie, none of those days work.

Two defaults on a fresh RHEL-family machine will cost you an incident. The journal is stored in `/run`, which is memory, so the boot that crashed is erased by the boot that recovered — `journalctl -b -1` has nothing to show you at exactly the moment you need it. And logs that nothing rotates grow until the filesystem is full, which is the Day 04 page arriving by a different route.

Today you fix both, and then you break them in the three ways that are hard to recognise: a rotated log that keeps growing while the file you are watching stays empty, a journal quietly deleting your history with no error anywhere, and a clock two hours out that makes entries invisible to the query you are typing.

## What you will work with

- `journalctl` and its four selectors - `-u` for a unit, `-b` for this boot (`-b -1` for the previous one), `-p err` for priority err and worse, and `--since` which takes plain English like `"2 hours ago"`. Those four cover most real use. The important thing to understand first is that the journal is not a text file: it is a binary, indexed store of structured fields, so you cannot `grep /var/log/journal` and `journalctl` is the only reader. Run `journalctl -n 1 -o json-pretty` once and you will stop thinking of log entries as lines.
- `Storage=` in `/etc/systemd/journald.conf` - the default is `auto`, which means "use `/var/log/journal` if that directory exists, otherwise keep everything in `/run/log/journal`". `/run` is tmpfs, so on a default machine the journal is erased at every boot. Creating the directory is genuinely all it takes to change the behaviour, which is why so many machines are non-persistent by accident rather than by decision.
- `SystemMaxUse=` - a hard cap enforced by deleting the oldest entries. Not a warning, not a refusal to log: silent deletion, while every command reports healthy. The default is 10% of the filesystem, which is a strange number to have chosen for you on a root filesystem you needed for something else. Set it deliberately and understand that you are choosing how far back you can see, not how much disk to spend.
- `logrotate` and `/etc/logrotate.d/` - the other logging system, still running on every one of these machines, for every log that is a plain file rather than a journal entry. A rule there is a **request**, not a schedule: `logrotate.timer` is what actually runs it. Debugging a rotation problem without checking `systemctl list-timers | grep logrotate` is the most common wasted hour in this area.
- `copytruncate`, and what a rename really does - logrotate's default is to rename `app.log` to `app.log.1` and create a new empty `app.log`. But a process that already has the file open holds a descriptor pointing at an **inode**, and renaming a file does not touch its inode. So a daemon that never reopens its log keeps writing into `app.log.1` forever while the file you are tailing stays at zero bytes. `copytruncate` avoids that by emptying the original file in place; the better answer, when the daemon supports it, is a `postrotate` stanza that signals it to reopen.
- `logrotate -d` - a dry run that says what it would do and changes nothing. It is the only safe way to test a rule, and it is today's first manual check. Note what it does *not* tell you: whether anything will ever call it.
- `chronyc tracking` and `chronyc sources -v` - `tracking` answers "is my clock right", where `Leap status: Normal` means synchronised and `System time` is your current error in seconds. `sources -v` answers "who is telling me", and the `^*` marker is the source actually in use. Chrony **slews** small errors — speeds the clock up or slows it down until it catches up — rather than jumping, because time going backwards breaks builds, databases and certificate checks. `chronyc makestep` forces a jump, and is the right tool exactly once: when you already know the clock is grossly wrong.
- `timedatectl` - and the distinction it makes that people miss. The timezone is a **display** setting; the journal always stores UTC internally, so changing the zone changes how `journalctl` prints entries and nothing about what was recorded. The clock is the actual number of seconds. `timedatectl` shows both, plus whether NTP is even switched on, and those lines can disagree with each other.

## Verify

Checked automatically:

- [ ] the journal is persistent across reboots
- [ ] journal size is bounded
- [ ] the clock is synchronised
- [ ] the timezone is set deliberately
- [ ] a logrotate rule exists for your own log

Only you can confirm:

- [ ] logrotate -d showed your rule doing what you intended
- [ ] you watched a rotated log keep growing, and found the open descriptor

Run the automatic checks with:

```bash
./days/day05/verify.sh
```

No root today. Every check reads something a normal user can read: a directory, two config files, and `chronyc`, which answers anybody. Root would let `journalctl` show you more, and the tour asks for it for that reason, but the checks themselves do not need it and none of them will print `SKIP`. If they ever do, `SKIP` is not a pass — it means the check could not run at all.

**Run it on node1, not on your laptop.** Nothing inside `verify.sh` checks which machine you are on, and today that is more dangerous than usual, because your laptop will score well. `the clock is synchronised` and `the timezone is set deliberately` both **PASS** on any working desktop, and `the journal is persistent across reboots` passes on most distributions too, since they ship `/var/log/journal` already. So an off-VM run can report four green lines and one red one, which looks like "nearly done" rather than "wrong machine". The only check that genuinely reflects your work today is `a logrotate rule exists for your own log`.

CI can only lint this day. Nothing on a GitHub runner has SELinux, firewalld, systemd units you control, or a second host to reach over SSH — so the checks below are proven by running `verify.sh` on your own lab, and nowhere else.

## Scripts for today

| Script | What it does | Root? |
|---|---|---|
| `lab-noisy.sh` | The payload. Writes one line per second to a plain file **and** to the journal, from the same loop. Holds its log open on fd 3 and never reopens it, exactly like a real daemon — which is what makes failure 1 possible. Installed as `/usr/local/bin/lab-noisy`. | no |
| `setup.sh` | Makes the journal persistent and caps it at 200 MB, sets the timezone and starts chronyd, installs the payload as `lab-noisy.service`, and writes the logrotate rule. Idempotent. | yes |
| `explore-logs.sh` | Read-only guided tour in ten sections: where the journal really lives, the selectors worth memorising, the plain-file log beside it, what logrotate would do, who actually runs it, and the clock. Works without root, but the journal shows you less — run it with `sudo` the first time and it says so. | no |
| `break-and-fix.sh` | Three failures, each repaired: a rotated log that keeps growing, a journal that deletes its own history, and a clock in the future. `--hard` adds a perfect rule that never runs and journald silently dropping messages. | yes |
| `teardown.sh` | Stops the writer *before* deleting its files, removes the unit, payload, log directory and rule, and proves each is gone. Deliberately leaves the journal and its settings. | yes |

Read them before you run them. They are commented as teaching material rather than production code — the comments are half the day.

## Run it on the lab

### 1. On your laptop, bring up node1

Day 05 runs on **`node1`**, the same VM as Days 02, 03 and 04. It needs no extra disk and nothing from those days, so whatever is already there can stay.

```bash
./lab/lab.sh status              # what is already running?
./lab/lab.sh up node1            # 768 MB, about a minute
```

If you tore the VM down since Day 04, remember what `down` takes with it: the whole machine, its disk, and any disk added with `add-disk`. A rebuilt `node1` is a blank Rocky image with none of the packages from previous days.

### 2. Copy the repo onto the VM

```bash
./lab/lab.sh push node1          # carries both days/ and lab/
./lab/lab.sh ssh node1
```

Both directories have to travel: the day scripts source `lab/on-lab-vm.sh`, and without it every one of them refuses to run.

### 3. Work through the day on the VM

Check the machine before typing anything that changes state — today's scripts edit `journald.conf` and move the system clock:

```bash
hostname                         # must print: node1
cd ~/lab/days/day05
```

The Rocky 9 cloud image does not ship chrony, so install today's tools first:

```bash
sudo dnf install -y chrony logrotate
```

`chrony` gives you `chronyd` and `chronyc`; `logrotate` gives the binary and its timer. `logger` and `journalctl` are already there, from `util-linux` and systemd. `setup.sh` checks for all five before it changes anything and stops with this same command if any are missing.

Look at the defaults before you change them — this is the part worth seeing once:

```bash
ls -ld /var/log/journal /run/log/journal 2>&1   # which one exists?
journalctl --list-boots                          # how many boots are remembered?
journalctl --disk-usage
timedatectl
```

On an untouched cloud image `/var/log/journal` does not exist, `--list-boots` prints exactly one line, and that one line is the whole of the machine's memory. Everything from before this boot is already gone.

In this order:

```bash
less scripts/setup.sh            # 1. read it BEFORE running it
sudo ./scripts/setup.sh          # 2. persistent journal, capped, service, rule
```

It prints each step as it goes and ends by showing you the same messages arriving in both systems. If chronyd cannot reach an NTP source it says so rather than pretending — that is a real finding about the VM's network, and `chronyc sources -v` is where you chase it.

```bash
tail -3 /var/log/lab-app/app.log            # 3. the file logrotate owns
journalctl -t lab-noisy -n 3 --no-pager     #    the journal journald owns
```

Same process, same second, two destinations. Almost every argument about "where do the logs go" on a modern machine comes from not noticing both systems are running.

Now the manual checks, by hand. First the dry run:

```bash
sudo logrotate -d /etc/logrotate.d/lab-app
```

Read its output properly and find the line that says whether the log needs rotating and why. `-d` changes nothing, which is what makes it the only safe way to test a rule. That is the first `YOU`.

Then force a real rotation and watch what happens to the file you are tailing:

```bash
sudo /usr/local/bin/lab-noisy burst 1200    # push it past the 100k threshold
sudo logrotate -f /etc/logrotate.d/lab-app
ls -l /var/log/lab-app/
sleep 5; ls -l /var/log/lab-app/            # which one is growing?
```

With `copytruncate` in the rule, `app.log` is the one that grows. `break-and-fix.sh` takes that one line out and shows you the other outcome, which is the second `YOU`.

```bash
./scripts/explore-logs.sh        # 4. the tour
sudo ./scripts/explore-logs.sh   #    again with root - the journal shows more
```

Stop at anything you cannot explain and read `man 5 journald.conf`, `man 8 logrotate` or `man 1 chronyc` on the VM.

```bash
sudo ./scripts/break-and-fix.sh          # 5. three failures, three fixes
sudo ./scripts/break-and-fix.sh --hard   # 6. the two nobody checks for
```

Failure 1 is the one to slow down on: it prints the two file sizes side by side, three seconds apart, and then shows you `/proc/<pid>/fd/3` still pointing at the renamed inode. That is the same technique you used to find the ghost file on Day 04, applied to a problem that looks completely different. Note that `--hard` moves the system clock forward two hours and hands it back to chronyd at the end; if this VM has no outbound NTP the clock may need `sudo date -s` by hand afterwards.

### 4. Check yourself

```bash
cd ~/lab
./days/day05/verify.sh
```

Expect **5 PASS, 2 YOU, exit 0**. No `sudo` needed. The two `YOU` lines are yours to judge honestly: nothing can prove you read the dry run, or that you watched the wrong file grow rather than taking this page's word for it.

### 5. Prove it holds across a reboot

This is the whole point of persistence, and it is the one thing on this page you cannot verify any other way — a journal that is persistent until the next boot is just a journal.

```bash
hostname                         # must still print: node1
journalctl -t lab-noisy -n 1 --no-pager   # note this timestamp
sudo reboot
```

The SSH session drops. Wait about thirty seconds, then from your laptop:

```bash
./lab/lab.sh ssh node1
```

And back on the VM:

```bash
journalctl --list-boots                   # now MORE than one line
journalctl -b -1 -t lab-noisy | tail -3   # the entries from before the reboot
journalctl -b -1 -p err                   # errors from the previous boot
systemctl is-active lab-noisy.service     # started itself again
tail -2 /var/log/lab-app/app.log
timedatectl                               # clock still correct, still synchronised
```

Three things are worth noticing. `journalctl -b -1` works at all — before today it would have said the boot ID has no effect, because there was nothing older than the current boot to look at. The service came back because it was **enabled**, not because it was running when you rebooted. And the clock is right immediately on boot, which is chronyd starting early and correcting it, not the hardware clock being trustworthy — a VM's hardware clock drifts and nothing about `date` alone would have survived.

### 6. Optional cleanup

```bash
sudo ./scripts/teardown.sh
```

You do not have to. Nothing in Days 06-20 conflicts with `lab-noisy` or `/var/log/lab-app`. Teardown exists so that "create, inspect, remove, prove it is gone" is a complete loop — and it deliberately leaves the journal, its persistence and its cap alone, because those are a machine improvement rather than this day's mess, and every later day reads logs. Run it and then `journalctl -t lab-noisy | tail`: the service is gone and its history is still there, which is the difference between the two systems in one command.

To give the RAM back to your laptop when you are done for the day:

```bash
./lab/lab.sh down node1          # deletes the VM and its disk
```

The base image stays cached, so `up` next time takes a minute, not a download. Note that this deletes the persistent journal along with the disk, so if you want to see `journalctl -b -1` work, do step 5 before you do this.

## Notes

Keep your own notes here. What broke, what the error actually said, and what fixed it — that is the part you will come back for.

---

Next up: **Day 06 — Interfaces, routing and building the namespace lab.**
