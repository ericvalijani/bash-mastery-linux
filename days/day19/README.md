# Day 19 — Intrusion detection and audit alerting

**Phase:** Production operations
**Runs on:** `node1`
**Time:** about ninety minutes

Days 11 to 13 were prevention: a firewall, a hardened sshd, SELinux in
enforcing mode. Prevention has a failure mode you cannot see from the inside
— it either worked or something got through, and nothing on the machine tells
you which.

Today you install the two sensors that answer the two questions nobody can
answer by watching a screen. **Suricata** sees what crossed the network
interface. **auditd** sees which syscall touched which file, and which *login*
account was behind it. Neither one prevents anything. That is not a gap in the
setup, it is the category — and it is why both of them exist on the same host
as Day 11's firewall rather than instead of it.

Installing them is one `dnf` line. The work is that a detection stack has a
failure mode of its own: running, enabled, valid configuration, zero
detection. Four of today's five failures look exactly like a healthy machine.

## What you will work with

- `suricata -T -c /etc/suricata/suricata.yaml`, the config-and-rules test — one
  missing semicolon in one rule stops the whole engine rather than that rule,
  so this runs before every reload
- the `af-packet` section, which names the interface to capture from. The
  packaged default is `eth0` and this VM's interface is not called that; an IDS
  on the wrong interface is the quietest outage in this course
- `rule-files`, absolute paths versus names under `default-rule-path`, and why
  your own rules never live where `suricata-update` can overwrite them
- rule syntax — `action proto src port -> dst port (options)`, `msg` as the
  line you will read at 3am, `itype`, the `dns.query` sticky buffer, `classtype`
- sid numbering, which is a namespace and not a label: reuse a public
  ruleset's number and one of the two rules silently loses
- `eve.json`, one JSON object per line, with alerts, flows, DNS, TLS and stats
  all in the same file, and `jq` as the only sane way to read it
- `auditctl -w path -p wa -k key`, `-a always,exit -F arch=b64 -S execve`, and
  why the key is not a comment
- `auid` versus `uid` — the login uid survives `su` and `sudo`, so it answers
  "who did this" where `uid` only answers "as whom"
- `/etc/audit/rules.d/` with `augenrules --load`, and `augenrules --check`, the
  only command that compares the kernel's rules with your files
- `systemctl restart auditd` being refused, which is correct and surprises
  everyone exactly once
- `ausearch -k`, `ausearch -i`, `aureport --summary` — searching by key,
  translating numbers into names, and counting before reading
- EPEL, again: Suricata is not in the base Rocky repositories, the same way
  Day 12's fail2ban was not

## One VM, and the memory

| VM | Memory | What runs on it | Why |
|---|---|---|---|
| `node1` | 2048 MB | Suricata, auditd | Suricata's detection engine is the memory in this day; auditd costs almost nothing |

About **2 GB** in total, the same single VM as Day 17. Nothing in this lab is
below 1536 MB, which is the minimum Rocky 9 recommends and the number
`virt-install` warns about.

No ruleset is downloaded. `suricata-update` is deliberately not run — today is
about rules you wrote, and the Emerging Threats open ruleset would not be kind
to a 2 GB VM. `setup.sh` creates an empty `/var/lib/suricata/rules/suricata.rules`
so the packaged configuration stays valid, and adds your own file to
`rule-files` by absolute path.

Days 14 to 18 are not prerequisites. Today touches nothing they built — no
`ansible.cfg`, no project directory, no tunnel, no bridge. The day it leans on
is Day 12, for the EPEL repository and for the habit of reading logs a daemon
wrote about somebody else's traffic.

The shape you are building:

```
   the wire                                     the disk
   ────────                                     ────────
   enp1s0 ──► suricata ──► /var/log/suricata/    open() ──► kernel audit ──► /var/log/audit/
              af-packet         eve.json         read()        rules.d          audit.log
              lab.rules         (jq)             write()       (auditctl -l)    (ausearch -k)
              sid 9000001                        execve()      key names
```

Two daemons, two blind spots, and no connection between them. Suricata knows
nothing about files; auditd knows nothing about packets. An attacker who logs
in with a stolen key produces no interesting packets, and an attacker
exploiting a service produces no interesting logins — which is why the answer
is both and not either.

## Scripts

| Script | What it does |
|---|---|
| `scripts/setup.sh` | eight steps: packages from EPEL, interface detection, `suricata.yaml`, two local rules, `-T` then the service, audit rules plus `augenrules --load`, the payload, and a live trigger of both sensors that fails the run if nothing was recorded. Idempotent |
| `scripts/lab-ids.sh` | installed as `lab-ids`. `status`, `alerts`, `audit`, `watch`, `prove`, `trigger` |
| `scripts/explore-detection.sh` | twelve read-only stops across both sensors |
| `scripts/break-and-fix.sh` | four real failures, each fixed in front of you. `--hard` leaves all of them live and adds a fifth |
| `scripts/teardown.sh` | lab rules, the canary and the payload removed. `--all` also stops Suricata and restores the packaged config |
| `verify.sh` | twenty-two automatic checks, two for you to judge |

