#!/usr/bin/env bash
#
# lab-ansible - what the project claims, and what the host actually reports.
#
#   lab-ansible              the whole picture
#   lab-ansible node1        one host: its variables and its facts
#   lab-ansible drift        what a check run would change right now
#
# Read-only. Every command here either reads a file in the project or asks a
# managed host a question. Nothing is applied, so this is safe on a host you
# do not understand yet - which is the only kind you ever inherit.

set -uo pipefail

PROJECT="${ANSIBLE_LAB_DIR:-$HOME/ansible-lab}"

sect() { printf '\n\033[1m%s\033[0m\n%s\n' "$1" "$(printf '%*s' "${#1}" '' | tr ' ' '-')"; }
run()  { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/  /' || true; printf '\n'; }

if [[ ! -d "$PROJECT" ]]; then
	echo "no project at $PROJECT - run: ~/lab/days/day14/scripts/setup.sh" >&2
	exit 1
fi
cd "$PROJECT" || exit 1

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
	echo "note: you are root, so ~/.ssh is /root/.ssh and the inventory key" >&2
	echo "      probably is not there. Run this as the lab user." >&2
fi

case "${1:-all}" in
# -------------------------------------------------------------------------
node*)
	host="$1"
	sect "$host - the variables Ansible will use"
	# This is the merged answer: every group_vars and host_vars file, plus
	# connection variables, resolved. Reading the files by hand and guessing
	# the precedence is how people get this wrong.
	run "ansible-inventory --host $host"

	sect "$host - facts, the ones templates usually want"
	run "ansible $host -m setup -a 'filter=ansible_hostname,ansible_distribution*,ansible_kernel,ansible_memtotal_mb,ansible_processor_vcpus' 2>&1 | head -30"

	sect "$host - what the play put there"
	run "ansible $host -m command -a 'ls -l /etc/lab-day14' -b"
	run "ansible $host -m command -a 'cat /etc/lab-day14/lab-info.conf' -b"
	;;

# -------------------------------------------------------------------------
drift)
	sect "what a real run would change, right now"
	# --check is a prediction, --diff is the prediction in detail. On a host
	# nobody has touched this prints nothing but ok lines; anything else is
	# either drift or a task that is not idempotent, and the difference
	# matters.
	run "ansible-playbook site.yml --check --diff"
	cat <<'EOF'
Reading that output:

  ok       state already matches - nothing to do
  changed  --check predicts this task WOULD change something
  skipped  a when clause said no

A "changed" line for a template or copy task is real drift: somebody edited
the host. A "changed" line for a command or shell task means nothing at all,
because those modules cannot predict anything - which is why the ones in
site.yml carry changed_when: false.
EOF
	;;

# -------------------------------------------------------------------------
all | *)
	sect "the configuration in effect"
	# The first surprise of the day for most people: which config file won.
	run "ansible-config dump --only-changed"
	run "ls -l ansible.cfg inventory/ site.yml"

	sect "the inventory Ansible actually read"
	run "ansible-inventory --graph"

	sect "the same hosts from the YAML file, for comparison"
	run "ansible-inventory -i inventory/hosts.yml --graph"

	sect "can we reach them"
	# ping is not ICMP. It connects over SSH, runs Python on the far side and
	# gets a pong back - so a pass here means the whole transport works, and
	# a failure is nearly always SSH or Python, never Ansible.
	run "ansible all -m ping"

	sect "variable precedence, resolved rather than guessed"
	run "grep -r . group_vars host_vars --include='*.yml' | sed 's/:---//' | grep -v '^$'"
	run "ansible-inventory --host node1 | head -20"

	sect "what the last run did"
	if [[ -f /tmp/day14-run2.log ]]; then
		run "grep -E '^(PLAY RECAP|node1)' /tmp/day14-run2.log"
	else
		printf '  no run log yet - run: ansible-playbook site.yml\n\n'
	fi

	sect "drift"
	run "ansible-playbook site.yml --check 2>&1 | grep -E '^(changed|PLAY RECAP|node1)' | tail -5"

	sect "where the answers disagree"
	cat <<'EOF'
Three pairs worth comparing before you trust anything here:

  ansible.cfg            vs  ansible-config dump --only-changed
      What you wrote versus what Ansible read. A config in your home
      directory silently replaces this one - they are not merged.

  group_vars/*.yml       vs  ansible-inventory --host node1
      What the files say versus the merged result. host_vars beats a named
      group, which beats all.yml, and -e on the command line beats the lot.

  --check --diff         vs  the real run
      A prediction versus the outcome. They agree for package, copy,
      template, user, service and lineinfile. They cannot agree for command
      or shell, because those are skipped in check mode.

The second run of a playbook is the only honest measurement of whether it
describes a state. changed=0 means yes.
EOF
	;;
esac
