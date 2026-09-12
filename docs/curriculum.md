# Curriculum

Twenty days, four phases of five. Each phase ends somewhere you could stop and still have gained something whole.

## At a glance

| Day | Title | Runs on | Memory | Verified by |
|---|---|---|---|---|
| 01 | [systemd and the boot path](../days/day01/README.md) | VM: control | ~1 GB | lint + your lab |
| 02 | [Users, sudo, permissions and ACLs](../days/day02/README.md) | VM: node1 | ~2 GB | lint + your lab |
| 03 | [Processes, signals, cgroups v2 and limits](../days/day03/README.md) | VM: node1 | ~2 GB | lint + your lab |
| 04 | [Storage: LVM, filesystems and mount units](../days/day04/README.md) | VM: node1 + extra disk | ~2 GB | lint + CI |
| 05 | [Logs and time: journald, logrotate and chrony](../days/day05/README.md) | VM: node1 | ~2 GB | lint + your lab |
| 06 | [Interfaces, routing and building the namespace lab](../days/day06/README.md) | Host: network namespaces | 0 MB | lint + CI |
| 07 | [The DNS resolution path](../days/day07/README.md) | Host: network namespaces | 0 MB | lint + CI |
| 08 | [Running DNS: authoritative and recursive](../days/day08/README.md) | Host: network namespaces | 0 MB | lint + CI |
| 09 | [Packet-level debugging](../days/day09/README.md) | Host: network namespaces | 0 MB | lint + CI |
| 10 | [TLS on the wire and a private CA](../days/day10/README.md) | Host: network namespaces | 0 MB | lint + CI |
| 11 | [firewalld, and the nftables underneath it](../days/day11/README.md) | VM: node1 | ~2 GB | lint + your lab |
| 12 | [SSH hardening, bastions and fail2ban](../days/day12/README.md) | VM: control + node1 | ~3 GB | lint + your lab |
| 13 | [SELinux: contexts, booleans and denial triage](../days/day13/README.md) | VM: node1 | ~2 GB | lint + your lab |
| 14 | [Ansible fundamentals](../days/day14/README.md) | control -> node1 | ~3 GB | lint + your lab |
| 15 | [Ansible roles: your hardening baseline](../days/day15/README.md) | control -> node1 + node2 | ~3.8 GB | lint + your lab |
| 16 | [WireGuard: a private network between hosts](../days/day16/README.md) | VM: control + node1 | ~3 GB | lint + your lab |
| 17 | [Reverse proxy and TLS termination](../days/day17/README.md) | VM: node1 | ~2 GB | lint + your lab |
| 18 | [Bridges, VLANs and link aggregation](../days/day18/README.md) | Host: network namespaces | 0 MB | lint + CI |
| 19 | [Intrusion detection and audit alerting](../days/day19/README.md) | VM: node1 | ~2 GB | lint + your lab |
| 20 | [Backup, restore and the restore drill](../days/day20/README.md) | VM: control + node1 | ~3 GB | lint + your lab |

## Phase 1 — The host (Days 01–05)

One machine, understood properly: boot, identity, processes, storage, logs.

### Day 01 — systemd and the boot path

Follow a Linux machine from power-on to a running service, and write a unit that survives a reboot.

*Runs on VM: control.* Every later day ends with "make it persist", and on this family of distros that always means a unit file. Start where the machine starts.

### Day 02 — Users, sudo, permissions and ACLs

Give a service account exactly the access it needs and nothing else.

*Runs on VM: node1.* "It works when I run it as root" is where most security incidents begin. Least privilege is a habit you build with your hands.

### Day 03 — Processes, signals, cgroups v2 and limits

Constrain a process so it cannot take the machine down with it.

*Runs on VM: node1.* Containers are cgroups plus namespaces. Meet the primitives directly and container behaviour stops being magic.

### Day 04 — Storage: LVM, filesystems and mount units

Grow a filesystem while it is mounted, and mount it persistently.

*Runs on VM: node1 + extra disk.* Disk full at 3am is the most common page in operations. Growing storage without downtime is the fix, and it should be boring.

### Day 05 — Logs and time: journald, logrotate and chrony

Make logs persistent, bounded, and correctly timestamped.

*Runs on VM: node1.* Every diagnosis in Days 6-20 is log reading. Unbounded logs fill the disk; wrong clocks make correlation across hosts impossible.

## Phase 2 — The network (Days 06–10)

Five days of real kernel networking that cost no memory at all.

### Day 06 — Interfaces, routing and building the namespace lab

