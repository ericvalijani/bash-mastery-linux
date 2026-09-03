# Day 13 — SELinux: contexts, booleans and denial triage

> Serve content from a non-default path with SELinux still enforcing.

| | |
|---|---|
| **Phase** | Hardening and configuration management |
| **Runs on** | VM: node1 |
| **Memory** | ~1 GB (one VM) |
| **Verified by** | lint + your lab |

## Why this day exists

This is the day that separates operators from people who type setenforce 0. Denial triage is a procedure, and once you know it, SELinux stops being an obstacle.

## What you will work with

- `getenforce, sestatus, setenforce`
- `ls -Z, ps -Z, id -Z`
- `semanage fcontext -a -t, restorecon`
- `chcon vs semanage (temporary vs permanent)`
- `getsebool -a, setsebool -P`
- `ausearch -m avc -ts recent, audit2allow, sealert`

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
- [ ] you built that module from a real AVC with audit2allow and read it before loading

Run the automatic checks with:

```bash
./days/day13/verify.sh
```

CI can only lint this day. Nothing on a GitHub runner has SELinux, firewalld, systemd units you control, or a second host to reach over SSH — so the checks below are proven by running `verify.sh` on your own lab, and nowhere else.

## Scripts for today

Put your work in `days/day13/scripts/`. If you add a `scripts/setup.sh` that builds this day’s environment from nothing, it becomes the entry point for both re-running the day and rebuilding a broken lab.

## Notes

Keep your own notes here. What broke, what the error actually said, and what fixed it — that is the part you will come back for.

---

Next up: **Day 14 — Ansible fundamentals.**
