#!/usr/bin/env bash
#
# Day 14 - four ways a playbook stops being idempotent, and the fix for each.
#
#   ./scripts/break-and-fix.sh           the four survivable failures
#   ./scripts/break-and-fix.sh --hard    adds the two you must not run
#
# Run it on control, as the lab user, after setup.sh. It writes its broken
# plays into /tmp, never into your project, and it puts node1 back with
# site.yml before it exits.

set -uo pipefail

# shellcheck source=../../../lab/on-lab-vm.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

PROJECT="${ANSIBLE_LAB_DIR:-$HOME/ansible-lab}"
TMP="/tmp/day14-broken"

say()  { printf '\n=== %s ===\n\n' "$*"; }
step() { printf '\n-- %s\n' "$*"; }
run()  { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/  /' || true; }
note() { printf '  (%s)\n' "$1"; }

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
	echo "run this as the lab user, not with sudo - see setup.sh step 0" >&2
	exit 1
fi
[[ -d "$PROJECT" ]] || { echo "no project at $PROJECT - run ./scripts/setup.sh first" >&2; exit 1; }
cd "$PROJECT" || exit 1
mkdir -p "$TMP"

HARD="no"
[[ "${1:-}" == "--hard" ]] && HARD="yes"

# How many tasks a run reported as changed. This is the only measurement in
# the script, and every failure below is a case of it refusing to reach zero.
changed_count() {
	local log="$1"
	sed -n 's/.*changed=\([0-9]*\).*/\1/p' "$log" | head -1
}

run_twice() {
	local play="$1" label="$2"
	ansible-playbook "$play" > "$TMP/$label-1.log" 2>&1 || true
	ansible-playbook "$play" > "$TMP/$label-2.log" 2>&1 || true
	printf '  first run:  changed=%s\n' "$(changed_count "$TMP/$label-1.log")"
	printf '  second run: changed=%s\n' "$(changed_count "$TMP/$label-2.log")"
}

# ---------------------------------------------------------------------------
# 1. command instead of a module
# ---------------------------------------------------------------------------
# The first playbook everybody writes is a shell script in YAML. It works,
# which is the problem: nothing tells you it is wrong until you need to know
# whether a host has drifted, and by then every run reports changes.
say "1. the play that is a shell script in YAML"

step "the correct version, twice"
run_twice site.yml correct
note "changed=0 on the second run. The play describes a state"

step "the same work with command and shell"
run_twice not-idempotent.yml wrong
note "changes every time. Not because the host drifted - because the tasks cannot tell"

step "and the damage it does on the way"
run "ansible node1 -b -m command -a 'cat /etc/lab-day14/lab-day14.txt'"
note "every run appended another owner= line. Five runs, five lines"

step "what --check says about it, which is nothing"
run "ansible-playbook not-idempotent.yml --check 2>&1 | tail -12"
note "skipped. command and shell are not run in check mode, so a dry run of this play is a blank prediction"

step "the fix: state modules, and the state is the documentation"
cat <<'EOF'
  - ansible.builtin.command: dnf install -y tree
  + ansible.builtin.package:
  +     name: tree
  +     state: present

  - ansible.builtin.shell: echo "owner=x" >> /etc/lab-day14/lab-day14.txt
  + ansible.builtin.lineinfile:
  +     path: /etc/lab-day14/lab-day14.txt
  +     regexp: '^owner='
  +     line: owner=x

  - ansible.builtin.command: systemctl restart rsyslog
  + notify on the task that changes the config, plus a handler
EOF

step "repair the file the bad play damaged"
run "ansible-playbook site.yml 2>&1 | grep -E '^(node1|PLAY RECAP)'"
note "copy noticed the checksum was wrong and put the file back. That is drift correction, and it only works because the task is idempotent"

# ---------------------------------------------------------------------------
# 2. lineinfile without a regexp
# ---------------------------------------------------------------------------
# The subtle one. It is a real module, it looks idempotent, and it is - for
# the exact line you wrote. Change the value and it appends instead of
# replacing, because you never told it what the old line looked like.
say "2. lineinfile that appends instead of replacing"

cat > "$TMP/no-regexp.yml" <<'EOF'
---
- name: lineinfile with no regexp
  hosts: webservers
  gather_facts: false
  become: true
  tasks:
    - name: Set a tuning value
      ansible.builtin.lineinfile:
        path: /etc/lab-day14/settings.conf
        line: "max_workers={{ workers | default(4) }}"
        create: true
        mode: "0644"
EOF

step "run it, then run it again with a different value"
run "ansible-playbook $TMP/no-regexp.yml 2>&1 | grep -E 'changed=|ok='"
run "ansible-playbook $TMP/no-regexp.yml -e workers=8 2>&1 | grep -E 'changed=|ok='"
run "ansible-playbook $TMP/no-regexp.yml -e workers=16 2>&1 | grep -E 'changed=|ok='"
run "ansible node1 -b -m command -a 'cat /etc/lab-day14/settings.conf'"
note "three values, all still there. Which one does the service use? Usually the last, which is luck rather than design"

step "the fix: a regexp that matches the line you are replacing"
cat > "$TMP/with-regexp.yml" <<'EOF'
---
- name: lineinfile done properly
  hosts: webservers
  gather_facts: false
  become: true
  tasks:
    - name: Set a tuning value
      ansible.builtin.lineinfile:
        path: /etc/lab-day14/settings.conf
        regexp: '^max_workers='
        line: "max_workers={{ workers | default(4) }}"
        create: true
        mode: "0644"
EOF
run "ansible node1 -b -m shell -a 'grep -v max_workers /etc/lab-day14/settings.conf > /tmp/s && mv /tmp/s /etc/lab-day14/settings.conf' "
run "ansible-playbook $TMP/with-regexp.yml -e workers=8 2>&1 | grep -E 'changed=|ok='"
run "ansible-playbook $TMP/with-regexp.yml -e workers=16 2>&1 | grep -E 'changed=|ok='"
run "ansible node1 -b -m command -a 'cat /etc/lab-day14/settings.conf'"
note "one line, current value. The regexp is what makes the task recognise its own work"
note "for a whole file, prefer template - lineinfile is for files you do not own"

# ---------------------------------------------------------------------------
# 3. the handler that never fires, and the one that always does
# ---------------------------------------------------------------------------
say "3. handlers: the restart you did not get"

step "change the config template's rendered value and watch the handler fire"
run "ansible node1 -b -m lineinfile -a 'path=/etc/rsyslog.d/99-lab-day14.conf regexp=^local3 line=\"local3.*  /var/log/lab-day14-moved.log\"'"
run "ansible-playbook site.yml 2>&1 | grep -E 'RUNNING HANDLER|Restart rsyslog|node1.*changed='"
note "template noticed the file differed, notified, and the handler ran once at the end"

step "now a settled host"
run "ansible-playbook site.yml 2>&1 | grep -E 'RUNNING HANDLER|node1.*changed=' || true"
note "no handler section at all. notify fires on changed, so nothing restarts. That is the whole point of handlers"

step "the two ways people break this"
cat <<'EOF'
  a) An unconditional restart task instead of a handler. Every run bounces
     the service, so a fleet-wide play becomes a rolling outage.

  b) Expecting a handler to run after a FAILED play. It does not: a failure
     stops the play and pending handlers are dropped, so the config on disk
     is new and the running process is old. --force-handlers exists for this,
     and knowing it exists is what stops the 2am confusion.

  Two more worth remembering: handlers run once no matter how many tasks
  notified them, and they run at the END of the play unless you ask for
  meta: flush_handlers.
