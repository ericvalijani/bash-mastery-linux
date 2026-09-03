# Day 11 — firewalld, and the nftables underneath it

> Close everything, open only what you need, and see the kernel rules your commands produced.

| | |
|---|---|
| **Phase** | Hardening and configuration management |
| **Runs on** | VM: node1 |
| **Memory** | ~1 GB (one VM) |
| **Verified by** | lint + your lab |

## Why this day exists

Most people learn the front end and never look underneath, so they cannot debug it when the front end lies. Look at both.

## What you will work with

- `firewall-cmd --list-all, --zone`
- `--add-port / --add-service, --permanent, --reload`
- `rich rules`
- `nft list ruleset`
- `nft chains, hooks and priorities`
- `ss -tulpn to confirm exposure`

## Verify

Checked automatically:

- [ ] firewalld is running and enabled
- [ ] your service port is open
- [ ] the rule is permanent, not runtime only
- [ ] firewalld built a real nftables table
- [ ] the default zone is not trusted

Only you can confirm:

- [ ] you reloaded and the rules survived, and you can point to each chain

Run the automatic checks with:

```bash
./days/day11/verify.sh
```

CI can only lint this day. Nothing on a GitHub runner has SELinux, firewalld, systemd units you control, or a second host to reach over SSH — so the checks below are proven by running `verify.sh` on your own lab, and nowhere else.

## Scripts for today

Put your work in `days/day11/scripts/`. If you add a `scripts/setup.sh` that builds this day’s environment from nothing, it becomes the entry point for both re-running the day and rebuilding a broken lab.

## Notes

Keep your own notes here. What broke, what the error actually said, and what fixed it — that is the part you will come back for.

---

Next up: **Day 12 — SSH hardening, bastions and fail2ban.**
