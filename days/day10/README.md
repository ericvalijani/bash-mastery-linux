# Day 10 — TLS on the wire and a private CA

> Run your own certificate authority and understand what a client actually verifies.

| | |
|---|---|
| **Phase** | The network |
| **Runs on** | Host: network namespaces |
| **Memory** | 0 MB (no VM at all) |
| **Verified by** | lint + CI |

## Why this day exists

Certificate errors are the most common self-inflicted outage. Issuing certificates yourself makes the trust chain concrete, and Day 17 needs this CA.

## What you will work with

- `openssl genrsa / ecparam`
- `openssl req with SANs`
- `openssl x509 -req -CA`
- `openssl verify -CAfile`
- `openssl s_client -connect -showcerts`
- `trust anchors in /etc/pki/`

## Verify

Checked automatically:

- [ ] a CA certificate exists and is marked as a CA
- [ ] a server certificate carries a subjectAltName
- [ ] the server certificate verifies against the CA
- [ ] the private key matches the certificate

Only you can confirm:

- [ ] you can read an s_client chain and say why it was trusted or refused
- [ ] you made verification fail on purpose, by hostname and by expiry

Run the automatic checks with:

```bash
./days/day10/verify.sh
```

A GitHub runner can build this environment for real, so CI executes `verify.sh` on every push once `scripts/setup.sh` exists.

## Scripts for today

Put your work in `days/day10/scripts/`. If you add a `scripts/setup.sh` that builds this day’s environment from nothing, it becomes the entry point for both re-running the day and for CI.

## Notes

Keep your own notes here. What broke, what the error actually said, and what fixed it — that is the part you will come back for.

---

Next up: **Day 11 — firewalld, and the nftables underneath it.**
