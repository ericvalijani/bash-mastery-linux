# Day 19 — Intrusion detection and audit alerting

> Notice an attack and a file change without watching the screen.

| | |
|---|---|
| **Phase** | Production operations |
| **Runs on** | VM: node1 |
| **Memory** | ~1 GB (one VM) |
| **Verified by** | lint + your lab |

## Why this day exists

Hardening stops the easy attempts. Detection is what tells you about the rest, and auditd is the tool that answers who changed this file.

## What you will work with

- `suricata -T, /etc/suricata/suricata.yaml`
- `eve.json and jq`
- `custom rules and sid numbering`
- `auditctl -w, -k, /etc/audit/rules.d/`
- `ausearch -k, aureport`
- `journald and forwarding`

## Verify

Checked automatically:

- [ ] suricata config passes its own test
- [ ] suricata is running and enabled
- [ ] at least one alert has been written
- [ ] auditd watches a sensitive file
- [ ] the audit rule is persistent
- [ ] an audit event was actually recorded

Only you can confirm:

- [ ] you triggered your own rule on purpose and found the alert
- [ ] you tuned out one false positive and can justify it

Run the automatic checks with:

```bash
./days/day19/verify.sh
```

CI can only lint this day. Nothing on a GitHub runner has SELinux, firewalld, systemd units you control, or a second host to reach over SSH — so the checks below are proven by running `verify.sh` on your own lab, and nowhere else.

## Scripts for today

Put your work in `days/day19/scripts/`. If you add a `scripts/setup.sh` that builds this day’s environment from nothing, it becomes the entry point for both re-running the day and rebuilding a broken lab.

## Notes

Keep your own notes here. What broke, what the error actually said, and what fixed it — that is the part you will come back for.

---

Next up: **Day 20 — Backup, restore and the restore drill.**