## Run it

On your laptop, in the repository:

```bash
./lab/lab.sh up node1                   # ~2 GB
./lab/lab.sh status                     # read the address
./lab/lab.sh push node1                 # carries days/ and lab/
./lab/lab.sh ssh node1
```

`lab.sh status` prints something like:

```
node1     running   192.168.122.140     # EXAMPLE address — use your own
```

That is an example. DHCP leases move every time a VM is rebuilt, so read it
yourself each session rather than copying it from here.

Then, on `node1`:

```bash
cd ~/lab/days/day19
sudo ./scripts/setup.sh
```

It enables EPEL if it has to, detects the interface your default route
actually uses, writes two rules of your own with local sids, loads audit rules
for `/etc/shadow`, `/etc/sudoers`, a canary file and every root command run
from a login session — and then **fires both sensors on purpose** and fails if
neither recorded anything. A detection stack nobody has ever seen fire is a
detection stack you do not know works.

Then, in order:

```bash
sudo lab-ids                         # both daemons, the capture interface, rule counts
sudo lab-ids alerts                  # eve.json, readably
sudo lab-ids audit                   # what auditd recorded, by key
sudo lab-ids watch                   # follow alerts live, Ctrl-C to stop
sudo lab-ids prove                   # trigger, wait, and time the flush
sudo lab-ids trigger                 # fire both sensors again, on demand
sudo ./scripts/explore-detection.sh  # read the stack you just built
sudo ./scripts/break-and-fix.sh      # four failures, four fixes
sudo ./scripts/break-and-fix.sh --hard
sudo ./verify.sh
```

If you edit the scripts on your laptop afterwards, push them again before you
re-run anything — the VM has its own copy and will happily keep running the
old one:

```bash
./lab/lab.sh push node1
```

### Seeing the flush interval for yourself

Worth doing once, before `verify.sh`. One session, no coordination:

```bash
sudo lab-ids prove
```

It counts the alerts in `eve.json`, fires both sensors, then waits up to 90
seconds for the count to go up and tells you how long it actually took. That
delay is the flush interval, and everything anyone ever builds on top of an
IDS — dashboards, tickets, pages — reads that file after it.

**The delay is the point, and it is longer than it feels like it should be.**
Suricata batches writes to `eve.json`; tens of seconds is normal on a 2 GB VM.
If you fire the sensors and look immediately, you see nothing, and nothing
looks exactly like broken.

If you want to watch it happen rather than be told about it, that takes **two
separate SSH sessions to node1** — the watching command never returns on its
own, so pasting both into one prompt just glues them together and gets you a
`jq` parse error. On your laptop, open a second terminal and run
`./lab/lab.sh ssh node1` in it, so you have two sessions on the VM:

```bash
# session A - leave this running; it prints a heartbeat every 15s
sudo lab-ids watch

# session B
sudo lab-ids trigger
```

Then wait. Up to a minute. `Ctrl-C` session A when the alert lines appear. The
heartbeat is there so you can tell "waiting" from "hung" — which is exactly
the ambiguity `lab-ids prove` exists to remove.

Neither command is magic. `lab-ids watch` is only this, if you would rather
type it out:

```bash
sudo tail -n 0 -F /var/log/suricata/eve.json \
  | grep --line-buffered '"event_type":"alert"' \
  | jq -c --unbuffered '{sid: .alert.signature_id, msg: .alert.signature}'
```

## What to actually look at

**The interface, twice.** These two must name the same device:

```bash
sudo awk '/^af-packet:/{f=1} f && /interface:/{print; exit}' /etc/suricata/suricata.yaml
ip route show default
```

When they disagree, `systemctl status suricata` is green, `suricata -T`
passes, the rules are loaded, and nothing will ever alert. There is no error
anywhere on the machine, and nothing in the logs to grep for. That is the
`--hard` failure, and it is the reason `setup.sh` reads the device from the
routing table instead of trusting the packaged `eth0`.

**`active` is not `ready`.** This one cost the first run of this day. Suricata
parses the config, builds a detection engine out of every rule, creates
capture threads, and only then looks at a single packet. `systemctl is-active`
goes green at the start of that, not the end, and on a 2 GB VM the rest takes
tens of seconds. Traffic sent in the gap did not happen as far as the IDS is
concerned, and nothing in `eve.json` says so — there is simply no alert. The
line that means ready lives in `suricata.log`:

```bash
sudo grep 'Engine started' /var/log/suricata/suricata.log
sudo lab-ids status                     # prints it, and the rule count
```

`setup.sh` waits for that line, then sends traffic on a loop rather than
once, because `eve.json` is flushed on an interval as well. A health check
that asks systemd whether a sensor is working gets this wrong on every IDS,
agent and log shipper there is.

**auditd buffers, so "no event" can mean "not written yet".** The kernel
hands each record to auditd the moment it happens, but `auditd.conf` ships
`flush = INCREMENTAL_ASYNC` with `freq = 50`, so auditd writes `audit.log`
every 50 records. Read a watched file once on an idle VM and `ausearch` finds
nothing, while the event has in fact been recorded and is sitting in a buffer.
This is exactly how a log search can say "clean" about a machine that is not:

