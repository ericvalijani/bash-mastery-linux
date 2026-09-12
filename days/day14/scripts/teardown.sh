#!/usr/bin/env bash
#
# Day 14 - undo the day, on node1 and on control.
#
#   ./scripts/teardown.sh            revert node1, keep the project
#   ./scripts/teardown.sh --all      also delete ~/ansible-lab
#
# Run on control, as the lab user, after setup.sh.
#
# The interesting part of this script is that the undo is itself a playbook.
# Once state is described in a file, removing it is the same operation with
# state: absent - which is the argument for configuration management in one
# sentence.

set -uo pipefail

# shellcheck source=../../../lab/on-lab-vm.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

PROJECT="${ANSIBLE_LAB_DIR:-$HOME/ansible-lab}"
PLAY="/tmp/day14-teardown.yml"

say()  { printf '\n=== %s ===\n\n' "$*"; }
run()  { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/  /' || true; }
note() { printf '  (%s)\n' "$1"; }

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
	echo "run this as the lab user, not with sudo" >&2
	exit 1
fi
[[ -d "$PROJECT" ]] || { echo "no project at $PROJECT - nothing to tear down" >&2; exit 0; }
cd "$PROJECT" || exit 1

ALL="no"
[[ "${1:-}" == "--all" ]] && ALL="yes"

say "the undo, written as a play"

cat > "$PLAY" <<'EOF'
---
# Every task here is a task from site.yml with the state inverted. Order
# matters in the same way it does anywhere else: the service configuration
# goes before the reload, and the files go before the directory.

- name: Remove the Day 14 baseline
  hosts: webservers
  gather_facts: false
  become: true

  tasks:
    - name: The log rule is gone
      ansible.builtin.file:
        path: /etc/rsyslog.d/99-lab-day14.conf
        state: absent
      notify: Restart rsyslog

    - name: The marker directory and everything in it is gone
      ansible.builtin.file:
        path: /etc/lab-day14
        state: absent

    - name: The log file it wrote is gone
      ansible.builtin.file:
        path: /var/log/lab-day14.log
        state: absent

    - name: The moved log file from break-and-fix.sh is gone
      ansible.builtin.file:
        path: /var/log/lab-day14-moved.log
        state: absent

    - name: The service account is gone
      ansible.builtin.user:
        name: labapp
        state: absent
        remove: false

    - name: The packages the day added are gone
      # rsyslog is deliberately NOT in this list. Rocky ships it, other days
      # rely on it, and removing a distribution package because your play
      # installed it is how a teardown becomes an outage.
      ansible.builtin.package:
        name:
          - tree
        state: absent

  handlers:
    - name: Restart rsyslog
      ansible.builtin.service:
        name: rsyslog
        state: restarted
EOF

run "ansible-playbook $PLAY --check --diff 2>&1 | tail -20"
note "the dry run first, even for a teardown - especially for a teardown"

say "applying it"
run "ansible-playbook $PLAY 2>&1 | grep -E '^(node1|PLAY RECAP)|RUNNING HANDLER'"

say "proving it"
run "ansible node1 -b -m command -a 'ls -d /etc/lab-day14' 2>&1 | tail -3"
note "a failure here is the proof: the directory is gone"
run "ansible node1 -b -m shell -a 'id labapp 2>&1 | tail -1'"
run "ansible node1 -b -m shell -a 'ls /etc/rsyslog.d/ | grep lab || echo no lab rules'"
run "ansible node1 -b -m command -a 'systemctl is-active rsyslog'"
note "rsyslog is left running. It was here before the day and it stays"

say "control"
if command -v lab-ansible >/dev/null 2>&1; then
	run "sudo rm -f /usr/local/bin/lab-ansible"
fi
rm -f /tmp/day14-check.log /tmp/day14-run1.log /tmp/day14-run2.log
rm -rf /tmp/day14-broken
printf '  removed the run logs and the broken plays from /tmp\n'

if [[ "$ALL" == "yes" ]]; then
	rm -rf "$PROJECT"
	printf '  removed %s\n' "$PROJECT"
	note "the project was the whole point of the day - re-run setup.sh to get it back"
else
	printf '  kept %s\n' "$PROJECT"
	note "Day 15 turns site.yml into a role, so the project is worth keeping. Pass --all if you disagree"
fi

rm -f "$PLAY"

cat <<'EOF'

node1 is back to where it started, and nothing was removed by hand.

The key was written to ~/.ssh/id_ed25519 on control by setup.sh and is left
there. If you are finished with the lab for the day:

  ./lab/lab.sh down control node1     from your laptop, frees ~3 GB
EOF
