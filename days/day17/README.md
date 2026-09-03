# Day 17 — Reverse proxy and TLS termination

> Put nginx in front of a plain HTTP service and serve it over TLS with your own CA.

| | |
|---|---|
| **Phase** | Production operations |
| **Runs on** | VM: node1 |
| **Memory** | ~1 GB (one VM) |
| **Verified by** | lint + your lab |

## Why this day exists

This is how almost every internal service is actually exposed. It also ties Day 10 to something running, and Day 13 will fight you here.

## What you will work with

- `nginx server blocks, proxy_pass`
- `ssl_certificate, ssl_protocols, ssl_ciphers`
- `HTTP to HTTPS redirect`
- `X-Forwarded-For and proxy headers`
- `nginx -t, nginx -T`
- `SELinux: httpd_can_network_connect`

## Verify

Checked automatically:

- [ ] the nginx config is valid
- [ ] nginx is running and enabled
- [ ] HTTPS works and verifies against your CA
- [ ] plain HTTP redirects instead of serving
- [ ] obsolete TLS versions are refused
- [ ] the backend is not reachable from outside

Only you can confirm:

- [ ] you hit an SELinux denial on proxy_pass and fixed it with a boolean

Run the automatic checks with:

```bash
./days/day17/verify.sh
```

CI can only lint this day. Nothing on a GitHub runner has SELinux, firewalld, systemd units you control, or a second host to reach over SSH — so the checks below are proven by running `verify.sh` on your own lab, and nowhere else.

## Scripts for today

Put your work in `days/day17/scripts/`. If you add a `scripts/setup.sh` that builds this day’s environment from nothing, it becomes the entry point for both re-running the day and rebuilding a broken lab.

## Notes

Keep your own notes here. What broke, what the error actually said, and what fixed it — that is the part you will come back for.

---

Next up: **Day 18 — Bridges, VLANs and link aggregation.**
