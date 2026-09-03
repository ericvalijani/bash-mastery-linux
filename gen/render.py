#!/usr/bin/env python3
"""Generate day pages, per-day verify.sh, and docs/curriculum.md."""
import os, sys, stat

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from data1 import DAYS_1_10
from data2 import DAYS_11_20

DAYS = DAYS_1_10 + DAYS_11_20
assert len(DAYS) == 20, len(DAYS)

PHASES = [
    (1, 5, "The host", "One machine, understood properly: boot, identity, processes, storage, logs."),
    (6, 10, "The network", "Five days of real kernel networking that cost no memory at all."),
    (11, 15, "Hardening and configuration management", "Lock a host down by hand, then make it repeatable."),
    (16, 20, "Production operations", "The things that turn a configured host into one you can rely on."),
]

NEED = {1: ["systemctl"], 2: ["setfacl"], 3: ["systemctl"], 4: ["vgs", "lvs"],
        5: ["chronyc"], 6: ["ip"], 7: ["getent"], 8: ["dig", "ip"],
        9: ["tcpdump", "ip"], 10: ["openssl"], 11: ["firewall-cmd", "nft"],
        12: ["fail2ban-client"], 13: ["getenforce", "semanage"],
        14: ["ansible-playbook"], 15: ["ansible-playbook"], 16: ["wg"],
        17: ["nginx", "curl"], 18: ["ip"], 19: ["suricata", "auditctl"],
        20: ["restic"]}

TIER_LABEL = {
    "ci": "lint + CI",
    "lab": "lint + your lab",
}
TIER_NOTE = {
    "ci": "A GitHub runner can build this environment for real, so CI executes "
          "`verify.sh` on every push once `scripts/setup.sh` exists.",
    "lab": "CI can only lint this day. Nothing on a GitHub runner has SELinux, "
           "firewalld, systemd units you control, or a second host to reach over "
           "SSH — so the checks below are proven by running `verify.sh` on your "
           "own lab, and nowhere else.",
}


def ram(runs):
    if runs.startswith("Host:"):
        return ("0 MB", "no VM at all")
    if "node2" in runs:
        return ("~2.5 GB", "three VMs")
    if "+ node1" in runs or "-> node1" in runs:
        return ("~1.8 GB", "two VMs")
    return ("~1 GB", "one VM")


def phase_of(n):
    for lo, hi, name, _ in PHASES:
        if lo <= n <= hi:
            return name
    raise ValueError(n)


