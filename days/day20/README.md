# Day 20 - Backup, restore and the restore drill

> Prove you can get the data back, on a schedule, and know how long it takes.

| | |
|---|---|
| **Phase** | Production operations |
| **Runs on** | VM: control + node1 |
| **Memory** | ~3.5 GB (two VMs) |
| **Verified by** | lint + your lab |

## Why this day exists

An untested backup is a rumour. This is the last day because it is the one that decides whether everything before it was worth configuring.

Two sentences get said in incidents, and only one of them is useful. "We have backups" is a hope. "A full restore of that dataset took four minutes and I ran it on Tuesday" is an answer. Today you produce the second sentence about your own lab, with a number you measured yourself.

Three ideas people skip, built into the day:

- A backup on the same disk as the data is not a backup. So the repository lives on **control**, and **node1** writes to it over ssh.
- A backup nobody has restored is a rumour. So `setup.sh` finishes by restoring into a scratch tree and comparing it with `diff -r` - and fails if they differ.
- A backup on a schedule is only real once the schedule has fired. So the timer is set up to fire within thirty seconds, and both setup and verify look at `LastTriggerUSec` rather than at `enabled`.

## What you will work with

- `restic init / backup / snapshots / ls / diff` - a content-addressed, deduplicating, encrypted repository
- `restic restore --target` and `diff -r` - the restore drill, and the only proof that matters
- `restic check`, `restic check --read-data` - integrity, which is not the same as the files being present
- `restic forget --keep-daily --keep-weekly --prune` - retention, so the repository does not fill the disk it lives on
- `restic unlock` - clearing a stale lock left by a killed run
- `sftp:user@host:/path` repositories over ssh, with a key instead of a password
- `RESTIC_PASSWORD_FILE` vs `RESTIC_PASSWORD` - why the path is the safe half
- `systemd` timers: `OnCalendar`, `OnActiveSec`, `Persistent`, `AccuracySec`, `list-timers`
- `EnvironmentFile=` - the reason a backup can work by hand and fail on the timer
- `useradd --shell` and why `/sbin/nologin` quietly breaks sftp

## The shape of it

```
  node1                                  control
  +-----------------------------+        +------------------------------+
  | /srv/data          the data |        | user restic, /bin/bash       |
  | /etc/restic/password  0600  |        | /srv/restic/repo       0700  |
  | /etc/restic/env             |        | /srv/restic/.ssh/            |
  | /usr/local/bin/lab-backup   |        |    authorized_keys           |
  | restic-backup.service       |        |                              |
  | restic-backup.timer         | -----> | no restic installed          |
  | /root/.ssh/id_ed25519       |  ssh   | no password, cannot read it  |
  | /var/tmp/restore  the drill |        |                              |
  +-----------------------------+        +------------------------------+
```

The direction matters. node1 pushes to control; control has no key to node1 and no way to read what it stores. If control is compromised, the attacker gets encrypted blobs. If node1 is compromised, the attacker can delete snapshots - which is why the real world adds append-only repositories, and why you should know that this lab does not.

## Scripts for today

| Script | What it does |
|---|---|
| `scripts/setup.sh` | Role-aware. On control: the `restic` user and the repository. On node1: restic, the data, the key, the password, `restic init`, the payload, the unit, the timer, and the first restore drill. |
| `scripts/lab-backup.sh` | Installed as `/usr/local/bin/lab-backup`. Subcommands: `status`, `run`, `snapshots`, `drill`, `check`, `forget`, `unlock`. Also the `ExecStart` of the service. |
| `scripts/explore-backup.sh` | Twelve read-only stops: the repository, dedup, what is inside a snapshot, the unit, the timer, the journal, the restore. Changes nothing. |
| `scripts/break-and-fix.sh` | Four failures, each diagnosed and repaired. `--hard` leaves a fifth for you: green everywhere, and the snapshots are empty. |
| `scripts/teardown.sh` | Role-aware. Removes the timer, unit, payload and restore tree. `--all` also removes the password, the data, and (on control) the repository. |

## The whole day, in order

Everything below is a step, and every step says which host it runs on. Top to bottom, once:

