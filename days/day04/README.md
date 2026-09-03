# Day 04 — Storage: LVM, filesystems and mount units

> Grow a filesystem while it is mounted, and mount it persistently.

| | |
|---|---|
| **Phase** | The host |
| **Runs on** | VM: node1 + extra disk |
| **Memory** | ~1 GB (one VM) |
| **Verified by** | lint + CI |

## Why this day exists

Disk full at 3am is the most common page in operations. Growing storage without downtime is the fix, and it should be boring.

## What you will work with

- `lsblk, blkid, pvcreate, vgcreate, lvcreate`
- `lvextend, resize2fs / xfs_growfs`
- `mkfs.xfs, mkfs.ext4`
- /etc/fstab vs .mount units
- `df -h vs du -sh`
- `lsof +L1 for deleted-but-open files`

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
./days/day04/verify.sh
```

A GitHub runner can build this environment for real, so CI executes `verify.sh` on every push once `scripts/setup.sh` exists.

## Scripts for today

Put your work in `days/day04/scripts/`. If you add a `scripts/setup.sh` that builds this day’s environment from nothing, it becomes the entry point for both re-running the day and for CI.

## Notes

Keep your own notes here. What broke, what the error actually said, and what fixed it — that is the part you will come back for.

---

Next up: **Day 05 — Logs and time: journald, logrotate and chrony.**
