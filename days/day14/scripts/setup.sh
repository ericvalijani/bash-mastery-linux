#!/usr/bin/env bash
#
# Day 14 - build the Ansible project that replaces a day of manual work.
#
#   ./scripts/setup.sh [node1-address]
#
# Run this on control, as the lab user, WITHOUT sudo. That is deliberate and
# it is the first lesson of the day: an Ansible project belongs to a person,
# not to root. The files are yours, the SSH key is yours, and privilege is
# something the playbook asks for per task with become - not something the
# whole run starts with.
#
# What it builds, all under ~/ansible-lab:
#   ansible.cfg            inventory path, no host key prompt, timing callback
#   inventory/hosts.ini    the INI form
#   inventory/hosts.yml    the same hosts in YAML, so you can compare
#   group_vars/, host_vars/
#   files/, templates/
#   site.yml               the idempotent play
#   not-idempotent.yml     the same work written badly, for break-and-fix.sh
#
# Idempotent: run it as often as you like. It rewrites the project files and
# leaves node1 exactly as the playbook describes.

set -uo pipefail

# shellcheck source=../../../lab/on-lab-vm.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

say()  { printf '\n=== %s ===\n\n' "$*"; }
ok()   { printf '  ok    %s\n' "$*"; }
info() { printf '  ..    %s\n' "$*"; }
die()  { printf '\nfailed: %s\n' "$*" >&2; exit 1; }

PROJECT="$HOME/ansible-lab"
KEY="$HOME/.ssh/id_ed25519"
PUSHED_KEY="$HOME/lab/id_ed25519"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# 0. the tools, and the user who should be running this
# ---------------------------------------------------------------------------
say "0. prerequisites"

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
	cat >&2 <<'EOF'
failed: do not run this with sudo.

Everything this day builds lives in your home directory and is used by
Ansible running as you. Run it as root and the project ends up owned by
root, ~/.ssh points at /root, and the playbook connects to node1 as root
with a key that is not there.

Ansible does not need root on the control node. Individual tasks ask for
privilege on the managed host with become.

  ./scripts/setup.sh [node1-address]
EOF
	exit 1
fi
ok "running as $(id -un), which is what Ansible wants"

missing=()
for t in ansible ansible-playbook ansible-inventory ansible-config ssh ssh-keygen sudo; do
	command -v "$t" >/dev/null 2>&1 || missing+=("$t")
