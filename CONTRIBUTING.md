# Contributing

This is a learning repository with a lab attached. That shapes everything
below: the goal is not the largest possible feature set, it is that **every
claim in here is true**.

Issues and pull requests are welcome. Fixing something that does not work on
your distribution, or on your hardware, is the most useful contribution there
is.

---

## The three rules that matter

### 1. Never claim something works that has not been executed

This repository distinguishes carefully between *lint-clean* and *verified*,
and that distinction is load-bearing.

- 7 of the 20 days can be executed for real on a GitHub runner, because an
  Ubuntu runner is a full VM with `sudo`. Those days are genuinely tested in
  CI: namespaces, DNS servers, `tcpdump`, `openssl`, LVM on a loopback file.
- The other 13 days need SELinux, firewalld, systemd units you own, or a
  second host over SSH. CI can only lint them. Their checks are proven by
  running `days/dayNN/verify.sh` on your own lab, and nowhere else.

Each day's README states which of the two it is. If you add or change a day,
say plainly what is proven and by whom. A green check must never imply more
than it tested.

If you write something you could not run, say so in the pull request. That is
not a failing — it is the difference between a useful contribution and a
plausible one.

### 2. Never add a simulation, mock, or offline mode

However convenient it looks. If a thing cannot be verified for real on the
hardware described in `lab/README.md`, the honest move is to say so, not to
fake the output and print a green tick.

One clarification, because it comes up: **network namespaces are not a
simulation.** They are real interfaces, real routing tables, real packets,
real captures — the same kernel machinery containers are built from. That is
precisely why five days of networking cost no memory. Do not describe them as
fake, and do not "upgrade" them to VMs for realism they already have.

### 3. Nothing dangerous runs on the contributor's host

Every command that hardens, firewalls, relabels, partitions or locks something
out must run **inside a VM**, which is disposable. The host is only ever
allowed to run `lab.sh`, `virsh`, `ssh` and `scp`.

The namespace days are the single exception and are safe by construction:
`netns-up` creates namespaces and veth pairs, edits no file anywhere, and
`netns-down` removes all of it. So does a reboot.

A patch that expects the reader to `dnf install` something on their laptop, or
edits a file outside `$LAB_HOME`, will be sent back.

---

## Before you open a pull request

```bash
./tests/cli.sh                 # 100+ checks, no VM and no root needed
```

Optionally, and recommended:

```bash
pip install --user pre-commit && pre-commit install
pre-commit run --all-files     # shellcheck, whitespace, large-file guard
```

If you changed anything a day does, also run that day's checks on a real lab
and paste the output:

```bash
./lab/lab.sh push control
./lab/lab.sh ssh control
cd ~/lab/days/dayNN && sudo ./verify.sh
```

---

## Keeping a day consistent

A day is three files that have to agree with each other:

| File | What it holds |
|---|---|
| `days/dayNN/README.md` | the objective, the work, the checks, what CI proves |
| `days/dayNN/verify.sh` | those same checks, as assertions |
| `days/dayNN/scripts/*` | the scripts the day walks you through |

If you add a check to `verify.sh`, add it to the README's check list too, and
the other way round. A page that claims a check its verifier does not run is
the one bug this repository cannot tolerate, because the whole point is that
the claims are true.

The same goes for the tier label and RAM figure at the top of each day page:
if a day starts needing a second VM, the day page, `README.md` and
`docs/HANDOFF.md` all have to say so.

## Writing day scripts

Day scripts are **teaching material that happens to be executable**. Optimise
for the reader, not for elegance.

- Comment the *why*, not the *what*. `# systemd has not read that yet` earns
  its line; `# reload systemd` does not.
- Say what a flag actually does the first time it appears.
- Every script that changes something must be **safe to run twice**, and
  should be the way back to a known-good state.
- Anything destructive gets a root check and a clear refusal, not a surprise.
- Print the command before running it when the point is for the reader to
  learn the command.
- Long output gets truncated with a note, so the terminal stays readable.

### Two mistakes this repository has already made

Both were caught before release. Do not reintroduce them.

**`((var++))` under `set -e`.** Post-increment returns the *pre*-increment
value, so the first `((count++))` returns `0`, which is a non-zero exit status,
which kills the script. Use `count=$((count + 1))`. Every counter in this
repository uses that form for exactly this reason.

**Never pass an unchecked PID to `kill`.** systemd reports `ExecMainPID` as
`0` when a service is not running, and `kill -9 0` signals *every process in
the caller's process group* — as root over SSH, that includes your own
session. Check for `0` and empty before killing anything.

For reference, one shape that looks dangerous but is not: a false test in a
non-final `&&` position, as in `[[ -n "$x" ]] && y=1`, does **not** trigger
`set -e`. Verified, not assumed.

---

## Never commit

The `.gitignore` covers these, but know why:

- VM disks and base images (`*.qcow2`, `*.img`, `*.iso`) — they belong under
  `$LAB_HOME`, never in git. A pre-commit hook rejects anything over 256 KB.
- Keys and certificates (`*.pem`, `*.key`, `*.crt`, `ca/`) — Day 10 generates
  a private CA. It stays on your lab.
- Packet captures (`*.pcap`) — Day 09 produces them and they contain whatever
  was on the wire.
- Ansible vault passwords (`.vault_pass`, `vault-password`).

If a secret does reach a commit, deleting the file in a later commit **does
not remove it** — it stays reachable in history and every scanner will keep
finding it. Say so immediately rather than quietly pushing a fix on top.

---

## Commits

Conventional commits, with a body that explains the reasoning:

```
feat(day07): DNS resolution path scripts
fix(lab): guard against an empty ExecMainPID before kill
docs(handoff): record the Day 15 platform decision
chore(ci): pin the checkout action
```

One concern per commit. If the subject needs "and", it is two commits.

---

## Adding or changing a day

Keep these in sync, or the repository starts lying:

1. `days/dayNN/README.md` and `days/dayNN/verify.sh`, together.
2. The CI matrix in `.github/workflows/ci.yml` if the day's tier changed.
3. The tier and memory tables in `README.md` and `docs/HANDOFF.md`.
4. The check counts in `docs/HANDOFF.md` §5.
5. `docs/HANDOFF.md` §10 lists every one of these pairings, and the
   **Last updated** date at its top.

Day dependencies are real and easy to break — Day 06 builds the topology that
07, 08, 09 and 18 use; Day 10's CA and Day 08's zone are consumed by Day 17;
Days 11–13 feed the Ansible role in Day 15. `docs/HANDOFF.md` §4 has the full
list. Check it before reordering anything.

---

## Reporting something that does not work

Most valuable report there is. Please include:

- your distribution and `uname -r`
- `./lab/lab.sh check` output
- the exact command and its full output
- for a failing check, `sudo ./days/dayNN/verify.sh` in full

"It failed" is hard to fix. "`virt-install` rejected `--os-variant rocky9` on
Debian 12" is fixed the same day.

---

## License

Contributions are accepted under the [MIT License](LICENSE), the same terms as
the rest of the repository.
