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

Yesterday you followed a name through the layers that could answer it, and the thing at the end of the chain was sixty lines of Python. Today the thing at the end is a real server, and the day's subject moves with it: not *can something answer*, but **which of two servers answered, and where did it get that from**.

Those two servers are different in kind, not in configuration. One owns data and has the right to say a name does not exist. The other owns nothing and remembers everything. Almost every confusing DNS incident is the gap between them.

```text
  client 10.10.0.2 ---> resolver 10.10.1.2 ---> auth 10.10.2.2
                        unbound, recursive      unbound, authoritative
                        caches, owns nothing    owns lab.test, caches nothing
                        flags: ra               flags: aa
                        TTL counts DOWN         TTL never moves
```

Ask both for `www.lab.test` and you get `10.10.2.10` twice. Nothing in the answer itself tells you they are different machines doing different jobs — that is in the flags and the TTL, which is why today spends so long on both.

## What you will work with

- **`unbound`** - the daemon for both halves of today, which is the point. `unbound` is famous as a recursive resolver, but a single `local-zone: "lab.test." static` line turns it into an authoritative server for one name space and nothing else. Same binary, same config syntax, opposite job: one instance holds data and refuses to look anything up, the other holds no data and looks everything up. Configuration files live under `/etc/unbound/lab/` today rather than in the distribution's own directory, so nothing you do here touches your machine's installed resolver.
- **`unbound-checkconf`** - validates a config before the daemon reads it, and you should run it before every restart. Be clear about what it does and does not catch: it will reject a misspelled option or a malformed address, and it will happily accept a record attached to the wrong name. Both `--hard` failures below pass `unbound-checkconf` cleanly. A validator proves your syntax, never your intent.
- **A zone's five required record types** - `SOA` names the authority and carries five timers (`serial refresh retry expire minimum`); the last one is the **negative** TTL, which is how long a *no* may be cached. `NS` names the zone's nameserver, and because it points at a name, that name needs an `A` record too or the delegation cannot be acted on. `A` maps a name to an address. `CNAME` is an alias: it answers with a *name* rather than an address, so somebody has to ask a second question. A full recursive resolver chases that for you; a `static` zone like today's hands you the bare alias and stops. Either way the lookup cost two round trips, which is why `CNAME` is banned at a zone apex.
- **`local-zone` types, especially `static` and `refuse`** - `static` means *this zone is mine and it is complete*, so a name inside it with no data gets `NXDOMAIN`. That single word is what earns the fifth check. `local-zone: "." refuse` on the authoritative server is what makes it non-recursive: ask it about `example.com` and it says `REFUSED`, which is a fundamentally different statement from `NXDOMAIN`.
- **`stub-zone`** - the resolver's only piece of knowledge about `lab.test`: send it to `10.10.2.2` and treat that answer as final. `stub-first: no` means that if the authoritative server is down, the lookup fails rather than quietly falling back to the public internet — a real feature, and a real footgun in the other direction, since the fallback would let an outsider answer for a name that is yours.
- **Authoritative vs recursive, in the flags** - `aa` is the server saying *this came from my own data*. `ra` is *I am willing to go and find things*. The authoritative half has `aa` and no `ra`; the recursive half has `ra` and no `aa`. When someone reports that DNS returns the wrong address, the flags on their answer tell you immediately whether you are debugging your data or somebody's cache.
- **TTL and negative caching** - a TTL is not a performance setting, it is **a promise about how long you are willing to be wrong**. The resolver serves a copy and counts down; the authoritative server serves the record and its TTL never moves. `www.lab.test` is deliberately given a 30 second TTL so you can watch a full expiry inside a minute, and `--hard` shows you the same record at 86400, where a completed, correct migration keeps serving the old address for a day with nothing logging an error.
- **`ss -ulpn`** - DNS is UDP first, so `-u` matters; `-l` for listening, `-p` for the process, `-n` to stop it turning `53` into `domain` and hiding the number you are grepping for. Run it inside each namespace and both servers own port 53 at once without a collision, which is worth seeing once, because "port 53 is already in use" is the error that sends people rebooting.
- **`lab-dnsq` (the payload)** - asks both servers the same question and prints status, flags, TTL and answer side by side. There is no daemon to write today, so the payload is instead a question you can ask repeatedly: run it twice and only one of the two TTLs will have moved. That is the cache, visible, with no tooling.

