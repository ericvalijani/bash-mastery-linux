# Day 02 — Users, sudo, permissions and ACLs

> Give a service account exactly the access it needs and nothing else.

| | |
|---|---|
| **Phase** | The host |
| **Runs on** | VM: node1 |
| **Memory** | ~1 GB (one VM) |
| **Verified by** | lint + your lab |

## Why this day exists

"It works when I run it as root" is where most security incidents begin. Least privilege is a habit you build with your hands.

## What you will work with

- `useradd -r -s /sbin/nologin`
- `visudo and /etc/sudoers.d/`
- `sudo -l -U <user>`
- `setgid directories`
- `setfacl / getfacl`
- `umask`

## Verify

Checked automatically:

- [ ] a system account appsvc exists with no login shell
- [ ] appsvc may restart one service and nothing else
- [ ] appsvc cannot become root
- [ ] the shared directory is setgid
- [ ] an ACL grants appsvc access without changing the owner

Only you can confirm:

- [ ] you can explain every line of sudo -l -U appsvc

Run the automatic checks with:

```bash
./days/day02/verify.sh
```

CI can only lint this day. Nothing on a GitHub runner has SELinux, firewalld, systemd units you control, or a second host to reach over SSH — so the checks below are proven by running `verify.sh` on your own lab, and nowhere else.

## Scripts for today

Put your work in `days/day02/scripts/`. If you add a `scripts/setup.sh` that builds this day’s environment from nothing, it becomes the entry point for both re-running the day and rebuilding a broken lab.

## Notes

Keep your own notes here. What broke, what the error actually said, and what fixed it — that is the part you will come back for.

---

Next up: **Day 03 — Processes, signals, cgroups v2 and limits.**
