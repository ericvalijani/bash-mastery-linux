#!/usr/bin/env bash
#
# teardown.sh - undo Day 15, written as a playbook.
#
#   ./teardown.sh           remove the role's work from node2 only
#   ./teardown.sh --all      node2 and node1, and delete the project files
#
# node2 is the default because node1 was hardened by hand on Days 11-13 and
# you probably still want that. Undoing configuration management with rm on
# the host is how estates drift; the inverse of a play is a play.

set -uo pipefail

PROJECT="${ANSIBLE_LAB_DIR:-$HOME/ansible-lab}"
PLAY="/tmp/day15-teardown.yml"

cd "$PROJECT" 2>/dev/null || {
	printf 'no project at %s - nothing to tear down\n' "$PROJECT" >&2
	exit 0
}

say()  { printf '\n=== %s ===\n\n' "$*"; }
ok()   { printf '  ok    %s\n' "$*"; }
note() { printf '        %s\n' "$*"; }

TARGET="fresh"
ALL=no
if [[ "${1:-}" == "--all" ]]; then
	TARGET="lab"
	ALL=yes
fi

say "the inverse play, on: $TARGET"

cat > "$PLAY" <<'EOF'
---
# Every state inverted. What is deliberately NOT here:
#
#   - SELinux is left enforcing. Turning it off to "clean up" is the one
#     change in this file that would make a host less safe than before.
#   - firewalld and rsyslog stay installed and running. The distribution
#     shipped them; the role did not.
#   - the labssh group stays. Removing it while sshd still references it in
#     any leftover drop-in is how you lock yourself out during a cleanup.
- name: Undo Day 15
  hosts: "{{ target | default('fresh') }}"
  gather_facts: false
  become: true

  tasks:
    - name: The sshd drop-in is gone
      ansible.builtin.file:
        path: /etc/ssh/sshd_config.d/00-lab-hardening.conf
        state: absent
      notify: Reload sshd

    - name: The fail2ban jail is gone
      ansible.builtin.file:
        path: /etc/fail2ban/jail.d/lab-sshd.local
        state: absent
      notify: Restart fail2ban

    - name: The marker directory is gone
      ansible.builtin.file:
        path: /etc/lab-day15
        state: absent

    - name: Which ports the zone still has
      ansible.builtin.command: firewall-cmd --permanent --zone=public --list-ports
      register: ports
      changed_when: false

    - name: The lab port is closed again
      ansible.builtin.command: firewall-cmd --permanent --zone=public --remove-port=8080/tcp
      when: "'8080/tcp' in ports.stdout"
      notify: Reload firewalld

  handlers:
    - name: Reload sshd
      ansible.builtin.service:
        name: sshd
        state: reloaded

    - name: Restart fail2ban
      ansible.builtin.service:
        name: fail2ban
        state: restarted

    - name: Reload firewalld
      ansible.builtin.command: firewall-cmd --reload
EOF
ok "wrote $PLAY"
note "read it before you run it - undoing hardening deserves the same review"
note "as applying it"

if ansible-playbook "$PLAY" -e "target=$TARGET"; then
	ok "the inverse play finished"
else
	printf '\n  the play failed. The hosts are in whatever state it reached;\n'
	printf '  re-run it, it is idempotent.\n'
	exit 1
fi

if [[ "$ALL" == yes ]]; then
	say "removing the project files"
	rm -rf "$PROJECT/roles/hardening" "$PROJECT/hardening.yml" \
		"$PROJECT/group_vars/lab" "$PROJECT/group_vars/fresh.yml"
	ok "role, playbook and group_vars removed"
	note "the vault password file at ~/.vault-pass-lab is left alone - deleting a"
	note "password while ciphertext still exists somewhere is a bad habit to build"
	note "Day 14's site.yml and inventory are untouched"
else
	cat <<EOF

node1 keeps the hardening it got on Days 11-13, and the project is still at
$PROJECT. Day 16 does not need any of it, but leaving it there costs nothing.

To remove the role and the playbook as well:  ./teardown.sh --all
To give the memory back, on your laptop:      ./lab/lab.sh down control node1 node2
EOF
fi