| | Where | Command |
|---|---|---|
| **Step 1** | laptop | `./lab/lab.sh up control node1`, `status`, `push` both, `ssh` both |
| **Step 2** | control | `sudo ./scripts/setup.sh` |
| **Step 3** | node1 | `sudo ./scripts/setup.sh` - prints a key, exits 0 |
| **Step 4** | control | `sudo ./scripts/setup.sh '<the key it printed>'` |
| **Step 5** | node1 | `sudo ./scripts/setup.sh <control-ip>` - the real work |
| **Step 6** | node1 | `sudo lab-backup drill` - the restore drill |
| **Step 7** | node1 | `sudo ./scripts/explore-backup.sh` - read what you built |
| **Step 8** | node1 | `sudo ./scripts/break-and-fix.sh` - four failures |
| **Step 9** | node1 | `sudo ./verify.sh` - 22 checks |
| Optional | node1 | `sudo ./scripts/break-and-fix.sh --hard` - the silent one |
| When done | node1, then control | `sudo ./scripts/teardown.sh` |

**Nothing runs on control except steps 2 and 4.** Control creates the `restic` user, authorises node1's key, and is finished. Every other command today is on node1.

## Step 1 - both VMs, from your laptop

On your laptop, in the repository:

```bash
./lab/lab.sh up control node1            # ~3.5 GB
./lab/lab.sh status                      # read BOTH addresses
./lab/lab.sh push control                # carries days/ and lab/
./lab/lab.sh push node1                  # today runs on both hosts
./lab/lab.sh ssh control
```

Both hosts need the repository today, same as Day 16. `push <vm>` with no path copies `days/` and `lab/`; `push <vm> <path>` copies **only** that one file.

`lab.sh status` prints something like:

```
control   running   192.168.122.108     # EXAMPLE address - use your own
node1     running   192.168.122.134     # EXAMPLE address - use your own
```

Those are examples. DHCP leases move every time a VM is rebuilt, so read them yourself each session rather than copying them from here.

You want **two terminals** for this day - one SSH session per host - because the two setup passes alternate between them. On your laptop, in a second terminal:

```bash
./lab/lab.sh ssh node1
```

## Steps 2 to 5 - setup, in four passes

Setup runs **four times**, alternating hosts, because a public key has to travel between two machines and no single command on one machine can do that. Each pass tells you the next one.

**Step 2, on control:**

```bash
cd ~/lab/days/day20
sudo ./scripts/setup.sh
```

Creates the `restic` user, the repository directory, and stops.

**Step 3, on node1:**

```bash
cd ~/lab/days/day20
sudo ./scripts/setup.sh
```

Installs restic, creates `/srv/data`, generates root's ssh key, prints the exact command to run on control, and exits 0. That exit is not a failure - read what it printed.

**Step 4, on control:** paste the command it printed, key and all:

```bash
sudo ./scripts/setup.sh 'ssh-ed25519 AAAA... root@node1'
```

**Step 5, on node1**, with control's address:

```bash
sudo ./scripts/setup.sh 192.168.122.108
```

That pass does the real work: the password file, the environment file, `restic init`, the payload, the unit, the timer, a wait of up to 90 seconds for the timer to actually fire, and the restore drill. It prints the restore time. Write it down.

Until step 5 finishes there is no `/etc/restic/env` and no `/usr/local/bin/lab-backup`, so `lab-backup` and `explore-backup.sh` will tell you to run setup first. That is the expected answer, not a fault.

If you edit the scripts on your laptop afterwards, push them again before you re-run anything - each VM has its own copy and will happily keep running the old one:

```bash
./lab/lab.sh push control
./lab/lab.sh push node1
```

**Re-running setup after a script change does not need a teardown.** `setup.sh` is written to be run again: it leaves `/srv/data`, `/etc/restic` and root's ssh key alone, and rebuilds the payload, the unit and the timer from the new copy. So one pass on node1 is enough, and control is not involved at all:

```bash
# on node1, with control's address
cd ~/lab/days/day20
sudo ./scripts/setup.sh 192.168.122.108
```

The address is also remembered in `/etc/restic/control-ip`, so `sudo ./scripts/setup.sh` with no argument works too once step 5 has succeeded once. Only tear down when you want the schedule, the data or the repository *gone* - see the last section.

## Step 6 - the drill, on node1

