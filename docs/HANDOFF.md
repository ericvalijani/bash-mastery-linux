# Bash Mastery: Linux — Project Handoff

> Complete state of this repository in one file. Written to be pasted into a
> fresh chat so an assistant can pick the work up cold, with no other context.

**Last updated:** 2026-09-07
**Repo:** `bash-mastery-linux`
**Status:** scaffold complete, 20 days written, **Day 01 and Day 02 scripts
written**; Days 03-20 scripts still to write
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
| Day scripts | shipped, written day by day | Days 01-02 done. A day with no scripts yet ships an empty `scripts/` and its README says so |
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
| `tests/cli.sh` | **127 passed, 0 failed** (was 109; Day 02's five scripts added checks) |
| `bash -n` on all 35 shell scripts | 0 failures |
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
2. **Write the day scripts.** Days 01 and 02 are done (5 scripts each).
   Days 03-20 ship an empty `scripts/` directory. They are written one day at a time, each run on
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

35 shell scripts, all `bash -n` clean. 20 days. Day 01 written and run for real
on the lab; Day 02 written, never executed; 03-20 outstanding. `tests/cli.sh`:
127 passed, 0 failed.
