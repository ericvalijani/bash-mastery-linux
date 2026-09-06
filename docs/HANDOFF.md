# Bash Mastery: Linux — Project Handoff

> Complete state of this repository in one file. Written to be pasted into a
> fresh chat so an assistant can pick the work up cold, with no other context.

**Last updated:** 2026-09-06
**Repo:** `bash-mastery-linux`
**Status:** scaffold complete, 20 days written, **Day 01 scripts written**;
Days 02-20 scripts still to write
**Never executed against real KVM hardware.** See §8.
**Licence:** MIT (`LICENSE`). Contribution rules: `CONTRIBUTING.md`.

---

## 0. How to use this file

If you are an assistant reading this in a new chat: this file plus the
repository is the whole project. Read §2 before proposing anything, because
several design choices are settled and re-litigating them wastes time.

If you change anything in this repo, update this handoff in the same pass.
That is the point of the file. §10 says what to touch.

---

## 1. What this project is

Twenty days of Linux operations — host, network, security hardening, and
configuration management — carried out on real machines the learner builds
themselves.

It is deliberately **not** a software project. There is no application, no
capstone deliverable, and nothing simulated. The learner gets three Rocky
Linux 9 virtual machines plus a kernel-level network lab, and operates them
until they behave.

### Why there is no capstone

A capstone is a thing you build. Operations is a diagnostic discipline, not a
constructive one — the exam for a developer is whether the thing works, the
exam for an operator is whether you can find out why it does not.

So instead of a final project, the lab persists and accumulates. Day 06 builds
a network and Days 07–10 and 18 operate inside it. Days 11–13 harden a host by
hand and Day 15 turns that work into an Ansible role applied to `node2`, which
starts clean. Day 20 restores data the earlier days created. Nothing is thrown
away and nothing is rebuilt from a template.

If a capstone were ever forced onto this, the only sensible one would be "a
hardened internal service platform: private CA, DNS zone, bastion, firewalled
web tier, deployed by one Ansible role" — but it would collapse Days 10–17
into integration debugging and cost more than it teaches. Decided against.

### Scope boundaries

In scope: systemd, users and permissions, processes and cgroups, storage and
LVM, logs and time, interfaces and routing, DNS, packet capture, TLS and a
private CA, firewalld and nftables, SSH hardening, SELinux, Ansible, WireGuard,
reverse proxying, VLANs and bridges, intrusion detection, backup and restore.

Out of scope, deliberately: containers and Kubernetes, cloud providers, CI/CD
pipelines as a subject, application development, mail servers, Samba, iSCSI,
kernel compilation.

---

## 2. Settled design decisions

Do not reopen these without being asked.

| Decision | Value | Why |
|---|---|---|
| Name | `bash-mastery-linux` | Owner's choice |
| Length | 20 days, 4 phases of 5 | Started at 15, extended to 20 on request |
| Capstone | none | See §1 |
| Application | none | Ops curriculum, not a software one |
| Simulation / offline mode | **forbidden** | Everything must run for real |
| Guest distro | Rocky Linux 9 | SELinux is RHEL-family; Ubuntu ships AppArmor |
| Hypervisor | KVM + libvirt | In-kernel on Linux; no VirtualBox or Multipass |
| Host | Linux, 8 GB RAM | Owner runs Ubuntu with only Docker/Podman installed |
| Networking days | `ip netns` on the host | Real kernel networking at zero RAM cost |
| SELinux | its own day (13) | Requested specifically |
| Verification | three tiers | See §5 |
| Day scripts | shipped, written day by day | Day 01 done. A day with no scripts yet ships an empty `scripts/` and its README says so |
| Blast radius | nothing the owner runs may put the laptop at risk | Every destructive step happens inside a VM or a namespace, both disposable |
| Ansible's job | configuration manager, nothing more | Days 14-15 only. It deploys a hardening baseline to VMs; it is not the subject of the course |
| Script style | commented as teaching material | The comments are half the lesson; these are not production scripts and should not be tightened into them |