done
if [[ ${#missing[@]} -gt 0 ]]; then
	printf '\nmissing: %s\n' "${missing[*]}" >&2
	printf 'install them with:\n  sudo dnf install -y ansible-core\n' >&2
	exit 1
fi
ok "ansible-core present: $(ansible --version | head -1)"

# ---------------------------------------------------------------------------
# 1. the credential
# ---------------------------------------------------------------------------
# Ansible has no transport of its own. It is SSH, every time, using your
# client configuration and your key. If ssh to the host does not work, no
# amount of inventory syntax will help - so this is settled first.
say "1. the SSH credential control will use"

if [[ ! -f "$KEY" ]]; then
	if [[ -f "$PUSHED_KEY" ]]; then
		mkdir -p "$HOME/.ssh"
		chmod 700 "$HOME/.ssh"
		install -m 0600 "$PUSHED_KEY" "$KEY"
		rm -f "$PUSHED_KEY"
		ok "installed the pushed key as $KEY (0600) and removed the copy from ~/lab"
	else
		cat >&2 <<EOF

failed: no private key at $KEY

control needs a key that node1 already trusts. The lab key on your laptop is
that key, so copy it over from the repository root:

  ./lab/lab.sh push control ~/.ssh/id_ed25519
  ./lab/lab.sh ssh control
  cd ~/lab/days/day14 && ./scripts/setup.sh

This script will then move it into place with mode 0600.

Worth knowing what you just did: a private key on a control node means
anybody who owns the control node owns every managed host. In real estates
you would use a key generated on the control node and authorised on the
fleet, an agent with forwarding, or a short-lived certificate - never a
copy of your laptop key. Here it is one throwaway VM reaching another.
EOF
		exit 1
	fi
else
	ok "key already present: $KEY"
fi
chmod 600 "$KEY" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2. where node1 is
# ---------------------------------------------------------------------------
# An inventory is a list of addresses and the variables that go with them.
# Nothing discovers hosts for you; this is the one fact the day cannot guess.
say "2. node1's address"

NODE1="${1:-${NODE1:-}}"
if [[ -z "$NODE1" && -f "$PROJECT/inventory/hosts.ini" ]]; then
	NODE1="$(sed -n 's/.*ansible_host=\([0-9.]*\).*/\1/p' "$PROJECT/inventory/hosts.ini" | head -1)"
	[[ -n "$NODE1" ]] && info "reusing the address from the existing inventory"
fi
if [[ -z "$NODE1" ]]; then
	cat >&2 <<'EOF'

failed: I do not know where node1 is.

On your laptop, ask the lab:

  ./lab/lab.sh status          # prints each VM and its address

Then, back on control:

  ./scripts/setup.sh 192.168.122.42      # use the address it printed

Use the address from status rather than one you remember. DHCP leases move,
and a stale address is the most common reason an Ansible run hangs on
"UNREACHABLE" with no useful detail.
EOF
	exit 1
fi
ok "node1 = $NODE1"

# Refusing to configure yourself. This catches the copy-paste of the example
# address out of the README, and the case where status was read from the wrong
# line - both of which otherwise end in a play that "works" against control.
if ip -brief addr show 2>/dev/null | grep -Fw "$NODE1" >/dev/null; then
	cat >&2 <<EOF

failed: $NODE1 is an address on control itself.

You are about to manage the machine you are typing on. That is not this day.
Get node1's address from your laptop:

  ./lab/lab.sh status

The README's 192.168.122.42 is an example, not your lab. libvirt hands out
addresses in whatever order the VMs booted.
EOF
	exit 1
fi

# One attempt, with the transcript kept. "ssh failed" on its own sends people
# to the wrong place; the reason is always in the verbose output, and there
# are only three reasons worth telling apart.
SSH_LOG="/tmp/day14-ssh-probe.log"
if ssh -v -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	-o ConnectTimeout=8 -o BatchMode=yes \
	"$(id -un)@$NODE1" true > "$SSH_LOG" 2>&1; then
	ok "plain ssh to node1 works, so Ansible's transport will work"
else
	printf '\nfailed: ssh to %s did not work, so Ansible cannot either.\n' "$NODE1" >&2
	printf '        (Ansible is only SSH with opinions - fix this layer first.)\n\n' >&2
	grep -Ev '^debug[0-9]' "$SSH_LOG" | tail -6 | sed 's/^/        /' >&2
	printf '\n' >&2

	if grep -qE 'No route to host|Network is unreachable|Connection timed out|Operation timed out' "$SSH_LOG"; then
		cat >&2 <<EOF
        Nothing answered at that address. Either node1 is not running or the
        address is stale - a libvirt lease moves when a VM is rebuilt.

        On your laptop:
          ./lab/lab.sh status            # is node1 running, and at which address?
          ./lab/lab.sh up node1          # if it is not

        Then re-run with the address it prints:
          ./scripts/setup.sh <address>
EOF
	elif grep -q 'Connection refused' "$SSH_LOG"; then
		cat >&2 <<EOF
        Something is at that address but nothing is listening on 22. That is
        usually a host that is still booting, or the wrong host entirely.

        Wait a few seconds, confirm the address with ./lab/lab.sh status on
        your laptop, and try again.
EOF
	elif grep -qE 'Permission denied|No supported authentication' "$SSH_LOG"; then
		cat >&2 <<EOF
        node1 answered and rejected the key. Three causes, in order of
        likelihood:

          1. It is a different key than the one node1 trusts. The key here
             came from ~/lab/id_ed25519; make sure you pushed the same key
             lab.sh uses:  ./lab/lab.sh push control ~/.ssh/id_ed25519
          2. Day 12 hardening on node1: sshd there has AllowGroups labssh, so
             the account must be in that group. From a shell on node1:
               id lab | grep labssh
          3. fail2ban on node1 banned this address after failed attempts.
             From a shell on node1:
               sudo fail2ban-client status sshd
               sudo fail2ban-client set sshd unbanip $(ip -brief addr show | awk 'NR==2{print \$3}' | cut -d/ -f1)
EOF
	else
		printf '        Full transcript: %s\n' "$SSH_LOG" >&2
		printf '        Reproduce it by hand:  ssh -v -i %s %s@%s\n' "$KEY" "$(id -un)" "$NODE1" >&2
	fi
	exit 1
fi

# ---------------------------------------------------------------------------
# 3. the project skeleton
# ---------------------------------------------------------------------------
say "3. the project at $PROJECT"

mkdir -p "$PROJECT"/{inventory,group_vars,host_vars,files,templates}
cd "$PROJECT" || die "cannot enter $PROJECT"
ok "directories: inventory group_vars host_vars files templates"

# ansible.cfg is read from the current directory first, and that file is the
# reason two people on the same machine get different behaviour from the same
# playbook. ansible-config dump --only-changed shows exactly what it changed.
cat > ansible.cfg <<'EOF'
# Read because it sits in the directory you run ansible from. Ansible looks
# for ANSIBLE_CONFIG, then ./ansible.cfg, then ~/.ansible.cfg, then
# /etc/ansible/ansible.cfg - and stops at the first one it finds. It does not
# merge them, which is why a stray config in your home directory can quietly
# change a run.
#
# Check what this file actually changed:  ansible-config dump --only-changed

[defaults]
inventory      = inventory/hosts.ini
remote_user    = lab
host_key_checking = false
# Lab only. In production you want host keys checked - that check is what
# stops you from configuring an impostor.
stdout_callback = default
callbacks_enabled = timer, profile_tasks
interpreter_python = auto_silent
retry_files_enabled = false

[privilege_escalation]
# Off by default on purpose. Each task that needs root says so, so reading
# the playbook tells you which steps touch the system.
become      = false
become_method = sudo
EOF
ok "ansible.cfg"

cat > inventory/hosts.ini <<EOF
# The INI form. Compact, and still the most common thing you will inherit.
#
#   [group]          hosts in that group
#   [group:vars]     variables for the group
#   [parent:children] group of groups
#
# Prove what Ansible read, rather than what you think you wrote:
#   ansible-inventory --graph
#   ansible-inventory --host node1

[webservers]
node1 ansible_host=$NODE1

[lab:children]
webservers

[lab:vars]
ansible_user=lab
ansible_ssh_private_key_file=~/.ssh/id_ed25519
EOF
ok "inventory/hosts.ini"

cat > inventory/hosts.yml <<EOF
# The same two hosts in YAML. Not used by default - ansible.cfg points at the
# INI file - so run it explicitly to compare:
#
#   ansible-inventory -i inventory/hosts.yml --graph
#
# Identical output from both files is the point. YAML is verbose and exact;
# INI is terse and has one nasty habit: a typo in a [group:vars] header is
# silently a host named "[group:vars".
---
all:
  children:
    lab:
      vars:
        ansible_user: lab
        ansible_ssh_private_key_file: ~/.ssh/id_ed25519
      children:
        webservers:
          hosts:
            node1:
              ansible_host: $NODE1
EOF
ok "inventory/hosts.yml"

# Variable precedence, the short version you actually need: role defaults lose
# to group_vars, group_vars/all loses to a named group, a named group loses to
# host_vars, and -e on the command line beats everything.
cat > group_vars/all.yml <<'EOF'
---
# Lowest of the files here. Anything every host should agree on.
lab_owner: "bash-mastery-linux"
lab_marker_dir: /etc/lab-day14
lab_packages:
  - rsync
  - tree
lab_app_user: labapp
EOF

cat > group_vars/webservers.yml <<'EOF'
---
# Beats group_vars/all.yml for hosts in this group.
lab_role_note: "web tier"
lab_log_facility: local3
EOF

cat > host_vars/node1.yml <<'EOF'
---
# Beats both group files. One host, one exception, written down where the next
# person will find it - instead of a hand edit on the box that nobody knows
# about.
lab_role_note: "web tier (first node)"
EOF
ok "group_vars/all.yml, group_vars/webservers.yml, host_vars/node1.yml"

cat > files/lab-day14.txt <<'EOF'
Copied verbatim by the copy module.

If this file changes on the host, the next run puts it back: copy compares
checksums, so "changed" here always means the host drifted.
EOF
ok "files/lab-day14.txt"

# A template is the reason you gather facts. Everything in {{ }} here comes
# from the host itself, so one file fits every host without an if statement.
cat > templates/lab-info.conf.j2 <<'EOF'
# Managed by Ansible - {{ lab_owner }}
# Local edits are reverted on the next run. Change the template instead.
#
# Rendered {{ ansible_facts['hostname'] }} from {{ inventory_hostname }}

role        = {{ lab_role_note }}
distro      = {{ ansible_facts['distribution'] }} {{ ansible_facts['distribution_version'] }}
kernel      = {{ ansible_facts['kernel'] }}
address     = {{ ansible_facts['default_ipv4']['address'] | default('unknown') }}
memory_mb   = {{ ansible_facts['memtotal_mb'] }}
cpus        = {{ ansible_facts['processor_vcpus'] }}
selinux     = {{ ansible_facts['selinux']['status'] | default('unknown') }}
facility    = {{ lab_log_facility }}
EOF

cat > templates/rsyslog-lab.conf.j2 <<'EOF'
# Managed by Ansible - {{ lab_owner }}
# Day 05 taught you where logs go. This is the same rule, written once and
# applied to every host in the group.
{{ lab_log_facility }}.*    /var/log/lab-day14.log
EOF
ok "templates/lab-info.conf.j2, templates/rsyslog-lab.conf.j2"

# ---------------------------------------------------------------------------
# 4. the play
# ---------------------------------------------------------------------------
say "4. site.yml"

cat > site.yml <<'EOF'
---
# Day 14 - the manual work of the last two weeks, written so it can run twice.
#
#   ansible-playbook site.yml --syntax-check     is the YAML and are the modules sane
#   ansible-playbook site.yml --check --diff     what WOULD change, and how
#   ansible-playbook site.yml                    do it
#   ansible-playbook site.yml                    changed=0, or something is wrong
#
# Read the second run as the real test. A playbook that reports changes every
# time is not describing a state; it is running commands, and you cannot tell
# a drifted host from a noisy task.

- name: Lab baseline
  hosts: webservers
  gather_facts: true # the templates below need facts; skip it and they fail

  tasks:
    - name: Packages are present
      # State, not action. There is no "install" here: present means present,
      # so the second run has nothing to do. Never shell out to dnf for this.
      ansible.builtin.package:
        name: "{{ lab_packages }}"
        state: present
      become: true

    - name: The log service is installed
      ansible.builtin.package:
        name: rsyslog
        state: present
      become: true

    - name: A system user owns the app files
      # Idempotent because the module reads /etc/passwd first. Note what is
      # NOT here: no password, no shell. A service account that cannot log in.
      ansible.builtin.user:
        name: "{{ lab_app_user }}"
        system: true
        shell: /sbin/nologin
        create_home: false
        state: present
      become: true

    - name: The marker directory exists
      ansible.builtin.file:
        path: "{{ lab_marker_dir }}"
        state: directory
        owner: root
        group: root
        mode: "0755"
      become: true

    - name: A file is copied verbatim
      # copy compares checksums, so this is only "changed" when the host
      # differs from the repository - which is exactly what drift means.
      ansible.builtin.copy:
        src: files/lab-day14.txt
        dest: "{{ lab_marker_dir }}/lab-day14.txt"
        owner: root
        group: root
        mode: "0644"
      become: true

    - name: A file is rendered from facts
      ansible.builtin.template:
        src: templates/lab-info.conf.j2
        dest: "{{ lab_marker_dir }}/lab-info.conf"
        owner: root
        group: root
        mode: "0644"
      become: true

    - name: One line is managed inside a file we do not own
      # The regexp is the whole task. It is what lets Ansible recognise a
      # line it wrote before and replace it, instead of appending a fifth
      # copy. lineinfile without a regexp is how config files grow duplicates.
      #
      # Note the path: settings.conf, NOT the file the copy task above owns.
      # Pointing lineinfile at a copied or templated file is the classic
      # fighting-tasks bug: copy restores the checksum, lineinfile puts its
      # line back, and both report changed on every single run forever. Two
      # tasks may not own one file. Either copy/template owns it entirely,
      # or lineinfile edits a file that some package owns.
      ansible.builtin.lineinfile:
        path: "{{ lab_marker_dir }}/settings.conf"
        regexp: '^owner='
        line: "owner={{ lab_owner }}"
        create: true
        owner: root
        group: root
        mode: "0644"
        state: present
      become: true

    - name: The log rule is in place
      ansible.builtin.template:
        src: templates/rsyslog-lab.conf.j2
        dest: /etc/rsyslog.d/99-lab-day14.conf
        owner: root
        group: root
        mode: "0644"
      become: true
      notify: Restart rsyslog
      # notify fires only if THIS task reported changed. That is the feature:
      # the service restarts when its configuration moved, and not otherwise.

    - name: The log service is enabled and running
      ansible.builtin.service:
        name: rsyslog
        state: started
        enabled: true
      become: true

    - name: Report what the host thinks it is
      # A command that only reads is still reported as changed, because
      # Ansible cannot know. changed_when: false is you telling it.
      ansible.builtin.command: hostnamectl --static
      register: static_hostname
      changed_when: false

    - name: Show it
      ansible.builtin.debug:
        msg: "{{ inventory_hostname }} is {{ static_hostname.stdout }} - {{ lab_role_note }}"

  handlers:
    - name: Restart rsyslog
      # Handlers run once, at the end, no matter how many tasks notified them.
      ansible.builtin.service:
        name: rsyslog
        state: restarted
      become: true
EOF
ok "site.yml"

# The same work done badly. break-and-fix.sh runs this one.
cat > not-idempotent.yml <<'EOF'
---
# The same outcomes as site.yml, written the way people write their first
# playbook: shell commands instead of modules. It works. It is also unusable,
# for reasons break-and-fix.sh demonstrates rather than asserts.
#
#   ansible-playbook not-idempotent.yml      then run it again, and again

- name: The wrong way, kept for comparison
  hosts: webservers
  gather_facts: false
  become: true

  tasks:
    - name: Install with a shell command
      # Reports changed every single time. Nothing here can tell you whether
      # the package was already installed, and --check skips it entirely,
      # so a dry run tells you nothing either.
      ansible.builtin.command: dnf install -y tree

    - name: Append a line
      # Run it five times, get five lines. This is the single most common
      # non-idempotent task in the wild.
      ansible.builtin.shell: echo "owner=appended" >> /etc/lab-day14/lab-day14.txt

    - name: Restart the service because we always restart the service
      # An unconditional restart is an outage you scheduled by accident.
      ansible.builtin.command: systemctl restart rsyslog
EOF
ok "not-idempotent.yml"

# ---------------------------------------------------------------------------
# 5. prove it, in the order you would prove anything
# ---------------------------------------------------------------------------
say "5. checking the work"

info "ansible-inventory --graph"
ansible-inventory --graph | sed 's/^/        /'

info "ansible node1 -m ping   (python on the far side, not ICMP)"
ansible node1 -m ping | sed 's/^/        /' || die "the ping module failed - see the error above"

info "ansible-playbook site.yml --syntax-check"
ansible-playbook site.yml --syntax-check >/dev/null || die "site.yml does not parse"
ok "syntax is valid"

info "ansible-playbook site.yml --check --diff   (nothing is changed yet)"
ansible-playbook site.yml --check --diff > /tmp/day14-check.log 2>&1 || true
sed -n '1,60p' /tmp/day14-check.log | sed 's/^/        /'
printf '\n'
ok "full dry run saved to /tmp/day14-check.log - compare it with the real run"

info "ansible-playbook site.yml   (for real)"
if ansible-playbook site.yml > /tmp/day14-run1.log 2>&1; then
	grep -E '^(node1|PLAY RECAP)' /tmp/day14-run1.log | sed 's/^/        /'
	ok "first run finished"
else
	tail -30 /tmp/day14-run1.log >&2
	die "the first run failed - the tail of /tmp/day14-run1.log is above"
fi

info "ansible-playbook site.yml   (again - this is the real test)"
ansible-playbook site.yml > /tmp/day14-run2.log 2>&1 || true
grep -E '^(node1|PLAY RECAP)' /tmp/day14-run2.log | sed 's/^/        /'
if grep -q 'changed=0' /tmp/day14-run2.log; then
	ok "changed=0 on the second run - the play describes a state, not a script"
else
	printf '  !!    the second run still reported changes. Find the task:\n'
	printf '        grep -B2 "changed:" /tmp/day14-run2.log\n'
fi

# ---------------------------------------------------------------------------
# 6. the payload
# ---------------------------------------------------------------------------
say "6. installing lab-ansible"

sudo install -m 0755 "$SCRIPT_DIR/lab-ansible.sh" /usr/local/bin/lab-ansible
ok "/usr/local/bin/lab-ansible - the one root action in this script, and it is a file copy"

cat <<EOF

Done. The project is at $PROJECT and node1 matches site.yml.

Next:
  lab-ansible                                     what the project says and what the host reports
  cd $PROJECT && ansible-playbook site.yml        changed=0, every time
  ~/lab/days/day14/scripts/explore-ansible.sh     twelve read-only stops
  ~/lab/days/day14/scripts/break-and-fix.sh       four ways a play stops being idempotent
  ~/lab/days/day14/verify.sh                      five checks, two for you

Run verify.sh as yourself. Not with sudo - see step 0.
EOF
