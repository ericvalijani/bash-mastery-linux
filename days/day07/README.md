# Day 07 — The DNS resolution path

> Trace one name lookup through every layer that can answer it.

| | |
|---|---|
| **Phase** | The network |
| **Runs on** | Host: network namespaces |
| **Memory** | 0 MB (no VM at all) |
| **Verified by** | lint + CI |

## Why this day exists

"It is always DNS" is a joke because it is usually true. Knowing which layer answered is the difference between a five minute fix and an afternoon.

A name lookup is not one thing. It is a queue of layers, each of which can answer and stop the search, and the layer that answers is almost never the one being blamed. Today you build that queue by hand and then make the same name return two different addresses depending on which tool asks — not as a trick, but because that is what a real machine does, and because the day you meet it in production you will not have time to learn it.

```
  application
      |
      | getent / any program using glibc
      v
  /etc/nsswitch.conf  ---> files ---> /etc/hosts        10.10.0.99
      |                                (answered - stop)
      | dns
      v
  /etc/resolv.conf    ---> 10.10.1.2 ---> lab-nameserver 10.10.2.2
      ^
      |
     dig, straight to the socket, reading none of the above
```

The important asymmetry: **`dig` is not a resolver.** It is a DNS client. It reads `/etc/resolv.conf` only to find out where to send a packet, and it never consults `nsswitch.conf` or `/etc/hosts` at all. So `dig` tells you what DNS thinks, and `getent` tells you what your application will actually get — and when those two disagree, `getent` is the one that matters and `dig` is the one that explains why.

The second thing this day teaches is where per-namespace DNS configuration actually comes from, because it is not obvious and it is not a kernel feature. `ip netns exec client …` bind-mounts everything in `/etc/netns/client/` over `/etc/` for the life of that one command. Put `resolv.conf` there and the client has its own nameserver; put it in the wrong directory and the file exists, greps fine, and is never read. That is failure 5.

## What you will work with

- `getent hosts` **vs** `dig` - the two halves of today. `getent` asks glibc, which means it obeys `nsswitch.conf`, reads `/etc/hosts`, and returns what a real program would get; its exit status is 2 when nothing was found. `dig` opens a UDP socket to a nameserver and prints the reply, so it sees DNS and nothing but DNS. Neither is more correct — they answer different questions, and using the wrong one is how people spend an afternoon debugging a hosts entry with a tool that cannot read hosts files.
- `/etc/nsswitch.conf` - the `hosts:` line is the queue itself, read left to right, first answer wins. `files dns` means a hosts entry is consulted before any packet is sent, so DNS is not slow in that case — it is never asked. Removing `files` from that line breaks nothing visibly and changes every pinned address on the machine, which is failure 1.
- `/etc/hosts` - matched as a **literal string**, with no DNS conventions applied. `www.lab.test` and `www.lab.test.` are two different entries and only one of them will ever match, because the trailing dot that means "fully qualified" in DNS means "a different name" here. That is failure 4, and it survives code review every time.
- `/etc/resolv.conf` - three or four lines that decide where queries go: `nameserver` (up to three, tried in order), `options timeout:` and `attempts:` (which is why a dead nameserver costs you seconds rather than milliseconds), and `search`, which today's file deliberately omits so that every lookup is the name you actually typed. On most modern desktops this file is generated and overwritten — check whether it is a symlink before you edit it, or your fix will vanish at the next reconnect.
- `/etc/netns/<namespace>/` - the bind-mount trick above. Anything you put here shadows `/etc/<same name>` inside that one namespace, and nowhere else. It is how this whole day runs without touching your machine's own resolver, and it is worth remembering as a general technique for testing resolver changes safely.
- `systemd-resolved` and `resolvectl` - the layer this day deliberately does *not* use, and you should know why. On a desktop, `/etc/resolv.conf` often points at `127.0.0.53`, a stub listener, and the real configuration lives in `resolvectl status` — per-interface nameservers, per-domain routing, a cache, and DNSSEC. If your own laptop is set up that way, `dig` against `127.0.0.53` tells you about the stub and not about the upstream. `resolvectl query` is the `getent`-equivalent there. Inside a namespace none of that is running, which is exactly why the plain path is legible today.
- `dig +short`, `+norecurse`, `+trace` - `+short` for scripting and quick answers; the full output for the **flags**, where `aa` means the server claimed authority for the zone and `ra` means it is willing to recurse. `+norecurse` asks a server to answer only from what it already knows, which is how you tell an authoritative server from a cache. `+trace` walks from the root down, one delegation at a time — it needs real internet roots, so it is a tool for tomorrow's public names rather than for this lab's private zone.
- `lab-nameserver` (the payload) - about sixty lines that answer A queries for four names and NXDOMAIN for everything else. It exists so you can watch queries arrive, in a log, with the asker's address, and so today has a nameserver without also having a day's worth of configuration. Day 08 throws it away and runs the real thing.