## Verify

Checked automatically:

- [ ] something is listening on port 53 in the auth namespace
- [ ] the zone answers with a SOA
- [ ] an A record resolves from the client
- [ ] the resolver namespace also answers for the zone
- [ ] an unknown name returns NXDOMAIN not an error

Only you can confirm:

- [ ] you lowered a TTL and watched the cache expire
- [ ] you can name what REFUSED, SERVFAIL and NXDOMAIN each tell you

Run the automatic checks with:

```bash
sudo ./days/day08/verify.sh
```

**Root is required today, for the same reason as Days 06 and 07.** Every check reads from inside a namespace, and entering one is privileged. Without root you get `SKIP` on every line, and `SKIP` is not a pass. `verify.sh` declares this with `vl_need_root` so a non-root run says so plainly rather than looking like five failures.

**Run it wherever you like - including your own laptop.** There is no VM today and no lab-VM guard: everything happens inside network namespaces, which cannot see or affect your machine's own network stack. Your installed resolver keeps running on port 53 throughout, untouched, because the two servers here are in namespaces of their own.

A GitHub runner can build this environment for real, so CI executes `verify.sh` on every push. If the checks pass in CI, they pass because the zone actually answered — not because a linter approved of the script.

## Scripts for today

| Script | What it does | Root? |
|---|---|---|
| `lab-dnsq.sh` | The payload: asks both servers the same question and prints status, flags, TTL and answer in two aligned lines. Run it twice to see the cache. Its exit status reflects DNS, so it works in a loop or a pipeline. | yes |
| `setup.sh` | Builds Day 06's topology if it is missing, stops Day 07's nameserver so port 53 is free, writes both `unbound` configs, validates them with `unbound-checkconf`, starts one server in each namespace, then proves the zone answers, the resolver agrees, an unknown name is `NXDOMAIN`, and the two TTLs behave differently. Idempotent - run it twice and the second run is a clean restart. | yes |
| `explore-dns-server.sh` | Read-only tour in twelve sections: two servers on the same port, the SOA timers, the NS record and its address, the same question to both, the flags, the TTL falling, a CNAME answering with a name instead of an address, negative caching, `REFUSED` vs `NXDOMAIN`, a query with no `@server` at all, the servers' own query logs, and both configs side by side. | yes |
| `break-and-fix.sh` | Three failures, each repaired: a stub pointing where nothing answers, an authoritative server stopped while its cache keeps answering correctly, and a client denied by `access-control`. `--hard` adds two that pass `unbound-checkconf` and print no error - an 86400 second TTL during a migration, and a missing trailing dot. | yes |
| `teardown.sh` | Stops both servers, shows the client timing out against a nameserver that no longer exists, and removes today's configs and the payload. Leaves the query logs, and leaves Day 06's namespaces up because Days 09 and 18 need them. | yes |

All five need root, because all five work inside namespaces.

Read them before you run them. They are commented as teaching material rather than production code — the comments are half the day.

## Run it on the lab

### 1. No VM today

Day 08 runs on **the machine you are reading this on**, inside Day 06's namespaces. Nothing to boot, nothing to copy, no memory to budget. If a VM is still running from Day 05 and you want the RAM back:

```bash
./lab/lab.sh down node1          # deletes the VM and its disk
```

The base image stays cached, so `up` next time takes a minute, not a download.

### 2. Check the tools

Today needs `unbound` itself, plus the client tools:

