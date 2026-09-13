#!/usr/bin/env bash
#
# explore-roles.sh - twelve read-only stops through the role you just built.
#
# Nothing here changes a host. Every command either reads a file, asks Ansible
# what it parsed, or runs a play in check mode.

set -uo pipefail

PROJECT="${ANSIBLE_LAB_DIR:-$HOME/ansible-lab}"
cd "$PROJECT" 2>/dev/null || {
	printf 'no project at %s - run days/day15/scripts/setup.sh first\n' "$PROJECT" >&2
	exit 1
}

stop() { printf '\n\033[1m%s\033[0m\n%s\n' "$1" "$(printf '%*s' "${#1}" '' | tr ' ' '-')"; }
run()  { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/  /'; printf '\n'; }
note() { printf '  %s\n' "$*"; }

stop "1. the layout, and why it is a convention"
run "find roles/hardening -type f | sort"
note "ansible-galaxy init makes exactly this tree. Each directory is a"
note "precedence level or a search path, not a preference"

stop "2. defaults are the role's API"
run "sed -n '1,12p' roles/hardening/defaults/main.yml"
note "lowest precedence in Ansible. Everything a user might reasonably want"
note "to change lives here, so nobody has to edit the role to use it"

stop "3. vars are the role's internals"
run "cat roles/hardening/vars/main.yml"
note "near the TOP of the precedence list. A path the handlers depend on goes"
note "here so inventory cannot quietly point the role somewhere else"

stop "4. what a host was actually given"
run "ansible-inventory --host node1 | grep -E 'hardening_(open_ports|ssh_group|selinux)'"
run "ansible-inventory --host node2 | grep -E 'hardening_(open_ports|ssh_group|selinux)'"
note "node1 has 8080 from group_vars/webservers.yml; node2 has [] from the role"
note "default. Never work precedence out in your head - ask"

stop "5. the playbook is six lines"
run "cat hardening.yml"
note "this is what a role buys: three days of manual work, applied to any"
note "number of hosts, readable by somebody who has never opened the role"

stop "6. tasks/main.yml only imports"
run "cat roles/hardening/tasks/main.yml"
note "one file per area, a tag on each import, and an order that matters:"
note "the group before sshd enforces it, ssh allowed before firewalld starts"

stop "7. --list-tasks: the blast radius, for free"
run "ansible-playbook hardening.yml --list-tasks"

stop "8. --list-tags, and running one area"
run "ansible-playbook hardening.yml --list-tags"
note "ansible-playbook hardening.yml --tags ssh        re-apply the drop-in only"
note "ansible-playbook hardening.yml --skip-tags fail2ban"
note "Tags are how a five-minute change stays a five-minute change - and how"
note "people skip the task the one they wanted depends on"

stop "9. --limit, and the failure it hides"
run "ansible-playbook hardening.yml --check --limit node2 2>&1 | tail -4"
note "now a typo:"
run "ansible-playbook hardening.yml --check --limit node22 2>&1 | tail -4"
note "'skipping: no hosts matched' - and exit status 0. A green run that did"
note "nothing at all is the most expensive output in this file"

stop "10. the vault"
run "head -2 group_vars/lab/vault.yml"
run "ansible-vault view group_vars/lab/vault.yml"
note "ciphertext in git, plaintext only in memory. The variable the role uses"
note "is hardening_alert_token, which points at vault_hardening_alert_token -"
note "so grepping for vault_ finds every secret the project reads"

stop "11. handlers, and when they do not fire"
run "cat roles/hardening/handlers/main.yml"
note "a handler runs once, at the end, and only if a task reported changed."
note "A failed play drops pending handlers, which is how a host ends up with"
note "new config on disk and the old process still running"

stop "12. meta/main.yml and role dependencies"
run "cat roles/hardening/meta/main.yml"
note "dependencies: [] on purpose. Role dependencies run before your tasks,"
note "every time, and three levels deep nobody can say what has already run."
note "Compose in the playbook, where it is visible"

stop "the order you will inherit a project in"
cat <<'TXT'
  Someone hands you a repository with roles/ in it. Read it in this order:

    1. the playbook       which roles, which hosts, which tags
    2. inventory          who is in which group
    3. group_vars/        the data that overrides the role
    4. roles/*/defaults   the role's API, and its assumptions
    5. roles/*/tasks      last, and only the areas you care about

  Reading tasks first is how you end up debugging a value that was never
  in the role at all.
TXT
printf '\n'
