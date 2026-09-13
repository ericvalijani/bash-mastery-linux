# Day 17 — Reverse proxy and TLS termination

**Phase:** Production operations
**Runs on:** `node1`
**Time:** about ninety minutes

Almost nothing serves its own TLS. The application listens on some high port,
in plain HTTP, on the loopback interface, and something in front of it holds
the certificate and does the arithmetic. That something is usually nginx, and
the arrangement is so common that most people have never seen the inside of
it.

Today you build it: nginx on `node1` terminating TLS for `www.lab.test`, in
front of a backend on `127.0.0.1:8080` that has never heard of a certificate.
The certificate is signed by the CA you built on Day 10, and the CA goes into
this host's trust store — the first time anything in this repository installs a
trust anchor. Day 10 deliberately stopped one step short of that.

Day 13 will fight you here, which the curriculum promised and meant. nginx
runs as `httpd_t`, and `httpd_t` may not open a socket to your backend until a
boolean says it can. The symptom is `502 Bad Gateway`. The word SELinux
appears nowhere in it.

## What you will work with

- `proxy_pass`, and the three headers that go with it —
  `Host`, `X-Real-IP`, `X-Forwarded-For` — because the backend otherwise sees
  every request as arriving from `127.0.0.1`, which is true and useless
- `listen 443 ssl` with `ssl_certificate` and `ssl_certificate_key`, and a
  `listen 80` server block whose only job is `return 301`
- `--bind 127.0.0.1` on the backend: the entire boundary between private and
  public here, and not the firewall, which never sees loopback traffic at all
- `subjectAltName`, which is the field clients match, and `CN`, which is
  decoration — a certificate with no SAN matches no hostname at all
- `openssl verify -CAfile` versus
  `openssl s_client -servername <name> -verify_hostname <name>`: the first
  checks the chain and the dates, the second also checks the name
- `openssl x509 -noout -modulus | openssl md5` against the key's, because
  "both files are valid" does not mean "these two belong together"
- `update-ca-trust` and `/etc/pki/ca-trust/source/anchors/`, and the fact that
  it satisfies curl and wget while Firefox, Java and node keep their own
  stores and go on refusing
- `setsebool -P httpd_can_network_connect on`, and what the missing `-P` buys
  you: a proxy that works until the next reboot
- `restorecon` on the installed certificate and key, since a file copied into
  `/etc/pki/tls` from elsewhere carries the label of where it came from
- `nginx -t` versus `nginx -T` versus what the workers are actually running —
  three different questions with three different answers
- `systemctl reload nginx`, not `restart`: reload replaces workers and lets
  requests in flight finish
- `502` versus `504`, and reading the error log to tell a refusal from silence

## One VM, and the memory

| VM | Memory | What runs on it | Why |
|---|---|---|---|
| `node1` | 2048 MB | nginx, the backend, the CA | nginx plus a python process needs the headroom |

About **2 GB** in total, down from Day 16's two VMs. Nothing in this lab is
below 1536 MB, which is the minimum Rocky 9 recommends and the number
`virt-install` warns about.

Days 14, 15 and 16 are not prerequisites. Today touches nothing they built —
no `ansible.cfg`, no project directory, no tunnel. The days it leans on are
Day 10 for the CA, Day 11 for `firewalld` and Day 13 for SELinux.

The shape you are building:

```
  client ──► :443  nginx  ──► 127.0.0.1:8080  python3 -m http.server
            TLS ends here      plain HTTP, loopback only, no certificate
            :80 → 301 https
```

The name comes from `/etc/hosts` — `127.0.0.1 www.lab.test`, written by
`setup.sh`. Day 08's zone serves `www.lab.test` properly, and if you have that
running you can point this VM's resolver at it instead and delete the hosts
entry. The shortcut is deliberate: a name in `/etc/hosts` works on exactly one
host, which is worth feeling once.

`/etc/lab-tls` is where Day 10 kept the CA. If it is not on this VM,
`setup.sh` issues one there with Day 10's own commands, so the day stands up on
a freshly built host. A day may lean on another day's lesson; it may not lean
on another day's leftovers.

## Scripts