def write(rel, text, executable=False):
    path = os.path.join(ROOT, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    if executable:
        os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return len(text)


def day_readme(d):
    n = d["n"]
    nn = "%02d" % n
    mem, vms = ram(d["runs"])
    L = []
    L.append("# Day %s — %s\n" % (nn, d["title"]))
    L.append("> %s\n" % d["obj"])
    L.append("| | |")
    L.append("|---|---|")
    L.append("| **Phase** | %s |" % phase_of(n))
    L.append("| **Runs on** | %s |" % d["runs"])
    L.append("| **Memory** | %s (%s) |" % (mem, vms))
    L.append("| **Verified by** | %s |" % TIER_LABEL[d["tier"]])
    L.append("")
    L.append("## Why this day exists\n")
    L.append(d["why"] + "\n")
    L.append("## What you will work with\n")
    for w in d["work"]:
        L.append("- `%s`" % w if not w.startswith("/") or " " not in w else "- %s" % w)
    L.append("")
    L.append("## Verify\n")
    L.append("Checked automatically:\n")
    for kind, text, _cmd in d["checks"]:
        if kind == "auto":
            L.append("- [ ] %s" % text)
    manual = [t for k, t, _ in d["checks"] if k == "manual"]
    if manual:
        L.append("\nOnly you can confirm:\n")
        for t in manual:
            L.append("- [ ] %s" % t)
    L.append("")
    L.append("Run the automatic checks with:\n")
    L.append("```bash")
    L.append("./days/day%s/verify.sh" % nn)
    L.append("```\n")
    L.append("%s\n" % TIER_NOTE[d["tier"]])
    L.append("## Scripts for today\n")
    if d.get("scripts"):
        L.append("| Script | What it does | Root? |")
        L.append("|---|---|---|")
        for name, what, root in d["scripts"]:
            L.append("| `%s` | %s | %s |" % (name, what, "yes" if root else "no"))
        L.append("")
        L.append("Read them before you run them. They are commented as teaching "
                 "material rather than production code — the comments are half "
                 "the day.\n")
    else:
        L.append("Put your work in `days/day%s/scripts/`. If you add a "
                 "`scripts/setup.sh` that builds this day’s environment from "
                 "nothing, it becomes the entry point for both re-running the day "
                 "and%s.\n" % (nn, " for CI" if d["tier"] == "ci" else " rebuilding a broken lab"))
    if d.get("howto"):
        L.append("## Run it on the lab\n")
        L.append(d["howto"].strip() + "\n")
    L.append("## Notes\n")
    L.append("Keep your own notes here. What broke, what the error actually "
             "said, and what fixed it — that is the part you will come back for.\n")
    L.append("---\n")
    if n < 20:
        nxt = DAYS[n]
        L.append("Next up: **Day %02d — %s.**\n" % (nxt["n"], nxt["title"]))
    else:
        L.append("That is the curriculum. There is no capstone by design — the "
                 "lab itself was the project, and it is still running.\n")
    return "\n".join(L)


def day_verify(d):
    n = d["n"]
    nn = "%02d" % n
    L = []
    L.append("#!/usr/bin/env bash")
    L.append("#")
    L.append("# Day %s — %s" % (nn, d["title"]))
    L.append("# Run this on: %s" % d["runs"])
    L.append("#")
    L.append("# Exits 0 only when every automatic check passes. Items printed as")
    L.append("# YOU are judgement calls and never affect the exit status.")
    L.append("")
    L.append("set -uo pipefail")
    L.append('cd "$(dirname "$0")"')
    L.append('# shellcheck source=../../lab/verify-lib.sh')
    L.append('source "../../lab/verify-lib.sh"')
    L.append("")
    L.append('vl_init "Day %s — %s"' % (nn, d["title"]))
    needs = NEED.get(n, [])
    if needs:
        L.append("vl_need %s" % " ".join(needs))
    if d["runs"].startswith("Host:"):
        L.append("vl_need_root")
    L.append("")
    for kind, text, cmd in d["checks"]:
        assert '"' not in text, (n, text)
        if kind == "manual":
            L.append('vl_manual "%s"' % text)
        else:
            assert "'" not in cmd, (n, cmd)
            L.append("vl_check \"%s\" '%s'" % (text, cmd))
    L.append("")
    L.append("vl_summary")
    return "\n".join(L) + "\n"


def curriculum():
    L = []
    L.append("# Curriculum\n")
    L.append("Twenty days, four phases of five. Each phase ends somewhere you "
             "could stop and still have gained something whole.\n")
    L.append("## At a glance\n")
    L.append("| Day | Title | Runs on | Memory | Verified by |")
    L.append("|---|---|---|---|---|")
    for d in DAYS:
        mem, _ = ram(d["runs"])
        L.append("| %02d | [%s](../days/day%02d/README.md) | %s | %s | %s |"
                 % (d["n"], d["title"], d["n"], d["runs"], mem, TIER_LABEL[d["tier"]]))
    L.append("")
    for lo, hi, name, blurb in PHASES:
        L.append("## Phase %d — %s (Days %02d–%02d)\n" % (PHASES.index((lo, hi, name, blurb)) + 1, name, lo, hi))
        L.append(blurb + "\n")
        for d in DAYS[lo - 1:hi]:
            L.append("### Day %02d — %s\n" % (d["n"], d["title"]))
            L.append("%s\n" % d["obj"])
            L.append("*Runs on %s.* %s\n" % (d["runs"], d["why"]))
    L.append("## Why there is no capstone\n")
    L.append("A capstone is a thing you build. Operations is not a building "
             "discipline — it is a diagnostic one. The exam for a developer is "
             "whether the thing works; the exam for an operator is whether you "
             "can find out why it does not.\n")
    L.append("So instead of a final project, the lab persists. Day 06 builds a "
             "network and Days 07–10 and 18 operate inside it. Days 11–13 harden "
             "a host by hand and Day 15 turns that work into an Ansible role "
             "applied to a machine that has never been touched. Day 20 restores "
             "the data the earlier days created. Nothing is thrown away, and "
             "nothing is rebuilt from a template.\n")
    return "\n".join(L)


def main():
    total = 0
    for d in DAYS:
        nn = "%02d" % d["n"]
        total += write("days/day%s/README.md" % nn, day_readme(d))
        total += write("days/day%s/verify.sh" % nn, day_verify(d), executable=True)
        os.makedirs(os.path.join(ROOT, "days/day%s/scripts" % nn), exist_ok=True)
    total += write("docs/curriculum.md", curriculum())
    print("days written: %d" % len(DAYS))
    print("generated bytes: %d" % total)


if __name__ == "__main__":
    main()
