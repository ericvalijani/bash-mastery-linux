# Day 20 — Backup, restore and the restore drill

> Prove you can get the data back, on a schedule, and know how long it takes.

| | |
|---|---|
| **Phase** | Production operations |
| **Runs on** | VM: control + node1 |
| **Memory** | ~3 GB (two VMs) |
| **Verified by** | lint + your lab |

## Why this day exists

An untested backup is a rumour. This is the last day because it is the one that decides whether everything before it was worth configuring.

## What you will work with

- `restic init / backup / snapshots`
- `restic restore --target, restic check`
- `retention: forget --keep-daily --prune`
- `systemd timers vs cron`
- `repository password handling`
- `diff -r to verify a restore`

## Verify

Checked automatically:

- [ ] the repository exists and is readable
- [ ] at least one snapshot exists
- [ ] the repository passes an integrity check
- [ ] a restore reproduces the source tree exactly
- [ ] backups run on a timer
- [ ] the timer has actually fired at least once
- [ ] a retention policy is configured

Only you can confirm:

- [ ] you timed a full restore and can state the number in minutes
- [ ] the repository password is not stored next to the repository

Run the automatic checks with:

```bash
./days/day20/verify.sh
```

CI can only lint this day. Nothing on a GitHub runner has SELinux, firewalld, systemd units you control, or a second host to reach over SSH — so the checks below are proven by running `verify.sh` on your own lab, and nowhere else.

## Scripts for today

Put your work in `days/day20/scripts/`. If you add a `scripts/setup.sh` that builds this day’s environment from nothing, it becomes the entry point for both re-running the day and rebuilding a broken lab.

## Notes

Keep your own notes here. What broke, what the error actually said, and what fixed it — that is the part you will come back for.

---

That is the curriculum. There is no capstone by design — the lab itself was the project, and it is still running.
