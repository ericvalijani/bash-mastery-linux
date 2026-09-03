# Day 07 — The DNS resolution path

> Trace one name lookup through every layer that can answer it.

| | |
|---|---|
| **Phase** | The network |
| **Runs on** | Host: network namespaces |
| **Memory** | 0 MB (no VM at all) |
| **Verified by** | lint + CI |

## Why this day exists

"It is always DNS" is a joke because it is usually true. Knowing which layer answered is the difference between a five minute fix and an afternoon.

## What you will work with

- `getent hosts vs dig`
- `/etc/nsswitch.conf`
- `/etc/hosts`
- `/etc/resolv.conf`
- `systemd-resolved and resolvectl`
- `dig +trace, +short, +norecurse`

## Verify

Checked automatically:

- [ ] nsswitch consults files before dns
- [ ] a hosts entry beats DNS for the same name
- [ ] the client has a nameserver configured
- [ ] dig and getent are both available to compare

Only you can confirm:

- [ ] you can explain why dig ignored /etc/hosts and getent did not
- [ ] you followed one name from application call to authoritative answer

Run the automatic checks with:

```bash
./days/day07/verify.sh
```

A GitHub runner can build this environment for real, so CI executes `verify.sh` on every push once `scripts/setup.sh` exists.

## Scripts for today

Put your work in `days/day07/scripts/`. If you add a `scripts/setup.sh` that builds this day’s environment from nothing, it becomes the entry point for both re-running the day and for CI.

## Notes

Keep your own notes here. What broke, what the error actually said, and what fixed it — that is the part you will come back for.

---

Next up: **Day 08 — Running DNS: authoritative and recursive.**
