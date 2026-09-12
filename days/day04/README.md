# Day 04 — Storage: LVM, filesystems and mount units

> Grow a filesystem while it is mounted, and mount it persistently.

| | |
|---|---|
| **Phase** | The host |
| **Runs on** | VM: node1 + extra disk |
| **Memory** | ~2 GB (one VM) |
| **Verified by** | lint + CI |

## Why this day exists

Disk full at 3am is the most common page in operations.

The fix is almost never "delete something". It is either a volume that can be grown without downtime, or a file that is already deleted and still costing you every block it ever used. Today you build the first, and then create the second on purpose so you recognise it the next time `df` and `du` disagree by 200 MB and nobody can find the files.

The volume starts at 512 MB deliberately. Storage you cannot grow while it is in use is storage that will eventually cost you an outage window.

## What you will work with

- `lsblk` and `blkid` - the two questions you ask a machine you have never seen before. `lsblk` draws the tree: which disks exist, which are partitioned, which carry logical volumes, what is mounted where. `blkid` reads the signature at the very start of a device and tells you what filesystem is there. A device with no `blkid` output is blank, and that is the only safe thing to hand to LVM — every destructive storage mistake starts with being wrong about which device was empty.
- `pvcreate`, `vgcreate`, `lvcreate` - the three LVM layers, in order, and people blur them constantly. A **physical volume** is a disk given to LVM. A **volume group** is one or more PVs pooled together. A **logical volume** is a slice of that pool, and it is the only one of the three you ever put a filesystem on. `pvs`, `vgs` and `lvs` report on each layer, and `vgs` has the number that matters most: `VFree`, the headroom you actually have.
- `lvextend` plus `resize2fs` / `xfs_growfs` - **two commands, always**. `lvextend` makes the container bigger; the filesystem inside it does not notice and will not find out on its own. Run only the first and `df` reports the old size forever, which reads convincingly as "lvextend did nothing". Note the difference in what they take: `resize2fs` wants the **device**, `xfs_growfs` wants the **mount point**.
- `mkfs.ext4` versus `mkfs.xfs` - both grow while mounted, which is the property that matters today. Only ext4 can shrink, and only while unmounted; xfs can never shrink at all. Rocky defaults to xfs, so on a real RHEL-family machine "make it smaller" means a new volume and a copy. This day uses ext4 so you can watch a shrink be refused for a reason worth understanding.
- `/etc/fstab` versus `.mount` units - the same job, two contracts. `fstab` is the old one, and systemd silently generates units from it at boot anyway (`systemd-fstab-generator`). Writing the unit yourself gets you `After=`, `Requires=` and `WantedBy=`. The catch is that a `.mount` unit's **filename is derived from the path** and is not a free choice: `/srv/data` must be `srv-data.mount`. Name it anything else and systemd ignores the file completely, with no error naming the cause.
- `df -h` versus `du -sh` - they answer different questions and are only equal by coincidence. `df` asks the filesystem how many blocks are spent. `du` walks the directory tree and adds up files that still have a name. When they disagree, `df` is right and `du` is not lying — there are blocks in use belonging to files with no name left.
- `lsof +L1` - the tool that finds those files. `+L1` means "link count below 1": deleted, but still open by a running process, so the kernel cannot release the blocks. The fix is never `rm`, because there is nothing left to remove — you restart or signal whatever holds the descriptor. This is why the advice for a log filling a disk is `: > file` rather than `rm file`.

## Verify

Checked automatically:

- [ ] the volume group labvg exists
- [ ] a logical volume labdata exists in it
- [ ] it is mounted at /srv/data
- [ ] the mount is persistent
- [ ] the filesystem fills the logical volume after extending

Only you can confirm:

- [ ] you extended it live, with no unmount, and watched df change
- [ ] you found a deleted-but-still-open file with lsof +L1

Run the automatic checks with:

```bash
sudo ./days/day04/verify.sh
```

Root is required today, as it was on Day 02. `vgs` and `lvs` refuse to report on volume groups for an unprivileged user, so without root the first two checks fail for want of permission while the two mount checks pass — `/proc/mounts` is world-readable. That combination reads convincingly as "my LVM is broken" when nothing is broken at all, so `verify.sh` requires root and prints `SKIP` for everything instead. `SKIP` is not a pass.

**Run it on node1, not on your laptop.** Nothing inside `verify.sh` checks which machine you are on, so on your laptop it runs anyway and reports `FAIL` for a volume group that was never meant to exist there. Red on the wrong machine means "wrong machine", not "wrong work". Be careful with the last check in particular: `the filesystem fills the logical volume after extending` only asks whether `df` prints a number for `/srv/data`, so if you happen to have any `/srv/data` at all it will report `PASS` without ever looking at LVM. It is the weakest check in this day, and it is listed as a known weakness in `docs/HANDOFF.md` rather than quietly presented as proof.