## Verify

Checked automatically:

- [ ] nsswitch consults files before dns
- [ ] a hosts entry beats DNS for the same name
- [ ] the client has a nameserver configured
- [ ] the nameserver answers from the resolver namespace
- [ ] dig and getent are both available to compare

Only you can confirm:

- [ ] you can explain why dig ignored /etc/hosts and getent did not
- [ ] you followed one name from application call to authoritative answer

Run the automatic checks with:

```bash
sudo ./days/day07/verify.sh
```

**Root is required today, for the same reason as Day 06.** Every check reads from inside a namespace, and entering one is privileged. Without root you get `SKIP` on every line, and `SKIP` is not a pass. `verify.sh` declares this with `vl_need_root` so a non-root run says so plainly.

**Run it wherever you like - including your own laptop.** There is no "wrong machine" on a namespace day. Nothing here reads or writes your own resolver configuration: the checks look inside the `client` namespace, and the files they read live under `/etc/netns/client/`. If the checks are red, the day genuinely is not built.

Every check reads from **inside** the namespace, and that is deliberate. An earlier version of this file checked the host's `/etc/nsswitch.conf`, which would have passed on almost any Linux machine whether you had done the day or not. When a check can pass without the work being done, it is decoration.

CI executes this day for real, on every push. The runner installs `dnsutils` and has `python3`, so the nameserver runs, the queries fly and `verify.sh` reports. That is a genuine gate, unlike Days 01-05.

## Scripts for today

| Script | What it does | Root? |
|---|---|---|
| `lab-nameserver.sh` | The payload: a small authoritative nameserver for four names, in about sixty lines. Logs every query with the asker's address, which is what makes "did the packet arrive?" answerable rather than guessable. Written in Python because a DNS answer is a byte layout, not text you can fake with `printf`. | yes |
| `setup.sh` | Builds Day 06's topology if it is missing (a reboot removes it, so that is the normal case, not an error), installs the payload, writes the client's own `resolv.conf`, `nsswitch.conf` and `hosts` under `/etc/netns/`, starts the nameserver in the `resolver` namespace, then proves both paths answer **and that they disagree**. Idempotent - run it twice and the second run restarts cleanly. | yes |
| `explore-dns.sh` | Read-only tour in twelve sections: the two different `/etc/resolv.conf` files, the same name asked two ways, a name only DNS knows, a name nobody knows, why `dig localhost` returns nothing, reading the `aa` flag, and the server-side log of everything you just asked. | yes |
| `break-and-fix.sh` | Three failures, each repaired: `files` dropped from nsswitch, a nameserver address that nothing answers on, and a nameserver that is stopped rather than absent. `--hard` adds two that read as correct configuration - a trailing dot in `/etc/hosts`, and the right file in the wrong namespace. | yes |
| `teardown.sh` | Stops the nameserver, removes the per-namespace files, and shows the client falling back to your machine's own resolver - without anything being unmounted, which explains what the bind mount really was. Leaves Day 06's namespaces alone, because Days 08, 09 and 18 need them. | yes |

Every script needs root today. It is not privilege creep: `ip netns exec` is privileged, port 53 is privileged, and `/etc/netns/` is root-owned.

Read them before you run them. They are commented as teaching material rather than production code - the comments are half the day.

## Run it on the lab

### 1. No VM today

