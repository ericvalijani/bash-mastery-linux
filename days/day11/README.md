# Day 11 - firewalld, and the nftables underneath it

> Close everything, open only what you need, and see the kernel rules your commands produced.

| | |
|---|---|
| **Phase** | Hardening and configuration management |
| **Runs on** | VM: node1 |
| **Memory** | ~2 GB (one VM) |
| **Verified by** | lint + your lab |

## Why this day exists

Most people learn the front end and never look underneath, so they cannot debug it when the front end lies.

And it does lie - not by being wrong, but by answering a narrower question than the one you asked. `firewall-cmd --query-port=8080/tcp` tells you what firewalld intends. It does not know whether anything is listening, whether another program wrote an nftables rule that runs first, or whether the change you made is in effect or merely on disk. All three of those produce a service that is "open" and unreachable.

So today you build both halves - a real service and the policy in front of it - and then you learn to ask the three questions separately: is something listening, does the policy allow it, and did that intent reach the kernel.

## What you will work with

- **`firewall-cmd --list-all` and `--zone`** - inspect the active firewalld policy instead of assuming which zone applies. Interfaces and sources are assigned to zones, and a perfectly written rule in the wrong zone protects nothing.
- **`--add-port`, `--add-service`, `--permanent`, and `--reload`** - distinguish the live runtime policy from the saved policy used after a reboot. You will make temporary changes, persist the ones you intend to keep, and prove that a reload produces the expected result.
- **Rich rules** - express conditions that a simple open port cannot, including source addresses, logging, rejection, and rate limits. They are still firewalld policy, but precise enough to document who is allowed to reach what.
- **`nft list ruleset`** - look below firewalld at the nftables rules it generated. Firewalld is the manager; nftables is the packet-filtering machinery the kernel actually evaluates.
- **nftables chains, hooks, and priorities** - follow a packet through the base chains attached to kernel hooks and understand why rule order is more than top-to-bottom text. Priorities decide which chains see a packet first.
- **`ss -tulpn`** - confirm which processes are listening and on which addresses before blaming the firewall. A closed service and a blocked service can look identical from another host, so verify the listener first and exposure second.

## Verify

Checked automatically:

- [ ] firewalld is running and enabled
- [ ] your service port is open
- [ ] the rule is permanent, not runtime only
- [ ] firewalld built a real nftables table
- [ ] the default zone is not trusted

Only you can confirm:

- [ ] you reloaded and the rules survived, and you can point to each chain

Run the automatic checks with:

```bash
sudo ./days/day11/verify.sh
```

CI can only lint this day. Nothing on a GitHub runner has SELinux, firewalld, systemd units you control, or a second host to reach over SSH - so the checks below are proven by running `verify.sh` on your own lab, and nowhere else.

## Scripts for today

| Script | What it does | Root? |
|---|---|---|
| `setup.sh` | Starts and enables firewalld, forces the default zone to `public`, installs a real web service on 8080, opens the port permanently **and** reloads, adds one rich rule, and shows the nftables table it all produced. Idempotent. | yes |
| `lab-fw.sh` | The payload. Answers the three questions side by side - what is listening, what the policy intends, what the kernel will do - and names the mismatch when they disagree. Installed as `/usr/local/bin/lab-fw`. | yes |
| `explore-firewall.sh` | Twelve read-only stops: zones, services as named port lists, runtime versus permanent, rich rules, then down into `nft` chains, hooks and priorities. | yes |
| `break-and-fix.sh` | Three failures and their repairs: a change that vanishes at the next reload, an open port with nothing behind it, and a zone that enforces nothing. `--hard` adds the two that get misdiagnosed. | yes |
| `teardown.sh` | Stops the service *before* closing its port, removes the port and rich rule from both configurations and proves it, then deletes the unit and payloads. Leaves firewalld itself running. | yes |

Read them before you run them. They are commented as teaching material rather than production code - the comments are half the day.

## Run it on the lab

### 1. On your laptop, bring up node1

Day 11 runs on **`node1`**, the same VM as Days 02 to 05. It needs no extra disk and nothing from those days.

```bash
./lab/lab.sh status              # what is already running?
./lab/lab.sh up node1            # 2 GB, about a minute
```

Days 06 to 10 needed no VM at all, so if you tore `node1` down after Day 05 it is gone along with its disk. A rebuilt `node1` is a blank Rocky image.

### 2. Copy the repo onto the VM

```bash
./lab/lab.sh push node1          # carries both days/ and lab/
./lab/lab.sh ssh node1
```

Both directories have to travel: the day scripts source `lab/on-lab-vm.sh`, and without it every one of them refuses to run.

### 3. Work through the day on the VM

Check the machine before typing anything that changes state - today's scripts change the default zone and open a port:

```bash
hostname                         # must print: node1
cd ~/lab/days/day11
```

The Rocky 9 cloud image ships firewalld but not always the rest, so install today's tools first:

```bash
sudo dnf install -y firewalld nftables iproute curl
```

`nft` is the one people are missing - firewalld works without the command-line tool because it talks to the kernel directly, which is exactly why so few people ever look underneath.

Look at the defaults before you change them:

```bash
sudo firewall-cmd --state
sudo firewall-cmd --get-default-zone
sudo firewall-cmd --list-all
sudo nft list tables
```

On an untouched image the default zone is `public`, `--list-all` shows `services: cockpit dhcpv6-client ssh` and no ports, and `nft list tables` already shows `table inet firewalld`. Nothing you have done yet - firewalld wrote that table the moment it started.

In this order:

```bash
less scripts/setup.sh            # 1. read it BEFORE running it
sudo ./scripts/setup.sh          # 2. service, zone, open port, rich rule
```

It prints each step, and step 6 is the one to slow down on: the chain list is your own `firewall-cmd` commands, translated.

```bash
curl -s http://127.0.0.1:8080/   # 3. prove the service is real
sudo /usr/local/bin/lab-fw
sudo /usr/local/bin/lab-fw 8080
```

`/usr/local/bin/lab-fw` with no argument ends with a section called "where the two disagree": ports open with nothing behind them, and listeners the firewall is blocking. On a tidy machine it prints `none`. On a machine that three people have administered, it rarely does.

```bash
sudo ./scripts/explore-firewall.sh    # 4. the tour
```

Stop at stop 9. `type filter hook input priority 0` is the whole story of how firewalld gets its say, and it is also the reason failure 4 below works. Read `man 5 firewalld.richlanguage` and `man 8 nft` on the VM for anything you cannot explain.

Now the manual check, by hand, because that is what the `YOU` item asks:

```bash
sudo firewall-cmd --add-port=9099/tcp          # runtime only, on purpose
sudo firewall-cmd --list-ports                 # 8080 and 9099
sudo firewall-cmd --reload
sudo firewall-cmd --list-ports                 # 9099 is gone. 8080 survived
sudo nft list table inet firewalld | grep -E 'chain |hook '
```

That is the day in five lines: one rule survived the reload and one did not, and you can point at the chain each one lives in. Say out loud which chain accepts 8080 before you move on.

```bash
sudo ./scripts/break-and-fix.sh          # 5. three failures, three fixes
sudo ./scripts/break-and-fix.sh --hard   # 6. the two that get misdiagnosed
```

Failure 4 is the one worth the time: another nftables table hooked at priority `-300` drops the packet before firewalld's chains ever see it, and `firewall-cmd --query-port` keeps answering `yes` throughout. Lower priority number runs first. That is how Docker and half the cluster tooling in the world silently overrule a firewall that reports itself healthy.

Failure 5 is deliberately described and not executed - it removes SSH and reloads, which would end your session with no console to rescue you. Read it and remember `--timeout=120`.

### 4. Check yourself

```bash
sudo ./days/day11/verify.sh
```

Five automatic checks and one that is yours. Note what the fifth one is really doing: `the default zone is not trusted` is not a style rule. A machine in the `trusted` zone runs firewalld, reports active and enabled, and filters nothing at all.

### 5. Optional cleanup

```bash
sudo ./scripts/teardown.sh
```

That stops the service first, then closes the port and removes the rich rule from both configurations, and checks each removal rather than assuming it. firewalld stays running - Days 12 and 13 assume a machine that still filters.

### 6. Back on your laptop

```bash
exit
./lab/lab.sh down node1          # frees the memory; takes the disk with it
```

Day 12 uses `node1` again, so you can leave it running if you have the RAM.

## Notes

The three questions, in the order that saves the most time:

1. **Is anything listening?** `ss -tulpn`. If the answer is nothing, or `127.0.0.1`, no firewall change will ever help. A process bound to loopback refuses the connection itself.
2. **Does the policy allow it?** `firewall-cmd --list-all`, and then both `--list-ports` and `--permanent --list-ports`. If those two disagree, someone forgot `--permanent` or forgot `--reload`, and the fix depends on which.
3. **Did that reach the kernel?** `nft list ruleset`. If firewalld says open, something is listening, and the connection still fails, the answer is here - usually another table with a lower priority number.

Two more worth keeping. `--add-service=http` is exactly `--add-port=80/tcp` with a name a human can read, so there is nothing to be afraid of in service files - `firewall-cmd --info-service=ssh` prints the whole definition. And `--timeout=120` is the single best habit on this day: a runtime rule that removes itself after two minutes, so a mistake made over SSH repairs itself while you are still logged in.

A firewall you cannot see working is a firewall you cannot debug. That is why the day ends in `nft` rather than in `firewall-cmd`.

Keep your own notes here. What broke, what the error actually said, and what fixed it - that is the part you will come back for.

---

Next up: **Day 12 - SSH hardening, bastions and fail2ban.**
