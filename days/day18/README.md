# Day 18 — Bridges, VLANs and link aggregation

> Segment one wire into isolated networks, then prove the isolation.

| | |
|---|---|
| **Phase** | Production operations |
| **Runs on** | Host: network namespaces |
| **Memory** | 0 MB (no VM at all) |
| **Verified by** | lint + CI |

## Why this day exists

Every hypervisor and every switch does this. It is also how you explain to yourself why two machines on the same cable cannot see each other.

## What you will work with

- `ip link add type bridge, brctl show`
- `ip link add link eth0 type vlan id 10`
- `bridge vlan show, tagged vs untagged`
- `ip link add type bond`
- `forwarding and STP basics`
- `testing isolation with ping`

## Verify

Checked automatically:

- [ ] a bridge exists in the router namespace
- [ ] a VLAN interface with a tag exists
- [ ] two hosts in the same VLAN can reach each other
- [ ] a host in a different VLAN cannot
- [ ] the bridge has interfaces enslaved to it

Only you can confirm:

- [ ] you can explain tagged versus untagged from the bridge vlan output

Run the automatic checks with:

```bash
./days/day18/verify.sh
```

A GitHub runner can build this environment for real, so CI executes `verify.sh` on every push once `scripts/setup.sh` exists.

## Scripts for today

Put your work in `days/day18/scripts/`. If you add a `scripts/setup.sh` that builds this day’s environment from nothing, it becomes the entry point for both re-running the day and for CI.

## Notes

Keep your own notes here. What broke, what the error actually said, and what fixed it — that is the part you will come back for.

---

Next up: **Day 19 — Intrusion detection and audit alerting.**