### Two points that are easy to get wrong

**Network namespaces are not a simulation.** They are real interfaces, real
routing tables, real packets and real `tcpdump` captures — the same kernel
machinery containers are built from. This matters because it is what makes five
of the twenty days cost no memory. Do not describe them as fake or as a
stand-in for "proper" networking.

**Nothing dangerous ever runs on the host.** This is a hard requirement, not
a preference. Every command that hardens, firewalls, relabels, partitions or
locks something out runs inside a Rocky VM, which can be deleted and rebuilt
in a minute with `lab.sh down` then `up`. The host only ever runs `lab.sh`,
`virsh`, `ssh` and `scp`.

The namespace days (06-10, 18) are the one thing that touches the host, and
they are safe by construction: `netns-up` creates named namespaces and veth
pairs, edits no file anywhere, and `netns-down` removes all of it. A reboot
also removes all of it. No host service, no sysctl outside the namespaces, no
rule in the host's own firewall tables.

If even that is unwanted, the escape hatch already works and costs 1 GB:
push the repo to the control VM and run the topology inside it —
`sudo ~/lab/lab/lab.sh netns-up`. The script only needs `ip` and root, both of
which the guest has. Same script, same checks, zero host involvement.

**Containers cannot replace the VMs.** Containers share the host kernel, so
there is no separate systemd, no separate disks and no separate SELinux state.
That rules out Days 01–05 and 13 entirely. The VMs are not a convenience.

---

## 3. The lab

One script owns the entire environment: `lab/lab.sh` (586 lines, 31 functions,
12 subcommands).

```bash
./lab/lab.sh check              # prerequisites, with per-distro install hints
./lab/lab.sh image              # download the Rocky 9 base image (~1 GB, once)
./lab/lab.sh up [vm...]         # create VMs (default: control node1)
./lab/lab.sh status             # VMs, their IPs, and namespaces
./lab/lab.sh ssh <vm>           # log in
./lab/lab.sh push <vm> [path]   # copy days/ and lab/ into ~/lab on a VM
./lab/lab.sh add-disk <vm> [GB] # attach a blank disk (Day 04 needs this)
./lab/lab.sh down [vm...]       # delete VMs and their disks
sudo ./lab/lab.sh netns-up      # build the Days 06-10 and 18 network
sudo ./lab/lab.sh netns-status  # show it and ping-test it
sudo ./lab/lab.sh netns-down    # tear it down
./lab/lab.sh destroy            # everything
```

`push` is how the repository reaches a VM. It `scp`s the given paths (default
`days` and `lab`) into `~/lab` on the guest and re-applies the execute bits,
because some `scp` builds drop them. Push both directories, not just `days`:
every `verify.sh` sources `../../lab/verify-lib.sh`, so a day pushed on its own
cannot check itself. There is deliberately no shared folder and no guest
agent — one copy command is easier to reason about than a mount that silently
stops syncing.

### Configuration (all overridable by environment variable)

| Variable | Default |
|---|---|
| `LAB_HOME` | `$HOME/.local/share/bash-mastery-linux` |
| `LAB_BASE_URL` | `https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2` |
| `LAB_USER` | `lab` |
| `LAB_NET` | `default` (the libvirt NAT network) |
| `SSH_KEY` | `$HOME/.ssh/id_ed25519` (generated if absent) |
| `LAB_DISK_SIZE` | `10G` |

Derived paths: `$LAB_HOME/images`, `$LAB_HOME/disks`, `$LAB_HOME/seed`.
Nothing is written inside the repository.

### The virtual machines

| VM | RAM | Role |
|---|---|---|
| `control` | 1024 MB | Where the learner sits. Ansible runs from here |
| `node1` | 768 MB | The machine that gets configured and broken |
| `node2` | 768 MB | Starts clean. Only Day 15 needs it |