Day 07 runs on **the machine you are reading this on**, inside Day 06's namespaces. Nothing to boot, nothing to copy, no memory to budget. If `node1` is still running from Day 05 and you want the RAM back:

```bash
./lab/lab.sh down node1          # deletes the VM and its disk
```

The base image stays cached, so `up` next time takes a minute, not a download.

### 2. Check the topology and the tools

Today resolves across Day 06's network. Namespaces live in the running kernel and never survive a reboot, so if you have rebooted since Day 06 they are simply gone - which is why `setup.sh` rebuilds them for you rather than complaining. You can also do it yourself first if you prefer to watch it happen:

```bash
sudo ./days/day06/scripts/setup.sh   # optional - or: sudo ./lab/lab.sh netns-up
command -v ip getent dig python3
```

On RHEL-family systems: `sudo dnf install -y iproute bind-utils python3`. On Debian or Ubuntu: `sudo apt-get install -y iproute2 dnsutils python3`. `setup.sh` checks all four before it changes anything, and stops with the right command for your distribution if any are missing.

### 3. Build the resolution path

```bash
cd ~/lab                                    # or wherever you cloned it
sudo ./days/day07/scripts/setup.sh          # 1. files, nameserver, both proofs
```

Read step 5 of its output carefully. It asks for one name two ways and gets two different addresses, and it **fails on purpose** if those two answers ever agree - because if they agree, the hosts file is not being read and the rest of the day would teach you nothing.

### 4. Look at what you built, then break it

```bash
sudo ./days/day07/scripts/explore-dns.sh    # 2. the tour, twelve sections
```

Section 1 is the one to slow down on: `cat /etc/resolv.conf` inside the namespace and outside it, two different files, same path. Section 7 is the one people remember - `dig +short localhost` returns nothing at all, on a working machine.

```bash
sudo ./days/day07/scripts/break-and-fix.sh          # 3. three failures
sudo ./days/day07/scripts/break-and-fix.sh --hard   # 4. two more, subtler
```

Five failures, and **four of the five never print an error message**. That is the point of the day, so keep this table beside you:

| Symptom | What it means | Which failure |
|---|---|---|
| `getent` and `dig` suddenly agree | A layer stopped being consulted. Read the `hosts:` line. | 1 |
| Some names resolve, others hang | The ones that work are not using DNS at all | 2 |
| A timeout rather than a refusal | Something is listening and nothing is answering | 3 |
| A hosts entry that reads correctly and is ignored | The exact string, dots and all | 4 |
| A file that exists, greps fine, and is not seen | Wrong directory under `/etc/netns/` | 5 |

Failure 3 is worth the detour. A timeout, a refusal and an NXDOMAIN are all reported as "DNS is broken" and they have three different causes: nothing read the packet, nothing was listening, or a server authoritatively said no. Learn to tell them apart from the *shape* of the failure and you skip most of the guessing.

Everything is restored before the script exits, so `verify.sh` is green afterwards. If you interrupt it half way, run `setup.sh` again.

### 5. Check yourself

```bash
sudo ./days/day07/verify.sh
```

Expect **5 PASS, 2 YOU, exit 0**.

The second `YOU` is the real exercise: follow one name from an application's point of view all the way to the answer, and be able to name every layer it passed and every layer it skipped. Do it out loud, with `/var/log/lab-nameserver.log` open in another terminal so you can see which of your lookups actually reached the server. Anything that never appears in that log was answered before DNS was reached - and knowing which of your lookups those were is the whole skill.

### 6. Optional cleanup

```bash
sudo ./days/day07/scripts/teardown.sh
```

None of this is persistent, so a reboot clears it whether you ask or not. Run teardown once anyway and read step 4: the client's `/etc/resolv.conf` goes back to being your machine's own file, and nothing was unmounted to make that happen - which tells you what the bind mount actually was.

It deliberately leaves Day 06's namespaces up. Day 08 replaces this toy nameserver with a real authoritative server and a real recursive resolver on the same topology, and Days 09 and 18 need the wiring too.

## Notes

Keep your own notes here. What broke, what the error actually said, and what fixed it - that is the part you will come back for.

---

Next up: **Day 08 — Running DNS: authoritative and recursive.**
