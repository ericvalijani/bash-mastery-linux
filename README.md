# Bash Mastery: Linux

> Twenty days of Linux operations — the host, the network, security hardening, and configuration management — on real machines you build yourself.

Nothing here is simulated. There is no offline mode, no fake output, and no capstone application. You get three virtual machines and a kernel-level network lab, and you operate them until they behave.

---

## 🚀 Get started

```bash
./lab/lab.sh check          # can this machine run the lab? start here
./lab/lab.sh image          # Rocky 9 base image, ~1 GB, downloaded once
./lab/lab.sh up control     # a real VM, about a minute
./lab/lab.sh ssh control    # you are in
```

`check` tells you exactly what your distribution is missing and prints the install command for it. On Ubuntu that is usually:

```bash
sudo apt-get install -y qemu-system-x86 libvirt-daemon-system libvirt-clients libvirt-daemon-config-network virtinst acl
sudo systemctl enable --now libvirtd
sudo usermod -aG kvm,libvirt "$USER"   # then log out and back in
```

> The `usermod` step is the one people skip. Without it `/dev/kvm` is not writable and every VM creation fails on permissions.

**Not ready to install a hypervisor?** Start at Day 06 instead. Days 06–10 and 18 need only `iproute2` and root:

```bash
sudo ./lab/lab.sh netns-up      # builds the whole network, 0 MB
sudo ./lab/lab.sh netns-status  # shows it and ping-tests it
```

---

## 🗺️ The path

**Phase 1 — The host** · Days 01–05
One machine, understood properly: boot, identity, processes, storage, logs.

**Phase 2 — The network** · Days 06–10
Five days of real kernel networking that cost no memory at all.

**Phase 3 — Hardening and configuration management** · Days 11–15
Lock a host down by hand, then make it repeatable.

**Phase 4 — Production operations** · Days 16–20
The things that turn a configured host into one you can rely on.

| Day | Title | Runs on | Verified by |
|---|---|---|---|
| **01** | [systemd and the boot path](days/day01/README.md) | VM: control | lint + your lab |
| **02** | [Users, sudo, permissions and ACLs](days/day02/README.md) | VM: node1 | lint + your lab |
| **03** | [Processes, signals, cgroups v2 and limits](days/day03/README.md) | VM: node1 | lint + your lab |
| **04** | [Storage: LVM, filesystems and mount units](days/day04/README.md) | VM: node1 + extra disk | lint + CI |
| **05** | [Logs and time: journald, logrotate and chrony](days/day05/README.md) | VM: node1 | lint + your lab |
| **06** | [Interfaces, routing and building the namespace lab](days/day06/README.md) | Host: network namespaces | lint + CI |
| **07** | [The DNS resolution path](days/day07/README.md) | Host: network namespaces | lint + CI |
| **08** | [Running DNS: authoritative and recursive](days/day08/README.md) | Host: network namespaces | lint + CI |
| **09** | [Packet-level debugging](days/day09/README.md) | Host: network namespaces | lint + CI |
| **10** | [TLS on the wire and a private CA](days/day10/README.md) | Host: network namespaces | lint + CI |
| **11** | [firewalld, and the nftables underneath it](days/day11/README.md) | VM: node1 | lint + your lab |
| **12** | [SSH hardening, bastions and fail2ban](days/day12/README.md) | VM: control + node1 | lint + your lab |
| **13** | [SELinux: contexts, booleans and denial triage](days/day13/README.md) | VM: node1 | lint + your lab |
| **14** | [Ansible fundamentals](days/day14/README.md) | control -> node1 | lint + your lab |
| **15** | [Ansible roles: your hardening baseline](days/day15/README.md) | control -> node1 + node2 | lint + your lab |
| **16** | [WireGuard: a private network between hosts](days/day16/README.md) | VM: control + node1 | lint + your lab |
| **17** | [Reverse proxy and TLS termination](days/day17/README.md) | VM: node1 | lint + your lab |
| **18** | [Bridges, VLANs and link aggregation](days/day18/README.md) | Host: network namespaces | lint + CI |
| **19** | [Intrusion detection and audit alerting](days/day19/README.md) | VM: node1 | lint + your lab |
| **20** | [Backup, restore and the restore drill](days/day20/README.md) | VM: control + node1 | lint + your lab |

Full detail, with the reasoning for each day, is in [docs/curriculum.md](docs/curriculum.md). The complete state of the project — design decisions, what is verified, what is not, and what is left to do — is in [docs/HANDOFF.md](docs/HANDOFF.md).

---

## 💾 Memory budget

Designed for an 8 GB laptop, measured rather than hoped.

| Days | Needs | RAM |
|---|---|---|
| 01–05, 11–13, 17, 19 | one VM | ~1 GB |
| **06–10, 18** | **no VM at all** | **0 MB** |
| 14, 16, 20 | two VMs | ~1.8 GB |
| 15 | three VMs | ~2.5 GB |

| VM | RAM | Role |
|---|---|---|
| `control` | 1024 MB | Where you sit. Ansible runs from here |
| `node1` | 768 MB | The machine you configure and break |
| `node2` | 768 MB | Starts clean. Only Day 15 needs it |

Disks are thin qcow2 overlays on one shared base image, so three VMs cost barely more than one until you install packages. Budget about 12 GB of disk. Peak memory happens on Day 15 only.

---

## 🧪 What a green tick means

Verification is split into three tiers, because pretending CI can prove everything is how you end up trusting a badge that proves nothing.

