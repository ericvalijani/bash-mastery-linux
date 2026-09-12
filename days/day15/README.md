# Day 15 — Ansible roles: your hardening baseline

> Turn Days 11-13 into one role and apply it to a host that has never been touched.

| | |
|---|---|
| **Phase** | Hardening and configuration management |
| **Runs on** | control -> node1 + node2 |
| **Memory** | ~3.8 GB (three VMs) |
| **Verified by** | lint + your lab |

## Why this day exists

A baseline you can apply to a fresh machine in one command is the whole point of configuration management. node2 is the proof, because it starts clean.

## What you will work with

- `ansible-galaxy init roles/hardening`
- `tasks, handlers, defaults, templates, files`
- `role dependencies and tags`
- `ansible-vault for secrets`
- `--limit and --tags`
- `drift detection with --check`

## Verify

Checked automatically:

- [ ] the role has the standard layout
- [ ] it applies to both nodes without failures
- [ ] a second run is a no-op on both
- [ ] node2 ends up enforcing SELinux too
- [ ] node2 ends up with password auth disabled

Only you can confirm:

- [ ] you broke a setting on node1 by hand and --check found the drift
- [ ] secrets live in vault, not in the repo

Run the automatic checks with:

```bash
./days/day15/verify.sh
```

CI can only lint this day. Nothing on a GitHub runner has SELinux, firewalld, systemd units you control, or a second host to reach over SSH — so the checks below are proven by running `verify.sh` on your own lab, and nowhere else.

## Scripts for today

Put your work in `days/day15/scripts/`. If you add a `scripts/setup.sh` that builds this day’s environment from nothing, it becomes the entry point for both re-running the day and rebuilding a broken lab.

## Notes

Keep your own notes here. What broke, what the error actually said, and what fixed it — that is the part you will come back for.

---

Next up: **Day 16 — WireGuard: a private network between hosts.**
