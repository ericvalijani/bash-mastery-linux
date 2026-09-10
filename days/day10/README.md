# Day 10 - TLS on the wire and a private CA

> Run your own certificate authority and understand what a client actually verifies.

| | |
|---|---|
| **Phase** | The network |
| **Runs on** | Host: openssl only, no namespaces |
| **Memory** | 0 MB (no VM at all) |
| **Verified by** | lint + CI |

## Why this day exists

"Invalid certificate" almost never means the certificate is invalid.

Today you issue three certificates from one authority, a minute apart. All three are properly signed by a CA the client trusts. One works. One is refused everywhere because it is out of date. One is refused everywhere because it carries a different name. Nothing about the second and third is corrupt, and no amount of re-issuing, restarting or reinstalling fixes them - only understanding which of three separate questions failed.

Those three questions are the day:

1. Does the chain lead to something this client was told to trust?
2. Is the certificate valid right now?
3. Does the name I asked for appear in it?

They fail independently, they have different fixes, and two of them are not the server's fault at all. Day 17 puts this CA behind a real web server, so the CA you build here is reused.

## What you will work with

- `openssl req -x509 -newkey` - a self-signed CA in one command, and why self-signed is what an authority *is*
- `basicConstraints=CA:TRUE`, `keyUsage=keyCertSign` - what makes a certificate allowed to sign others
- `openssl req -newkey` plus `openssl x509 -req -CA` - a signing request, and the signature over it
- `subjectAltName` - the field that decides hostname matching, and the reason `CN` no longer does
- `openssl verify -CAfile` - checks the chain and the dates, and *never* the hostname
- `openssl s_client -connect -servername -verify_hostname -CAfile` - a real handshake, checked properly
- `Verify return code: 0 (ok)` - the only line in that output that means trusted
- `openssl x509 -noout -modulus | openssl md5` - whether a key and a certificate are actually a pair
- file modes on private keys, and why `0600` on the CA key is not optional

## Verify

Checked automatically:

- [ ] a CA certificate exists and is marked as a CA
- [ ] a server certificate carries a subjectAltName for www.lab.test
- [ ] the server certificate verifies against the CA
- [ ] the private key matches the certificate
- [ ] the CA key is readable only by root
- [ ] a handshake on 127.0.0.1:4433 verifies with the CA and the hostname
- [ ] the same handshake is refused when no CA is supplied

Only you can confirm:

- [ ] you can read an s_client chain and say why it was trusted or refused
- [ ] you made verification fail on purpose, by hostname and by expiry

Run the automatic checks with:

```bash
sudo ./days/day10/verify.sh
```

A GitHub runner can build this environment for real, so CI executes `verify.sh` on every push.

## Scripts for today

| Script | What it does | Root? |
|---|---|---|
| `scripts/setup.sh` | Builds the CA, issues three certificates from it, starts a TLS server, and checks one handshake both ways | yes |
| `scripts/lab-tls.sh` | The payload. Separates chain, dates and hostname, and says which one failed | yes |
| `scripts/explore-tls.sh` | Twelve looks at three certificates that differ only by a name and a date | yes |
| `scripts/break-and-fix.sh` | Five certificate failures and the line that identifies each. `--hard` adds the two that get misdiagnosed | yes |
| `scripts/teardown.sh` | Stops the server, frees the port, removes the CA and its keys | yes |

Read them before you run them. They are commented as teaching material rather than production code - the comments are half the day.

## Run it on the lab

### 1. No VM today

This day needs `openssl` and nothing else - no namespaces, no VM, no root-owned network state. TLS does not care about topology; it cares about names, dates and signatures, and all three can be got wrong on one machine talking to itself. Run it wherever you like - including your own laptop.

If a VM from an earlier day is still running and you want the memory back:

```bash
./lab/lab.sh down node1
```

### 2. Check what you already have

```bash
openssl version
date -u
```

Both matter. The second one matters more than people expect: TLS is a dated protocol, and a machine whose clock is wrong reports every certificate on earth as expired or not-yet-valid.

### 3. Build it

```bash
sudo ./days/day10/scripts/setup.sh
```