```bash
command -v ip dig unbound unbound-checkconf ss
```

On RHEL-family systems: `sudo dnf install -y unbound bind-utils iproute`. On Debian or Ubuntu: `sudo apt-get install -y unbound dnsutils iproute2`. `setup.sh` checks all five before it changes anything and stops with the right command for your distribution if any are missing.

If your distribution starts `unbound` as a service on install, leave it alone. Today's instances run from explicit config files inside namespaces and never touch the system one.

### 3. Build both servers

```bash
sudo ./days/day08/scripts/setup.sh
```

It rebuilds Day 06's namespaces first if they are gone — they live in the running kernel and never survive a reboot, so that is expected rather than a fault. It also stops Day 07's Python nameserver, which is holding `10.10.1.2:53`; without that step `unbound` would fail with "address already in use", and you would go looking for a bug in today's configuration instead of yesterday's leftovers.

### 4. Look at what you built, then break it

```bash
sudo lab-dnsq www.lab.test       # run it twice - one TTL falls, one does not
sudo lab-dnsq web.lab.test       # a CNAME: an answer that is a name, not an address
sudo lab-dnsq lab.test SOA

sudo ./days/day08/scripts/explore-dns-server.sh
sudo ./days/day08/scripts/break-and-fix.sh
sudo ./days/day08/scripts/break-and-fix.sh --hard
```

Do the `--hard` pass. The three ordinary failures announce themselves; the two hard ones leave a service that is running perfectly and answering wrongly, and those are the ones that reach production.

The manual check about a TTL is worth doing by hand rather than reading about:

```bash
for i in 1 2 3 4 5 6 7 8; do sudo ip netns exec client dig +noall +answer A www.lab.test @10.10.1.2; sleep 5; done
```

One line on purpose. Eight answers five seconds apart: the TTL counts down 30, 25, 20 ... and then jumps back to 30. That jump is the cache entry expiring and the resolver going to ask the authoritative server again. Nothing announces it. That number is the only evidence.

If every line shows the same TTL, you are not reading a cache - you are reading the authoritative server. Check the address in the command.

### 5. Check yourself

```bash
sudo ./days/day08/verify.sh
```

Five checks and two for you to judge. Expect `5 passed, 0 failed, 2 for you to judge`.

### 6. Optional cleanup

```bash
sudo ./days/day08/scripts/teardown.sh
```

You do not have to. Nothing in Days 09-20 conflicts with two `unbound` instances in namespaces, and Day 09 is considerably more interesting with a DNS server to point `tcpdump` at. Teardown deliberately leaves Day 06's namespaces up for the same reason.

## Notes

Keep your own notes here. What broke, what the error actually said, and what fixed it — that is the part you will come back for.

Two things worth writing down in your own words.

**`.test` is a reserved top-level domain**, and `unbound` ships a built-in `local-zone` for it that returns `NXDOMAIN` for everything underneath — *before* your `stub-zone` is ever consulted. Your config is right, the authoritative server is up and answering, and the resolver still says the name does not exist. The one clue is the `SOA` in the reply, which names `localhost.` instead of your nameserver: that is a server answering from its own built-in data, not from your zone. `local-zone: "lab.test." nodefault` removes the built-in zone for that one name. Reserved names — `.test`, `.invalid`, `.localhost`, `.example` — are the correct choice for a lab precisely because they can never collide with the real internet, and resolvers know it, which is the same reason they refuse to look them up.

And: **`private-domain`**. `unbound` discards answers containing RFC1918 addresses by default, to protect you from DNS rebinding attacks. This lab is entirely built on `10.10.0.0/16`, so without `private-domain: "lab.test."` in the resolver config every reply from the authoritative server would come back stripped — `NOERROR`, zero answers, no error logged. It is the most confusing failure in today's stack and it is a security feature working exactly as designed.

---

Next up: **Day 09 — Packet-level debugging.**
