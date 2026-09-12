# Day 03 — Processes, signals, cgroups v2 and limits

> Constrain a process so it cannot take the machine down with it.

| | |
|---|---|
| **Phase** | The host |
| **Runs on** | VM: node1 |
| **Memory** | ~2 GB (one VM) |
| **Verified by** | lint + your lab |

## Why this day exists

Containers are cgroups plus namespaces. Meet the primitives directly and container behaviour stops being magic.

Today builds one service that misbehaves on request — it eats memory as fast as bash can allocate it, or burns a whole core — and then holds it to 100 MB and a fifth of one core. Same program, two very different neighbours. Then you hit each cap on purpose and read what the machine says, which is much less than you would expect.

## What you will work with

- `ps -eo pid,ppid,stat,cmd` - the process table with the columns that matter. `STAT` is the one people skip and then guess about: `S` sleeping, `R` running, `D` uninterruptible sleep, `Z` zombie, `T` stopped. A pile of `D` means storage or network is not answering, and no amount of `kill` will help — `D` cannot be interrupted, which is what the name means.
- `kill -TERM` versus `kill -KILL`, and `trap` - `kill` sends a signal, it does not kill. `TERM` asks a process to stop and can be trapped, so the process closes its files and releases its locks first. `KILL` (9) and `STOP` (19) are handled by the kernel and the process is never told, so there is nothing to trap and no cleanup. That is why `kill -9` is not a fix, and why an OOM kill leaves a log ending mid-sentence.
- `/sys/fs/cgroup/` - the unified hierarchy, as files. `memory.max` and `cpu.max` are the caps as the *kernel* stores them, `memory.current` is live usage, and `memory.events` counts `oom_kill`. This is the authority: `systemctl show` tells you what systemd asked for, and these files tell you what is being enforced. When the two disagree, the setting was accepted and silently dropped.
- `systemd-run --scope -p MemoryMax=` - a throwaway cgroup around a command, with no unit file and no `daemon-reload`. The fastest way to find out how much memory something actually needs before you write a cap into a unit, and the fastest way to see a cap kill something you started yourself.
- `systemctl set-property` - changes a cap on a **running** service, immediately, by writing the kernel file directly. The trap is where it writes the persistent copy: `/etc/systemd/system.control/`, not your unit file. After using it, reading the unit file alone will mislead you; `systemctl cat` shows both.
- `ulimit` and `/etc/security/limits.d/` - the *other* limit system, and the one constantly confused with the first. These are per **login session**, applied by `pam_limits` when a user logs in, and inherited by whatever that shell starts. Systemd does not log anybody in to start a service, so `limits.d` has no effect on daemons at all — a unit takes its own `LimitNOFILE=`. That single fact is the most expensive misunderstanding in this day.

## Verify

Checked automatically:

- [ ] cgroups v2 is the unified hierarchy
- [ ] a service is capped with MemoryMax
- [ ] the same service is capped with CPUQuota
- [ ] a nofile limit is raised for one account only

Only you can confirm:

- [ ] you triggered the memory cap and found the kill in the journal
- [ ] you can explain why SIGKILL cannot be trapped

Run the automatic checks with:

```bash
./days/day03/verify.sh
```

No root needed today, unlike Day 02: every check reads state that is world-readable — a mount table, two `systemctl show` properties, and a file in `/etc/security/limits.d/`.

**Run it on node1, not on your laptop.** Nothing inside `verify.sh` checks which machine you are on, so on your laptop it runs anyway and reports `FAIL` for `lab-cap.service` — a service that was never meant to exist there. Red on the wrong machine means "wrong machine", not "wrong work". Worse, `cgroups v2 is the unified hierarchy` reads nothing but the mount table, so it will report `PASS` on any modern Linux: a green line for work you never did. The only results that mean anything are the ones from a shell on the VM.

CI can only lint this day. Nothing on a GitHub runner has SELinux, firewalld, systemd units you control, or a second host to reach over SSH — so the checks below are proven by running `verify.sh` on your own lab, and nowhere else.

## Scripts for today

