#!/usr/bin/env bash
#
# break-and-fix.sh - five ways a role reports success and delivers nothing.
#
#   ./break-and-fix.sh          the four you can run safely
#   ./break-and-fix.sh --hard   plus the two that are described, not run
#
# Every broken play is written to /tmp/day15-broken and never added to your
# project. The script finishes by re-applying the real role twice.

set -uo pipefail

PROJECT="${ANSIBLE_LAB_DIR:-$HOME/ansible-lab}"
TMP="/tmp/day15-broken"

cd "$PROJECT" 2>/dev/null || {
	printf 'no project at %s - run days/day15/scripts/setup.sh first\n' "$PROJECT" >&2
	exit 1
}
mkdir -p "$TMP"

say()  { printf '\n\033[1m%s\033[0m\n%s\n' "$1" "$(printf '%*s' "${#1}" '' | tr ' ' '-')"; }
step() { printf '\n  -> %s\n' "$*"; }
run()  { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/  /'; printf '\n'; }
note() { printf '  %s\n' "$*"; }

HARD=no
[[ "${1:-}" == "--hard" ]] && HARD=yes

# ---------------------------------------------------------------------------
say "1. the green run that touched nothing"
# The most expensive failure in this file, because the exit status is 0 and
# the recap looks fine at a glance.
step "a --limit that matches no host"
run "ansible-playbook hardening.yml --limit node-2 2>&1 | tail -5; echo \"exit status: \${PIPESTATUS[0]}\""
note "'skipping: no hosts matched' and exit 0. In CI that is a green tick on a"
note "deployment that did not happen"
step "the fix: make Ansible refuse an empty host list"
run "ANSIBLE_ERROR_ON_UNDEFINED_VARS=true ansible-playbook hardening.yml --limit node-2 --check 2>&1 | tail -3"
note "there is a real setting for this: in ansible.cfg"
note "  [inventory]"
note "  host_pattern_mismatch = error"
note "Set it and a typo fails the run instead of passing it"

# ---------------------------------------------------------------------------
say "2. editing defaults and wondering why nothing changed"
step "what the role offers"
run "grep -A2 '^hardening_open_ports' roles/hardening/defaults/main.yml"
step "what node1 actually got"
run "ansible-inventory --host node1 | grep -A3 hardening_open_ports"
note "group_vars/webservers.yml wins. Editing defaults/main.yml here is a"
note "silent no-op - no error, no warning, no effect"
step "the fix: change the data where it is set, or override explicitly"
run "ansible-playbook hardening.yml --check --limit node1 --tags firewall -e 'hardening_open_ports=[\"8080/tcp\",\"9090/tcp\"]' 2>&1 | grep -E '^(TASK|changed|ok|PLAY RECAP|node1 )' | tail -6"
note "-e beats everything, which makes it perfect for a test and wrong for a"
note "permanent change. Permanent belongs in group_vars, in git"

# ---------------------------------------------------------------------------
say "3. the tag that skipped the task the other one needed"
cat > "$TMP/tagged.yml" <<'EOF'
---
# A role where the access group is created under one tag and enforced under
# another. Perfectly reasonable-looking. Run --tags ssh on a fresh host and
# sshd is told to allow a group that does not exist yet.
- name: Tags done badly
  hosts: fresh
  gather_facts: false
  tasks:
    - name: The group exists
      ansible.builtin.group:
        name: labssh-demo
        state: present
      become: true
      tags: [users]

    - name: Something that needs the group
      ansible.builtin.command: getent group labssh-demo
      changed_when: false
      tags: [ssh]
EOF
step "run only the ssh half, on a host that never ran the users half"
run "ansible-playbook $TMP/tagged.yml --tags ssh 2>&1 | grep -E '^(TASK|fatal|ok|PLAY RECAP|node2 )' | tail -6"
note "the real version of this bug locks you out: AllowGroups pointing at a"
note "group nobody is in. sshd validates the file happily - the group does not"
note "have to exist for the config to parse"
step "the fix: tag the dependency with both, or do not split it"
run "ansible-playbook $TMP/tagged.yml --tags users,ssh 2>&1 | grep -E '^(TASK|ok|changed|PLAY RECAP|node2 )' | tail -6"
note "in the real role the group task carries the ssh tag for this reason:"
run "grep -n 'tags' roles/hardening/tasks/main.yml"

# ---------------------------------------------------------------------------
say "4. the handler that never ran"
cat > "$TMP/handler.yml" <<'EOF'
---
# The config is written, the handler is notified, and the play fails before
# the end. Pending handlers are dropped: new file on disk, old process
# running, and a recap that tells you something failed but not what survived.
- name: Handlers and failure
  hosts: fresh
  gather_facts: false
  become: true
  tasks:
    - name: Write a config
      ansible.builtin.copy:
        content: "# day15 handler demo {{ 999 | random }}\n"
        dest: /etc/lab-day15/handler-demo.conf
        mode: "0644"
      notify: Restart the thing

    - name: A task that fails afterwards
      ansible.builtin.command: /bin/false

  handlers:
    - name: Restart the thing
      ansible.builtin.debug:
        msg: "THIS NEVER PRINTS"
EOF
step "write config, notify, then fail"
run "ansible-playbook $TMP/handler.yml 2>&1 | grep -E '^(TASK|RUNNING HANDLER|fatal|changed|PLAY RECAP|node2 )' | tail -8"
note "no RUNNING HANDLER line. The file changed; nothing was restarted"
step "the fix: force handlers to run, or flush them when it matters"
run "ansible-playbook $TMP/handler.yml --force-handlers 2>&1 | grep -E '^(RUNNING HANDLER|ok:|fatal|PLAY RECAP|node2 )' | tail -6"
note "--force-handlers for a one-off; meta: flush_handlers inside the play for"
note "a restart that must happen before the next task"

# ---------------------------------------------------------------------------
say "5. the vault password that is not there"
step "a command with the vault password file taken away"
run "ANSIBLE_VAULT_PASSWORD_FILE=/nonexistent ansible-playbook hardening.yml --check --limit node2 --tags marker 2>&1 | tail -5"
note "the error names the file, not the variable, which is why people go"
note "looking for a missing var. It is the password that is missing"
step "and the other half of the same mistake"
run "grep -c ANSIBLE_VAULT group_vars/lab/vault.yml"
note "1 means the file is encrypted. 0 means somebody decrypted it to debug"
note "something and committed the plaintext - check this in CI, not by memory"

# ---------------------------------------------------------------------------
if [[ "$HARD" == yes ]]; then
	say "the two that are described, not run"
	cat <<'TXT'
  Both of these end with a host you cannot reach. Read them instead.

  a. AllowGroups before the membership

       - name: The drop-in
         template: ... AllowGroups labssh
         notify: Reload sshd
       # and the group/user tasks come LATER in the file

     sshd -t validates this: the group does not have to exist for the
     config to parse. The reload succeeds. The next connection - including
     Ansible's own - is refused, and the only way in is the console.
     In the real role those two tasks are the first thing in ssh.yml, in
     that order, for exactly this reason.

  b. the role applied to the control node

       ansible-playbook hardening.yml --limit all

     with control in the inventory. It hardens the machine you are sitting
     on, using an SSH policy it then reloads underneath your session. If
     your account is not in labssh, the session you still have open is the
     last one you will get.

     This is why setup.sh refuses an address belonging to this machine,
     and why control is not in the lab group.
TXT
fi

# ---------------------------------------------------------------------------
say "putting it back"
ansible node2 -b -m file -a 'path=/etc/lab-day15/handler-demo.conf state=absent' >/dev/null 2>&1 || true
ansible node2 -b -m group -a 'name=labssh-demo state=absent' >/dev/null 2>&1 || true
ansible-playbook hardening.yml >/dev/null 2>&1 || true
ansible-playbook hardening.yml > /tmp/day15-refix.log 2>&1 || true
note "hardening.yml, run again: $(grep -c 'changed=0' /tmp/day15-refix.log) of 2 hosts report changed=0"
note "broken plays are in $TMP and were never added to your project"

cat <<'TXT'

Five failures.

  --limit typo         green run, exit 0, nothing deployed
  defaults vs data     editing the role has no effect on a set variable
  tags                 the half you ran needed the half you skipped
  handlers             a failed play drops them; config moved, process did not
  vault                the error names a file, not the variable people hunt for

Only the vault one announces itself clearly. The other four look like success.

Check yourself:  ~/lab/days/day15/verify.sh
TXT
