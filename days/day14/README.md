# Day 14 — Ansible fundamentals

> Replace one day of manual work with a playbook that is safe to run twice.

| | |
|---|---|
| **Phase** | Hardening and configuration management |
| **Runs on** | control -> node1 |
| **Memory** | ~1.8 GB (two VMs) |
| **Verified by** | lint + your lab |

## Why this day exists

You have now configured hosts by hand for thirteen days. This is the day that work becomes repeatable, and idempotency stops being a buzzword.

## What you will work with

- `inventory: INI and YAML`
- `ansible -m ping, ansible-inventory --list`
- `ansible-playbook --check --diff`
- `modules: package, service, copy, template, user, lineinfile`
- `handlers and notify`
- `variables, group_vars, host_vars`

## Verify

Checked automatically:

- [ ] the inventory parses
- [ ] node1 answers a ping module
- [ ] the playbook has valid syntax
- [ ] a first run completes with no failures
- [ ] a second run changes nothing

Only you can confirm:

- [ ] --check predicted the same changes the real run made
- [ ] you can explain which module was not idempotent and why

Run the automatic checks with:

```bash
./days/day14/verify.sh
```

CI can only lint this day. Nothing on a GitHub runner has SELinux, firewalld, systemd units you control, or a second host to reach over SSH — so the checks below are proven by running `verify.sh` on your own lab, and nowhere else.

## Scripts for today

Put your work in `days/day14/scripts/`. If you add a `scripts/setup.sh` that builds this day’s environment from nothing, it becomes the entry point for both re-running the day and rebuilding a broken lab.

## Notes

Keep your own notes here. What broke, what the error actually said, and what fixed it — that is the part you will come back for.

---

Next up: **Day 15 — Ansible roles: your hardening baseline.**