Step 5 already ran this once. Run it again yourself, because this is the part to take seriously:

```bash
sudo lab-backup drill
```

It restores `latest` into `/var/tmp/restore`, times it, runs `diff -r /srv/data /var/tmp/restore/srv/data`, compares the mode of a 0600 file, and writes the number of seconds to `/var/lib/lab-backup/last-restore-seconds`.

Three things it does that a casual restore does not:

- It restores into an **empty** tree every time. Restore on top of last week's restore and a missing file will pass a `diff`.
- It compares, and the comparison decides the exit status. A restore that ran is not a restore that worked.
- It checks permissions. Bytes back with the wrong mode means you just made a secret world-readable during an incident.

## Step 7 - look at what you built, on node1

The read-only tour. It changes nothing, so there is no way to get this wrong:

```bash
sudo ./scripts/explore-backup.sh
```

And the things worth running on their own:

```bash
sudo lab-backup status            # repository, schedule, last run, last restore time
sudo lab-backup snapshots         # what is actually in the repository
sudo lab-backup run               # take a snapshot now, then apply retention
sudo lab-backup check             # integrity of the repository structure
systemctl cat restic-backup.service
systemctl list-timers restic-backup.timer --no-pager
journalctl -u restic-backup.service -n 30 --no-pager
```

The two commands people never run until it is too late:

```bash
sudo lab-backup snapshots         # is there a snapshot at all, and how big
sudo lab-backup drill             # does it come back, and in how long
```

Both of those go through `lab-backup`, which loads the environment for you. `restic` on its own does not have it, and `/etc/restic/env` is 0600 root-only, so `. /etc/restic/env` as your own user gives you `Permission denied` and `restic` then says `Fatal: Please specify repository location`. Load it inside a root shell instead:

```bash
sudo bash -c 'set -a; . /etc/restic/env; set +a; restic snapshots'
sudo bash -c 'set -a; . /etc/restic/env; set +a; restic ls latest | wc -l'
```

Setup also symlinks the payload to `/usr/sbin/lab-backup`. Without that, `sudo lab-backup` reports `command not found` even though `/usr/local/bin/lab-backup` exists and is on your own `PATH` - because `sudo` ignores your `PATH` and uses `secure_path` from `/etc/sudoers`, which on Rocky does not list `/usr/local/bin`. If you are on a host set up before this fix, use the full path: `sudo /usr/local/bin/lab-backup status`.

In `lab-backup status`, read **last run exit**. A `1` there with snapshots in the repository means your backups are only happening when you run them by hand - which is the state this day is about. `journalctl -u restic-backup.service` tells you why in one line.

Two columns in `list-timers` are worth trusting: **LAST** and **NEXT**. `systemctl is-enabled` only promises the timer will start at boot. It says nothing about whether a backup has ever happened.

`lab-backup unlock` is deliberately not in the list above. There is no lock to clear until something is killed mid-write, which is exactly what step 8 does - so the only place you need `unlock` today is failure 4 and the repair that follows it.

One thing to know before step 9: the timer is `OnCalendar=*:0/10`, so a backup starts at every tenth minute of the hour and holds a lock on the repository while it writes - an exclusive one while `forget --prune` runs. That is normal, not a fault. `verify.sh` now waits for a running backup to finish before it touches the repository, so you no longer have to time your own commands around the schedule. If you want the schedule out of the way while you experiment:

```bash
sudo systemctl stop restic-backup.timer      # quiet while you poke at it
sudo systemctl start restic-backup.timer     # put it back when you are done
```

## Step 8 - break it on purpose, on node1

```bash
sudo ./scripts/break-and-fix.sh
```

Four failures, each one shown, diagnosed and repaired:

1. **The password file is gone.** The repository is intact and unreadable, which is the same thing as lost. This is the only failure in the file you cannot fix from this host.
2. **The repository host is unreachable.** A network error wearing a backup error's clothes. Prove the transport with `ssh` before you suspect restic.
3. **It works by hand and fails on the timer.** `EnvironmentFile=` is removed from the unit. Your shell has `RESTIC_REPOSITORY`; systemd does not, and never did.
4. **A stale lock.** A backup is killed mid-write, the lock outlives it, and every run after that refuses. `restic unlock`, never `rm` - and note that plain `unlock` removes only locks it can *prove* are stale. A lock it cannot prove is stale survives, `verify.sh` keeps failing `no stale lock is holding the repository`, and clearing it needs a deliberate `restic unlock --remove-all` once you have checked that nothing is backing up on any host. `sudo lab-backup unlock` does exactly that escalation, and refuses to escalate while `restic-backup.service` is actually running.

