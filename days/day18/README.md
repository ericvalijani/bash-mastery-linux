# Day 18 — Bridges, VLANs and link aggregation

**Phase:** Production operations
**Runs on:** this machine — network namespaces, no VM
**Memory:** 0 MB
**Time:** about seventy-five minutes

Every virtual machine you have started in this course was plugged into a
bridge. Every container host has one. A bridge is a switch written in
software, and once you turn on VLAN filtering it is a switch with all of the
same lies available: a port that is up and carries nothing, a port that is in
the VLAN you meant and puts traffic in another one, a trunk that silently
stops being a trunk.

Today you build one switch with two VLANs and five things plugged into it,
then prove that two hosts on the same wire, in the same bridge, in the same
kernel, cannot reach each other — with no firewall anywhere in the topology.
Then you bond two cables into one interface and pull one of them out while
traffic is running.

This day costs nothing and runs everywhere, because all of it lives in
network namespaces on the machine you are reading this on. Namespaces are
kernel objects: they do not survive a reboot, so re-running `setup.sh` is
normal, not a repair. Day 18's namespaces are named apart from Day 06's, so
both topologies can be up at the same time and Days 07–09 keep working.

## What you will work with

- `ip link add br0 type bridge vlan_filtering 1`, and what the old
  `brctl show` cannot tell you, which is everything interesting
- `bridge vlan show`, the only command that shows per-port VLAN membership —
  `ip link` shows a port as UP whether it is in a VLAN or in none
- **PVID** versus **Egress Untagged**: the tag applied on the way in, and the
  tag removed on the way out. Two settings, one port, and a host that ends up
  in the wrong network when they disagree
- access ports versus trunk ports, and why an access host needs no VLAN
  configuration at all — the switch does the tagging on its behalf
- `ip link add link eth0 name eth0.10 type vlan id 10`, the other half of a
  trunk: one link, two subinterfaces, two addresses, two networks
- VLAN 1, which is added to every new bridge port for you — and to the bridge
  device itself, whose own row needs `vid 1 self` to remove. It is the quiet
  way two "isolated" VLANs end up sharing a third one
- `bridge fdb show`, and the fact that the forwarding database is per VLAN —
  the same MAC can be reachable in one VLAN and invisible in another
- `ip link add bond0 type bond mode active-backup miimon 100`, enslaving
  legs, and why the address goes on `bond0` and never on a leg
- `/proc/net/bonding/bond0`, `Currently Active Slave`, and why
  `active-backup` does not fail back when the old leg returns
- why `802.3ad` is not the default here: LACP needs the switch to agree, and
  a bond configured for LACP against a switch that is not doing LACP is worse
  than no bond at all
- `net.ipv4.ip_forward` per namespace, set rather than assumed, because a
  fresh namespace can inherit a host where Docker or a VPN turned it on
- the difference between segmentation that is enforced at layer 2 and
  segmentation that is a firewall rule you can turn off

## No VM, and the memory

| Where | Memory | What runs | Why |
|---|---|---|---|
| this machine | **0 MB** | six network namespaces | a bridge, veth pairs and a bond are kernel objects; a VM would add nothing |

This is the same trick as Days 06–09. It is also why Day 18 is one of the
days CI executes for real on every push: a GitHub runner can build this
topology exactly as your laptop does.

## The topology

```
            namespace sw18            ┌──────────────────────────────┐
                                      │            br0               │
  h18a 10.30.10.2 ── a-eth0 ──────────┤ sw-a   access  VLAN 10 untag  │
  h18b 10.30.10.3 ── b-eth0 ──────────┤ sw-b   access  VLAN 10 untag  │
  h18c 10.30.20.3 ── c-eth0 ──────────┤ sw-c   access  VLAN 20 untag  │
                                      │                              │
  h18t  t-eth0.10 10.30.10.4 ─┐       │                              │
        t-eth0.20 10.30.20.4 ─┴───────┤ sw-t   trunk   10 + 20 tagged │
                                      │                              │
  h18d  bond0 10.30.10.5 ─┬─ d-eth0 ──┤ sw-d0  access  VLAN 10 untag  │
                          └─ d-eth1 ──┤ sw-d1  access  VLAN 10 untag  │
                                      └──────────────────────────────┘
```

One switch. `br0` has no IP address and the namespace has forwarding off, so
there is nothing in this picture that could route between VLAN 10 and
VLAN 20 even if you asked it to.

## Scripts

| Script | What it does |
|---|---|
| `scripts/setup.sh` | nine steps: tools and kernel modules, namespaces, the VLAN-aware bridge, the veth pairs, per-port VLAN membership, addresses, the trunk subinterfaces, the bond, the payload, and a proof that isolation actually holds. Idempotent |
| `scripts/lab-vlan.sh` | installed as `lab-vlan`. `status`, `vlans`, `test`, `bond` |
| `scripts/explore-vlans.sh` | twelve read-only stops through the switch you just built |
| `scripts/break-and-fix.sh` | four real failures, each fixed in front of you. `--hard` leaves them live and adds the worst one |
| `scripts/teardown.sh` | removes today's six namespaces and nothing else. `--all` also removes `lab-vlan` and the backups |
| `verify.sh` | twenty-two automatic checks, two for you to judge |