```bash
sudo grep -E '^(flush|freq)' /etc/audit/auditd.conf
for i in $(seq 1 60); do sudo cat /etc/lab-canary >/dev/null; done
sudo ausearch -k lab_canary -ts today | tail
```

`setup.sh` generates a burst past `freq` rather than a single access, for this
reason.

**The file and the kernel, for audit rules.** `auditctl -l` prints what the
kernel is enforcing; `/etc/audit/rules.d/` holds what you intended. They can
disagree in both directions — a rule written and never loaded, or a rule
loaded by hand and never saved:

```bash
sudo augenrules --check      # 'No change' is the only good answer
```

This is the same lesson as Day 11's `sysctl` files, Day 16's `wg showconf` and
Day 17's certificate-without-a-reload, and it is the fourth appearance on
purpose: **a configuration file is a request, not a state.**

**One bad rule takes down every rule.** The ruleset is compiled as a unit. A
missing semicolon does not disable that signature, it stops the engine from
starting — so a reload without `suricata -T` first can leave a host with no
detection at all, which is strictly worse than the one rule you were adding.

**`auid` is the field that matters.** Read one event in full:

```bash
sudo ausearch -k shadow_watch -ts today -i | tail -20
```

`uid=0` tells you almost nothing on a machine where everybody uses `sudo`.
`auid` is the account that logged in, it survives `su` and `sudo`, and it is
the reason auditd answers questions `journalctl` cannot.

**The canary is the shape a good rule has.** `/etc/lab-canary` is watched with
`-p rwa`, so even reading it is recorded. Nobody has a legitimate reason to
read it, so every single event is interesting — and a rule whose every event
is interesting is the only kind worth alerting on. Compare it with the ICMP
rule, which is a fine lab rule and would be pure noise in production. Naming
that distinction is one of the two judgement calls.

**Alert volume is where tuning starts.**

```bash
sudo jq -r 'select(.event_type=="alert") | .alert.signature' \
  /var/log/suricata/eve.json | sort | uniq -c | sort -rn
```

The signature at the top of that list is either your most important detection
or the one nobody will ever read again. An IDS is a log generator; if nothing
reads the log on a schedule you have bought storage costs and a feeling.

**sids are a namespace.** 1000000–1999999 is the local range; anything lower
belongs to a public ruleset. Today's rules use the 9000000 block so lab rules
are obvious in a log, and `verify.sh` asserts that no lab sid sits in the
public ranges — a collision means your rule or theirs quietly loses, with no
error either way.

**auditd is not restarted with systemd.** Try it:

```bash
sudo systemctl restart auditd
```

The refusal is deliberate — auditd is started by the kernel's audit subsystem,
not by you. Rules are reloaded with `augenrules --load`, and the daemon itself
with `service auditd restart` if you genuinely must.

**Neither sensor stops anything.** Worth saying out loud once, because the
instinct after Days 11–13 is to look for the blocking switch. Suricata has
one — IPS mode, inline, with `drop` rules — and it is not today's lab, because
an IPS you have not tuned is an outage generator pointed at your own users.

## The four failures

| Break | What you see | Why |
|---|---|---|
| a rule missing its semicolon | `suricata -T` fails for **every** rule | the ruleset compiles as one unit; reloading without testing leaves no detection at all |
| a valid rule never reloaded | the file has it, the engine does not, nothing alerts | editing a rule file is a request; `systemctl reload suricata` is the state change |
| an audit rule written but not loaded | `grep` in `rules.d` passes, `auditctl -l` is missing it | an audit built by reading files would pass this machine; `augenrules --check` is what catches it |
| `auditctl -D` | every file is perfect and nothing is recorded | the kernel's rule set is runtime state, and no configuration file reflects that it was emptied |

And with `--hard`, a fifth: Suricata capturing on `lo`. Running, enabled,
config valid, `-T` passing, rules loaded, watching an interface where none of
the traffic you care about goes. All five are left live at once, `verify.sh`
should fail, and `sudo ./scripts/setup.sh` puts everything back.

## Teardown

On `node1`:

```bash
sudo ./scripts/teardown.sh          # lab rules, the canary, the payload
sudo ./scripts/teardown.sh --all    # also stops suricata, restores its config
```

Deleting an audit rules file is not enough — the rules are in the kernel until
something reloads them, so teardown runs `augenrules --load` and then checks
that the watches are really gone rather than assuming it.

auditd is never stopped, and `eve.json` is never deleted, by either mode.
Turning off the record of who did what in order to tidy up is a habit worth
not building, and deleting logs during cleanup is how incidents become
unexplainable.

Then, on your laptop:

```bash
./lab/lab.sh down node1
```

## Done when

`sudo ./verify.sh` prints **22 passed, 0 failed**, 2 for you to judge, and you
can say which of today's two sensors would have caught a stolen SSH key, which
would have caught a port scan, why neither would have stopped either, and what
`augenrules --check` compares.

---

Next up: **Day 20 — Backup, restore and the restore drill.**
