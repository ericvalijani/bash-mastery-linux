# Day 06 — Interfaces, routing and building the namespace lab

> Build a four-node routed network inside your kernel and prove packets cross it.

| | |
|---|---|
| **Phase** | The network |
| **Runs on** | Host: network namespaces |
| **Memory** | 0 MB (no VM at all) |
| **Verified by** | lint + CI |

## Why this day exists

This is real kernel networking, not a simulation: real interfaces, real routing tables, real packets. It is also the environment Days 07-10 and 18 run in, at zero memory cost.

Today is the first day with no VM, and that changes what you should expect. A network namespace is a separate, empty copy of the kernel's entire network stack — its own interfaces, its own routing table, its own sysctls. Nothing you do today adds an address, a route or a rule to the namespace your own machine uses, which is why this day is safe to run on your laptop and why CI can execute it for real instead of only linting it.

```
  client   10.10.0.2  ---  10.10.0.1  .
                                       router  (forwards IPv4)
  resolver 10.10.1.2  ---  10.10.1.1  '
  auth     10.10.2.2  ---  10.10.2.1  '
```

| Namespace | Its address | Its veth | Router's veth | Router's address |
|---|---|---|---|---|
| `client` | 10.10.0.2/24 | `veth-cl` | `veth-rcl` | 10.10.0.1/24 |
| `resolver` | 10.10.1.2/24 | `veth-rs` | `veth-rrs` | 10.10.1.1/24 |
| `auth` | 10.10.2.2/24 | `veth-au` | `veth-rau` | 10.10.2.1/24 |

Three separate /24s, one router with a leg in each, and no other connection between them. The leaf namespaces cannot reach each other at all except through the router, and the router needs no default route because it is directly attached to every network in the lab. Learn these three names and three networks now: Day 07 resolves through the `resolver`, Day 08 makes `auth` authoritative for a zone, Day 09 captures packets on the router's legs, and Day 18 rebuilds the wiring with bridges and VLANs.

The network you build is four namespaces and one router, and it is deliberately not bridged and not NAT-ed. For the client to reach the auth network, a packet has to genuinely be forwarded by a Linux box that has been told to forward. Then you break that five ways and learn that the five breakages produce four distinguishable symptoms — which is the actual skill, because on a bad day the symptom is all you get.

## What you will work with

- `ip netns add` and `ip netns exec` - a named network namespace, and a way to run one command inside it. A fresh namespace is emptier than a machine with networking switched off: it has exactly one interface, `lo`, and even that starts **DOWN**, so it cannot reach `127.0.0.1` until you bring it up. `ip -n client route` is shorthand for `ip netns exec client ip route` and is worth using for anything that is purely an `ip` command.
- `ip link add ... type veth peer name ...` - a veth is created as a **pair** and only ever exists as a pair: two interfaces, a virtual cable between them, whatever enters one end leaves the other. You cannot create one veth any more than you can create one end of a cable, and deleting either end deletes both. The pair is born in your own namespace and then each end is *moved* where it belongs - and moving an interface into a namespace wipes its addresses, which is why addressing has to come after the move rather than during it.
- `ip addr` and the prefix length - the number after the slash is not decoration. It is what tells the kernel which addresses are on-link, reachable without a router, and it silently creates the **connected route** you will find in the routing table without having typed it. One wrong digit there is failure 5 of `break-and-fix.sh`, and it is the most convincing wrong configuration in this whole repo.
- `ip route` and `ip route get` - `ip route` lists the rules; `ip route get 10.10.2.2` performs the actual lookup and shows you the decision: which route matched, which device, which source address, which next hop. When a routing table looks correct and traffic still goes the wrong way, `route get` is the command that tells you what the kernel concluded instead of leaving you to infer it. Longest prefix always wins, and `default` is the shortest prefix there is.
- `net.ipv4.ip_forward` - the difference between a router and a host with three interfaces. A Linux host that receives a packet addressed to somebody else, with forwarding off, drops it **silently**: no ICMP, no log, no counter you will find on your first look. The only symptom is a ping that never comes back. This sysctl is per-namespace, like nearly everything under `net.ipv4`, so the router's setting and your laptop's setting are unrelated values.
- `ip -br addr` and `ip -br link` - brief output, one line per interface, which is what makes a namespace's whole configuration readable at a glance. Read the **flags**, not just the `inet` line: `state DOWN` and `NO-CARRIER` sit right there and are the most skipped-over fields in this area. An address can be perfectly configured and completely unusable, and only the flags say so.
- `ip neigh` - the ARP table, populated by traffic rather than by configuration, so it is empty until something is sent. When a ping fails you can ask whether the next hop's MAC was ever learned, which separates "my neighbour is not there" from "my neighbour is there and the problem is further away".
- `lab/lab.sh netns-up` - the same topology in one command, for every day after this one. Days 07-10 and 18 begin with either that or today's `setup.sh`; both build identical names and addresses on purpose, so a later day cannot tell which you used.