## Run it

No VM today. From the repository root on your own machine:

```bash
cd days/day18
sudo ./scripts/setup.sh
```

Then look at what you built:

```bash
sudo lab-vlan vlans     # per-port membership, and whether filtering is on
sudo lab-vlan test      # every pair that should work, and every pair that must not
sudo lab-vlan bond      # which leg is carrying traffic right now
```

The tour, then the failures, then the check:

```bash
sudo ./scripts/explore-vlans.sh
sudo ./scripts/break-and-fix.sh
sudo ./verify.sh
```

If `setup.sh` says the bonding module is missing, the VLAN half of the day
still runs in full and `verify.sh` will not fail you for a kernel you did not
build.

## What to actually look at

**Do this before anything else.** Ping across the VLAN boundary and watch it
fail, then find the reason in a table rather than in a firewall:

```bash
sudo ip netns exec h18a ping -c2 -W1 10.30.10.3     # works
sudo ip netns exec h18a ping -c2 -W1 10.30.20.3     # does not
sudo bridge -n sw18 vlan show
```

Both hosts are in the same bridge and both are up. The only difference is one
number in that table.

**The two columns that are the whole configuration.** In `bridge vlan show`,
a port with `PVID Egress Untagged` is an access port: untagged frames
arriving get that VLAN, and frames leaving have the tag stripped, so the host
on the far end never learns a VLAN exists. A port listing several VLANs with
no PVID is a trunk: tagged in, tagged out, and the host has to do the tagging
itself. That difference is all a switch port is.

**`ip link` cannot see any of this.** Compare:

```bash
sudo ip -n sw18 -brief link show master br0
sudo bridge -n sw18 vlan show
```

The first says every port is UP. It says that whether the port is in the
right VLAN, the wrong VLAN, or no VLAN at all. When someone reports "the
interface is up but there is no traffic", this is usually the pair of
commands that ends the conversation.

**The bridge is in the VLAN tables too.** `br0` appears as its own row, and
removing VLAN 1 from it needs the `self` flag:
`bridge vlan del dev br0 vid 1 self`. Forget it and the switch itself still
has a foot in a VLAN nobody configured — harmless here, and exactly the kind
of leftover that turns into a leak on a real switch.

**The trunk host is doing work the access hosts are not.** `h18t` has two
subinterfaces on one link and an address on each; `t-eth0` itself has no
address. `h18a` has one plain interface and no VLAN configuration whatsoever.
They are on the same switch, in the same VLAN, talking to each other.

**Filtering is a flag, and the tables are decoration without it.** This is
what `--hard` turns off, and it is the failure worth internalising: every
line of `bridge vlan show` stays exactly correct while the switch ignores all
of it.

**The bond moves nothing when a cable dies.** Watch
`Currently Active Slave` change in `/proc/net/bonding/bond0` while a ping
keeps running. The address never moves because it was never on a leg.

## The four failures

| Break | What you see | Why |
|---|---|---|
| port removed from its only VLAN | link UP, address present, nothing arrives | membership is checked on ingress; `ip link` has no column for it |
| right VLAN, wrong PVID | pings still work — to the wrong network | membership and PVID are separate settings; untagged frames follow the PVID |
| trunk made untagged for one VLAN | one VLAN keeps working, the other goes dark | the tag is stripped on egress and the host's subinterface never sees it |
| active bond leg taken down | nothing happens, which is the point | the address is on `bond0`; failover is invisible above it |

And with `--hard`, a fifth: `vlan_filtering 0`, where the configuration is
perfect and inert, all four VLAN faults are left live, and
`sudo ./scripts/setup.sh` puts everything back.

## Teardown

```bash
sudo ./scripts/teardown.sh          # today's six namespaces
sudo ./scripts/teardown.sh --all    # also lab-vlan and /tmp/day18-broken
```

Deleting a namespace deletes everything inside it, and a veth pair with one
end gone disappears entirely — so the bridge, the ports, the VLAN
subinterfaces and the bond all go with it. There is nothing left behind to
clean up, and Day 06's namespaces are untouched.

A reboot does the same thing whether you ask for it or not.

## Done when

`sudo ./verify.sh` prints **22 passed, 0 failed**, 2 for you to judge, and
you can point at a line of `bridge vlan show` and say whether that port is an
access port or a trunk, what happens to an untagged frame arriving on it, and
why the isolation you just proved is not a firewall rule.

---

Next up: **Day 19 — Intrusion detection and audit alerting.**