Disks are thin qcow2 overlays on one shared base image
(`qemu-img create -f qcow2 -F qcow2 -b <base>`), so three VMs cost barely more
than one until packages are installed. Budget ~12 GB of disk.

VMs are created with `virt-install --import --cloud-init`, `--graphics none`,
`--noautoconsole`, virtio disk and network. The `--os-variant` value is probed
via `osinfo-query` with a fallback chain `rocky9 → rhel9.0 → rhel9-unknown →
generic`, because older `osinfo-db` packages do not know Rocky 9.

cloud-init sets the hostname, creates `$LAB_USER` with passwordless sudo, and
installs the public half of `$SSH_KEY`. **SELinux is deliberately left
enforcing** — Day 13 depends on it.

### The namespace network (Days 06–10, 18)

```
  client 10.10.0.2 ---- 10.10.0.1 [router] 10.10.1.1 ---- 10.10.1.2 resolver
                                  10.10.2.1 ---- 10.10.2.2 auth
```

Four namespaces: `client`, `router`, `resolver`, `auth`. Three veth pairs
(`veth-cl/veth-rcl`, `veth-rs/veth-rrs`, `veth-au/veth-rau`). The router has
`net.ipv4.ip_forward=1` and every namespace gets a default route through it.
`netns-up` finishes by pinging `client → auth` to prove the topology works.

Costs 0 MB and needs only `iproute2` and root. This is the recommended entry
point for anyone who does not want to install a hypervisor yet.

---

## 4. The twenty days

Four phases of five. Each phase ends somewhere the learner could stop and
still have gained something whole.

**Phase 1 — The host (01–05).** One machine, understood properly.
**Phase 2 — The network (06–10).** Real kernel networking, no memory cost.
**Phase 3 — Hardening and configuration management (11–15).** Lock a host down by hand, then make it repeatable.
**Phase 4 — Production operations (16–20).** What turns a configured host into one you can rely on.

| Day | Title | Runs on | Verified by |
|---|---|---|---|
| 01 | systemd and the boot path | VM: control | lint + lab |
| 02 | Users, sudo, permissions and ACLs | VM: node1 | lint + lab |
| 03 | Processes, signals, cgroups v2 and limits | VM: node1 | lint + lab |
| 04 | Storage: LVM, filesystems and mount units | VM: node1 + extra disk | lint + **CI** |
| 05 | Logs and time: journald, logrotate and chrony | VM: node1 | lint + lab |
| 06 | Interfaces, routing and building the namespace lab | Host: namespaces | lint + **CI** |
| 07 | The DNS resolution path | Host: namespaces | lint + **CI** |
| 08 | Running DNS: authoritative and recursive | Host: namespaces | lint + **CI** |
| 09 | Packet-level debugging | Host: namespaces | lint + **CI** |
| 10 | TLS on the wire and a private CA | Host: namespaces | lint + **CI** |
| 11 | firewalld, and the nftables underneath it | VM: node1 | lint + lab |
| 12 | SSH hardening, bastions and fail2ban | VM: control + node1 | lint + lab |
| 13 | SELinux: contexts, booleans and denial triage | VM: node1 | lint + lab |
| 14 | Ansible fundamentals | control → node1 | lint + lab |
| 15 | Ansible roles: your hardening baseline | control → node1 + node2 | lint + lab |
| 16 | WireGuard: a private network between hosts | VM: control + node1 | lint + lab |
| 17 | Reverse proxy and TLS termination | VM: node1 | lint + lab |
| 18 | Bridges, VLANs and link aggregation | Host: namespaces | lint + **CI** |
| 19 | Intrusion detection and audit alerting | VM: node1 | lint + lab |
| 20 | Backup, restore and the restore drill | VM: control + node1 | lint + lab |

### Dependencies between days

Days are otherwise self-contained, but these links are intentional and must
not be broken when editing:

- **06 → 07, 08, 09, 18.** Day 06 builds the namespace topology the rest use.
- **10 → 17.** Day 17 serves TLS using the private CA issued on Day 10.
- **08 → 17.** Day 17 expects `www.lab.test` to resolve from Day 08's zone.
- **11, 12, 13 → 15.** Day 15 turns that manual hardening into an Ansible role.
- **04 → 20.** Day 20 backs up and restores `/srv/data` from Day 04.
- **14 → 15.** Roles build on the playbook basics.

### Memory budget

| Days | Needs | RAM |
|---|---|---|
| 01–05, 11–13, 17, 19 | one VM | ~1 GB |
| **06–10, 18** | **no VM at all** | **0 MB** |
| 14, 16, 20 | two VMs | ~1.8 GB |
| 15 | three VMs | ~2.5 GB |

Peak is Day 15 only. Designed against an 8 GB laptop.

---

## 5. The verification model

This is the part most likely to be misunderstood, so it is spelled out.

Verification is split into three tiers because pretending CI can prove
everything produces a badge that proves nothing.

| Tier | What it checks | Where it runs | Days |
|---|---|---|---|
| **lint** | `bash -n`, shellcheck | GitHub Actions | all 20 |
| **CI** | the day executed for real | GitHub Actions | 04, 06, 07, 08, 09, 10, 18 |
| **lab** | the day executed for real | the learner's VMs | the other 13 |

GitHub runners are full Ubuntu VMs with `sudo`, so namespaces, DNS servers,
`tcpdump`, `openssl`, VLANs and **LVM on a loopback file** are all genuinely
real there. That is 7 of 20 days machine-verified in CI.

The other 13 cannot be faked on a runner: Ubuntu has no SELinux, no firewalld,
and no second host to reach over SSH. Those days are still *automated* — just
by the learner, on their own lab.

### `days/dayNN/verify.sh`

Every day has one. **102 automatic checks and 31 judgement items** across the
twenty days. Each script sources `lab/verify-lib.sh`, declares its checks, and
ends with `vl_summary`. Exit status is 0 only when nothing failed.

Four outcomes:

| | Meaning |
|---|---|
| `PASS` | the command succeeded |
| `FAIL` | the command failed — the day is not done |
| `SKIP` | a prerequisite is missing, so the check could not run |
| `YOU` | a judgement call; printed as a reminder, never affects exit status |

The `SKIP` path matters: running a lab-tier day on the wrong machine reports
what is missing rather than producing false failures. Verified behaviour on an
Ubuntu host with no SELinux:

```
Day 13 — SELinux: contexts, booleans and denial triage
  SKIP  SELinux is enforcing
  SKIP  the web root carries a web content label
  YOU   you fixed a denial by relabelling, not by disabling SELinux

could not run: missing getenforce semanage
This day runs elsewhere - see the "Runs on" line in its README
7 checks skipped, 2 for you to judge.
exit=0
```

### `lab/verify-lib.sh` API (100 lines)

```bash
vl_init "Day 01 - systemd and the boot path"   # header
vl_need systemctl semanage                     # missing -> later checks SKIP
vl_need_root                                   # not root -> later checks SKIP
vl_check "description" 'shell command string'  # PASS / FAIL / SKIP
vl_manual "description"                        # YOU, never fails
vl_summary                                     # totals; exit 1 if any FAIL
```

**Convention:** `vl_check` command strings are written inside single quotes,
so use double quotes within the command itself. Keep to it and the checks
stay readable and quote-safe.

Checks test the **work product**, not knowledge. Examples: `semanage fcontext
-l` contains `/srv/www` (permanent, not a transient `chcon`); `restorecon -nvR`
produces no output; a second `ansible-playbook` run reports `changed=0`; a
`restic` restore `diff -r`s clean against the source.

---

## 6. CI

`.github/workflows/ci.yml` (79 lines), three jobs:

| Job | What it does |
|---|---|
| `lint` | `bash -n` on every `*.sh`, then `shellcheck -x -S warning` |
| `verifiable-days` | matrix over days 04, 06, 07, 08, 09, 10, 18; runs `sudo bash lab/ci-day.sh <NN>` |
| `coverage` | `if: always()`; prints exactly which days were **not** proven and why |