| Script | What it does | Root? |
|---|---|---|
| `lab-cap.sh` | The service payload. Ticks quietly into the journal and traps SIGTERM, or on request eats 10 MB a second, or burns a core. | no |
| `setup.sh` | Installs the payload and `lab-cap.service` with `MemoryMax=100M` and `CPUQuota=20%`, then the `labworker` account and its own `nofile` limit. Idempotent. | yes |
| `explore-procs.sh` | Read-only guided tour: process states, the tree, signals, the unified hierarchy, this day's cgroup from both sides, and both limit systems. Runs without root; two blocks show more with it and say so. | no |
| `break-and-fix.sh` | Three resource failures, each repaired: an OOM kill, silent CPU throttling, and SIGKILL against a trap. `--hard` adds a limit that is set correctly and ignored, and a cap so low the service cannot start. | yes |
| `teardown.sh` | Removes the unit, both override directories, the payload, the limit file and the account, then proves each is gone. | yes |

Read them before you run them. They are commented as teaching material rather than production code — the comments are half the day.

## Run it on the lab

### 1. On your laptop, bring up node1

Day 03 runs on **`node1`**, the same VM as Day 02. Nothing today conflicts with Day 02, so you can leave `appsvc` and `/srv/shared` in place.

```bash
./lab/lab.sh status              # what is already running?
./lab/lab.sh up node1            # 2 GB, about a minute
```

If `node1` is already up from yesterday, `status` will say so and `up` is a no-op.

### 2. Copy the repo onto the VM

```bash
./lab/lab.sh push node1          # carries both days/ and lab/
./lab/lab.sh ssh node1
```

Both directories have to travel: the day scripts source `lab/on-lab-vm.sh`, and without it every one of them refuses to run.

### 3. Work through the day on the VM

As always the day page names the machine. Check it before typing anything that changes state:

```bash
hostname                         # must print: node1
cd ~/lab/days/day03
```

In this order:

```bash
less scripts/setup.sh            # 1. read it BEFORE running it
sudo ./scripts/setup.sh          # 2. build the capped service
```

It refuses to continue on a machine that is not on the unified hierarchy, and it prints the caps twice — once as systemd reports them, once as the kernel stores them. Those two lists must agree. When they do not, systemd accepted a setting the kernel is not enforcing, and reading both is the habit worth taking from today.

```bash
systemctl cat lab-cap            # 3. look at your own work
systemctl show lab-cap -p MemoryMax -p CPUQuotaPerSecUSec
cat /sys/fs/cgroup/system.slice/lab-cap.service/cpu.max
journalctl -u lab-cap -f         #    ctrl-c when you have seen enough
```

`cpu.max` prints `20000 100000`: 20 ms of CPU per 100 ms, which is the 20% you asked for, expressed the way the kernel stores it.

```bash
sudo ./scripts/explore-procs.sh  # 4. the tour
```

It works without root, but two blocks need it, so run it with `sudo` the first time and read every section. Stop at anything you cannot explain and read `man 5 systemd.resource-control`, `man 7 signal` or `man 5 limits.conf` on the VM — all three are installed.

```bash
sudo ./scripts/break-and-fix.sh          # 5. three failures, three fixes
```

This one takes about a minute of waiting, on purpose. It watches `memory.current` climb second by second until the kernel kills the process, then shows you that the journal ends mid-sentence with no shutdown line. It cannot print one — an OOM kill inside a cgroup is a `SIGKILL`, so the `trap` in `lab-cap.sh` is never reached. The receipt is the `oom_kill` counter in `memory.events`, not the log.

The second failure is the one worth slowing down for. A throttled service reports `active (running)`, logs nothing, fails nothing, and does a fifth of the work. The only place that is visible is `cpu.stat`.

```bash
sudo ./scripts/break-and-fix.sh --hard   # 6. two harder ones
```

The `--hard` pair are the mistakes that cost the most time:

