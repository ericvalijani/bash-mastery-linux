#!/usr/bin/env bash
#
# Day 14 - twelve read-only stops through an Ansible project.
#
#   ./scripts/explore-ansible.sh
#
# Nothing here changes a managed host. Every stop either reads a project file
# or asks node1 a question, so you can run this on a live estate you have
# just inherited and learn the shape of it without touching anything.
#
# Run it after setup.sh, as the lab user, from control.

set -uo pipefail

PROJECT="${ANSIBLE_LAB_DIR:-$HOME/ansible-lab}"

stop=0
sect() {
	stop=$((stop + 1))
	printf '\n\033[1m%2d. %s\033[0m\n' "$stop" "$1"
}
run()  { printf '   $ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/     /' || true; }
note() { printf '   -> %s\n' "$1"; }

[[ -d "$PROJECT" ]] || { echo "no project at $PROJECT - run ./scripts/setup.sh first" >&2; exit 1; }
cd "$PROJECT" || exit 1

printf '\nTwelve stops in %s. Read-only.\n' "$PROJECT"

sect "which ansible, and which Python"
run "ansible --version"
note "the config file line is the one to read: it tells you which ansible.cfg won"

sect "what this project changed from the defaults"
run "ansible-config dump --only-changed"
note "everything else is stock. This is the shortest description of a project's opinions"

sect "the inventory, as a tree"
run "ansible-inventory --graph"
note "@all and @ungrouped always exist. A host in @ungrouped is a host whose group name you typo'd"

sect "the same hosts in YAML"
run "ansible-inventory -i inventory/hosts.yml --graph"
note "identical output. Format is a preference; the data model is the same"

sect "one host, fully resolved"
run "ansible-inventory --host node1"
note "this is the merged answer from every vars file - never work out precedence in your head"

sect "reachability, which is SSH and Python rather than ICMP"
run "ansible all -m ping"
note "a failure here is an ssh or python problem on the far side, not an Ansible problem"

sect "an ad-hoc module call, no playbook involved"
run "ansible webservers -m command -a 'uptime'"
note "-m module -a arguments. This is the whole ad-hoc interface, and it is enough for triage"

sect "facts: what the host tells you about itself"
run "ansible node1 -m setup -a 'filter=ansible_distribution*' 2>&1 | head -12"
note "gather_facts costs a round trip per host. Templates need it; a two-task play often does not"

sect "the play, and whether it parses"
run "ansible-playbook site.yml --syntax-check"
run "ansible-playbook site.yml --list-tasks"
note "--list-tasks before a run on an unfamiliar playbook. It costs nothing and prints the blast radius"

sect "what a run would change, and how"
run "ansible-playbook site.yml --check --diff 2>&1 | tail -25"
note "--check predicts, --diff shows the lines. package/copy/template/user/service predict honestly; command and shell are skipped"

sect "handlers, and why they usually do nothing"
run "grep -n -A4 'handlers:' site.yml"
run "grep -n 'notify' site.yml"
note "notify fires only when that task reported changed, so a settled host restarts nothing"

sect "the managed host, from the host's side"
run "ansible node1 -b -m command -a 'ls -l /etc/lab-day14'"
run "ansible node1 -b -m command -a 'systemctl is-enabled rsyslog'"
note "-b is become. Without it these run as lab and the directory listing fails on permissions"

cat <<'EOF'

The order to use when you inherit a project you did not write:

  1. ansible --version                      which config file is in play
  2. ansible-config dump --only-changed     what it changed
  3. ansible-inventory --graph              which hosts, in which groups
  4. ansible-inventory --host <one>         the variables, already merged
  5. ansible-playbook <play> --list-tasks   what it would do
  6. ansible-playbook <play> --check --diff what it would change today

Only then run it. Steps 1-6 are read-only, take under a minute, and are the
difference between applying a playbook and detonating one.

Next:  ./scripts/break-and-fix.sh
EOF