The `coverage` job exists so a green run never implies more than it did. It
names all 13 lab-only days and the reason each is unprovable on a runner.

### `lab/ci-day.sh` (57 lines)

Builds an environment for one day, then runs its `verify.sh`:

1. If `days/dayNN/scripts/setup.sh` exists, run it.
2. Else, if the day is 06, 07, 08, 09 or 18, run `lab/lab.sh netns-up`.
3. Else, print `SKIPPED (not yet implemented)` and **exit 0**.

**`verify.sh` only runs when the day's work exists.** A `setup.sh` means it exists. Day 06 is the single exception: the namespace topology *is* its work, so `netns-up` alone is enough. For days 07, 08, 09 and 18 the topology is only the floor - the zone, the resolver and the bridge are the day's work, and running `verify.sh` before those scripts exist fails every time. That is a missing script, not a broken repo, so those jobs skip and exit 0.

Step 3 is why CI is green today: no day scripts exist yet, so there is nothing
to stand up. Each CI day becomes genuinely verified the moment its `setup.sh`
is written. This is honest rather than convenient — the alternative was a
failing pipeline that trains people to ignore it.

Permissions are pinned to `contents: read`. Actions used: `actions/checkout@v4`.

---

## 7. How a day is put together

Every file in this repository is hand-written and hand-edited. There is no
generator and no build step.

A day is three files that must agree with each other:

| File | What it holds |
|---|---|
| `days/dayNN/README.md` | objective, why it matters, the work, the checks, what CI proves |
| `days/dayNN/verify.sh` | those same checks, as assertions, using the `vl_*` API in §5 |
| `days/dayNN/scripts/*` | the scripts the day walks the reader through |

**The one rule: a check listed on the page must exist in `verify.sh`, and the
other way round.** A page claiming a check its verifier does not run is the
single failure this repository cannot tolerate, because every claim in it is
supposed to be true. Add or remove a check in both places, in the same commit.

Day pages follow a fixed order so they read the same way: title and metadata
line, objective, why it matters, the work, then - once the day has scripts -
a **Scripts for today** table and a **Run it on the lab** runbook, then the
check list. Copy the shape from `days/day01/README.md`, which is the only
complete example so far.

The metadata line carries the day's tier and memory cost. If either changes,
§4 and §5 here, the tier table in `README.md` and the CI matrix in `ci.yml`
all have to change with it. §10 lists every one of those pairings.
## 8. Verified state, and what is not verified

### What has actually been run

| Check | Result |
|---|---|
| `tests/cli.sh` | **109 passed, 0 failed** |
| `bash -n` on all 29 shell scripts | 0 failures |
| `lab/lab.sh --help` | stops cleanly at the memory budget |
| `lab/lab.sh check` | runs every section, prints the full summary |
| `lab/lab.sh bogus` | `FAIL unknown subcommand`, exit 1 |
| `lab/lab.sh netns-down` as non-root | `FAIL this subcommand needs root`, exit 1 |
| `days/day13/verify.sh` on Ubuntu | 7 SKIP, 2 YOU, exit 0 |
| `lab/ci-day.sh 04` | `SKIPPED (not yet implemented)`, exit 0 |
| `lab/ci-day.sh 99` / no argument | exit 2 with usage |
| First real CI run (2026-09-04) | days 04, 06, 10 green; 07, 08, 09, 18 now skip; `lint` fixed |
| `ci.yml` structure and tabs | parses, no tabs |
| `lab.sh push` with no argument | `FAIL usage: ... push <vm> [path...]`, exit 1 |
| `lab.sh push bogus` | `FAIL unknown vm`, exit 1 |
| `lab.sh --help` after the patch | lists 12 subcommands including `push` |
| `set -e` behaviour of `[[ cond ]] && x=y` | confirmed safe: a false test in a non-final `&&` position does not exit |