Then, when you want the one that teaches the most:

```bash
sudo ./scripts/break-and-fix.sh --hard
```

An exclude pattern swallows `/srv/data`. The service exits 0, a new snapshot appears, the timer is green, and any dashboard you could build from systemd says the backup is healthy. The snapshots contain nothing.

Nothing is hidden - `systemctl cat restic-backup.service`, `cat /etc/restic/exclude` and `restic ls latest` tell you everything. Fix it, then prove the fix with `sudo lab-backup drill` rather than with a green unit. The original unit is kept at `/tmp/day20-broken/restic-backup.service.prehard`.

The full repair by hand. The order is the lesson - the exclude file goes first because the unit is what reads it, and the backup goes last because it is the only thing that puts content back into `latest`:

```bash
sudo rm -f /etc/restic/exclude
sudo install -m 0644 /tmp/day20-broken/restic-backup.service.prehard \
  /etc/systemd/system/restic-backup.service
sudo systemctl daemon-reload
sudo lab-backup unlock && sudo lab-backup run && sudo lab-backup drill
```

All four lines matter, in that order:

1. `rm` the exclude file - while it exists every backup you take is empty, so doing this after the backup fixes nothing.
2. reinstall the saved unit - it is what pointed at the exclude file.
3. `daemon-reload` - until you do, systemd is still holding the broken unit in memory.
4. `unlock && run && drill` - `unlock` clears the lock failure 4 left behind on purpose, `run` writes a snapshot that has content in it, and `drill` is the only line that proves any of it worked.

Restoring the unit alone leaves the empty snapshot as `latest`, so the drill still reports `DIFFERENT - this is what an untested backup looks like` and verify still fails `a restore reproduces the source tree exactly`. **Running `verify.sh` while the day is still broken is supposed to fail** - `18 passed, 4 failed` is the correct score for that state, not a bug.

### When a lock will not go away

`verify.sh` asks about locks before it runs `restic check`, because `check` takes an exclusive lock itself - a lock question asked after it can end up reporting your own check. `sudo lab-backup unlock` prints the contents of each lock first, which names the host and pid that wrote it.

A lock is only removable if nothing owns it. If `no stale lock is holding the repository` stays red **after** an unlock, the lock is not stale - some restic process is still alive and refreshing it every few minutes. One live lock takes three checks down with it, which is why this looks like three unrelated problems:

| Red line | Why the lock does it |
|---|---|
| `no stale lock is holding the repository` | the lock is there |
| `the repository passes an integrity check` | `restic check` needs the repository to itself and refuses |
| `the scheduled service has run and exited 0` | the timer fired, hit the lock, and exited 1 |

So find the owner before you remove anything:

```bash
pgrep -af restic                       # is a backup still running?
sudo pkill -9 -f 'restic backup'       # only once you know it is an orphan
sudo lab-backup unlock                 # now the lock really is stale
sudo lab-backup run && sudo lab-backup check
sudo systemctl start restic-backup.service   # prove the timer path works again
sudo ./verify.sh
```

`restic unlock --remove-all` on a lock that still has a living owner is pointless - the owner takes it again a second later, and on a shared repository you have just let two backups write at once.

If `verify.sh` straight after this repair shows `at least one snapshot exists` or `no stale lock is holding the repository` red, look at `systemctl is-active restic-backup.service` before you suspect the repair. A scheduled run locks the repository, and a locked repository fails both of those checks. Current `verify.sh` waits that out for you.

If you would rather start the day over than repair it, do it **on node1 only**. Both commands below run on node1, and you do not touch control at all - `--hard` only ever changed node1:

```bash
# on node1, in ~/lab/days/day20
sudo ./scripts/setup.sh 192.168.122.108
```