| Script | What it does |
|---|---|
| `scripts/setup.sh` | eleven steps: packages, backend and its unit, CA, certificate, trust store, `/etc/hosts`, nginx config, the SELinux boolean, firewalld, payload, proof. Idempotent |
| `scripts/lab-proxy.sh` | installed as `lab-proxy`. `status`, `certs`, `test`, `logs` |
| `scripts/explore-proxy.sh` | twelve read-only stops through the proxy you just built |
| `scripts/break-and-fix.sh` | four real failures, each fixed in front of you. `--hard` describes two that break nothing and expose everything |
| `scripts/teardown.sh` | proxy, backend, ports and name removed. `--all` also removes the certificates, the CA and the trust anchor |
| `verify.sh` | nineteen automatic checks, two for you to judge |

## Run it

On your laptop, in the repository:

```bash
./lab/lab.sh up node1                   # ~2 GB
./lab/lab.sh status                     # read the address
./lab/lab.sh push node1                 # carries days/ and lab/
./lab/lab.sh ssh node1
```

`lab.sh status` prints something like:

```
node1     running   192.168.122.140     # EXAMPLE address — use your own
```

That is an example. DHCP leases move every time a VM is rebuilt, so read it
yourself each session rather than copying it from here.

Then, on `node1`:

```bash
cd ~/lab/days/day17
sudo ./scripts/setup.sh
```

It ends by proving the whole path: a handshake it verified itself, a request
over `https://www.lab.test/`, and the same content fetched from the backend
directly with no TLS anywhere near it.

Then, in order:

```bash
sudo lab-proxy                       # units, listeners, ports, SELinux
sudo lab-proxy certs                 # what the certificate claims, and who signed it
sudo lab-proxy test                  # a verified handshake and a real request
sudo lab-proxy logs                  # the proxy's two logs, and the backend's journal
sudo ./scripts/explore-proxy.sh      # read the proxy you just built
sudo ./scripts/break-and-fix.sh      # four failures, four fixes
sudo ./scripts/break-and-fix.sh --hard
sudo ./verify.sh
```

If you edit the scripts on your laptop afterwards, push them again before you
re-run anything — the VM has its own copy and will happily keep running the
old one:

```bash
./lab/lab.sh push node1
```

Before `verify.sh`, do one thing by hand:

```bash
curl -s http://127.0.0.1:8080/
```

No certificate, no verification, no encryption. That is the hop you are
trusting, and the reason it is acceptable is that it never leaves the host.

## What to actually look at

**TLS terminates somewhere, and you should be able to point at it.** After
nginx, this traffic is ordinary HTTP. Over loopback that is fine. Over a
network it is the thing people think they have stopped doing — and it is what
Day 16's tunnel would be for, if the backend lived on another host.

**`subjectAltName`, not CN.** Clients have matched names against the SAN for
years and browsers stopped reading CN entirely. `break-and-fix.sh` serves a
certificate for `other.lab.test` and everything about it is valid: signed by a
CA this host trusts, in date, correct key. Every client still refuses it,
because "is this certificate good" and "is this certificate for the name I
asked for" are two separate questions.

**`openssl verify` has never checked a hostname.** It will tell you `OK` about
a certificate no browser will accept. The command that answers the real
question is
`openssl s_client -connect host:443 -servername <name> -verify_hostname <name>
-CAfile <ca>`, and the only line that means yes is `Verify return code: 0
(ok)`.

**SNI decides which certificate you get.** Connect without `-servername` and
nginx answers with its default server block. On a host with one site you never
notice; on a host with six you get somebody else's certificate and a confusing
afternoon. Stop 5 of the tour shows both.

**A valid certificate and a valid key are not a pair.** Nothing in
`openssl verify` checks that. Compare the moduli — `lab-proxy certs` prints
both — because the failure mode is nginx refusing to start after a renewal,
with an error about a key not matching, at the worst possible moment.

**502 is not a generic error.** `502` with `Connection refused` in the error
log means something answered the connect attempt with a refusal, instantly:
the backend is down. `502` with `Permission denied` means the connect was
never allowed: SELinux. `504` means nobody answered at all and nginx gave up
waiting: dropped packets, a firewall rule, a hung application. Three different
places to look, and the status code narrows it before you read anything.

**The boolean is the day's real lesson.** nginx is `httpd_t`, and SELinux
treats "open a TCP socket to 127.0.0.1:8080" as a policy decision rather than
a network one. With `httpd_can_network_connect` off, the config is perfect,
the certificate is perfect, the backend is running and answering — and every
request is a 502. The only place the cause is named is the audit log. Use
`-P`, or you have built a proxy that stops working at the next reboot.