| Tier | What it checks | Where it runs | Days |
|---|---|---|---|
| **lint** | `bash -n`, shellcheck | GitHub Actions | all 20 |
| **CI** | the day executed for real | GitHub Actions | 04, 06, 07, 08, 09, 10, 18 |
| **lab** | the day executed for real | your VMs | 01, 02, 03, 05, 11, 12, 13, 14, 15, 16, 17, 19, 20 |

GitHub runners are full Ubuntu VMs with `sudo`, so namespaces, DNS servers, `tcpdump`, `openssl`, VLANs and even LVM on a loopback file are genuinely real there — that is 7 of the 20 days.

The other 13 cannot be faked on a runner. Ubuntu has no SELinux, no firewalld, and no second host to reach over SSH. Those days are verified by a script you run on your own lab:

```bash
./days/day13/verify.sh
```

```
Day 13 — SELinux: contexts, booleans and denial triage
---------------------------------------------------
  PASS  SELinux is enforcing
  PASS  the web root carries a web content label
  FAIL  a custom policy module is loaded
  YOU   you fixed a denial by relabelling, not by disabling SELinux

6 passed, 1 failed, 2 for you to judge
```

Every day has one. `PASS`/`FAIL` come from real commands against real state; `YOU` items are judgement calls that no script can test and that never affect the exit status. Run it on the wrong machine and it reports `SKIP` with the reason, rather than lying in either direction.

---

## 🧰 The lab

One script owns the whole environment.

```bash
./lab/lab.sh check              # prerequisites, with install hints
./lab/lab.sh image              # download the Rocky 9 base image
./lab/lab.sh up [vm...]         # create VMs (default: control node1)
./lab/lab.sh status             # VMs, their IPs, and namespaces
./lab/lab.sh ssh <vm>           # log in
./lab/lab.sh push <vm> [path]   # copy days/ and lab/ to ~/lab on a VM
./lab/lab.sh add-disk <vm> [GB] # attach a blank disk (Day 04)
./lab/lab.sh down [vm...]       # delete VMs and their disks
sudo ./lab/lab.sh netns-up      # build the Days 06-10 network
sudo ./lab/lab.sh netns-status  # show it and ping-test it
sudo ./lab/lab.sh netns-down    # tear it down
./lab/lab.sh diagnose <vm>      # every clue about a VM that will not boot
./lab/lab.sh console <vm>       # attach to its console (--restart to watch it boot)
./lab/lab.sh destroy            # everything
```

### Looking at a VM

Every VM gets a VNC screen bound to `127.0.0.1`:

```bash
virsh vncdisplay control    # e.g. 127.0.0.1:0 - open it in any VNC viewer
```

That is deliberate. A headless guest that boots but writes nothing to its
serial port is impossible to diagnose, and on some hardware the absence of a
display device stops these cloud images booting at all. Set
`LAB_GRAPHICS=none` if you want strictly headless VMs.

### The namespace network

```
  client 10.10.0.2 ---- 10.10.0.1 [router] 10.10.1.1 ---- 10.10.1.2 resolver
                                  10.10.2.1 ---- 10.10.2.2 auth
```

Real interfaces, real routing tables, real packets, real `tcpdump` captures — this is the same kernel machinery containers are built from. It is not a simulation, and it costs no memory.

### Why Rocky Linux guests on an Ubuntu host

Because of Day 13. SELinux is RHEL-family; Ubuntu ships AppArmor instead. It also makes Day 11 `firewalld`-first and makes Ansible feel native. Your host distribution barely matters — KVM is in the Linux kernel already, so Ubuntu, Fedora, Debian and Arch hosts are all fine and `check` prints the right package names for each.

---

## 📁 Layout

```
README.md                    you are here
docs/curriculum.md           all 20 days, with the reasoning
docs/HANDOFF.md              complete project state, for a cold start
CONTRIBUTING.md              how to change this without breaking it
LICENSE                      MIT
tests/cli.sh                 repo self-test: no VM, no root, no network
.pre-commit-config.yaml      shellcheck, whitespace, large-file guard
lab/lab.sh                   the whole environment, one script
lab/verify-lib.sh            assertion helpers for verify.sh
lab/ci-day.sh               runs one day in CI, honestly
lab/README.md                hardware, install, manual fallbacks
days/dayNN/README.md         the day
days/dayNN/verify.sh         did you finish it
days/dayNN/scripts/          your work goes here
.github/workflows/ci.yml     lint everything, execute what it can
```

---

## ⚠️ Honest status

`lab.sh` has never been executed against real KVM hardware. It is syntax-clean, and its `check`, `--help` and error paths have been exercised — but VM creation, cloud-init and the namespace wiring have not run on a real host yet.

So run `./lab/lab.sh check` first. It is the most tested part, and it will tell you what is missing before anything tries to create a VM. If `virt-install` rejects `--os-variant rocky9`, your `osinfo-db` predates Rocky 9 — use `rhel9.0`; the script already tries to fall back, and `lab/README.md` has the manual commands.

Days 01 through 08 ship five worked scripts each. The other 12 `days/dayNN/scripts/` directories are empty on purpose - they are written one day at a time, each run on the real lab before the next is started.

---

## License and contributing

MIT - see [LICENSE](LICENSE).

Fixes are welcome, especially anything that does not work on your distribution or your hardware. Read [CONTRIBUTING.md](CONTRIBUTING.md) first - it covers how a day is put together and what has to stay in step with what.