Build a four-node routed network inside your kernel and prove packets cross it.

*Runs on Host: network namespaces.* This is real kernel networking, not a simulation: real interfaces, real routing tables, real packets. It is also the environment Days 7-10 and 18 run in, at zero memory cost.

### Day 07 — The DNS resolution path

Trace one name lookup through every layer that can answer it.

*Runs on Host: network namespaces.* "It is always DNS" is a joke because it is usually true. Knowing which layer answered is the difference between a five minute fix and an afternoon.

### Day 08 — Running DNS: authoritative and recursive

Serve your own zone, then resolve it recursively from another namespace.

*Runs on Host: network namespaces.* Reading DNS is one skill; owning a zone is another. Days 10, 12 and 17 all need names that resolve to your own machines.

### Day 09 — Packet-level debugging

Prove where a packet stops, instead of guessing.

*Runs on Host: network namespaces.* When two hosts disagree about whether traffic arrived, only a capture settles it. This day is the one you will reuse most.

### Day 10 — TLS on the wire and a private CA

Run your own certificate authority and understand what a client actually verifies.

*Runs on Host: network namespaces.* Certificate errors are the most common self-inflicted outage. Issuing certificates yourself makes the trust chain concrete, and Day 17 needs this CA.

## Phase 3 — Hardening and configuration management (Days 11–15)

Lock a host down by hand, then make it repeatable.

### Day 11 — firewalld, and the nftables underneath it

Close everything, open only what you need, and see the kernel rules your commands produced.

*Runs on VM: node1.* Most people learn the front end and never look underneath, so they cannot debug it when the front end lies. Look at both.

### Day 12 — SSH hardening, bastions and fail2ban

Reach node1 only through control, with keys only, and ban brute force.

*Runs on VM: control + node1.* SSH is the door. It is also the service most often left with defaults that a scanner finds in minutes.

### Day 13 — SELinux: contexts, booleans and denial triage

Serve content from a non-default path with SELinux still enforcing.

*Runs on VM: node1.* This is the day that separates operators from people who type setenforce 0. Denial triage is a procedure, and once you know it, SELinux stops being an obstacle.

### Day 14 — Ansible fundamentals

Replace one day of manual work with a playbook that is safe to run twice.

*Runs on control -> node1.* You have now configured hosts by hand for thirteen days. This is the day that work becomes repeatable, and idempotency stops being a buzzword.

### Day 15 — Ansible roles: your hardening baseline

Turn Days 11-13 into one role and apply it to a host that has never been touched.

*Runs on control -> node1 + node2.* A baseline you can apply to a fresh machine in one command is the whole point of configuration management. node2 is the proof, because it starts clean.

## Phase 4 — Production operations (Days 16–20)

The things that turn a configured host into one you can rely on.

### Day 16 — WireGuard: a private network between hosts

Build an encrypted tunnel between two machines and make it come back after reboot.

*Runs on VM: control + node1.* Every real environment has a management network you are not supposed to expose. WireGuard is small enough to understand completely, which is rare in VPNs.

### Day 17 — Reverse proxy and TLS termination

Put nginx in front of a plain HTTP service and serve it over TLS with your own CA.

*Runs on VM: node1.* This is how almost every internal service is actually exposed. It also ties Day 10 to something running, and Day 13 will fight you here.

### Day 18 — Bridges, VLANs and link aggregation

Segment one wire into isolated networks, then prove the isolation.

*Runs on Host: network namespaces.* Every hypervisor and every switch does this. It is also how you explain to yourself why two machines on the same cable cannot see each other.

### Day 19 — Intrusion detection and audit alerting

Notice an attack and a file change without watching the screen.

*Runs on VM: node1.* Hardening stops the easy attempts. Detection is what tells you about the rest, and auditd is the tool that answers who changed this file.

### Day 20 — Backup, restore and the restore drill

Prove you can get the data back, on a schedule, and know how long it takes.

*Runs on VM: control + node1.* An untested backup is a rumour. This is the last day because it is the one that decides whether everything before it was worth configuring.

## Why there is no capstone

A capstone is a thing you build. Operations is not a building discipline — it is a diagnostic one. The exam for a developer is whether the thing works; the exam for an operator is whether you can find out why it does not.

So instead of a final project, the lab persists. Day 06 builds a network and Days 07–10 and 18 operate inside it. Days 11–13 harden a host by hand and Day 15 turns that work into an Ansible role applied to a machine that has never been touched. Day 20 restores the data the earlier days created. Nothing is thrown away, and nothing is rebuilt from a template.