CI runs this day for real. Unlike Days 01–03, a GitHub runner can build this environment: LVM, a filesystem and a mount unit need no hardware, no second host and no SELinux. So `lab/ci-day.sh 04` executes `scripts/setup.sh` and then `verify.sh` on every push. The runner has no spare disk, so it gets the loop-device path described below — which is the same LVM, on a block device the kernel builds out of a file.

## Scripts for today

| Script | What it does | Root? |
|---|---|---|
| `lab-writer.sh` | The payload. Fills a directory with real (non-sparse) files, or deletes a file while holding it open so you can hunt it with `lsof`. Installed as `/usr/local/bin/lab-writer`. | no |
| `setup.sh` | Finds a spare disk or falls back to a loop device, then builds `labvg`, a 512 MB `labdata`, an ext4 filesystem, and `srv-data.mount`. Idempotent, and never reformats an existing filesystem. | yes |
| `explore-storage.sh` | Read-only guided tour: block devices, the three LVM layers, `df` against `du`, the mount described three ways, and the room left to grow. Runs without root; two blocks show more with it and say so. | no |
| `break-and-fix.sh` | Three storage failures, each repaired: a volume grown without its filesystem, a mount unit systemd ignores, and a full disk whose files cannot be found. `--hard` adds an exhausted volume group and a refused shrink. | yes |
| `teardown.sh` | Unmounts, removes the unit, the LV, the VG and the PV in the order that works, detaches the loop device, and proves each is gone. | yes |

Read them before you run them. They are commented as teaching material rather than production code — the comments are half the day.

## Run it on the lab

### 1. On your laptop, bring up node1

Day 04 runs on **`node1`**, the same VM as Days 02 and 03, and it needs something Days 02 and 03 did not: a second disk.

```bash
./lab/lab.sh status              # what is already running?
./lab/lab.sh up node1            # 2 GB, about a minute
./lab/lab.sh add-disk node1 2    # a blank 2 GB disk, appears as /dev/vdb
```

`add-disk` attaches the disk persistently, so it is still there after a reboot — which step 5 depends on. Nothing today conflicts with Days 02 or 03, so `appsvc` and `lab-cap` can stay.

If you skip `add-disk`, `setup.sh` still works: it falls back to a loop device built from a sparse file, and says loudly that it did. That is real LVM on a real block device, but a loop device does not survive a reboot, so **step 5 cannot be done that way**. Use the real disk if you can.

### 2. Copy the repo onto the VM

```bash
./lab/lab.sh push node1          # carries both days/ and lab/
./lab/lab.sh ssh node1
```

Both directories have to travel: the day scripts source `lab/on-lab-vm.sh`, and without it every one of them refuses to run.

### 3. Work through the day on the VM

As always the day page names the machine. Check it before typing anything that changes state — and today that matters more than on any previous day, because these scripts write filesystem signatures:

```bash
hostname                         # must print: node1
cd ~/lab/days/day04
```

The Rocky 9 cloud image is minimal and has none of today's tools, so install them first:

```bash
sudo dnf install -y lvm2 e2fsprogs lsof
```

`lvm2` gives you `pvs`, `vgs`, `lvs` and `lvextend`; `e2fsprogs` gives `mkfs.ext4` and `resize2fs`; `lsof` is needed for the second manual check. `setup.sh` checks for all of them before it touches a disk and stops with this same command if any are missing — it will not create a volume group it cannot then put a filesystem on.

If you recreated the VM since last time, note what `./lab/lab.sh down node1` took with it: the VM's own disk **and** the extra disk from `add-disk`. So a rebuilt `node1` has no `lvm2`, no `/dev/vdb`, no `labvg` and no `/srv/data` — `pvs`, `vgs` and `lvs` print nothing at all, and `systemctl cat srv-data.mount` reports no such unit. That is a blank machine, not a broken one. Install the packages above, run `add-disk` again from your laptop, and start this step from the top.

