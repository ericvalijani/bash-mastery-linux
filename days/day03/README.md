# Day 03 — Processes, signals, cgroups v2 and limits

> Constrain a process so it cannot take the machine down with it.

| | |
|---|---|
| **Phase** | The host |
| **Runs on** | VM: node1 |
| **Memory** | ~1 GB (one VM) |
| **Verified by** | lint + your lab |

## Why this day exists

Containers are cgroups plus namespaces. Meet the primitives directly and container behaviour stops being magic.

## What you will work with

- `ps -eo pid,ppid,stat,cmd`
- `kill -TERM vs -KILL, trap`
- `/sys/fs/cgroup/`
- `systemd-run --scope -p MemoryMax=`
- `systemctl set-property`
- `ulimit, /etc/security/limits.d/`

## Verify

Checked automatically:

- [ ] cgroups v2 is the unified hierarchy
- [ ] a service is capped with MemoryMax
- [ ] the same service is capped with CPUQuota
- [ ] a nofile limit is raised for one account only

Only you can confirm:

- [ ] you triggered the memory cap and found the kill in the journal
- [ ] you can explain why SIGKILL cannot be trapped

Run the automatic checks with:

```bash
./days/day03/verify.sh
```

CI can only lint this day. Nothing on a GitHub runner has SELinux, firewalld, systemd units you control, or a second host to reach over SSH — so the checks below are proven by running `verify.sh` on your own lab, and nowhere else.

## Scripts for today

Put your work in `days/day03/scripts/`. If you add a `scripts/setup.sh` that builds this day’s environment from nothing, it becomes the entry point for both re-running the day and rebuilding a broken lab.

## Notes

Keep your own notes here. What broke, what the error actually said, and what fixed it — that is the part you will come back for.

---

Next up: **Day 04 — Storage: LVM, filesystems and mount units.**