**`restorecon`, every time you copy a certificate in.** A file inherits the
label of where it was created, not where it now lives. The certificates go
under `/etc/pki/tls` precisely because that tree is already labelled `cert_t`,
and `setup.sh` relabels anyway, because assuming is how you get a permission
denied on a file whose `ls -l` looks flawless.

**nginx read the certificate once.** Same lesson as Day 16's `wg showconf`,
in the place it costs the most: renewal. Replace the certificate on disk and
the workers keep serving the old one indefinitely. `nginx -t` passes, because
the file on disk is valid. `openssl s_client | openssl x509 -noout -serial`
against the serial on disk is the check, and `systemctl reload nginx` is the
fix. A renewal cron that forgets the reload expires in production while the
new certificate sits on disk, unused.

**`reload`, not `restart`.** Reload starts new workers with the new
configuration and lets the old ones finish what they were doing. Restart drops
every connection in flight, including the upload somebody is twenty minutes
into.

**HTTP/2 is spelled two different ways, and the wrong one is fatal.** Before
nginx 1.25.1 it is a parameter on the listen line, `listen 443 ssl http2;`.
From 1.25.1 it is its own directive, `http2 on;`. Rocky 9 ships 1.20, so
`http2 on;` there is `unknown directive "http2"` and nginx refuses to start at
all — not a warning, a parse error. `setup.sh` reads `nginx -v` and writes
whichever form applies, and prints which one it chose. Most nginx examples
on the internet are one side or the other of that split with no version next
to them.

**Trust stores are per-consumer.** `update-ca-trust` writes the bundle that
curl, wget, git and most of the system read, which is why `curl
https://www.lab.test/` needs no `--cacert` after today. Firefox, Chrome's
profile store, Java's `cacerts` and node's bundled roots are all separate, and
none of them will trust this certificate. "I added the CA" is always followed
by "to what".

**"Not filtered" is not "allowed".** A rebuilt `node1` may not have firewalld
installed at all — Day 11 installed it, and a fresh VM has never run Day 11.
With no firewalld, 443 answers perfectly, because nothing is filtering
anything. `setup.sh` now installs firewalld if it is missing, starts and
enables it, and only then adds the ports, because a port "open" in a policy
that no daemon has loaded is a comment. Day 16 taught the daemon-versus-offline
split; this is the layer under it — the package itself.

**8080 stays closed in firewalld, on purpose.** `verify.sh` asserts that it
is closed. The backend is private because it is bound to loopback; the closed
port is the second layer, and the `--hard` section shows what happens when
either one is quietly given up.

## The four failures

| Break | What you see | Why |
|---|---|---|
| `httpd_can_network_connect` off | `502`, `Permission denied` in the error log | nginx is `httpd_t`; the upstream connect is a policy decision |
| certificate for `other.lab.test` | `openssl verify` says OK, every client refuses | chain and dates are one question, hostname is another |
| backend stopped | `502` with `Connection refused` | a refusal is instant; dropped packets would give `504` after the timeout |
| certificate replaced, no reload | disk and wire disagree, `nginx -t` passes | nginx reads certificates once, when the workers start |

The `--hard` pair are described rather than caused: binding the backend to
`0.0.0.0`, and opening 8080 in firewalld "to test something". Neither one
fails. Both serve the same content unencrypted, off to the side of the proxy,
with nothing in the access log to say so — because those requests never touch
nginx at all. Worth doing once, by hand, with `ss -tlnp` open in another
window.

## Teardown

On `node1`:

```bash
sudo ./scripts/teardown.sh          # proxy, backend, ports, name; certs kept
sudo ./scripts/teardown.sh --all    # certificates, CA and trust anchor too
```

Certs kept means `sudo ./scripts/setup.sh` puts the whole thing back in
seconds. `--all` removes the CA key as well, so the next run issues a new CA —
and anything that trusted the old one now trusts nothing. That is the correct
behaviour and a useful thing to have watched happen.

The SELinux boolean is left on by both. It is a policy change, it costs
nothing, and turning it off would break any other `httpd_t` service on the
host.

Then, on your laptop:

```bash
./lab/lab.sh down node1
```

## Done when

`sudo ./verify.sh` prints **19 passed, 0 failed**, 2 for you to judge, and you
can say out loud where TLS stops, what protects the hop after it, and which
log line told you the last failure was SELinux and not nginx.

---

Next up: **Day 18 — Bridges, VLANs and link aggregation.**