Find out what you are working with before you build anything:

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS   # /dev/vdb, 2G, no FSTYPE
sudo blkid /dev/vdb              # prints nothing. that is what blank means
```

In this order:

```bash
less scripts/setup.sh            # 1. read it BEFORE running it
sudo ./scripts/setup.sh          # 2. build the volume and mount it
```

It prints which device it chose and why. It refuses any device carrying a signature, a partition table, or a mount, so it cannot eat something you care about. It also never reformats an existing `labdata` — run it twice and the second run reports what is already there.

```bash
sudo pvs; sudo vgs; sudo lvs     # 3. look at your own work, one layer each
df -h /srv/data
systemctl cat srv-data.mount
```

`vgs` shows roughly 1.5 GB of `VFree`: the volume is 512 MB out of a 2 GB group, and that free space is what you are about to grow into.

Now the day itself, by hand, with the filesystem mounted and in use the whole time:

```bash
sudo lvextend -L +512M labvg/labdata
df -h /srv/data                  # UNCHANGED. the volume grew, the fs did not
sudo resize2fs /dev/labvg/labdata
df -h /srv/data                  # now it grew, with nothing unmounted
```

That is the second manual check, and those four commands are the reason this day exists.

```bash
./scripts/explore-storage.sh     # 4. the tour
```

It works without root, but two blocks need it, so run it with `sudo` the first time and read every section. Stop at anything you cannot explain and read `man 8 lvextend`, `man 5 systemd.mount` or `man 8 lsof` on the VM.

```bash
sudo ./scripts/break-and-fix.sh          # 5. three failures, three fixes
sudo ./scripts/break-and-fix.sh --hard   # 6. the two that destroy data
```

The third failure holds a deleted file open and shows you `df`, `du` and `ls` disagreeing about the same 200 MB. Watch all three. `--hard` ends on the sequence that actually destroys filesystems: growing is `lvextend` then `resize2fs`, shrinking is `resize2fs` then `lvreduce`, and getting the shrink order backwards cuts the end off a filesystem that still believes it owns those blocks.

To make the ghost file yourself, in two shells on the VM:

```bash
# shell 1 - it needs to write into /srv/data, which root owns
sudo ./scripts/lab-writer.sh ghost /srv/data 100

# shell 2 - ssh in again from your laptop: ./lab/lab.sh ssh node1
df -h /srv/data                  # the space is gone
du -sh /srv/data                 # du cannot see it
sudo lsof +L1                    # NLINK 0 - there it is
```

`setup.sh` also installs that script as `/usr/local/bin/lab-writer`, so `sudo lab-writer ghost /srv/data 100` works too — but only if `/usr/local/bin` is on your `PATH`, and `sudo` on RHEL-family systems uses its own `secure_path` which often does not include it. Calling the script by path always works, so that is what this page does.

### 4. Check yourself

```bash
cd ~/lab
sudo ./days/day04/verify.sh
```

Expect **5 PASS, 2 YOU, exit 0**. The two `YOU` lines are yours to judge honestly: nothing can prove you watched `df` change, or that you found the deleted file rather than reading about it here.

### 5. Prove it holds across a reboot

A mount that works until the next boot is not a persistent mount. This step needs the real disk from `add-disk` — on a loop device the volume group will be gone and that is expected, not a failure.

```bash
hostname                         # must still print: node1
sudo reboot
```

The SSH session drops. Wait about thirty seconds, then from your laptop:

```bash
./lab/lab.sh ssh node1
```

And back on the VM:

```bash
mountpoint /srv/data             # mounted, with nobody having mounted it
systemctl is-enabled srv-data.mount
df -h /srv/data                  # still the size you grew it to
sudo lvs labvg/labdata
sudo journalctl -u srv-data.mount -b | tail
```

Three things are worth noticing. The mount came back because the unit was **enabled**, not because it was mounted when you rebooted — `mount` alone would not have survived. The filesystem is still the extended size, because `resize2fs` wrote that into the superblock on disk rather than into memory. And LVM found `labvg` on its own before anything tried to mount it, because it scans devices at boot and assembles volume groups from the metadata written on the disks themselves — which is why an LVM disk can be moved to a different machine and still work.

### 6. Optional cleanup

```bash
sudo ./scripts/teardown.sh
```

You do not have to. Nothing in Days 05-20 conflicts with `labvg` or `/srv/data` — Day 20 backs up `/srv/data` and is glad to find it already there. Teardown exists so that "create, inspect, remove, prove it is gone" is a complete loop, and because storage leftovers are expensive: an enabled mount unit for a device that no longer exists can block anything ordered after it at boot.

To give the RAM back to your laptop when you are done for the day:

```bash
./lab/lab.sh down node1          # deletes the VM and its disk
```

The base image stays cached, so `up` next time takes a minute, not a download. Note that `down` removes the extra disk from `add-disk` as well, so `up` gives you a clean VM and you would run `add-disk` again.

## Notes

---

Next up: **Day 05 — Logs and time: journald, logrotate and chrony.**