### What has never been run

**`lab.sh` has never touched real KVM hardware.** The sandbox it was written in
has no `/dev/kvm`, no libvirt, no `virsh`, no `ip`, and no network. Unverified:

- VM creation (`virt-install`), including the `--os-variant` fallback chain
- cloud-init user creation and SSH key injection
- base image download
- namespace and veth wiring (`netns-up` / `netns-status` / `netns-down`)
- disk attach (`add-disk`)
- every one of the 102 automatic checks, in its passing state
- `lab.sh push` against a live guest (`scp`, the remote `chmod`, the SSH options)
- **all five Day 01 scripts.** They are `bash -n` clean and were read line by
  line, but nothing in the sandbox has systemd as PID 1, so `systemctl`,
  `journalctl`, `systemd-analyze` and `systemd-cgls` have never executed. The
  likeliest failure is cosmetic (a property name, or `systemd-cgls` output
  shape), not structural

`./lab/lab.sh check` is the most tested part and the correct first command. If
`virt-install` rejects `--os-variant rocky9`, the host `osinfo-db` predates
Rocky 9 — use `rhel9.0`; the fallback chain attempts this already, and
`lab/README.md` carries the manual `virt-install` commands.

### First real host run (2026-09-06)

`./lab/lab.sh check` behaved correctly on Ubuntu with no virtualization
stack installed: every detection section was right and the install hint it
printed was the right one. Two faults surfaced from the owner pasting all
four step-1 commands at once, and both are fixed:

- `cmd_image` and `cmd_up` ran despite `check` having failed, so a 1 GB
  download completed and then died on `qemu-img: command not found`. Both
  now call **`require_lab_tools`** first, which dies with the install hint.
- A failed qcow2 validation left the bad download in place, so a retry
  would have trusted it. `cmd_image` now deletes it and says to re-run.

`days/day01/README.md` step 1 was also rewritten to run the four commands
one at a time, with `check` stated as a gate and the apt install spelled out.

### Sandbox limitations worth knowing

No shellcheck, bats, `ip`, `nft`, KVM, libvirt or network access. Verification
is therefore `bash -n`, targeted `grep`, running the error paths, and reading
output carefully. Also: file writes have silently succeeded while creating
nothing — always confirm with `ls -l` before trusting a write.

---

## 9. Open items

In the order they should probably be done.

1. **Finish the first real host run.** `check` has now been run on the owner's
   Ubuntu laptop (2026-09-06): host, KVM, memory and disk sections all pass;
   it correctly reported 5 blocking problems because libvirt, virtinst and
   qemu-kvm were not installed. Nothing past `check` has run for real yet:
   `image`, `up control`, `push control`, `ssh control` are still untested
   against real KVM, as are all five Day 01 scripts against real systemd.
2. **Write the day scripts.** Day 01 is done (5 scripts). Days 02-20 ship an
   empty `scripts/` directory. They are written one day at a time, each run on
   the real lab before the next is started — writing them in bulk would produce
   plausible code that has never met a Rocky VM. Delivery convention agreed with
   the owner: **Day 01 shipped as the complete repository; every day after that
   ships only the changed files**, which will usually be
   `days/dayNN/scripts/*`, `days/dayNN/README.md`, `days/dayNN/verify.sh`,
   and this handoff.
3. **Add `scripts/setup.sh` for the CI days** (04, 06, 07, 08, 09, 10, 18).
   Each one converts a `SKIPPED` CI job into a real one.
4. **Git.** Not initialised. No remote, no first commit. The owner is doing
   this themselves.
5. **Pre-commit: shipped.** `.pre-commit-config.yaml` has whitespace and
   shebang hooks, `shellcheck -x -S warning`, a 256 KB large-file guard (VM
   images must never enter git), and `tests/cli.sh` as a local hook.
   **Never executed** — `pre-commit` is not installed in the authoring
   sandbox and installing it needs network. The YAML is tab-free and was
   structurally checked, nothing more. Confirm with
   `pre-commit run --all-files` on first use.
