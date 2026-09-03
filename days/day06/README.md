# Day 06 — Interfaces, routing and building the namespace lab

> Build a four-node routed network inside your kernel and prove packets cross it.

| | |
|---|---|
| **Phase** | The network |
| **Runs on** | Host: network namespaces |
| **Memory** | 0 MB (no VM at all) |
| **Verified by** | lint + CI |

## Why this day exists

This is real kernel networking, not a simulation: real interfaces, real routing tables, real packets. It is also the environment Days 7-10 and 18 run in, at zero memory cost.

## What you will work with

- `ip netns add / exec`
- `ip link add type veth`
- `ip addr, ip route`
- `net.ipv4.ip_forward`
- `ip -br addr, ip route get`
- `lab/lab.sh netns-up`

## Verify

Checked automatically:

- [ ] all four namespaces exist
- [ ] the client has an address on 10.10.0.0/24
- [ ] the router forwards IPv4
- [ ] the client reaches the auth network through the router
- [ ] the client has a default route

Only you can confirm:

- [ ] you can draw the topology from ip route output alone

Run the automatic checks with:

```bash
./days/day06/verify.sh
```

A GitHub runner can build this environment for real, so CI executes `verify.sh` on every push once `scripts/setup.sh` exists.

## Scripts for today

Put your work in `days/day06/scripts/`. If you add a `scripts/setup.sh` that builds this day’s environment from nothing, it becomes the entry point for both re-running the day and for CI.

## Notes

Keep your own notes here. What broke, what the error actually said, and what fixed it — that is the part you will come back for.

---

Next up: **Day 07 — The DNS resolution path.**