## Verify

Checked automatically:

- [ ] all four namespaces exist
- [ ] the client has an address on 10.10.0.0/24
- [ ] the router forwards IPv4
- [ ] the client reaches the auth network through the router
- [ ] the client has a default route

Only you can confirm:

- [ ] you can draw the topology from ip route output alone
- [ ] you saw a ping fail in one direction only, and proved which one

Run the automatic checks with:

```bash
sudo ./days/day06/verify.sh
```

**Root is required today, and this is the one day where that is not a compromise.** Entering a network namespace is a privileged operation, so without root there is nothing to check at all - every line would print `SKIP`, and `SKIP` is not a pass. `verify.sh` declares this with `vl_need_root`, so a non-root run says so plainly instead of reporting five red lines you would then go and debug.

**Run it wherever you like - including your own laptop.** This is the first day with no "wrong machine", because namespaces are isolated from the machine that hosts them. There is no false PASS to warn you about and no VM to be on. If the checks are red, the topology genuinely is not built: run `sudo ./days/day06/scripts/setup.sh`.

CI executes this day for real. A GitHub runner has a Linux kernel, and a Linux kernel is the only thing this day needs - so `scripts/setup.sh` runs and then `verify.sh` runs, on every push. If you break the topology, the pipeline tells you, which is not true of Days 01-05.

## Scripts for today

| Script | What it does | Root? |
|---|---|---|
| `lab-netcheck.sh` | The payload. Prints a reachability matrix: every namespace tried against every address in the topology. There is no daemon on a networking day - the thing worth having is a question you can ask repeatedly, so leave this in one terminal and re-run it after every change. Takes an optional namespace name to test just one source. | yes |
| `setup.sh` | Builds the whole network by hand in seven visible steps: namespaces, veth pairs, addresses, forwarding, default routes, then shows the routing table it produced and pings across it. Same names and addresses as `lab.sh netns-up`. Idempotent - run it twice and the second run repairs. | yes |
| `explore-net.sh` | Read-only tour in ten sections: what a fresh namespace really contains, how the kernel describes a veth pair, the two routes in the client's table, `route get` as the decision itself, the router's three legs, ARP arriving with traffic, and what the namespace cannot see. | yes |
| `break-and-fix.sh` | Three failures, each repaired: forwarding off, no default route, and a far end that cannot reply. `--hard` adds two that look like working configuration - a correct address on a dead link, and a `/16` where a `/24` belonged. | yes |
| `teardown.sh` | Deletes the leaves one at a time so you can watch the router lose a leg with each one, then removes the router and proves all four are gone. Counts stranded interfaces on your own machine, and shows that your `ip_forward` was never touched. | yes |

Every script needs root today, which is unusual for this repo and worth saying out loud rather than leaving you to discover it. It is not privilege creep: `ip netns exec` is privileged, and there is no unprivileged way to look inside another network stack.

Read them before you run them. They are commented as teaching material rather than production code - the comments are half the day.

## Run it on the lab

### 1. No VM today

Day 06 runs on **the machine you are reading this on**. There is nothing to boot, nothing to copy, nothing to SSH into, and no memory to budget. If you still have `node1` running from Day 05 and want the RAM back:

```bash
./lab/lab.sh down node1          # deletes the VM and its disk
```

The base image stays cached, so `up` next time takes a minute, not a download. Days 07-10 and 18 need no VM either, so that RAM stays yours for a while.

### 2. Check you have the three tools

```bash
command -v ip ping sysctl
```

On RHEL-family systems: `sudo dnf install -y iproute iputils procps-ng`. On Debian or Ubuntu: `sudo apt-get install -y iproute2 iputils-ping procps`. `setup.sh` checks all three before it changes anything and stops with the right command for your distribution if any are missing.

### 3. Build the network

```bash
cd ~/lab                                   # or wherever you cloned it
sudo ./days/day06/scripts/setup.sh         # 1. seven steps, each explained
sudo ./days/day06/scripts/lab-netcheck.sh  # 2. the reachability matrix
```

Read the setup output as it goes rather than at the end. Step 3 prints the addresses; step 6 prints the client's routing table and points out that one of its two lines was never typed by anyone. If you already built the topology with `sudo ./lab/lab.sh netns-up`, this script repairs rather than complains - the two are interchangeable by design.

The matrix is six addresses against four sources, every combination. That is the picture to keep in a second terminal for the rest of the day.

### 4. Look at what you built, then break it

```bash
sudo ./days/day06/scripts/explore-net.sh   # 3. the tour
```

Stop at anything you cannot explain and read `man 8 ip-route`, `man 8 ip-netns` or `man 8 ip-address`. Section 5 is the one to slow down on: three `route get` calls giving three different answers, from one routing table with two lines in it.

```bash
sudo ./days/day06/scripts/break-and-fix.sh          # 4. three failures
sudo ./days/day06/scripts/break-and-fix.sh --hard   # 5. two more, subtler
```

Five failures, four symptoms. This table is the day's real content, and it is worth writing on paper before you run either command:

| Symptom | What it means | Which failure |
|---|---|---|
| Instant "Network is unreachable" | No route matched. Nothing was ever transmitted, so nothing is on the wire to capture. | 2 |
| Timeout, next hop still answers | The packet left and died elsewhere - classically forwarding, or a filter | 1 |
| Timeout, and requests are arriving at the far end | The return path is broken, not the forward one | 3 |
| Timeout, with address, link and gateway all apparently correct | The kernel decided something you did not intend - ask `ip route get` | 4, 5 |

Failure 3 is today's second `YOU`. Nothing about the client or the router changes - the far end simply loses its route home, so the echo request arrives and the reply has nowhere to go. A ping proves a **round trip**, so a failed ping can never tell you which direction failed; `tcpdump` at the far end can, and does. Everything is restored before the script exits, so `verify.sh` is green afterwards. If you interrupt it half way, run `setup.sh` again.

### 5. Check yourself

```bash
sudo ./days/day06/verify.sh
```

Expect **5 PASS, 2 YOU, exit 0**. Root is required, and without it every line prints `SKIP` rather than red.

The first `YOU` is a real exercise, not a formality: run `sudo ip netns exec client ip route`, then the same for `router`, `resolver` and `auth`, and draw the four boxes and three cables on paper from those four outputs alone. If you can do that, you can read a real network's routing tables, which is most of what Days 07-10 ask of you.

### 6. Optional cleanup

```bash
sudo ./days/day06/scripts/teardown.sh
```

On this day cleanup costs you nothing, because none of it is persistent. Namespaces live in the running kernel, so a reboot removes all four whether you ask or not, and every day from 07 onwards starts by rebuilding them in about a second. That is a feature: the environment is never stale and never needs migrating.

Run teardown once anyway, and watch the middle of the output. It deletes the leaves one at a time and counts the router's remaining legs after each, so you see a veth pair dying from the other end - the deletion you typed was three namespaces away from the interface that disappeared.

## Notes

Keep your own notes here. What broke, what the error actually said, and what fixed it - that is the part you will come back for.

---

Next up: **Day 07 — The DNS resolution path.**
