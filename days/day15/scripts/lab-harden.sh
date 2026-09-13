#!/usr/bin/env bash
#
# lab-harden - what the role says, and what the hosts report.
#
#   lab-harden           both hosts, side by side
#   lab-harden node1     one host, in detail
#   lab-harden node2     one host, in detail
#   lab-harden drift     what a run would change right now
#
# Read-only. Every command here either reads a file or asks a daemon.

set -uo pipefail

PROJECT="${ANSIBLE_LAB_DIR:-$HOME/ansible-lab}"
cd "$PROJECT" 2>/dev/null || {
	printf 'no project at %s - run days/day15/scripts/setup.sh first\n' "$PROJECT" >&2
	exit 1
}

head2() { printf '\n\033[1m%s\033[0m\n%s\n' "$1" "$(printf '%*s' "${#1}" '' | tr ' ' '-')"; }
run()  { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/  /'; printf '\n'; }
note() { printf '  %s\n' "$*"; }

mode="${1:-all}"

case "$mode" in
all)
	head2 "the policy, as data"
	run "grep -rh '^hardening_' roles/hardening/defaults/main.yml | head -20"
	note "defaults. Anything in group_vars beats these, and nothing had to be edited"

	head2 "what each host was given"
	for h in node1 node2; do
		run "ansible-inventory --host $h | grep -E 'hardening_|lab_role_note'"
	done
	note "same role, different data. node1 opens 8080 because it runs Day 13's nginx"

	head2 "SELinux"
	run "ansible lab -m command -a 'getenforce' -o"

	head2 "sshd, effective - not the file"
	run "ansible lab -b -m shell -a 'sshd -T | grep -E \"^(passwordauthentication|permitrootlogin|allowgroups|maxauthtries) \"' -o"

	head2 "firewalld saved policy"
	run "ansible lab -b -m shell -a 'firewall-cmd --permanent --list-services; firewall-cmd --permanent --list-ports' -o"

	head2 "fail2ban"
	run "ansible lab -b -m shell -a 'fail2ban-client status sshd | tr \"\\n\" \" \"' -o"

	head2 "the report the role rendered"
	run "ansible lab -b -m command -a 'cat /etc/lab-day15/hardening.conf' | grep -Ev '^#'"
	note "alert_token came out of the vault. In git that value is ciphertext"
	;;

node1 | node2)
	host="$mode"
	head2 "$host - every variable, already merged"
	run "ansible-inventory --host $host"
	note "host_vars beats a named group, which beats group_vars/all, and -e beats the lot"

	head2 "$host - group membership"
	run "ansible $host -m debug -a 'var=group_names'"

	head2 "$host - what the role produced"
	run "ansible $host -b -m command -a 'cat /etc/lab-day15/hardening.conf'"
	run "ansible $host -b -m command -a 'cat /etc/ssh/sshd_config.d/00-lab-hardening.conf'"
	run "ansible $host -b -m command -a 'cat /etc/fail2ban/jail.d/lab-sshd.local'"

	head2 "$host - and what the host is actually doing"
	run "ansible $host -m command -a 'getenforce'"
	run "ansible $host -b -m shell -a 'sshd -T | sort | grep -E \"^(allowgroups|passwordauthentication|permitrootlogin)\"'"
	run "ansible $host -b -m shell -a 'id -nG $(id -un)'"
	note "that last one matters: AllowGroups is only safe while your account is in the group"
	;;

drift)
	head2 "what a run would change right now"
	run "ansible-playbook hardening.yml --check --diff 2>&1 | grep -E '^(changed|fatal|PLAY RECAP|node[12] )' | tail -12"
	note "changed here from a template task means somebody edited the host"
	note "changed from a command task means nothing - those cannot predict, which is"
	note "why the ones in this role carry changed_when: false or a when: clause"

	head2 "tags, so you can narrow a run"
	run "ansible-playbook hardening.yml --list-tags"
	note "--tags ssh re-applies the drop-in and nothing else. --skip-tags fail2ban"
	note "leaves the jail alone. Both are how you make a five-minute change safely"

	head2 "where the answers disagree"
	cat <<'TXT'
  Three pairs worth comparing before you trust anything here:

    defaults/main.yml     vs  ansible-inventory --host node1
        What the role offers versus what the host was actually given.
        Editing defaults has no effect on a value set in group_vars -
        a silent no-op that costs people an afternoon.

    the drop-in file       vs  sshd -T
        Intent versus behaviour. A drop-in sorting after ours wins,
        and only -T knows.

    --permanent            vs  the running firewall
        firewall-cmd --permanent writes the saved policy. Until a
        reload, the kernel is still enforcing the old one.
TXT
	;;

*)
	printf 'usage: lab-harden [all|node1|node2|drift]\n' >&2
	exit 2
	;;
esac
