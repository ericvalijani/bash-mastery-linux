# Day 05 — Logs and time: journald, logrotate and chrony

> Make logs persistent, bounded, and correctly timestamped.

| | |
|---|---|
| **Phase** | The host |
| **Runs on** | VM: node1 |
| **Memory** | ~1 GB (one VM) |
| **Verified by** | lint + your lab |

## Why this day exists

Every diagnosis in Days 6-20 is log reading. Unbounded logs fill the disk; wrong clocks make correlation across hosts impossible.

## What you will work with

- `journalctl -u, -b, -p, --since, -f`
- `/etc/systemd/journald.conf`
- `Storage=persistent, SystemMaxUse=`
- `logrotate.d and logrotate -d`
- `chronyc sources / tracking`
- `timedatectl`

## Verify

Checked automatically:

- [ ] the journal is persistent across reboots
- [ ] journal size is bounded
- [ ] the clock is synchronised
- [ ] the timezone is set deliberately
- [ ] a logrotate rule exists for your own log

Only you can confirm:

- [ ] logrotate -d showed your rule doing what you intended

Run the automatic checks with:

```bash
./days/day05/verify.sh
```

CI can only lint this day. Nothing on a GitHub runner has SELinux, firewalld, systemd units you control, or a second host to reach over SSH — so the checks below are proven by running `verify.sh` on your own lab, and nowhere else.

## Scripts for today

Put your work in `days/day05/scripts/`. If you add a `scripts/setup.sh` that builds this day’s environment from nothing, it becomes the entry point for both re-running the day and rebuilding a broken lab.

## Notes

Keep your own notes here. What broke, what the error actually said, and what fixed it — that is the part you will come back for.

---

Next up: **Day 06 — Interfaces, routing and building the namespace lab.**