EOF

# ---------------------------------------------------------------------------
# 4. become, and the failure that looks like a bug in Ansible
# ---------------------------------------------------------------------------
say "4. the missing become"

cat > "$TMP/no-become.yml" <<'EOF'
---
- name: forgot become
  hosts: webservers
  gather_facts: false
  tasks:
    - name: Write into /etc
      ansible.builtin.copy:
        content: "nope\n"
        dest: /etc/lab-day14/needs-root.txt
        mode: "0644"
EOF

step "run it"
run "ansible-playbook $TMP/no-become.yml 2>&1 | tail -12"
note "Permission denied. Correct, and unhelpful until you notice the play has no become"

step "the fix, per task rather than per run"
run "ansible-playbook $TMP/no-become.yml --become 2>&1 | grep -E 'changed=|ok='"
note "--become on the command line proves the diagnosis; the real fix is become: true on the task, in the file"
cat <<'EOF'
  Why per task and not become: true at the top of every play: reading the
  playbook should tell you which steps touch the system. A play that runs
  entirely as root hides that, and "everything runs as root" is how a typo in
  a path becomes an incident.

  Also: become is sudo by default and needs sudo to work. On this lab it is
  passwordless. On a real host you will meet --ask-become-pass, and a run
  that hangs silently is usually sudo waiting for a password nobody typed.