6. Optional: a `lab.sh snapshot` / `revert` pair using `virsh snapshot-create-as`.
   Days 11–13 and 19 involve changes that can lock a host out, and a one-command
   revert would make experimentation cheaper.
7. Optional: extend past 20 days. Candidates never written up: Kerberos and
   FreeIPA, NFS with SELinux labels, systemd-nspawn, kernel tunables and
   sysctl, performance triage with `perf` and `bpftrace`.

---

## 10. Maintenance rules

When changing this repository, keep these in sync:

| If you change | Also update |
|---|---|
| A day's content | its `README.md` and `verify.sh`, together |
| A day's scripts | the Scripts table and runbook on its page; §8 and §11 here |
| A day's tier | the CI matrix in `ci.yml`, §4 and §5 here, and the README tier table |
| The number of days | both tier tables, the memory tables, `docs/curriculum.md`, §4 here |
| A check | the count in §5 here (`102 automatic, 31 judgement`) |
| `lab.sh` subcommands | §3 here, the README lab section, `lab/README.md` |
| VM names or memory | §3 and §4 here, both memory tables, `vm_mem()` in `lab.sh` |
| The namespace topology | §3 here, the README diagram, `NS_LIST` and `cmd_netns_up` |
| A `lab.sh` subcommand | the header help block too, or `tests/cli.sh` fails |
| A rule in §2 or §5 | `CONTRIBUTING.md` restates all three headline rules |
| The day-script conventions | `CONTRIBUTING.md` “Writing day scripts” |
| Anything at all | run `./tests/cli.sh`, then the **Last updated** date at the top of this file |

### Rules that exist for a reason

1. **Never claim something works that has not been executed.** The
   distinction between "lint-clean" and "verified" is the whole point of §5.
2. **Never add a simulation or offline mode**, however convenient. If a thing
   cannot be verified for real, say so plainly instead.
3. **Never describe network namespaces as fake.** See §2.
4. **A day page and its `verify.sh` must never disagree.** See §7.
5. **A green CI run does not mean a day works.** It means lint passed and, for
   7 of 20 days, that a runner executed them.
6. **Confirm file writes with `ls -l`.** They have silently no-opped.
7. **Do not put lab state in the repo.** Everything lives under `$LAB_HOME`;
   `.gitignore` covers qcow2 images, pcaps, private keys and vault passwords.

---

## 11. File inventory

```
README.md                     9.4 KB   overview, quickstart, tiers, memory budget
docs/curriculum.md            9.5 KB   all 20 days with reasoning
docs/HANDOFF.md                        this file
lab/lab.sh                   19.0 KB   608 lines, 32 functions, 12 subcommands
lab/verify-lib.sh             2.7 KB   100 lines, 6 public functions
lab/ci-day.sh                 1.9 KB   57 lines
lab/README.md                 3.3 KB   hardware, install, manual fallbacks
days/dayNN/README.md          20 files
days/dayNN/verify.sh          20 files, 102 auto + 31 judgement checks
days/day01/scripts/           5 files   470 lines: lab-demo.sh, setup.sh,
                                        explore-boot.sh, break-and-fix.sh,
                                        teardown.sh
days/day02-20/scripts/        19 empty directories
.github/workflows/ci.yml      2.5 KB   79 lines, 3 jobs
CONTRIBUTING.md               7.7 KB   208 lines, 9 sections
LICENSE                       1.1 KB   MIT, holder: ericvalijani
tests/cli.sh                  3.0 KB   109 checks, no VM or root needed
.pre-commit-config.yaml       1.3 KB   never executed, see §9 item 5
.gitignore                    413 B    33 lines
```

29 shell scripts, all `bash -n` clean. 20 days. Day 01 scripts written; 02-20 outstanding. `tests/cli.sh`: 109 passed, 0 failed.
