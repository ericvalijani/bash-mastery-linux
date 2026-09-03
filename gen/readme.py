#!/usr/bin/env python3
"""Generate the root README.md and lab/README.md."""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from render import DAYS, PHASES, TIER_LABEL, ram, write

CI_DAYS = [d["n"] for d in DAYS if d["tier"] == "ci"]
LAB_DAYS = [d["n"] for d in DAYS if d["tier"] == "lab"]


def readme():
    L = []
    L.append("# Bash Mastery: Linux\n")
    L.append("> Twenty days of Linux operations — the host, the network, "
             "security hardening, and configuration management — on real "
             "machines you build yourself.\n")
    L.append("Nothing here is simulated. There is no offline mode, no fake "
             "output, and no capstone application. You get three virtual "
             "machines and a kernel-level network lab, and you operate them "
             "until they behave.\n")
    L.append("---\n")

    L.append("## 🚀 Get started\n")
    L.append("```bash")
    L.append("./lab/lab.sh check          # can this machine run the lab? start here")
    L.append("./lab/lab.sh image          # Rocky 9 base image, ~1 GB, downloaded once")
    L.append("./lab/lab.sh up control     # a real VM, about a minute")
    L.append("./lab/lab.sh ssh control    # you are in")
    L.append("```\n")
    L.append("`check` tells you exactly what your distribution is missing and "
             "prints the install command for it. On Ubuntu that is usually:\n")
    L.append("```bash")
    L.append("sudo apt-get install -y libvirt-daemon-system virtinst qemu-kvm")
    L.append("sudo systemctl enable --now libvirtd")
    L.append('sudo usermod -aG kvm,libvirt "$USER"   # then log out and back in')
    L.append("```\n")
    L.append("> The `usermod` step is the one people skip. Without it `/dev/kvm` "
             "is not writable and every VM creation fails on permissions.\n")
    L.append("**Not ready to install a hypervisor?** Start at Day 06 instead. "
             "Days 06–10 and 18 need only `iproute2` and root:\n")
    L.append("```bash")
    L.append("sudo ./lab/lab.sh netns-up      # builds the whole network, 0 MB")
    L.append("sudo ./lab/lab.sh netns-status  # shows it and ping-tests it")
    L.append("```\n")
    L.append("---\n")

    L.append("## 🗺️ The path\n")
    for i, (lo, hi, name, blurb) in enumerate(PHASES, 1):
        L.append("**Phase %d — %s** · Days %02d–%02d  \n%s\n" % (i, name, lo, hi, blurb))
    L.append("| Day | Title | Runs on | Verified by |")
    L.append("|---|---|---|---|")
    for d in DAYS:
        L.append("| **%02d** | [%s](days/day%02d/README.md) | %s | %s |"
                 % (d["n"], d["title"], d["n"], d["runs"], TIER_LABEL[d["tier"]]))
    L.append("")
    L.append("Full detail, with the reasoning for each day, is in "
             "[docs/curriculum.md](docs/curriculum.md). The complete state of "
             "the project — design decisions, what is verified, what is not, "
             "and what is left to do — is in "
             "[docs/HANDOFF.md](docs/HANDOFF.md).\n")
    L.append("---\n")

    L.append("## 💾 Memory budget\n")
    L.append("Designed for an 8 GB laptop, measured rather than hoped.\n")
    L.append("| Days | Needs | RAM |")
    L.append("|---|---|---|")
    rows = [
        ("01–05, 11–13, 17, 19", "one VM", "~1 GB"),
        ("**06–10, 18**", "**no VM at all**", "**0 MB**"),
        ("14, 16, 20", "two VMs", "~1.8 GB"),
        ("15", "three VMs", "~2.5 GB"),
    ]
    for a, b, c in rows:
        L.append("| %s | %s | %s |" % (a, b, c))
    L.append("")
    L.append("| VM | RAM | Role |")
    L.append("|---|---|---|")
    L.append("| `control` | 1024 MB | Where you sit. Ansible runs from here |")
    L.append("| `node1` | 768 MB | The machine you configure and break |")
    L.append("| `node2` | 768 MB | Starts clean. Only Day 15 needs it |")
    L.append("")
    L.append("Disks are thin qcow2 overlays on one shared base image, so three "
             "VMs cost barely more than one until you install packages. Budget "
             "about 12 GB of disk. Peak memory happens on Day 15 only.\n")
    L.append("---\n")

    L.append("## 🧪 What a green tick means\n")
    L.append("Verification is split into three tiers, because pretending CI can "
             "prove everything is how you end up trusting a badge that proves "
             "nothing.\n")
    L.append("| Tier | What it checks | Where it runs | Days |")
    L.append("|---|---|---|---|")
    L.append("| **lint** | `bash -n`, shellcheck | GitHub Actions | all 20 |")
    L.append("| **CI** | the day executed for real | GitHub Actions | %s |"
             % ", ".join("%02d" % n for n in CI_DAYS))
    L.append("| **lab** | the day executed for real | your VMs | %s |"
             % ", ".join("%02d" % n for n in LAB_DAYS))
    L.append("")
    L.append("GitHub runners are full Ubuntu VMs with `sudo`, so namespaces, "
             "DNS servers, `tcpdump`, `openssl`, VLANs and even LVM on a "
             "loopback file are genuinely real there — that is %d of the 20 "
             "days.\n" % len(CI_DAYS))
    L.append("The other %d cannot be faked on a runner. Ubuntu has no SELinux, "
             "no firewalld, and no second host to reach over SSH. Those days are "
             "verified by a script you run on your own lab:\n" % len(LAB_DAYS))
    L.append("```bash")
    L.append("./days/day13/verify.sh")
    L.append("```\n")
    L.append("```")
    L.append("Day 13 — SELinux: contexts, booleans and denial triage")
    L.append("---------------------------------------------------")
    L.append("  PASS  SELinux is enforcing")
    L.append("  PASS  the web root carries a web content label")
    L.append("  FAIL  a custom policy module is loaded")
    L.append("  YOU   you fixed a denial by relabelling, not by disabling SELinux")
    L.append("")
    L.append("6 passed, 1 failed, 2 for you to judge")
    L.append("```\n")
    L.append("Every day has one. `PASS`/`FAIL` come from real commands against "
             "real state; `YOU` items are judgement calls that no script can "
             "test and that never affect the exit status. Run it on the wrong "
             "machine and it reports `SKIP` with the reason, rather than lying "
             "in either direction.\n")
    L.append("---\n")

    L.append("## 🧰 The lab\n")
    L.append("One script owns the whole environment.\n")
    L.append("```bash")
    L.append("./lab/lab.sh check              # prerequisites, with install hints")
    L.append("./lab/lab.sh image              # download the Rocky 9 base image")
    L.append("./lab/lab.sh up [vm...]         # create VMs (default: control node1)")
    L.append("./lab/lab.sh status             # VMs, their IPs, and namespaces")
    L.append("./lab/lab.sh ssh <vm>           # log in")
    L.append("./lab/lab.sh push <vm> [path]   # copy days/ and lab/ to ~/lab on a VM")
    L.append("./lab/lab.sh add-disk <vm> [GB] # attach a blank disk (Day 04)")
    L.append("./lab/lab.sh down [vm...]       # delete VMs and their disks")
    L.append("sudo ./lab/lab.sh netns-up      # build the Days 06-10 network")
    L.append("sudo ./lab/lab.sh netns-status  # show it and ping-test it")
    L.append("sudo ./lab/lab.sh netns-down    # tear it down")
    L.append("./lab/lab.sh destroy            # everything")
    L.append("```\n")
    L.append("### The namespace network\n")
    L.append("```")
    L.append("  client 10.10.0.2 ---- 10.10.0.1 [router] 10.10.1.1 ---- 10.10.1.2 resolver")
    L.append("                                  10.10.2.1 ---- 10.10.2.2 auth")
    L.append("```\n")
    L.append("Real interfaces, real routing tables, real packets, real "
             "`tcpdump` captures — this is the same kernel machinery containers "
             "are built from. It is not a simulation, and it costs no memory.\n")
    L.append("### Why Rocky Linux guests on an Ubuntu host\n")
    L.append("Because of Day 13. SELinux is RHEL-family; Ubuntu ships AppArmor "
             "instead. It also makes Day 11 `firewalld`-first and makes Ansible "
             "feel native. Your host distribution barely matters — KVM is in "
             "the Linux kernel already, so Ubuntu, Fedora, Debian and Arch "
             "hosts are all fine and `check` prints the right package names for "
             "each.\n")
    L.append("---\n")

    L.append("## 📁 Layout\n")
    L.append("```")
    L.append("README.md                    you are here")
    L.append("docs/curriculum.md           all 20 days, with the reasoning")
    L.append("docs/HANDOFF.md              complete project state, for a cold start")
    L.append("CONTRIBUTING.md              how to change this without breaking it")
    L.append("LICENSE                      MIT")
    L.append("tests/cli.sh                 repo self-test: no VM, no root, no network")
    L.append(".pre-commit-config.yaml      shellcheck, whitespace, large-file guard")
    L.append("lab/lab.sh                   the whole environment, one script")
    L.append("lab/verify-lib.sh            assertion helpers for verify.sh")
    L.append("lab/ci-day.sh               runs one day in CI, honestly")
    L.append("lab/README.md                hardware, install, manual fallbacks")
    L.append("days/dayNN/README.md         the day")
    L.append("days/dayNN/verify.sh         did you finish it")
    L.append("days/dayNN/scripts/          your work goes here")
    L.append(".github/workflows/ci.yml     lint everything, execute what it can")
    L.append("```\n")
    L.append("---\n")

    L.append("## ⚠️ Honest status\n")
    L.append("`lab.sh` has never been executed against real KVM hardware. It is "
             "syntax-clean, and its `check`, `--help` and error paths have been "
             "exercised — but VM creation, cloud-init and the namespace wiring "
             "have not run on a real host yet.\n")
    L.append("So run `./lab/lab.sh check` first. It is the most tested part, and "
             "it will tell you what is missing before anything tries to create a "
             "VM. If `virt-install` rejects `--os-variant rocky9`, your "
             "`osinfo-db` predates Rocky 9 — use `rhel9.0`; the script already "
             "tries to fall back, and `lab/README.md` has the manual commands.\n")
    L.append("Day 01 ships five worked scripts. The other 19 "
             "`days/dayNN/scripts/` directories are empty on purpose - they are "
             "written one day at a time, each run on the real lab before the next "
             "is started.\n")
    L.append("---\n")
    L.append("## License and contributing\n")
    L.append("MIT - see [LICENSE](LICENSE).\n")
    L.append("Fixes are welcome, especially anything that does not work on your "
             "distribution or your hardware. Read "
             "[CONTRIBUTING.md](CONTRIBUTING.md) first: the day pages and the "
             "`verify.sh` files are generated, so they are the two things you "
             "must not hand-edit.\n")
    return "\n".join(L)


def main():
    n = write("README.md", readme())
    print("README.md bytes: %d" % n)


if __name__ == "__main__":
    main()