One pass is enough, and no teardown is needed: setup removes the leftover exclude file, clears a stale lock, rewrites the unit and timer, notices if `latest` is empty and takes a snapshot with content in it, then re-runs the drill. Add `sudo ./scripts/teardown.sh` first only if you also want the data and the password gone.

That address is the **argument**, not another host to log into: it is control's IP, which is how node1 is told where the repository lives. Same value you used in step 5, and node1 saved it at `/etc/restic/control-ip` if you have forgotten it - so `sudo ./scripts/setup.sh` with no argument works too.

This is the failure that ends companies. Not a backup that errors - those get noticed. A backup that reports success for eleven months and restores an empty directory.

## Step 9 - verify, on node1

Run on **node1**, with sudo, because the checks read root-only files and talk to the repository with root's key:

```bash
cd ~/lab/days/day20
sudo ./verify.sh
```

If it prints `a scheduled backup is running - waiting for it to finish`, that is the timer rather than a problem: the checks start when the run ends.

Checked automatically:

- [ ] the repository environment file exists and is root-only
- [ ] the repository is on another host, not this one
- [ ] the environment names a password file, not a password
- [ ] the password file exists and is 0600 root:root
- [ ] the data being protected still exists
- [ ] the repository exists and is readable
- [ ] at least one snapshot exists
- [ ] the repository passes an integrity check
- [ ] the latest snapshot contains the data path
- [ ] the latest snapshot is not empty
- [ ] no stale lock is holding the repository
- [ ] the backup payload is installed and executable
- [ ] a retention policy is configured
- [ ] the retention policy prunes, not just forgets
- [ ] the backup service unit exists
- [ ] the unit carries the repository in its own environment
- [ ] the scheduled service has run and exited 0
- [ ] backups run on a timer
- [ ] the timer is loaded and running right now
- [ ] the timer has actually fired at least once
- [ ] a restore reproduces the source tree exactly
- [ ] the restore preserved file permissions

Only you can confirm:

- [ ] you timed a full restore and can state the number in minutes
- [ ] the repository password is not stored next to the repository

CI can only lint this day. Nothing on a GitHub runner has SELinux, firewalld, systemd units you control, or a second host to reach over SSH - so the checks above are proven by running `verify.sh` on your own lab, and nowhere else.

## When you are done - tear it down

Two hosts, so there are two teardowns, and the order matters if you want the repository gone: node1 first, control second.

**On node1** - removes the timer, the unit, `/usr/local/bin/lab-backup`, the exclude file, `/var/tmp/restore`, `/var/lib/lab-backup` and `/tmp/day20-broken`:

```bash
sudo ./scripts/teardown.sh
```

It deliberately keeps `/etc/restic` and `/srv/data`. Delete the password and every snapshot on control becomes unreadable, so that needs the flag:

```bash
sudo ./scripts/teardown.sh --all      # also deletes /etc/restic and /srv/data
```

**On control** - nothing happens without `--all`, because the repository is the only copy of the data:

```bash
sudo ./scripts/teardown.sh            # prints what exists, changes nothing
sudo ./scripts/teardown.sh --all      # deletes /srv/restic and the restic user
```

To rebuild afterwards, you are back to the full four passes - the key exchange has to happen again. Or just delete both VMs from your laptop, which is faster and takes the disks with them:

```bash
./lab/lab.sh down control node1      # deletes both VMs and their disks
```

## Notes

Keep your own notes here. What broke, what the error actually said, and what fixed it - that is the part you will come back for.

Things this day deliberately leaves unfinished, so you know they exist:

- **Append-only repositories.** node1 can delete snapshots it wrote. Real setups use `rest-server --append-only` or a storage backend with object lock, so ransomware on the client cannot erase the backups.
- **Off-host password custody.** The password lives only on node1. Lose that host completely and the repository is landfill. In production the password goes in a password manager or a KMS, not next to the machine it protects.
- **`restic check --read-data`.** Today's check verifies structure. Reading every byte back is the only version that catches storage silently returning the wrong data, and it is slow enough to schedule weekly rather than hourly.
- **Monitoring the absence of backups.** Nothing here pages you when the timer stops firing. `OnFailure=`, a dead-man's-switch ping, or a check on snapshot age are each one small unit away.

---

That is the curriculum. There is no capstone by design - the lab itself was the project, and it is still running.
