# Day 16 — WireGuard: a private network between hosts

> Build an encrypted tunnel between two machines and make it come back after reboot.

| | |
|---|---|
| **Phase** | Production operations |
| **Runs on** | VM: control + node1 |
| **Memory** | ~1.8 GB (two VMs) |
| **Verified by** | lint + your lab |

## Why this day exists

Every real environment has a management network you are not supposed to expose. WireGuard is small enough to understand completely, which is rare in VPNs.

## What you will work with

- `wg genkey / pubkey`
- `/etc/wireguard/wg0.conf`
- `AllowedIPs as a routing table`
- `wg-quick up / down, wg show`
- `systemctl enable wg-quick@wg0`
- `firewalld and the tunnel port`

## Verify

Checked automatically:

- [ ] the wg0 interface exists
- [ ] a peer is configured
- [ ] a handshake has happened
- [ ] the tunnel address is reachable
- [ ] the tunnel comes up at boot
- [ ] the private key is not world readable

Only you can confirm:

- [ ] you can explain what AllowedIPs does in both directions

Run the automatic checks with:

```bash
./days/day16/verify.sh
```

CI can only lint this day. Nothing on a GitHub runner has SELinux, firewalld, systemd units you control, or a second host to reach over SSH — so the checks below are proven by running `verify.sh` on your own lab, and nowhere else.

## Scripts for today

Put your work in `days/day16/scripts/`. If you add a `scripts/setup.sh` that builds this day’s environment from nothing, it becomes the entry point for both re-running the day and rebuilding a broken lab.

## Notes

Keep your own notes here. What broke, what the error actually said, and what fixed it — that is the part you will come back for.

---

Next up: **Day 17 — Reverse proxy and TLS termination.**