EOF

step "clean up that file"
run "ansible node1 -b -m file -a 'path=/etc/lab-day14/needs-root.txt state=absent'"

# ---------------------------------------------------------------------------
# the two that are not exercises
# ---------------------------------------------------------------------------
if [[ "$HARD" == "yes" ]]; then
	say "5. ad-hoc commands against all - described, not executed"
	cat <<'EOF'
  ansible all -b -m shell -a 'rm -rf /var/log/*'

  One line, every host in the inventory, in parallel, with no dry run, no
  record in any repository, and no way to answer "what did you actually run"
  a week later. Ad-hoc mode is a triage tool: -m ping, -m setup, -m command
  for a read. The moment it changes something on more than one host, it
  belongs in a playbook where it can be reviewed and re-run.

  Two habits that make this survivable:

    --limit node1          prove it on one host first, always
    --check --diff         see the prediction before the change

  And know what --limit does not protect you from: it filters hosts, not
  tasks. A destructive task limited to one host is still destructive there.
EOF

	say "6. become: true on every play - also not executed"
	cat <<'EOF'
  Setting become: true at the play level, or worse in ansible.cfg, is the
  configuration-management version of working in a root shell. Nothing
  breaks immediately. What you lose is the ability to read a playbook and
  see its blast radius, and the safety net where a task that should never
  have needed privilege fails loudly instead of succeeding quietly.

  The related one: running ansible itself as root on the control node. Then
  ~/.ssh is /root/.ssh, the key is missing, and the error says UNREACHABLE -
  which sends people to the network for a problem that is entirely local.
EOF
else
	say "the two not shown"
	cat <<'EOF'
  Run with --hard for the two failures that are described rather than
  performed: an ad-hoc shell command against all hosts, and become: true
  everywhere. Neither teaches anything by happening.
EOF
fi

# ---------------------------------------------------------------------------
# put it back, and prove it
# ---------------------------------------------------------------------------
say "putting it back"

ansible node1 -b -m file -a 'path=/etc/lab-day14/settings.conf state=absent' >/dev/null 2>&1 || true
ansible-playbook site.yml > "$TMP/final-1.log" 2>&1 || true
ansible-playbook site.yml > "$TMP/final-2.log" 2>&1 || true
printf '  site.yml, run again: changed=%s\n' "$(changed_count "$TMP/final-2.log")"
printf '  broken plays are in %s and were never added to your project\n' "$TMP"

cat <<'EOF'

Four failures.

  command/shell        works, reports changed forever, and lies in --check
  lineinfile no regexp idempotent for one value, appending for the next
  handler expectations  no change means no restart; a failed play drops them
  missing become        Permission denied, blamed on Ansible for an hour

Only the last one announces itself. The other three pass their first run.

Check yourself:  ~/lab/days/day14/verify.sh
EOF