That creates `/etc/lab-tls` with mode `0700`, a self-signed CA valid for ten years, three leaf certificates signed by it, and a TLS server on `127.0.0.1:4433`. It then makes one handshake with `-CAfile` and one without, so you see both answers before you read a word of explanation.

To start over from nothing:

```bash
sudo ./days/day10/scripts/setup.sh --fresh
```

What you end up with:

```text
/etc/lab-tls/ca.crt          self-signed, CA:TRUE, the only thing to trust
/etc/lab-tls/server.crt      good: SAN www.lab.test, valid a year
/etc/lab-tls/expired.crt     same CA, same name, valid until yesterday
/etc/lab-tls/wrongname.crt   same CA, valid dates, SAN other.lab.test
```

### 4. Look at what you built, then break it

```bash
sudo lab-tls
sudo lab-tls 127.0.0.1:4433 other.lab.test
sudo ./days/day10/scripts/explore-tls.sh
```

The tour is worth reading slowly at step 6, where `openssl verify` accepts `wrongname.crt` without complaint. That is correct behaviour and it surprises everyone: `verify` checks the chain and the dates. It is never told what hostname you wanted, so it cannot object to it. Hostname matching happens in the client, later, and that split is why a certificate can pass every check you thought to run and still be refused.

Then the five failures:

```bash
sudo ./days/day10/scripts/break-and-fix.sh
sudo ./days/day10/scripts/break-and-fix.sh --hard
```

`--hard` adds the two that get blamed on the wrong thing: a certificate and key that were never a pair, which is the only failure here that stops the *server* from starting, and the same certificate verifying for one client and failing for another because trust lives in the client's own store.

Do the two manual ones by hand as well, because that is what the `YOU` items ask:

```bash
# fail by hostname: genuine certificate, name you did not ask for
echo | sudo openssl s_client -connect 127.0.0.1:4433 \
  -servername other.lab.test -verify_hostname other.lab.test \
  -CAfile /etc/lab-tls/ca.crt 2>&1 | grep -E "verify error|Verify return"

# fail by expiry: same CA, same name, yesterday's dates
sudo openssl verify -CAfile /etc/lab-tls/ca.crt /etc/lab-tls/expired.crt
sudo openssl x509 -in /etc/lab-tls/expired.crt -noout -dates
```

Say out loud which of the three questions each one failed. If you can do that from the output alone, the day is done.

### 5. Check yourself

```bash
sudo ./days/day10/verify.sh
```

Seven automatic checks and two that are yours. The last automatic one is deliberately a *negative* check - a handshake with no `-CAfile` must be refused. A lab where everything passes has not tested trust at all.

### 6. Optional cleanup

```bash
sudo ./days/day10/scripts/teardown.sh
```

That stops the server, proves port 4433 is free, and deletes `/etc/lab-tls` including the CA key.

If you plan to do Day 17 soon, you may prefer to leave the CA in place - Day 17 puts this same authority behind a real web server. It can also rebuild it from scratch, so either choice is fine.

## Notes

The three questions again, because they are the entire day and they are the thing to remember in an incident:

1. **Chain** - `unable to get local issuer certificate`. The client's problem. Nothing is wrong with the server, and the fix is on the client: supply the CA, or install it in that client's store.
2. **Dates** - `certificate has expired`. Check `date -u` *before* re-issuing. A wrong clock reports every certificate as bad, and re-issuing under a wrong clock produces a certificate that is broken everywhere else.
3. **Hostname** - `Hostname mismatch`. A genuine, trusted, in-date certificate for a name you did not ask for. Read the `subjectAltName`, not the `CN` - clients stopped honouring `CN` years ago.

Two more worth keeping. Trust is a property of the client, not of the certificate: openssl, curl, Java, Python and Firefox each have their own store, which is why "it works in my browser" is a real observation rather than an excuse. And a certificate and its key are a pair you can check in two seconds with matching modulus hashes - run that first when a service dies immediately after a renewal, because a key mismatch is the one failure that stops the server rather than the client.

Deleting a CA key is final. Everything it signed becomes unrenewable, which is an outage with a date on it rather than an immediate one.

Keep your own notes here. What broke, what the error actually said, and what fixed it - that is the part you will come back for.

---

Next up: **Day 11 - firewalld, and the nftables underneath it.**