- a `nofile` limit set correctly in `/etc/security/limits.d/`, verified with `su - labworker; ulimit -n`, and completely ignored by the service — because `pam_limits` runs at **login** and systemd never logs anybody in. The setting that applies to a daemon is the unit's `LimitNOFILE=`.
- a cap so low the service cannot start at all, where the error says *start request repeated too quickly* and never mentions memory.

Every override the script makes goes into a drop-in and is removed again, so your unit file is left exactly as `setup.sh` wrote it. Confirm that yourself:

```bash
systemctl cat lab-cap                                     # unit only, no drop-ins
ls /etc/systemd/system/lab-cap.service.d/ 2>/dev/null || echo none
ls /etc/systemd/system.control/ 2>/dev/null || echo none
```

### 4. Check yourself

```bash
./verify.sh
echo "exit: $?"
```

Expected on a healthy Day 03: **4 PASS, 2 YOU, exit 0.** The two `YOU` lines are what this day is actually for — you have seen an OOM kill you caused, and you can say why no amount of trapping would have caught it.

Two things to look at before you move on, because neither is on any dashboard:

```bash
systemctl show lab-cap -p NRestarts
cat /sys/fs/cgroup/system.slice/lab-cap.service/cpu.stat
```

`Restart=on-failure` makes a service that is being killed every ten seconds read as `active (running)`. `NRestarts` is where the truth is, and `throttled_usec` is where a latency complaint with no error in it comes from.

### 5. Prove it holds across a reboot

This matters more today than on either of the previous two days, because Day 03 sets limits through three different mechanisms and they do not all persist the same way. One is a unit file, one is a `limits.d` file that is only read at login, and one — if you used `systemctl set-property` — is a drop-in under a directory you never wrote to by hand.

**Reboot the VM, not your laptop.** Run this while logged in over `./lab/lab.sh ssh node1`, so the shell belongs to the VM:

```bash
hostname                         # must print: node1
sudo reboot                      # your ssh session will drop - that is the point
```

If `hostname` prints your laptop's name, you are in the wrong shell and this would restart your own machine. You can also power-cycle it from the laptop: `virsh reboot node1`.

Then, once it is back:

```bash
./lab/lab.sh ssh node1
systemctl is-enabled lab-cap                                    # enabled
systemctl is-active lab-cap                                     # active
systemctl show lab-cap -p MemoryMax -p CPUQuotaPerSecUSec       # still capped
cat /sys/fs/cgroup/system.slice/lab-cap.service/memory.max      # kernel agrees
su - labworker -c 'ulimit -n'                                   # still raised
systemctl show lab-cap -p NRestarts                             # back to 0
```

Three things worth noticing in that output:

- The cgroup at `/sys/fs/cgroup/.../memory.max` is a **new** one. Cgroups are kernel state and did not survive the reboot — systemd recreated it from the unit file. That is the difference between a limit that is *configured* and a limit that is *in effect*, and a reboot is the cleanest way to see it.
- `NRestarts` is back to `0`. If you were using it to spot a service being killed in a loop, a reboot erases your evidence. The journal does not — `journalctl -u lab-cap -b -1` reads the *previous* boot.
- `ulimit -n` for `labworker` still shows the raised value, because `limits.d` is on disk and `su -` is a login. The service's own limit is still `LimitNOFILE` from the unit, and still a different number. Same reboot, same file, two answers — which is the `--hard` lesson again, from the other side.

### 6. Optional cleanup

```bash
sudo ./scripts/teardown.sh
```

You do not have to. Nothing in Days 04-20 conflicts with `lab-cap` or `labworker`. Run it once anyway, so that "create, inspect, remove, prove it is gone" is a complete loop — and because two of the things it removes are easy to leave behind: a drop-in that survives deleting the unit file, and a file in `limits.d` that applies to every future login of that account.

To give the RAM back to your laptop when you are done for the day:

```bash
./lab/lab.sh down node1          # deletes the VM and its disk
```

The base image stays cached, so `up` next time takes a minute, not a download.

## Notes

Keep your own notes here. What broke, what the error actually said, and what fixed it — that is the part you will come back for.

---

Next up: **Day 04 — Storage: LVM, filesystems and mount units.**
