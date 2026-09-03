# Day 08 — Running DNS: authoritative and recursive

> Serve your own zone, then resolve it recursively from another namespace.

| | |
|---|---|
| **Phase** | The network |
| **Runs on** | Host: network namespaces |
| **Memory** | 0 MB (no VM at all) |
| **Verified by** | lint + CI |

## Why this day exists

Reading DNS is one skill; owning a zone is another. Days 10, 12 and 17 all need names that resolve to your own machines.

## What you will work with

- `unbound or bind in a namespace`
- `a zone file: SOA, NS, A, CNAME`
- `authoritative vs recursive`
- `dig SOA / NS / ANY`
- `TTL and negative caching`
- `ss -ulpn to see the listener`

## Verify

Checked automatically:

- [ ] something is listening on port 53 in the auth namespace
- [ ] the zone answers with a SOA
- [ ] an A record resolves from the client
- [ ] the resolver namespace also answers for the zone
- [ ] an unknown name returns NXDOMAIN not an error

Only you can confirm:

- [ ] you lowered a TTL and watched the cache expire

Run the automatic checks with:

```bash
./days/day08/verify.sh
```

A GitHub runner can build this environment for real, so CI executes `verify.sh` on every push once `scripts/setup.sh` exists.

## Scripts for today

Put your work in `days/day08/scripts/`. If you add a `scripts/setup.sh` that builds this day’s environment from nothing, it becomes the entry point for both re-running the day and for CI.

## Notes

Keep your own notes here. What broke, what the error actually said, and what fixed it — that is the part you will come back for.

---

Next up: **Day 09 — Packet-level debugging.**
