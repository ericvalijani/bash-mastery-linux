# Day 12 — SSH hardening, bastions and fail2ban

> Reach node1 only through control, with keys only, and ban brute force.

| | |
|---|---|
| **Phase** | Hardening and configuration management |
| **Runs on** | VM: control + node1 |
| **Memory** | ~1.8 GB (two VMs) |
| **Verified by** | lint + your lab |

## Why this day exists

SSH is the door. It is also the service most often left with defaults that a scanner finds in minutes.

## What you will work with

- `sshd -T to read the effective config`
- `/etc/ssh/sshd_config.d/`
- `PasswordAuthentication, PermitRootLogin`
- `AllowUsers, AllowGroups`
- `ProxyJump and ~/.ssh/config`
- `fail2ban-client status sshd`

## Verify

Checked automatically:

- [ ] password authentication is off
- [ ] root cannot log in with a password
- [ ] login is restricted to a named user or group
- [ ] the config is valid
- [ ] fail2ban is watching sshd

Only you can confirm:

- [ ] you reached node1 with ProxyJump through control, and direct access is refused
- [ ] you triggered a ban on purpose and then unbanned yourself

Run the automatic checks with:

```bash
./days/day12/verify.sh
```

CI can only lint this day. Nothing on a GitHub runner has SELinux, firewalld, systemd units you control, or a second host to reach over SSH — so the checks below are proven by running `verify.sh` on your own lab, and nowhere else.

## Scripts for today

Put your work in `days/day12/scripts/`. If you add a `scripts/setup.sh` that builds this day’s environment from nothing, it becomes the entry point for both re-running the day and rebuilding a broken lab.

## Notes

Keep your own notes here. What broke, what the error actually said, and what fixed it — that is the part you will come back for.

---

Next up: **Day 13 — SELinux: contexts, booleans and denial triage.**
