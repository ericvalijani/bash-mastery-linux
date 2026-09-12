# Bash Mastery: Linux — Project Handoff

> Complete state of this repository in one file. Written to be pasted into a
> fresh chat so an assistant can pick the work up cold, with no other context.

**Last updated:** 2026-09-12
**Repo:** `bash-mastery-linux`
**Status:** scaffold complete, 20 days written, **Days 01–14 scripts written**;
Days 12 and 13 verified on a real Rocky 9 lab VM, Day 14 written and linted
**Executed against real KVM hardware through Day 12.** See §8.
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
| Day scripts | shipped, written day by day | Days 01 through 14 done. A day with no scripts yet ships an empty `scripts/` and its README says so |
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
| `node1` | 2048 MB | The machine that gets configured and broken |
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
| 01 | one VM (`control`) | ~1 GB |
| 02–05, 11–13, 17, 19 | one VM (`node1`) | ~2 GB |
| **06–10, 18** | **no VM at all** | **0 MB** |
| 14, 16, 20 | two VMs | ~3 GB |
| 15 | three VMs | ~3.8 GB |

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
| `tests/cli.sh` | **307 passed, 0 failed** (was 292; Day 14's five scripts added checks) |
| `bash -n` on all 85 shell scripts | 0 failures |
| `lab/lab.sh --help` | stops cleanly at the memory budget |
| `lab/lab.sh check` | runs every section, prints the full summary |
| `lab/lab.sh bogus` | `FAIL unknown subcommand`, exit 1 |
| `lab/lab.sh netns-down` as non-root | `FAIL this subcommand needs root`, exit 1 |
| `days/day13/verify.sh` on Ubuntu | 7 SKIP, 2 YOU, exit 0 |
| `lab/ci-day.sh 04` | no longer skips: `days/day04/scripts/setup.sh` now exists, so CI executes it and then `verify.sh`. **Never yet run on a real runner** |
| `lab/ci-day.sh 99` / no argument | exit 2 with usage |
| First real CI run (2026-09-04) | days 04, 06, 10 green; 07, 08, 09, 18 now skip; `lint` fixed |
| `ci.yml` structure and tabs | parses, no tabs |
| `lab.sh push` with no argument | `FAIL usage: ... push <vm> [path...]`, exit 1 |
| `lab.sh push bogus` | `FAIL unknown vm`, exit 1 |
| `lab.sh --help` after the patch | lists 14 subcommands including `console` and `diagnose` |
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

**The apt hint itself was wrong, and is fixed.** It named `qemu-kvm`, which
Debian and Ubuntu now ship only as a virtual package with no installation
candidate. apt therefore aborts and installs *nothing*, so the following
`systemctl enable --now libvirtd` fails with "Unit libvirtd.service does not
exist" and looks like a second, unrelated fault. It is not. The correct
package is `qemu-system-x86`; plain `qemu-system`, which the QEMU website
suggests, installs every CPU architecture and is wrong for a KVM lab.

`pkg_hint()` now emits `qemu-system-x86 libvirt-daemon-system libvirt-clients
libvirt-daemon-config-network virtinst`, and a new **`enable_hint()`** prints
`libvirtd` or the modular `virtqemud.socket virtnetworkd.socket` depending on
what the host actually has, since recent libvirt ships no `libvirtd.service`.
`enable_hint()` is called from all three places that used to hardcode the
unit name. `README.md`, `lab/README.md` and `days/day01/README.md` were
corrected to match.

### The libvirt URI trap (fixed 2026-09-06)

`check` reported `network 'default' is defined but inactive` while `sudo virsh
net-list --all` on the same machine showed it `active`. The Active-field parser
was verified correct against realistic `net-info` output using a fake `virsh`,
so the disagreement was not parsing. Two real causes, both now handled:

1. **No libvirt URI was pinned.** Root gets `qemu:///system`; an unprivileged
   user can silently fall back to `qemu:///session`, which holds none of this
   lab's VMs or networks. `lab.sh` now exports
   `LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"`, so the
   script, the user's shell and `sudo` all read the same daemon. This was a
   latent fault that would have surfaced again on `up`, `status` and `ssh`.
2. **A first-call race.** The first `virsh` call after boot can socket-activate
   `virtnetworkd`, which then autostarts the network - so the network genuinely
   reads inactive during that call and is active a second later, which is
   exactly why the owner's follow-up `net-start` answered "already active".
   `check` now re-reads the state after a 2 second pause before failing, and
   the failure hint says to re-run `check` if `net-start` reports that.

Also added: a **libvirt group** check (missing membership is why libvirt
commands need `sudo` until the user logs out and back in), a `net-define`
hint for the genuinely-missing case, and `net_state()`, which reads the
`Active` field by name via awk instead of pattern-matching the whole block.

`tests/cli.sh` caught a side effect of that change immediately: its
"every subcommand is documented" check scraped every `case` branch in
`lab.sh`, so the new `active)` and `inactive)` branches were demanded of the
help text. It now reads the `main()` dispatcher only. **108 checks.**

### qemu cannot read your home directory (fixed 2026-09-07)

`up control` failed with `Cannot access storage file
'/home/eric/.local/share/bash-mastery-linux/disks/control.qcow2'
(as uid:64055, gid:991): Permission denied`, after `virt-install` had already
warned that `libvirt-qemu` needed search permission on `/home/eric`,
`/home/eric/.local` and `/home/eric/.local/share`.

This is structural, not a mistake by the operator. Under `qemu:///system` the
VM process does not run as you: it runs as `libvirt-qemu` on Debian and Ubuntu,
and as `qemu` on Rocky. A home directory is mode 0700, so that user cannot
traverse into it, and `LAB_HOME` defaults to `~/.local/share`. The lab could
never have started a VM on a default Ubuntu install.

Rejected fixes: `chmod 755 ~` (exposes the whole home directory to every local
account), and running qemu as root via `/etc/libvirt/qemu.conf` (changes the
host's security posture for a teaching lab). Chosen fix: **POSIX ACLs granting
exactly one user exactly what it needs**, which the owner of the directories
can set without `sudo`.

New functions in `lab/lab.sh`:

- `qemu_user()` - resolves `libvirt-qemu`, else `qemu`, else fails.
- `grant_path <perms> <path>...` - one `setfacl -m u:<qemu-user>:<perms>` per
  existing path; a no-op when `setfacl` or the user is absent.
- `grant_hypervisor_access()` - walks up from `LAB_HOME` to `$HOME` granting
  **search only** (`x`), then `rx` on `images/` and `seed/`, `r` on the base
  image, `rwx` on `disks/`.

Called from `cmd_image` (both the fresh-download and cached paths) and from
`create_vm` immediately after `qemu-img create`, which also grants `rw` on the
new overlay - each overlay is created 0600 and needs its own entry. `cmd_check`
now reports this too: it looks for the `x` entry on `$HOME` via `getfacl` and
warns if it is missing, and warns separately if the `acl` package is not
installed. `acl` was added to the apt, dnf and pacman package hints and to the
three documented install lines.

Proved with a fake `setfacl` on `PATH` and a fake `$HOME` tree: eight calls,
search-only on the four path components, and read/write confined to `disks/`.

Also fixed in the same run: `virt-install` reported `Using --osinfo generic, VM
performance may suffer`, because `osvariant()` only tried `rocky9`, `rhel9.0`
and `rhel9-unknown`. It now falls back through `rocky9`, `rocky9.0`, `rhel9.6`
down to `rhel9.0`, then `rhel9-unknown`, `centos-stream9` and `linux2022`, and
queries `virt-install --osinfo list` when `osinfo-query` is missing. A close
RHEL 9 profile still yields virtio and a correct clock; `generic` does not.

### AppArmor, not permissions: the lab moved out of $HOME (2026-09-07)

After the ACL fix above, `up control` still failed:
`Could not open '/home/eric/.local/share/bash-mastery-linux/images/
Rocky-9-GenericCloud-Base.latest.x86_64.qcow2': Permission denied`. Two signals
proved the ACLs had in fact worked: libvirt's own accessibility warning about
`/home/eric`, `/home/eric/.local` and `/home/eric/.local/share` no longer
appeared, and `--osinfo` resolved to `rocky9`.

So the remaining denial is not discretionary access control. On Ubuntu, libvirt
confines each qemu process with an AppArmor profile whose allowed paths do not
include home directories. Correct file permissions cannot help; the kernel
refuses the open regardless, and reports it as `EACCES`, which reads exactly
like a permission problem.

Rejected fixes: putting the AppArmor profile in complain mode (disables a host
security control for a teaching lab) and editing
`/etc/apparmor.d/abstractions/libvirt-qemu` (a host-wide change that a learner
would have to remember to undo). Chosen fix: **keep the lab where libvirt and
AppArmor already expect image files.**

- `LAB_LIBVIRT_HOME=/var/lib/libvirt/images/bash-mastery-linux`.
- `lab_home_default()` returns that path when it exists and is writable by the
  invoking user, otherwise the old `~/.local/share` path. `LAB_HOME` still
  overrides everything, so nothing that set it breaks.
- `relocate_hint()` prints the single command that creates it - `sudo install -d
  -o <user> -g <group> ...` - plus an `mv` of the existing `images/` directory
  when one is present, so the ~900 MB base image is not downloaded twice.
- `cmd_check` now reports `lab directory is outside your home directory`, or
  warns and prints the hint. `create_vm` prints the same warning before it
  builds an overlay that cannot possibly boot.

The ACL machinery from the previous fix is kept: it is still what makes a
home-directory lab work on distributions without AppArmor, and it is harmless
where it is not needed.

Verified in the sandbox by pointing `LAB_LIBVIRT_HOME` at a writable temporary
directory (chose it) and at a missing one (fell back to `$HOME`), and by
inspecting `relocate_hint` output.

### The VM that creates itself and then powers off (2026-09-07)

With the storage problems gone, `up control` reported `control defined and
booting`, then `status` showed `control  shut off`. Nothing was broken on the
host; the sequence is how `virt-install` works, and `lab.sh` did not account
for it.

`virt-install --import --cloud-init` treats the first boot as an *install
phase*. During that phase libvirt sets `on_reboot=destroy` on the domain so the
generated cloud-init ISO can be detached cleanly, and the Rocky image does
reboot once cloud-init has applied the seed. Because we pass `--noautoconsole`,
`virt-install` has already returned - it even prints "Domain is still running.
Installation may be in progress" - so when that reboot lands, the domain is
destroyed and left `shut off`. The final XML has no ISO attached and boots
normally, so the only missing step was starting it.

- New `ensure_running()` reads `virsh domstate` and starts a `shut off` domain,
  resumes a `paused` one, does nothing when it is already `running`, and warns
  for anything else. It never fails, so it is safe under `set -e`.
- `wait_for_ip()` now sleeps 10s to let cloud-init run, calls `ensure_running`,
  then polls for up to 180s (was 120s) and re-checks the domain state every
  16 seconds, because the power-off can land at any point in that first boot.
- `cmd_status` prints `start it with: lab.sh up <vm>` under a `shut off` VM.
  `up` on an existing VM skips creation but still waits, so re-running it is
  now the single recovery command for this and most other boot problems.

Tested with a fake `virsh` across all of `running`, `shut off`, `paused` and
`pmsuspended`, including a `virsh start` that exits non-zero: the failure warns
and still returns 0.

### Running but no address, and a status line that misled (2026-09-07)

`up control` started the powered-off domain correctly, but no DHCP lease ever
appeared: `status` showed `control  running  -`, and `ssh` failed with
`no address for control`. Two separate shortcomings in `lab.sh` came out of
this, both about the script telling the operator too little:

1. **There was no way to look at the VM.** A running VM with no lease can only
   be explained from its console - kernel messages, cloud-init output, or a
   login prompt meaning the guest is fine and the problem is DHCP or the lease
   lookup. New 13th subcommand **`console <vm>`** (`exec virsh console`, with a
   reminder that Enter gives a prompt and `Ctrl+]` exits). `status` now prints
   `running but no DHCP lease yet: lab.sh console <vm>` in exactly that case,
   and both `ssh` and `push` print the console command plus
   `virsh net-dhcp-leases` instead of a bare failure.
2. **`status` read like an instruction.** Its namespace line said
   `none - run: sudo lab.sh netns-up`, which on Day 01 looks like a required
   step; the operator asked whether they had to run it. Namespaces are only for
   Days 6-10. The line now reads
   `none - only Days 6-10 need these (sudo lab.sh netns-up)`.

Lesson recorded for the remaining days: any status line that names a command is
read as an order. If a command is optional or belongs to another day, the line
has to say so on the same line.

### Watching the boot from the first byte (2026-09-07)

The first host run reached a state that none of the previous fixes explain:
`domstate` says `running`, `domiflist` shows a virtio NIC on the `default`
network, the domain XML has a correct virtio disk under
`/var/lib/libvirt/images/bash-mastery-linux/disks/` and a proper `isa-serial`
console on `/dev/pts/1` - and yet `virsh console` prints nothing and the DHCP
lease table is empty.

An empty console proves nothing on its own, which was the real gap: attaching
to a VM that has already finished booting shows no output, because the boot
messages scrolled past before the connection existed and an idle guest writes
nothing new. "Booted fine but no DHCP" and "never executed a kernel" look
identical from there.

- **`console <vm> --restart`** power-cycles the domain and attaches with
  `virsh start --console`, so firmware, boot loader and kernel output are all
  captured. The plain form now suggests it when nothing appears.
- **Backing-chain validation in `create_vm`.** A thin overlay whose chain to the
  base image is broken - for example because the base image was moved after the
  overlay was created, which is exactly what the relocation fix asked the
  operator to do - produces a guest that boots to nothing with no host-side
  error at all. `qemu-img info --backing-chain` is now checked immediately after
  `qemu-img create`; on failure the overlay is deleted and the operator is told
  to re-run `image` then `up`.

The empty `<disk device='cdrom'>` entry with no `<source>` seen in the XML is
the detached cloud-init ISO from the install phase. It is expected and harmless.

### The seed ISO we build ourselves (2026-09-07)

The install-phase problem was patched twice (ensure_running, then the console
tooling) before the mechanism itself was replaced. `virt-install --cloud-init`
is convenient and fragile: it runs the first boot as an install phase with
`on_reboot=destroy` so it can detach the seed ISO cleanly, and because
`--noautoconsole` makes virt-install return early, the guest's post-cloud-init
reboot leaves the domain powered off at the worst possible moment - mid-way
through growing the filesystem, creating the `lab` user and installing the SSH
key.

`create_vm` now builds the NoCloud seed ISO itself and attaches it as a
permanent read-only cdrom, with `--boot hd` and no `--cloud-init` flag at all.
There is no install phase, so the very first boot is an ordinary boot.

- `seed_iso()` writes `user-data` (from `write_seed`) and a `meta-data` file
  containing `instance-id` and `local-hostname` into `seed/<vm>/`, then builds
  the image with `cloud-localds`, or `genisoimage`, or `xorriso` - whichever
  exists. **The filesystem label must be exactly `CIDATA`** or cloud-init will
  not look at the disk.
- The ISO is granted `r` through `grant_path`, like the base image.
- With no builder present the old `--cloud-init` path still runs, but it warns
  and prints `iso_pkg_hint()` (`cloud-image-utils` on apt, `cloud-utils` on
  dnf). `cloud-image-utils` was added to all three install lines.
- cloud-init re-reads the seed on every boot now that the ISO stays attached.
  That is harmless: its modules are idempotent.

Both branches were proved with fake `virt-install`/`cloud-localds` binaries:
the ISO branch emits `device=cdrom,readonly=on` and `--boot hd` and **zero**
`--cloud-init` flags; the fallback branch warns, prints the hint, and still
passes `user-data=...,disable=on`.

**A lock error is not a corruption error.** `qemu-img info` on a disk belonging
to a running domain fails with `Failed to get shared "write" lock`, which says
nothing about the image. Use `--force-share`, or check it while the VM is off.

### One command that collects every clue (2026-09-07)

The stuck-VM investigation cost four round trips because each host-side command
answers only a fraction of the question, and the most informative file was never
asked for. `console <vm> --restart` finally produced the decisive observation:
**no output at all, not even firmware**, which rules out the guest OS entirely
and points at qemu never getting the guest off the ground.

`diagnose <vm>` (14th subcommand) collects the whole picture in one run:

| Measurement | What it distinguishes |
| --- | --- |
| `domstate`, `dominfo` | defined vs running vs paused |
| `cpu-stats --total`, read twice three seconds apart | whether the vCPU is executing instructions at all |
| `domblkstat` `rd_req`/`rd_bytes` | whether the guest read a single block; a guest that reached its boot loader has read thousands |
| `qemu-img info --backing-chain --force-share` | whether the overlay still resolves to the base image |
| seed ISO presence | whether the VM predates the seed-ISO path |
| `/var/log/libvirt/qemu/<vm>.log` | **the file that names the reason a domain will not run.** Needs root; the command is printed when it cannot be read |
| `dmesg` AppArmor/OOM lines, `free -m`, lease table | host-side refusals and memory pressure |

The device name comes from `domblklist` rather than being hardcoded to `vda`,
and `--force-share` is mandatory: a running domain holds a write lock and
`qemu-img` otherwise fails with an error that reads like corruption but is not.

**Lesson for every future stuck-guest problem: read the per-domain qemu log
first.** Serial silence is not evidence, because attaching to an already-booted
VM shows nothing either way.

### Alive, spinning, and silent (2026-09-07)

The first `diagnose` run on the host overturned the previous conclusion. The
guest is not failing to start - it is running hard and saying nothing:

| Measurement | Value | Meaning |
| --- | --- | --- |
| `cpu_time` | 650.2s, +3.3s over 3s | one vCPU pegged at ~100%, not idle, not stopped |
| `rd_req` / `rd_bytes` | 82,236 / 1.44 GB | the guest read a gigabyte and a half; it is well past firmware |
| backing chain | resolves to the base image | the relocation did not break anything |
| seed ISO | 374 KB, `libvirt-qemu:kvm`, attached as `ide-cd` | the new seed path works |
| qemu log | ordinary command line, `char device redirected to /dev/pts/1`, no error | qemu itself is not complaining |
| free memory | 2175 MB | no OOM kill |

So "qemu never gets the guest executing" was wrong. A guest burning a full core
while reading gigabytes and never reaching NetworkManager - hence the empty
lease table - has two plausible explanations, and `diagnose` was missing the
measurement that separates them:

1. **Software emulation instead of KVM.** TCG pegs one host core, makes boot
   glacial, and produces exactly this pattern. `info kvm` via the qemu monitor
   settles it in one line; the tail of the qemu log never shows the `-accel`
   argument, which is why four round trips missed it.
2. **A guest genuinely stuck in early boot**, spinning on I/O.

Added, therefore:

- `diagnose` now runs `qemu-monitor-command --hmp 'info kvm'` and `'info status'`,
  and `domifaddr --source arp` - because the host ARP table sees a guest that
  configured an address without asking libvirt's dnsmasq, which a lease table
  never shows.
- **`LAB_GRAPHICS`** (default `none`). `LAB_GRAPHICS=vnc ./lab/lab.sh up control`
  gives the guest a screen, bound to `127.0.0.1` only because these guests have
  no console password. Serial-only is right for a scripted lab, but a guest that
  boots and never writes to `ttyS0` is invisible without it, and there was no
  way to look at the screen at all. `diagnose` prints the `vncdisplay` when one
  exists and the recreate command when it does not.

**Lesson: serial silence is not evidence of a dead guest, and CPU time plus
block-read counters are the cheapest proof of life there is.**

### The missing display device (2026-09-07, resolved)

`LAB_GRAPHICS=vnc ./lab/lab.sh up control` booted in under a minute and reported
`control is 192.168.122.122`. The same image, the same seed ISO, the same disk
chain and `kvm support: enabled` had previously spun for nineteen minutes with
`--graphics none`. **The one variable was the presence of a display device.**

The likely mechanism is the boot loader: RHEL-family cloud images configure GRUB
for a graphical terminal, and with no video device at all it can hang before
handing over to the kernel - which fits every observation, including the pegged
vCPU, the gigabyte of disk reads, and the complete absence of serial output.
This is stated as the probable cause rather than a proven one: the decisive
experiment (booting headless with a serial-forced kernel command line) was never
run, because the working configuration was preferable to a proof.

**`LAB_GRAPHICS` now defaults to `vnc`, bound to `127.0.0.1`.** The reasoning is
not subtle: a guest whose console cannot be looked at is not debuggable, and
this project asks a learner to break things on purpose. `LAB_GRAPHICS=none`
restores headless behaviour.

The second half of the user's question - "why is it not in the README" - was the
fairer one. It was not in the README because it had been invented twenty minutes
earlier as a debugging flag, which is exactly the failure mode described in
maintenance rule 4: a workaround that lives only in a chat transcript. The
working configuration is now the default, and `virsh vncdisplay <vm>` plus
`diagnose` are documented in `README.md`, `lab/README.md` and
`days/day01/README.md`.

**Rule: when a flag turns out to be the difference between working and not
working, it stops being a flag. It becomes the default, in the documentation,
in the same change.**

### Day 01 was run on the laptop (2026-09-07)

Day 01 passed - 4 PASS, 1 YOU, exit 0, \`Restart=\` proven by killing the process
and watching it come back. It was run on the host, not on \`control\`. The
screenshots show \`eric@eric-X556UQ .../days/day01$ sudo ./scripts/setup.sh\`,
and \`lab-demo.service\` was installed and enabled on the user's own Ubuntu
machine. On \`control\`, \`systemctl is-enabled lab-demo\` still answered
\`No such file or directory\`.

Nothing was damaged - \`lab-demo\` is a harmless \`sleep\` loop as \`User=nobody\` -
but Day 11 rewrites firewall rules, Day 12 hardens sshd and Day 13 relabels
filesystems. The same mistake on any of those days ends the project and
violates the one hard requirement of this repo: never risk the host OS.

The cause was documentation, not the user. \`### 5. Prove it survives a reboot\`
said \`sudo reboot\` without saying which machine, and every step before it read
as something you type wherever you happen to be. The give-away was
\`Operation inhibited by "eric" ... user session inhibited\` - systemd refusing to
reboot a desktop with a graphical session, which no VM would ever say.

Fixed structurally rather than with a warning paragraph:

- **\`lab/on-lab-vm.sh\`**, a guard library exporting \`require_lab_vm\`. A machine
  qualifies if \`/etc/bash-mastery-linux-lab\` exists or its short hostname is
  \`control\`, \`node1\` or \`node2\`. Otherwise it prints the three commands that get
  you onto a VM and exits 1 before anything is touched. \`hostname(1)\` is not
  installed everywhere, so it falls back to \`/etc/hostname\` and then to
  \`unknown\` - which refuses, because refusing is the safe default.
  \`LAB_ALLOW_THIS_MACHINE=1\` overrides it and says so on stderr.
- **cloud-init writes the marker** via \`write_files\` in \`write_seed\`, so a lab VM
  identifies itself even if it is renamed.
- **\`setup.sh\` and \`break-and-fix.sh\` call it.** \`teardown.sh\` deliberately does
  not: it removes state, and it must stay usable on a machine where \`setup.sh\`
  should never have run in the first place. \`explore-boot.sh\` is read-only and
  needs no guard.
- Every state-changing script in Days 02-20 must source it. This is now
  maintenance rule 8 in section 10.

**Rule: an instruction that does not name the machine it runs on will be run on
the wrong machine. Guard the script; do not warn in prose.**

### Day 02 was written (2026-09-07), and has not been run

Five scripts, following Day 01's shape exactly: a payload, an idempotent
`setup.sh`, a read-only tour, a `break-and-fix.sh` with a `--hard` mode, and a
`teardown.sh`. `bash -n` clean, `tests/cli.sh` green at 127. **Nothing has been
executed**: the authoring sandbox has no systemd, no `setfacl`, no `visudo` and
no Rocky guest, so every claim below is design intent until `node1` says
otherwise.

What the day builds, and why each piece is there rather than being asserted in
prose:

| Object | Choice | Reason |
|---|---|---|
| group `appdata` | owns `/srv/shared`, mode `2770` | gives the setgid check something real to inherit from |
| user `appsvc` | `--system`, `/sbin/nologin`, **own primary group**, *not* in `appdata` | if `appsvc` were an `appdata` member the ACL would be decoration. Excluding it makes the ACL load-bearing, which is what the day is teaching |
| `/srv/shared` | `setfacl -m u:appsvc:rwx` plus a **default** ACL | the `-m` entry and the `-d` entry are separate; setting one does not set the other, and that gap is a real production bug |
| `/etc/sudoers.d/appsvc` | `Cmnd_Alias`, absolute paths, `(root)` not `(ALL)`, `0440` | `(root)` is what keeps `verify.sh`'s "cannot become root" check honest, since it greps for `(ALL).*ALL` |
| `lab-app.service` | `User=appsvc`, `ProtectSystem=full` + `ReadWritePaths=/srv/shared` | Day 01 used `ProtectSystem=strict`, which would block this service's only job. The pairing is the lesson |

The service **writes** rather than just sleeping, which is the one structural
difference from Day 01's payload. That is deliberate: a permission mistake has
to produce a dead service and a `Permission denied` in the journal, otherwise
the ACL demonstration proves nothing.

Two deviations from Day 01, both intentional:

- **`teardown.sh` calls `require_lab_vm`.** Day 01's teardown deliberately does
  not, because it only removes a unit file and a script. This one deletes a
  user, a group and `/srv/shared` — a plausible path on a real machine — so the
  guard is worth more than the "usable anywhere" property. The exception in
  maintenance rule 8 now covers read-only tours only.
- **`verify.sh` gained `vl_need_root` and `vl_need getfacl sudo`.** No check was
  added or removed, so the counts in §5 are unchanged. Without root,
  `sudo -l -U appsvc` fails and two checks reported `FAIL` when the honest
  answer was `SKIP` — the exact false-failure the `SKIP` tier exists to prevent.

Expected on a healthy run: **5 PASS, 1 YOU, exit 0.**

The likeliest real-world failures, in order: `sudo -u appsvc` behaving
differently than expected against a `nologin` account; `useradd --system
--create-home` not creating the home directory on Rocky 9; and the exact wording
of sudo's refusal, which `break-and-fix.sh` describes but does not parse.

### Day 05 was written (2026-09-08), and has not been run

Five scripts, same shape as Days 01-04: `lab-noisy.sh` (payload, no root),
`setup.sh`, `explore-logs.sh` (read-only tour, no root), `break-and-fix.sh`
and `teardown.sh`. Objects: `lab-noisy.service`, `/usr/local/bin/lab-noisy`,
`/var/log/lab-app/app.log`, `/etc/logrotate.d/lab-app`, `/var/log/journal`,
`SystemMaxUse=200M`, chronyd, timezone UTC. Lab tier - CI lints only.

The organising idea is that **two logging systems are running at once** and
the reader has probably never seen them side by side. The payload writes one
line per second to a plain file *and* to the journal from the same loop, so
every comparison in the day is between two destinations fed by one process.

| Choice | Why |
|---|---|
| Payload holds its log open on fd 3, never reopens | This is the whole of failure 1. A rename cannot reach an open descriptor, so removing `copytruncate` makes the rotated file keep growing while the tailed file stays empty. Without the held descriptor the failure cannot be demonstrated at all. |
| `size 100k` rather than `daily` in the rule | The reader can trigger a real rotation now instead of waiting until tomorrow. |
| `SystemMaxUse=200M`, deliberately small | Small enough that `break-and-fix.sh` can drop it to 5M and show journald deleting its own history with no error anywhere. |
| Timezone forced to UTC | Correlation across hosts in Days 06-20. Also sets up the `TZ=` display demo in the tour: the journal stores UTC regardless. |
| `teardown.sh` leaves the journal alone | Persistence is a machine improvement, not this day's mess, and deleting a journal is not undoable. It also produces the best line in the day: the service is gone and `journalctl -t lab-noisy` still has its history. |
| Clock moved forward, not backward, in failure 3 | Backwards time breaks `make`, databases and certificate validity. Forward is enough to make `--since "5 min ago"` miss real entries. |

**One check was tightened rather than left on the weak list.** The generator's
`a logrotate rule exists for your own log` was `ls /etc/logrotate.d/ | grep -q .`,
which passes on any stock machine because the distro ships rules of its own. It
now requires `/etc/logrotate.d/lab-app` to name `app.log` *and* contain
`copytruncate`. The description is unchanged, so parity holds at 20/20. **Four
weak checks remain** (d04, d07, d16, d03), down from five.

A second `vl_manual` was added - `you watched a rotated log keep growing, and
found the open descriptor` - taking the day to 5 PASS, 2 YOU, matching Day 04.
The README checklist was updated in the same change.

Packages the VM needs, per the Day 04 lesson: `sudo dnf install -y chrony
logrotate`. `setup.sh` checks for `chronyc logrotate logger journalctl
timedatectl` before changing anything.

### Day 14 was written (2026-09-12)

`days/day14/` ships five scripts, a rewritten README and a six-check verify.
The day is Ansible fundamentals: `control` manages `node1`, and the whole day
is built around one measurement - the second run reports `changed=0`.

Decisions worth knowing:

- **This is the only day whose `setup.sh` refuses root.** The project lives in
  `$HOME`, Ansible connects as the lab user with the lab user's key, and
  `become` is per task. Run it with sudo and the project is owned by root,
  `~/.ssh` is `/root/.ssh`, and every task fails as UNREACHABLE for a reason
  that has nothing to do with the day. `verify.sh` makes "not root" its first
  check for the same reason - that is the sixth check the stub did not have.
- **The credential is the prerequisite, and it is explicit.** `control` holds
  nothing node1 trusts, so the README adds a second push:
  `./lab/lab.sh push control ~/.ssh/id_ed25519`. `setup.sh` installs
  `~/lab/id_ed25519` as `~/.ssh/id_ed25519` mode 0600, deletes the pushed
  copy, and then proves plain `ssh` works before writing any inventory. Both
  the README and the script say plainly that a private key on a control node
  is a real-world tradeoff, not a pattern.
- **node1's address is an argument, not a guess.** `control` cannot run
  `virsh`, so `setup.sh` takes the address as `$1` or `$NODE1`, otherwise
  reuses the one in the existing inventory, otherwise dies pointing at
  `./lab/lab.sh status`. A stale DHCP lease is the most common cause of a
  hung run.
- **The project is `~/ansible-lab`**, holding `ansible.cfg`,
  `inventory/hosts.ini` and `inventory/hosts.yml` (the same hosts in both
  formats, so `ansible-inventory --graph` can be compared), `group_vars/`,
  `host_vars/`, `files/`, `templates/`, `site.yml`, and `not-idempotent.yml`.
- **`site.yml` notifies a handler on `rsyslog`,** not nginx or chronyd.
  `/etc/rsyslog.d/*.conf` is definitely included on Rocky 9, rsyslog ships
  installed, restarting it is harmless, and it calls back to Day 05. Day 13
  already owns nginx on node1, so the two days do not collide.
- **`teardown.sh` is itself a playbook** with every state inverted, and it
  deliberately leaves `rsyslog` installed and running because the
  distribution shipped it. It keeps `~/ansible-lab` unless given `--all`,
  since Day 15 turns `site.yml` into a role.
- `break-and-fix.sh` writes its broken plays to `/tmp/day14-broken`, never
  into the project, and finishes by re-applying `site.yml` twice.
- **Fixed after the first hardware run (2026-09-12):** `site.yml` had `copy`
  owning `/etc/lab-day14/lab-day14.txt` and `lineinfile` adding `owner=` to
  that same file. Two tasks owning one file is the fighting-tasks bug: `copy`
  restored its checksum, `lineinfile` re-added its line, and every run reported
  `changed=2` forever, so `verify.sh`'s second-run check failed on an
  otherwise-correct lab. The `lineinfile` task now owns
  `/etc/lab-day14/settings.conf` with `create: true`, and the task comment
  explains the rule: either `copy`/`template` owns a file entirely, or
  `lineinfile` edits a file a package owns. `break-and-fix.sh` case 2 already
  used `settings.conf`, and its cleanup removing the file is harmless because
  the next `site.yml` run recreates it.
- **Also fixed after that run:** `setup.sh`'s SSH precheck printed only
  "ssh failed". It now shows the real `ssh -v` error and classifies it (no
  route, refused, key rejected including Day 12's `AllowGroups labssh` and a
  fail2ban ban), and it refuses an address belonging to `control` itself. The
  README no longer presents any address as anything but an example, because
  the first hardware run used the README's `192.168.122.42` verbatim.

The four failures: `command`/`shell` instead of a module (works, reports
changed forever, and is skipped by `--check` so the dry run predicts nothing),
`lineinfile` with no `regexp` (idempotent for one value, appending for the
next), handler expectations (no change means no restart; a failed play drops
pending handlers), and a missing `become`.

Day 14 has **not** been run on hardware yet - the authoring sandbox has no
second host. CI lints it only.

Packages the control VM needs: `sudo dnf install -y ansible-core`. The managed
host needs nothing beyond the Python Rocky already ships.

### Day 13 was written (2026-09-12)

`days/day13/` now ships five scripts plus a policy source file, a rewritten
README and a seven-check verify. The day is SELinux: serving `/srv/www` with
nginx while the machine stays enforcing.

Decisions worth knowing:

- **Port 8080, not 80.** Rocky's `nginx.conf` already has a default server on
  80, and a second `default_server` is an nginx error, not an SELinux one.
  8080/tcp is already `http_cache_port_t`, so the bind succeeds and the port
  lesson stays a deliberate exercise rather than an accident.
- **`setup.sh` refuses to run unless SELinux is enforcing.** It will flip
  Permissive to Enforcing, but a Disabled system needs an autorelabel and a
  reboot, so it dies with those instructions instead of pretending.
- **Nothing in the day ever runs `setenforce 0`.** Every fix is an fcontext
  rule plus `restorecon`, a `semanage port` entry, a `-P` boolean, or a module
  whose source was printed first. `--hard` describes `setenforce 0` and a full
  filesystem relabel without performing either.
- **The module ships as readable source.** `scripts/lab_selinux.te` grants
  `httpd_t` read on `var_log_t` and nothing else, with the permissions named
  individually, because the teaching point is that `audit2allow` will happily
  write `:file *`. `setup.sh` compiles it with `checkmodule` /
  `semodule_package`, printing the rules before `semodule -i`.
- **`teardown.sh` removes the fcontext rule before the directory,** so no local
  rule is left describing a path that no longer exists, and it leaves SELinux
  enforcing because Days 14-20 assume a labelling machine.
- Verify needs root (`semanage`, `semodule`, `restorecon` read non-world-readable
  policy) and checks the permanent forms: `semanage fcontext -l -C`, a silent
  `restorecon -nvR`, and `semanage boolean -l -C`.

The four failures in `break-and-fix.sh`: a `chcon` that a relabel reverts, an
httpd type that is still not readable content, an unlabelled port that refuses
a valid bind, and a boolean that was off when no module was needed.

Day 13 **passed on real hardware: 7 PASS, 0 FAIL, 2 YOU** (2026-09-12), on
`node1` with SELinux enforcing throughout. CI still only lints it - a GitHub
runner has no policy store.

Packages the VM needs: `sudo dnf install -y nginx policycoreutils
policycoreutils-python-utils checkpolicy setools-console audit curl`.

### Day 12 was written (2026-09-11)

`days/day12/` now ships five scripts, a 233-line README and a five-check
verify. The day is SSH hardening: keys only, `AllowGroups labssh`, a
fail2ban jail with a two-minute ban, and ProxyJump.

Decisions worth knowing:

- **One VM, not two.** The curriculum lists this day as `control + node1`
  because a bastion needs two hosts. All five automatic checks run on
  `node1` alone, and the README gives a single-host ProxyJump exercise
  (`ssh -J lab@node1 lab@127.0.0.1`) for anyone without the 3 GB.
- **setup.sh refuses to run if the login user has no `authorized_keys`.**
  Disabling passwords on an account with no key is the way people lose a
  cloud VM, and a teaching script must not be able to do it.
- **Nothing in this day ever restarts sshd.** Every change is validated
  with `sshd -t` and loaded with `systemctl reload sshd`, which keeps the
  current session alive even when the new policy would refuse it.
- **fail2ban comes from EPEL** on Rocky 9, so setup fails with the two
  `dnf` lines rather than a bare "command not found".
- **`vl_need_root` and absolute `/usr/sbin/sshd`** in verify.sh: `sshd -T`
  reads host keys and `/usr/sbin` is not on a normal PATH. Same root-
  required lesson as Day 11.
- The payload is `/usr/local/bin/lab-ssh`, and every reference to it in
  the README and the scripts uses the **full path**, because `sudo` on
  Rocky uses a `secure_path` that excludes `/usr/local/bin`.

The five failures in `break-and-fix.sh`: a later drop-in that never wins
(00 sorts before 70, first value wins), an allow list that excludes you,
self-ban, a `Match` block where `sshd -T` is green and `sshd -T -C` is
not, and the unsurvivable one, described and not executed.

Day 12 was first exercised end to end in the authoring sandbox against mock
`sshd`, `fail2ban-client` and `systemctl`. Real Rocky 9 execution then exposed
three portability issues, all now handled by the repository:

- `node1` was raised from 768 MB to 2048 MB because `dnf` could be killed by
  the OOM killer while installing EPEL and fail2ban. All memory tables and
  launch notes were updated in the same change.
- The managed policy is `00-lab-hardening.conf`, not `60-`, so it is read
  before Rocky's and cloud-init's `50-*` drop-ins. Setup removes the legacy
  `60-` filename and teardown cleans up both names.
- With `set -o pipefail`, `sshd -T | grep -q` could report a false failure
  after grep found its match and sshd received `SIGPIPE`. Day 12's checks now
  consume the full output (setup captures `sshd -T` once). Rocky/OpenSSH may
  canonicalize `PermitRootLogin prohibit-password` as the equivalent
  `without-password`; setup and verify accept `no`, `prohibit-password`, or
  `without-password` as policies that disable root password login.

These fixes were applied to `setup.sh`, `verify.sh`, the related diagnostic and
cleanup scripts, the Day 12 README, and this handoff. **Day 12 then passed on
real hardware: 5 PASS, 0 FAIL, 2 YOU** (2026-09-12). `sshd -T` on that VM
prints `permitrootlogin without-password`, confirming the alias handling was
necessary, and `lab-ssh root` correctly reports `REFUSED - not in any allowed
group` because root is not in `labssh`. The executable bits on all five Day 12
scripts and `verify.sh` were also restored after archive merging, and
`./tests/cli.sh` is green. The remaining two Day 12 items are the manual ones:
the ProxyJump exercise must be run from the **laptop**, not from a shell on
`node1`, and with the address `./lab/lab.sh status` prints rather than a
remembered one.

### Day 11 was written (2026-09-10)

Day 11 is a VM day - `node1`, Rocky 9 - and the first VM day since Day 05,
because Days 06 to 10 needed no virtual machine at all. Every script sources
`lab/on-lab-vm.sh` and calls `require_lab_vm`, per Rule 8. It cannot be run
in the authoring sandbox or in CI: no firewalld, no nftables, no systemd
units to own. CI lints it and nothing more, which the README says plainly.

The day builds both halves of reachability, because a firewall with nothing
behind it teaches nothing. `setup.sh` starts and enables firewalld, forces
the default zone to `public`, installs `/usr/local/bin/lab-web` (a one-line
`python3 -m http.server 8080 --bind 0.0.0.0`) as `lab-web.service`, opens
8080/tcp permanently AND reloads, adds one rich rule (9090/tcp from
127.0.0.0/8 only), and then prints the `nft` chains its own commands
produced.

The spine of the day is that "is the port open" is three questions answered
by three programs: `ss` (is anything listening), `firewall-cmd` (what the
policy intends, runtime and permanent separately), and `nft` (what the
kernel will actually do). The payload `lab-fw` prints all three side by
side and names the mismatch; with no argument it ends in a "where the two
disagree" section that lists open ports with no listener and listeners the
firewall blocks.

`break-and-fix.sh` has three cases plus two behind `--hard`: a runtime-only
change that vanishes at the next reload, an open port with the service
stopped, the `trusted` default zone (a healthy firewalld enforcing nothing
- which is exactly what verify's fifth check exists to catch), then
`--hard` adds a second nftables table hooked at priority -300 that drops
the packet while `firewall-cmd --query-port` keeps saying yes, and finally
the SSH lockout, which is DESCRIBED AND NOT EXECUTED because it would end
the reader's session with no console to recover from. `--timeout=120` is
taught there as the habit that makes remote firewall work safe.

`restore()` runs on `trap ... EXIT INT TERM`, re-adds the port, resets the
default zone, deletes the stray nft table, restarts the service, and then
CHECKS the result with `--query-port` and a real curl probe rather than
assuming it - the Day 09 lesson applied here.

`verify.sh` is the stub's, unchanged: five automatic checks and one manual.
The README was written to it, parity verified.

### Day 10 was written (2026-09-10) and RAN GREEN in the authoring sandbox

Day 10 is the first day since Day 04 that could be executed where it was
written, because it needs only `openssl` - no namespaces, no VM, no `ip`.
Setup, verify, the tour, `break-and-fix.sh --hard` and teardown were all run
end to end here: **7 passed, 0 failed, 2 YOU**. The header row says
"Host: openssl only, no namespaces", changed from the stub's
"Host: network namespaces", because the day does not use them.

Everything lives in `/etc/lab-tls` (mode 0700), plus `/run/lab-tls` for the
pidfile and the server log, and `/usr/local/bin/lab-tls` for the payload.
The CA is self-signed with `basicConstraints=critical,CA:TRUE` and
`keyUsage=critical,keyCertSign,cRLSign`, valid 3650 days. Three leaves are
issued by one `issue()` function that differs only in SAN and dates:
`server.crt` (SAN www.lab.test, 365 days), `wrongname.crt` (SAN
other.lab.test), and `expired.crt` (`-not_before` 30 days ago,
`-not_after` yesterday, with a `-days -1` fallback for older openssl).
Every leaf gets `basicConstraints=CA:FALSE`, `keyUsage`, `serverAuth`, and a
SAN list including `localhost` and `IP:127.0.0.1` so the server can be
reached on loopback.

The teaching point the scripts are built around: `openssl verify` accepts
`wrongname.crt` because it checks the chain and the dates and is never told
what hostname you wanted. Hostname matching is the client's job
(`-verify_hostname`), which is why chain, dates and hostname are reported
separately by `lab-tls` and by every case in `break-and-fix.sh`.

`s_server` runs as `nohup openssl s_server -accept 4433 -naccept 200 -www`
with its pid in `/run/lab-tls/s_server.pid`. `break-and-fix.sh` swaps the
served certificate with a `serve()` helper rather than editing files, and a
`trap restore EXIT INT TERM` puts the good pair back. Case 4 (cert with the
wrong key) is the only case where the SERVER fails to start; it was verified
to print `key values mismatch` from the real openssl log.

Verify has seven automatic checks, one of them negative: a handshake with no
`-CAfile` must be REFUSED. Teardown stops the pidfile server, then kills any
stray `s_server` on 4433 by `pgrep`, then proves the port is free with `ss`
- the Day 08 stray-daemon lesson applied to a port instead of a namespace.
Nothing is ever added to a system trust store; Day 17 is the day that does
that, and it reuses this CA.

### Day 09 was written (2026-09-10) and has not been run locally

Day 09 adds no topology. It reuses Day 06's four namespaces and installs one
observer, `/usr/local/bin/lab-trace`, plus a capture directory at
`/var/log/lab-trace`. `setup.sh` rebuilds Day 06's topology if a namespace is
missing (same idiom as Days 07 and 08), then takes one real capture at
`router:veth-rcl` and reads it back, so the day proves its own tooling before
teaching with it.

The interface to watch is `veth-rcl`, the router's end of the client's veth
pair. Capturing in the middle is the whole point: it is the only place that
can tell "never sent" apart from "never arrived".

`break-and-fix.sh` has five cases. Three are loud (interface down, no route,
far end with no route back) and two are behind `--hard`: an MTU of 1280 that
passes ping and refuses `-M do -s 1400`, and a permanent bogus ARP entry for
10.10.0.1. All are undone by a `trap restore EXIT INT TERM`, so an interrupt
cannot leave the network broken.

Every capture uses `tcpdump -c N -w FILE` started one second before the
traffic and killed afterwards if `-c` did not end it. That pattern lives in
one function, `capture_probe`, rather than being copied per case.

Day 08's DNS is optional for Day 09. Setup reports whether the resolver is
still on :53 and continues either way, so CI does not depend on Day 08
having run.

Also fixed in this pass: Day 08's `teardown.sh` no longer asserts "Nothing,
after a two second wait" without reading the command's output. It captures
the answer and branches - empty means the timeout paragraph, non-empty means
a paragraph explaining that a name still resolving after its server is gone
is the most misleading state in DNS, with two commands to find who answered.

### Day 08 was written (2026-09-09) and has not been run locally

Five scripts: `lab-dnsq.sh` (payload), `setup.sh`, `explore-dns-server.sh`
(read-only tour, twelve sections), `break-and-fix.sh`, `teardown.sh`. All five
need root, like Days 06 and 07. No `on-lab-vm.sh` guard, same reason: namespaces
cannot reach the host's own stack. CI executes this day for real.

The authoring sandbox has neither `ip` nor `unbound`, so nothing here was
executed. Every config was written against the unbound documentation and is
validated at runtime by `unbound-checkconf` before the daemon reads it, which
is the strongest guarantee available without running it. CI is the first real
run.

| Decision | Why |
|---|---|
| `unbound` for BOTH halves, not bind for one | `ci.yml` already installs `unbound` and nothing else DNS-serving. One binary doing both jobs is also the better lesson: `local-zone: "lab.test." static` is the entire difference between authoritative and recursive |
| Configs under `/etc/unbound/lab/`, started with explicit `-c` | Never touches the distribution's own `unbound.conf` or its service. A reader with unbound already running on port 53 is unaffected, because both instances live in namespaces |
| `local-zone: "." refuse` on the auth server | Makes it non-recursive, which produces `REFUSED` for outside names. That gives the day three distinguishable rejections - NXDOMAIN, SERVFAIL, REFUSED - instead of two |
| `private-domain: "lab.test."` on the resolver | Without it unbound strips RFC1918 answers as DNS-rebinding protection and every reply comes back NOERROR with zero answers, nothing logged. The single most confusing failure available in this stack, so it is called out in the README's Notes |
| `www.lab.test` TTL is 30 seconds | A full cache expiry is watchable inside a minute. `--hard` then sets the same record to 86400 to show a correct, completed migration serving the old address for a day |
| `setup.sh` kills Day 07's nameserver | It holds `10.10.1.2:53`. Otherwise unbound fails with "address already in use" and the reader debugs today's config instead of yesterday's leftovers |
| Payload is a query tool, not a daemon | unbound IS the daemon today. `lab-dnsq` asks both servers and prints status/flags/TTL/answer aligned, so "run it twice" makes the cache visible with no tooling |
| Day 06's topology rebuilt, not required | The rule earned by Day 07's CI failure - see below |

The reader's first run found one bug: unbound ships a built-in `local-zone` for
the reserved TLD `.test` (RFC 6761) that answers NXDOMAIN before any `stub-zone`
is consulted, so the resolver denied every name while the authoritative server
answered correctly. The tell was the SOA in the reply naming `localhost.`. Fixed
with `local-zone: "lab.test." nodefault` and `domain-insecure` on the resolver.
Same class of default as `private-domain`; Days 10, 12 and 17 inherit both.

Also fixed then: `lab-dnsq` keyed answer/TTL extraction on the query type, so a
CNAME reply printed `-` for both, and the README wrongly claimed a CNAME returns
two records - a static local-zone does not chase the alias.

Verify checks were all five tightened from the generator's stubs, which had
`grep -q .` on three of them (any answer at all would pass). They now match
exact addresses and the SOA's own mname/rname. `vl_need dig ip ss` gained `ss`,
which check one needs. A second `vl_manual` was added - naming what REFUSED,
SERVFAIL and NXDOMAIN each mean - and the README's manual list was updated in
the same change, because parity compares descriptions.

### Day 07 was written (2026-09-09), and its payload was run, but the day was not

Five scripts: `lab-nameserver.sh` (payload), `setup.sh`, `explore-dns.sh`
(read-only tour, twelve sections), `break-and-fix.sh`, `teardown.sh`. All five
need root, like Day 06. No `on-lab-vm.sh` guard, for the Day 06 reasons -
everything it writes lives under `/etc/netns/<ns>/` and is invisible outside
the namespace it belongs to. No `ci.yml` override needed.

Objects: `/usr/local/bin/lab-nameserver`, `/etc/netns/client/{resolv.conf,
nsswitch.conf,hosts}`, `/etc/netns/resolver/resolv.conf`,
`/run/lab-nameserver.pid`, `/var/log/lab-nameserver.log`, backups in
`/root/day07-backup`. Zone served: `lab.test`, `www.lab.test`,
`auth.lab.test` -> 10.10.2.2, `client.lab.test` -> 10.10.0.2. The hosts file
says `www.lab.test` is 10.10.0.99, so `getent` and `dig` disagree on purpose.

**The payload WAS executed in the authoring sandbox and works.** `sudo
./lab-nameserver.sh serve 127.0.0.1`, then `dig @127.0.0.1`: A records
returned with the right TTL and address, NXDOMAIN for an unknown name, and
every query logged with the asker's address. What could NOT be run is the day
itself, because the sandbox still has no `ip` binary and no network to install
one - so `setup.sh`, `explore-dns.sh`, `break-and-fix.sh`, `teardown.sh` and
`verify.sh` are linted only, and CI is their first real run.

| Choice | Why |
|---|---|
| A hand-written ~60-line Python nameserver instead of `dnsmasq` or `unbound` | Day 08 is "Running DNS: authoritative and recursive" and owns `unbound`. If Day 07 configured a real server there would be nothing left for Day 08 to teach. The payload also needs no package that a CI runner might not have: `python3` is everywhere, and a DNS answer is a byte layout, so it cannot be faked with `printf` and netcat. |
| Day 07 does not invent a network; it calls Day 06's idempotent `setup.sh` when the namespaces are absent, then pings across it before relying on it | First real inter-day dependency, and the first version got it wrong: it *died* telling the reader to run Day 06 first. Namespaces do not survive a reboot, and every CI job is a fresh runner, so a missing topology is the NORMAL case. CI failed on exactly that (`no 'client' namespace`, exit 1) while Days 06, 08, 09, 10 and 18 passed, because they build their own floor. A prerequisite that can be rebuilt in one second must be rebuilt, not reported. |
| Per-namespace config via `/etc/netns/<ns>/` rather than editing `/etc/resolv.conf` | This is the day's best single fact: `ip netns exec` bind-mounts `/etc/netns/NAME/foo` over `/etc/foo` for the life of that one command. It is also what makes the day safe on a reader's laptop and what makes failure 5 possible. |
| `setup.sh` *fails* if `dig` and `getent` ever agree about `www.lab.test` | If they agree, the hosts entry is not being read and the entire day teaches nothing. Better to stop at setup than to have the reader work through a tour whose premise is silently false. |
| Four of the five failures print no error at all | The thesis of the day: DNS failures are mostly not errors, they are correct answers from the wrong layer. Failure 1 (drop `files` from nsswitch) is the sharpest - `getent` starts *agreeing* with `dig`, and a pinned address silently stops applying. |
| `--hard` = trailing dot in `/etc/hosts`, and the right file in the wrong `/etc/netns` directory | Both pass a configuration review. `/etc/hosts` matches literal strings, so `www.lab.test.` never matches `www.lab.test`; and `grep -r` finds a misfiled hosts entry immediately, which is exactly why people believe it is being used. |
| Failure 3 uses SIGSTOP, not SIGTERM | Distinguishes timeout (socket open, nobody reading) from connection-refused (nothing listening) from NXDOMAIN (a server said no). All three get reported as "DNS is broken". `teardown.sh` sends SIGCONT before SIGTERM for this reason - a stopped process cannot act on SIGTERM. |

**`verify.sh` was rewritten, not extended.** The stub had two checks that
could pass without the day being done: `grep -qE "^hosts:" /etc/nsswitch.conf`
read the *host's* file, which is `files dns` on nearly every Linux machine;
and the nameserver check ended in `|| ip netns exec client cat
/etc/resolv.conf`, which succeeds whenever the file exists. Both now read from
inside the namespace and match on the exact address. This clears one of the
four known weak checks (the d07 one). A fifth check was added, `the nameserver
answers from the resolver namespace`, taking the day to 5 PASS + 2 YOU and
matching Days 04-06. `vl_need ip getent dig` + `vl_need_root`.

README is 176 lines and follows **Day 06's** host-day headings, not Day 05's
VM sequence. It carries the layer diagram, a five-failures table, and states
plainly that `dig` is a DNS client rather than a resolver - it reads
`resolv.conf` only to find a socket, and never reads `nsswitch.conf` or
`/etc/hosts`.

### Day 06 was written (2026-09-08), and has not been run anywhere

Five scripts: `lab-netcheck.sh` (payload), `setup.sh`, `explore-net.sh`
(read-only tour), `break-and-fix.sh`, `teardown.sh`. All five need root,
which is a first for this repo - `ip netns exec` is privileged and there is no
unprivileged substitute. Objects: namespaces `client router resolver auth`,
veth pairs `veth-cl/veth-rcl`, `veth-rs/veth-rrs`, `veth-au/veth-rau`, three
/24s on 10.10.0/1/2, `net.ipv4.ip_forward=1` in the router namespace only.

**This is the first day whose scripts do NOT source `lab/on-lab-vm.sh`, and
that is deliberate, not an oversight of Rule 8.** A network namespace is a
separate copy of the kernel's network stack; nothing here adds an address, a
route or a sysctl to the namespace the host actually uses. That isolation is
the same fact that makes Days 06-10 cost 0 MB and makes them CI-executable.
Rule 8 exists to stop a day rewriting the reader's own machine, and this day
cannot. No `LAB_ALLOW_THIS_MACHINE` override is needed in `ci.yml` either -
there is no guard to override, unlike Day 04.

| Choice | Why |
|---|---|
| `setup.sh` builds the topology itself instead of calling `lab.sh netns-up` | `ci-day.sh` prefers `scripts/setup.sh` when it exists, so adding one silently changes what CI runs for Day 06. Building it here in seven narrated steps is the day's actual content; `lab.sh netns-up` remains the one-command form for Days 07-10 and 18. Same names, same addresses, so a later day cannot tell which was used. |
| Idempotent via `addr replace` / `route replace`, and repairing rather than dying on a second run | `lab.sh netns-up` **dies** if a namespace already exists. A reader who ran that first and then `setup.sh` would hit a dead end on line 1. `setup.sh` also clears veth ends stranded in the root namespace by a half-finished run. |
| No `set -e` in `lab-netcheck.sh` | A reachability probe whose job is to report failures must not exit on the first one. Its exit status still reflects the network. |
| Five failures chosen to produce four *distinguishable* symptoms | The skill being taught is reading the symptom, not the fix. Instant "unreachable" = local routing; timeout with a reachable next hop = forwarding or a filter; timeout with requests arriving = return path; timeout with everything apparently correct = `ip route get`. The README carries this as a table. |
| `--hard` = link down with the address still present, and `/16` where `/24` belonged | Both look like working configuration. The first withdraws the connected route while `ip addr` still shows the address; the second makes the client ARP for hosts two networks away. Neither would fail a config review. |
| Second `vl_manual` added: `you saw a ping fail in one direction only, and proved which one` | Ties failure 3 to the checklist and makes the point that a ping proves a round trip, so a failed ping never says which direction broke. Takes the day to 5 PASS, 2 YOU, matching Days 04 and 05. |
| `10.10.0.2` tightened to `10.10.0.2/24` in check 2 | The loose form also matched `10.10.0.20` and, worse, the `/16` of failure 5 - so break-and-fix could leave the day broken and still green. |

The README departs from the Days 01-05 runbook shape in one visible way: the
six step headings are not the VM sequence (`bring up node1`, `copy the repo`,
`prove it across a reboot`). There is no VM to bring up and nothing survives a
reboot by design, so step 1 is "No VM today" and step 5 is the check. Days 07,
08, 09 and 18 should follow **Day 06's** headings, not Day 05's.

### Day 04 was written (2026-09-08), and RAN GREEN on node1

First day after Day 01 to be executed on a real Rocky VM. Final result:
**5 PASS, 0 FAIL, 2 YOU, exit 0**, with the ghost file found via
`sudo lsof +L1` showing `NLINK 0` on `/srv/data/ghost.bin`. `setup.sh`, the
live `lvextend` + `resize2fs` grow, and `break-and-fix.sh --hard` all
completed for real.

Three bugs the run exposed, all fixed:

1. **No `vl_need_root` in `verify.sh`.** `vgs` and `lvs` are root-only while
   `/proc/mounts` is world-readable, so a non-root run printed FAIL for the
   volume group and PASS for the mount served *by* that volume group - a
   convincing false red. The README had *documented* the hazard instead of
   fixing it. Standing rule now: **if a day's checks read privileged state,
   call `vl_need_root`; never substitute README prose for a missing guard.**
2. **Bare `lab-writer` in the README.** Installed to `/usr/local/bin`, which
   `sudo`'s `secure_path` omits on RHEL-family systems. Now called by path.
3. **No package list.** The Rocky 9 cloud image ships neither `lvm2`,
   `e2fsprogs` nor `lsof`, and `lab.sh` cloud-init installs nothing. Every
   day must now name the packages it needs, and the dependency check must
   cover every tool the whole day uses, not just setup's own.

Also confirmed by the run: `./lab/lab.sh down node1` really does take the
`add-disk` disk with it, and a rebuilt VM has no packages - `pvs`/`vgs`/`lvs`
printing nothing is a blank machine, not a broken one. Documented in the day's
step 3.

### Day 04 as originally written

Five scripts, same shape as Days 01-03: `lab-writer.sh` (payload, no root),
`setup.sh`, `explore-storage.sh`, `break-and-fix.sh`, `teardown.sh`. Objects:
PV on `/dev/vdb` or a loop device, VG `labvg`, LV `labdata` (512 MB), ext4,
mount point `/srv/data`, unit `srv-data.mount`, payload installed as
`/usr/local/bin/lab-writer`.

Why each choice, so the next person does not undo one by accident:

| Choice | Reason |
|---|---|
| LV starts at 512 MB, not the whole disk | the day is about growing it online; a full-size volume has nothing to teach |
| ext4, not xfs | both grow mounted, only ext4 can shrink. `--hard` step 5 needs a shrink that is *refused for a reason*, not one that is impossible |
| `.mount` unit, not `/etc/fstab` | so the filename-must-match-the-path rule can be broken on purpose in `break-and-fix.sh` step 2 |
| real disk preferred, loop device as fallback | a loop device is real LVM but does not survive a reboot, so step 5 of the README needs the real one. `setup.sh` prints which it chose and why |
| refuses any device with a `blkid` signature, partitions, or a mount | this is the most destructive script in the repo; `pvcreate` on the wrong device is unrecoverable |
| never reformats an existing `labdata` | a second `setup.sh` run must not destroy the reader's data |

Expected on a healthy run: **5 PASS, 2 YOU, exit 0.**

**Day 04 is the first day CI actually executes.** `lab/ci-day.sh 04` finds
`scripts/setup.sh` and runs it as root on an Ubuntu runner, which is not a lab
VM by hostname, so `require_lab_vm` would refuse. Resolved by setting
`LAB_ALLOW_THIS_MACHINE=1` on the day-04 matrix step only, in `ci.yml`, with a
comment explaining it — a runner is destroyed after every job, which is the
only thing that guard is really asking about. Rule 8 is unchanged and the
other six CI days do not need this: days 06-09 and 18 work inside network
namespaces, and day 10 only writes files under `ca/`.

The likeliest real-world failures, in order: `lsof` not being installed on a
minimal Rocky 9 image (`break-and-fix.sh` step 3 falls back to `/proc/PID/fd`
and says so); `resize2fs` on a loop device inside CI behaving differently from
one on virtio; and the ordering of `udev` settling after `lvcreate`, which can
make `mkfs` race on a slow machine.

### First real execution of any verify.sh (2026-09-08)

The owner ran three days on their **Ubuntu laptop**, not on a VM. This is the
first execution evidence in the project, and it is all off-target on purpose:

| Day | Result on the laptop |
|---|---|
| 01 | 1 PASS, 3 FAIL, 1 YOU — the PASS is `the machine boots with no failed units`, which is about the laptop |
| 02 | 5 SKIP, 1 YOU — `vl_need_root` caught it, the only day that degrades honestly |
| 03 | 1 PASS, 3 FAIL, 2 YOU — the PASS is `cgroups v2 is the unified hierarchy`, true of any modern Linux |

Two lessons were taken from this. A lab-VM guard in `verify-lib.sh` was
considered and **declined** by the owner in favour of documentation, so each
day's README now carries a bolded "Run it on \<vm\>, not on your laptop"
paragraph that names the checks which would falsely `PASS` off the VM. And a
sentence in Day 03's README claiming "if every check reports SKIP, systemctl is
missing" was factually wrong and has been removed — the laptop has systemctl.

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
   qemu were not installed. Nothing past `check` has run for real yet:
   `image`, `up control`, `push control`, `ssh control` are still untested
   against real KVM, as are all five Day 01 scripts against real systemd.
2. **Write the day scripts.** Days 01 through 14 are done (5 scripts each).
   Days 05-20 ship an empty `scripts/` directory. They are written one day at a time, each run on
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
8. **Every script that changes system state must `source lab/on-lab-vm.sh` and
   call `require_lab_vm`.** Day 01 was run on the user's laptop because no
   script asked where it was. Read-only tours are the one deliberate exception.
   A teardown may skip the guard only when everything it removes is unambiguously
   ours, as in Day 01; Day 02's teardown deletes a user and `/srv/shared`, so it
   is guarded.
9. **Name the machine in every instruction.** "Run `sudo reboot`" is a bug.
   "Reboot the VM: check `hostname` prints `control`, then `sudo reboot`" is
   not.

---

## 11. File inventory

```
README.md                     9.4 KB   overview, quickstart, tiers, memory budget
docs/curriculum.md            9.5 KB   all 20 days with reasoning
docs/HANDOFF.md                        this file
lab/lab.sh                   36.2 KB   1043 lines, 42 functions, 14 subcommands
lab/verify-lib.sh             2.7 KB   100 lines, 6 public functions
lab/on-lab-vm.sh              2.0 KB   65 lines, refuses to run off a lab VM
lab/ci-day.sh                 1.9 KB   57 lines
lab/README.md                 3.3 KB   hardware, install, manual fallbacks
days/dayNN/README.md          20 files
days/dayNN/verify.sh          20 files, 102 auto + 31 judgement checks
days/day01/scripts/           5 files   470 lines: lab-demo.sh, setup.sh,
                                        explore-boot.sh, break-and-fix.sh,
                                        teardown.sh
days/day02/scripts/           5 files   ~34 KB: lab-app.sh, setup.sh,
                                        explore-perms.sh, break-and-fix.sh,
                                        teardown.sh
days/day03-20/scripts/        18 empty directories
.github/workflows/ci.yml      2.5 KB   79 lines, 3 jobs
CONTRIBUTING.md               7.7 KB   208 lines, 9 sections
LICENSE                       1.1 KB   MIT, holder: ericvalijani
tests/cli.sh                  4.2 KB   127 checks, no VM or root needed
.pre-commit-config.yaml       1.3 KB   never executed, see §9 item 5
.gitignore                    413 B    33 lines
```

50 shell scripts, all `bash -n` clean. 20 days. Day 01 written and run for real
on the lab; **Day 04 written and run end-to-end on `node1` (2026-09-08)**;
Days 02, 03 and 05 written, never executed on a Rocky VM. Days 06, 07 and 08 written and never executed locally - they need no VM, but the authoring sandbox has no `ip` and no `unbound`, so CI is their first real run (Day 07's nameserver payload alone WAS run and works). Day 06 is green in CI; Day 07's first CI run failed on a missing prerequisite and was fixed by rebuilding it. Days 09-20 outstanding, except Days 11-14 which are written (Days 12 and 13 run on hardware, Day 14 lint-only so far). `tests/cli.sh`: 307 passed, 0 failed.
