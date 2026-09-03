# Day 09 — Packet-level debugging

> Prove where a packet stops, instead of guessing.

| | |
|---|---|
| **Phase** | The network |
| **Runs on** | Host: network namespaces |
| **Memory** | 0 MB (no VM at all) |
| **Verified by** | lint + CI |

## Why this day exists

When two hosts disagree about whether traffic arrived, only a capture settles it. This day is the one you will reuse most.

## What you will work with

- `tcpdump -ni, -w, host/port filters`
- `ss -tulpn, ss -s`
- `ping vs traceroute vs mtr`
- `ip route get`
- `MTU and path MTU discovery`
- `conntrack basics`

## Verify

Checked automatically:

- [ ] tcpdump can capture on a router interface
- [ ] the capture contains packets
- [ ] ss reports the DNS listener
- [ ] ip route get names the outgoing interface

Only you can confirm:

- [ ] you attributed a dropped packet to a specific hop
- [ ] you lowered an MTU, broke a transfer, and diagnosed it from the capture

Run the automatic checks with:

```bash
./days/day09/verify.sh
```

A GitHub runner can build this environment for real, so CI executes `verify.sh` on every push once `scripts/setup.sh` exists.

## Scripts for today

Put your work in `days/day09/scripts/`. If you add a `scripts/setup.sh` that builds this day’s environment from nothing, it becomes the entry point for both re-running the day and for CI.

## Notes

Keep your own notes here. What broke, what the error actually said, and what fixed it — that is the part you will come back for.

---

Next up: **Day 10 — TLS on the wire and a private CA.**
