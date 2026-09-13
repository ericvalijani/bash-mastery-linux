#!/usr/bin/env bash
#
# Day 15 - turn Days 11, 12 and 13 into one role, and apply it to a machine
# that has never been touched.
#
#   ./scripts/setup.sh [node1-address] [node2-address]
#
# Run this on control, as the lab user, WITHOUT sudo - same rule as Day 14.
#
# Day 14 is NOT a prerequisite. If its project is already in ~/ansible-lab we
# extend it; if not - a rebuilt control VM, for instance - we write the
# ansible.cfg ourselves and carry on.
#
# What it builds, all under ~/ansible-lab:
#   inventory/hosts.ini      node1 and node2, in two groups
#   group_vars/lab/vars.yml  the variables you are meant to read
#   group_vars/lab/vault.yml the one you are not - encrypted
#   roles/hardening/         defaults, vars, tasks, handlers, templates, meta
#   hardening.yml            the play that is one line long
#
# Day 14's site.yml, if present, is left alone on purpose, so both days keep
# working. Nothing today reads it.
#
# Idempotent: run it as often as you like. It rewrites the role and re-applies
# it, and a second run reports changed=0 on both hosts.

set -uo pipefail

# shellcheck source=../../../lab/on-lab-vm.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

say()  { printf '\n=== %s ===\n\n' "$*"; }
ok()   { printf '  ok    %s\n' "$*"; }
info() { printf '  ..    %s\n' "$*"; }
note() { printf '        %s\n' "$*"; }
die()  { printf '\nfailed: %s\n' "$*" >&2; exit 1; }

PROJECT="${ANSIBLE_LAB_DIR:-$HOME/ansible-lab}"
KEY="$HOME/.ssh/id_ed25519"
PUSHED_KEY="$HOME/lab/id_ed25519"
VAULT_PASS="$HOME/.vault-pass-lab"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGIN_USER="$(id -un)"

# ---------------------------------------------------------------------------
# 0. the tools, and the user who should be running this
# ---------------------------------------------------------------------------
say "0. prerequisites"

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
	cat >&2 <<'EOF'
failed: do not run this with sudo.

Same reason as Day 14. The project and the SSH key belong to you; the role
asks for privilege on the managed hosts with become, per task.

  ./scripts/setup.sh [node1-address] [node2-address]
EOF
	exit 1
fi
ok "running as $LOGIN_USER, which is what Ansible wants"

missing=()
for t in ansible ansible-playbook ansible-inventory ansible-galaxy ansible-vault ssh; do
	command -v "$t" >/dev/null 2>&1 || missing+=("$t")
done
if [[ ${#missing[@]} -gt 0 ]]; then
	printf '\nmissing: %s\n' "${missing[*]}" >&2
	printf 'install them with:\n  sudo dnf install -y ansible-core\n' >&2
	exit 1
fi
ok "ansible-core present: $(ansible --version | head -1)"

if [[ ! -f "$KEY" ]]; then
	if [[ -f "$PUSHED_KEY" ]]; then
		mkdir -p "$HOME/.ssh"
		chmod 700 "$HOME/.ssh"
		install -m 0600 "$PUSHED_KEY" "$KEY"
		rm -f "$PUSHED_KEY"
		ok "installed the pushed key as $KEY (0600)"
	else
		cat >&2 <<EOF

failed: no private key at $KEY

control needs the key both nodes trust. From the repository root on your
laptop:

  ./lab/lab.sh push control ~/.ssh/id_ed25519
  ./lab/lab.sh ssh control
  cd ~/lab/days/day15 && ./scripts/setup.sh
EOF
		exit 1
	fi
else
	ok "key already present: $KEY"
fi
chmod 600 "$KEY" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 1. where the two nodes are
# ---------------------------------------------------------------------------
# Addresses come from ./lab/lab.sh status on your laptop. control cannot run
# virsh, so it cannot look them up. Reuse whatever is already in the inventory
# when no argument is given, which makes re-runs painless and a rebuilt VM
# obvious.
say "1. the two addresses"

old_ini="$PROJECT/inventory/hosts.ini"
guess_addr() {
	[[ -f "$old_ini" ]] || return 1
	sed -n "s/^$1[[:space:]].*ansible_host=\\([0-9.]*\\).*/\\1/p" "$old_ini" | head -1
}

NODE1="${1:-${NODE1:-$(guess_addr node1 || true)}}"
NODE2="${2:-${NODE2:-$(guess_addr node2 || true)}}"

if [[ -z "$NODE1" || -z "$NODE2" ]]; then
	cat >&2 <<EOF

failed: I need both addresses.

On your laptop, in the repository:

  ./lab/lab.sh up control node1 node2      # ~5.5 GB, the peak of the course
  ./lab/lab.sh status                      # read both addresses

Then here:

  ./scripts/setup.sh <node1-address> <node2-address>

The leases move when a VM is rebuilt, so read them every time rather than
trusting an address from a README.
EOF
	exit 1
fi
ok "node1 = $NODE1"
ok "node2 = $NODE2"

# The addresses this machine owns. Handing setup.sh control's own address is a
# mistake worth naming, because Ansible would then harden the control node -
# and the SSH policy it applies is the one you are connected over.
my_addrs="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
for a in $my_addrs; do
	for given in "$NODE1" "$NODE2"; do
		[[ "$a" == "$given" ]] && die "$given is an address of THIS machine (control).
         Hardening control with this role would apply AllowGroups and
         PasswordAuthentication no to the host you are sitting on.
         Read the node addresses from ./lab/lab.sh status on your laptop."
	done
done

# ---------------------------------------------------------------------------
# 2. ssh, before Ansible
# ---------------------------------------------------------------------------
# Ansible is SSH with opinions. If ssh does not work, no inventory syntax will
# save you - and the error Ansible prints (UNREACHABLE) is the same whether
# the host is down, the port is shut, or the key is wrong.
say "2. plain ssh to both nodes"

probe() {
	local host="$1" log="$2"
	ssh -v -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o ConnectTimeout=8 -o BatchMode=yes "$LOGIN_USER@$host" true >"$log" 2>&1
}

diagnose() {
	local host="$1" log="$2"
	{
		printf '\nfailed: ssh to %s did not work.\n\n' "$host"
		grep -Ei 'no route|timed out|refused|permission denied|unreachable|banner' "$log" |
			sed 's/^/        /' | head -5
		if grep -qEi 'no route|timed out' "$log"; then
			printf '\n        Nothing answered. The VM is not running, or that address\n'
			printf '        belongs to a lease it no longer holds. On your laptop:\n'
			printf '          ./lab/lab.sh status\n          ./lab/lab.sh up %s\n' "$host"
		elif grep -qi 'refused' "$log"; then
			printf '\n        Something answered and shut the door: sshd is not up yet\n'
			printf '        (give a fresh VM a minute) or not listening on 22.\n'
		elif grep -qEi 'permission denied|no supported authentication' "$log"; then
			printf '\n        The host answered and rejected the key:\n'
			printf '          1. wrong key - push the one lab.sh uses:\n'
			printf '               ./lab/lab.sh push control ~/.ssh/id_ed25519\n'
			printf '          2. Day 12 hardening on node1: sshd there has AllowGroups\n'
			printf '             labssh, so this account must be in that group\n'
			printf '          3. fail2ban banned this address after failed attempts:\n'
			printf '               sudo fail2ban-client status sshd\n'
		fi
		printf '\n        Full transcript: %s\n' "$log"
		printf '        By hand:  ssh -v -i %s %s@%s\n' "$KEY" "$LOGIN_USER" "$host"
	} >&2
	exit 1
}

for pair in "node1:$NODE1" "node2:$NODE2"; do
	name="${pair%%:*}"
	addr="${pair#*:}"
	log="/tmp/day15-ssh-$name.log"
	if probe "$addr" "$log"; then
		ok "ssh to $name ($addr) works"
	else
		diagnose "$addr" "$log"
	fi
done
note "node2 has never been configured. That is the whole point of it"

# ---------------------------------------------------------------------------
# 3. inventory: two groups, because they are not the same kind of host
# ---------------------------------------------------------------------------
say "3. inventory with node2 in it"

mkdir -p "$PROJECT"/{inventory,group_vars,host_vars,files,templates,roles}
cd "$PROJECT" || die "cannot enter $PROJECT"

cat > inventory/hosts.ini <<EOF
# Day 15 - two hosts, two groups, one parent.
#
#   webservers   node1, hardened by hand on Days 11-13
#   fresh        node2, never touched
#   lab          both - and the group the hardening role is applied to
#
# The groups are not decoration. group_vars/webservers.yml opens port 8080
# because Day 13 put nginx there; node2 has no web server, so it gets no open
# port. Same role, different data.

[webservers]
node1 ansible_host=$NODE1

[fresh]
node2 ansible_host=$NODE2

[lab:children]
webservers
fresh

[lab:vars]
ansible_user=$LOGIN_USER
ansible_ssh_private_key_file=~/.ssh/id_ed25519
EOF
ok "inventory/hosts.ini - webservers, fresh, lab"

cat > inventory/hosts.yml <<EOF
# The same three groups in YAML. Compare the two:
#   ansible-inventory --graph
#   ansible-inventory -i inventory/hosts.yml --graph
---
all:
  children:
    lab:
      vars:
        ansible_user: $LOGIN_USER
        ansible_ssh_private_key_file: ~/.ssh/id_ed25519
      children:
        webservers:
          hosts:
            node1:
              ansible_host: $NODE1
        fresh:
          hosts:
            node2:
              ansible_host: $NODE2
EOF
ok "inventory/hosts.yml"

# ---------------------------------------------------------------------------
# 4. variables, including one that is encrypted
# ---------------------------------------------------------------------------
# group_vars/lab can be a file or a directory, never both - Ansible reads
# every .yml inside the directory. Splitting it in two is the convention that
# makes vault usable: vars.yml is readable in a diff, vault.yml holds only
# secrets, and nothing in vars.yml has to be encrypted just because it lives
# near one.
say "4. group_vars, and the vault"

mkdir -p group_vars/lab

cat > group_vars/lab/vars.yml <<'EOF'
---
# Readable on purpose. Anyone reviewing a change can see the policy without
# a vault password.
hardening_admin_contact: "ops@lab.invalid"
hardening_banner_owner: "bash-mastery-linux"

# The indirection that makes vault bearable: the secret lives under a
# vault_ name, and the variable the role uses points at it. Grep for
# vault_ and you have found every secret the project reads.
hardening_alert_token: "{{ vault_hardening_alert_token }}"
EOF
ok "group_vars/lab/vars.yml"

cat > group_vars/webservers.yml <<'EOF'
---
# Beats role defaults. node1 serves Day 13's nginx on 8080, so this group -
# and only this group - opens that port.
lab_role_note: "web tier"
lab_log_facility: local3
hardening_open_ports:
  - 8080/tcp
EOF

cat > group_vars/fresh.yml <<'EOF'
---
# node2 runs no service worth exposing, so it inherits the role default of no
# open ports. Written down rather than left implicit.
lab_role_note: "clean host"
lab_log_facility: local3
hardening_open_ports: []
EOF
ok "group_vars/webservers.yml, group_vars/fresh.yml"

# The vault password. In a real estate this comes from a secret manager or is
# typed; here it is a random string in a 0600 file outside the project, so it
# cannot be committed by accident.
if [[ ! -f "$VAULT_PASS" ]]; then
	(umask 077; tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 > "$VAULT_PASS")
	ok "generated a vault password at $VAULT_PASS (0600, outside the project)"
else
	ok "vault password already at $VAULT_PASS"
fi
chmod 600 "$VAULT_PASS"

# Encrypt only if it is not already encrypted. ansible-vault is not idempotent
# on its own: encrypting twice gives you a vault inside a vault.
if [[ -f group_vars/lab/vault.yml ]] && head -1 group_vars/lab/vault.yml | grep -q '^\$ANSIBLE_VAULT'; then
	ok "group_vars/lab/vault.yml is already encrypted - left alone"
else
	umask 077
	cat > /tmp/day15-vault-plain.yml <<'EOF'
---
# The only file in this project with a secret in it. Read it with:
#   ansible-vault view group_vars/lab/vault.yml
vault_hardening_alert_token: "lab-not-a-real-token-7f3c91"
EOF
	ansible-vault encrypt --vault-password-file "$VAULT_PASS" \
		--output group_vars/lab/vault.yml /tmp/day15-vault-plain.yml >/dev/null ||
		die "ansible-vault encrypt failed"
	rm -f /tmp/day15-vault-plain.yml
	ok "group_vars/lab/vault.yml encrypted"
fi
note "git would store the ciphertext. A diff of it is useless, which is the price"

# ansible.cfg. If Day 14's project is here, we add one line to it: where the
# vault password lives. If it is not - a rebuilt control VM, or you skipped
# Day 14 - we write the whole file, because Day 15 should not fail on the
# absence of a previous day. The config below is Day 14's, plus the vault line.
if [[ ! -f ansible.cfg ]]; then
	cat > ansible.cfg <<EOF
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
# Where the vault password lives. Without this line every command wants
# --vault-password-file, and people start committing the plaintext to save
# the typing.
vault_password_file = $VAULT_PASS

[privilege_escalation]
# Off by default on purpose. Each task that needs root says so, so reading
# the playbook tells you which steps touch the system.
become      = false
become_method = sudo
EOF
	ok "wrote ansible.cfg (no Day 14 project here - Day 15 does not need one)"
	note "Day 14's site.yml is not present, and nothing today uses it. If you want"
	note "it back:  cd ~/lab/days/day14 && ./scripts/setup.sh $NODE1"
elif ! grep -q '^vault_password_file' ansible.cfg; then
	sed -i "/^\\[defaults\\]/a vault_password_file = $VAULT_PASS" ansible.cfg
	ok "ansible.cfg now points at the vault password file"
else
	ok "ansible.cfg already has vault_password_file"
fi

cat > .gitignore <<'EOF'
# Never commit these. The vault password is not in the project, but a stray
# copy here would be.
*.vault-pass*
*-plain.yml
*.retry
EOF
ok ".gitignore"

# ---------------------------------------------------------------------------
# 5. the role, in the layout every role uses
# ---------------------------------------------------------------------------
# ansible-galaxy init makes this tree for you. It is worth running once to see
# that the layout is a convention with meaning, not a preference:
#
#   defaults/main.yml   lowest precedence of all - your API, meant to be
#                       overridden by inventory
#   vars/main.yml       high precedence - internal facts of the role that a
#                       user has no business changing
#   tasks/main.yml      the entry point; everything else is imported
#   handlers/main.yml   restart/reload, run once at the end
#   templates/, files/  referenced by bare filename from inside the role
#   meta/main.yml       dependencies and metadata
say "5. roles/hardening"

ROLE="roles/hardening"
mkdir -p "$ROLE"/{defaults,vars,tasks,handlers,templates,files,meta}

cat > "$ROLE/defaults/main.yml" <<'EOF'
---
# Role defaults: the lowest precedence in Ansible, and therefore the right
# place for everything a user might want to change. Anything set here can be
# overridden by group_vars, host_vars or -e without editing the role.
#
# The rule of thumb: if changing it is a decision, it belongs here. If
# changing it breaks the role, it belongs in vars/main.yml.

# packages (Days 11-13, as a list instead of three dnf commands)
hardening_packages:
  - firewalld
  - policycoreutils
  - policycoreutils-python-utils
  - fail2ban
  - fail2ban-firewalld

# SELinux (Day 13)
hardening_selinux_state: enforcing

# firewalld (Day 11)
hardening_firewall_zone: public
hardening_firewall_services:
  - ssh
hardening_open_ports: []

# sshd (Day 12)
hardening_ssh_group: labssh
hardening_ssh_users: "{{ [ansible_user] }}"
hardening_ssh_password_auth: false
hardening_ssh_permit_root: prohibit-password
hardening_ssh_max_auth_tries: 3
hardening_ssh_login_grace: 20

# fail2ban (Day 12) - short ban on purpose, so you can trigger it and
# recover without rebuilding the VM
hardening_f2b_maxretry: 3
hardening_f2b_findtime: 120
hardening_f2b_bantime: 120

# marker files, so you can see the role's work without reading config
hardening_marker_dir: /etc/lab-day15
EOF
ok "$ROLE/defaults/main.yml"

cat > "$ROLE/vars/main.yml" <<'EOF'
---
# Role vars: near the top of the precedence list. These are facts about how
# the role works, not choices. Put a path here and inventory cannot silently
# point the role at the wrong file - which is exactly what you want for a
# path the role's own handlers and checks depend on.
hardening_sshd_dropin: /etc/ssh/sshd_config.d/00-lab-hardening.conf
hardening_f2b_jail: /etc/fail2ban/jail.d/lab-sshd.local
hardening_sshd_binary: /usr/sbin/sshd
EOF
ok "$ROLE/vars/main.yml"

cat > "$ROLE/meta/main.yml" <<'EOF'
---
# meta/main.yml is where a role declares what it needs from other roles.
#
#   dependencies:
#     - role: baseline
#
# Dependencies run before this role's tasks, every time, and they are the
# most common way a role becomes impossible to reason about: three roles deep,
# nobody knows what has already run. This role has none deliberately -
# composition happens in the playbook, where it is visible.
galaxy_info:
  role_name: hardening
  author: bash-mastery-linux
  description: Days 11-13 hardening - SELinux, firewalld, sshd, fail2ban
  license: MIT
  min_ansible_version: "2.14"
  platforms:
    - name: EL
      versions:
        - "9"
dependencies: []
EOF
ok "$ROLE/meta/main.yml"

cat > "$ROLE/tasks/main.yml" <<'EOF'
---
# The entry point. It does nothing itself except import, in an order that
# matters, with a tag on each import so you can run one area at a time:
#
#   ansible-playbook hardening.yml --list-tags
#   ansible-playbook hardening.yml --tags selinux
#   ansible-playbook hardening.yml --skip-tags fail2ban
#
# Order is the interesting part. The access list has to exist before sshd is
# told to enforce it, and firewalld has to allow ssh before it is started.
# Get either backwards and you lock yourself out of a host you can only reach
# over ssh.

- name: Packages
  ansible.builtin.import_tasks: packages.yml
  tags: [packages]

- name: SELinux
  ansible.builtin.import_tasks: selinux.yml
  tags: [selinux]

- name: Firewall
  ansible.builtin.import_tasks: firewall.yml
  tags: [firewall]

- name: SSH access
  ansible.builtin.import_tasks: ssh.yml
  tags: [ssh]

- name: fail2ban
  ansible.builtin.import_tasks: fail2ban.yml
  tags: [fail2ban]

- name: Marker
  ansible.builtin.import_tasks: marker.yml
  tags: [marker]
EOF

cat > "$ROLE/tasks/packages.yml" <<'EOF'
---
# fail2ban is not in the Rocky repositories; it is in EPEL. So EPEL is its own
# task, before the list that needs it. A single package task with both in it
# fails on a clean host, because the repository does not exist yet at the
# moment dnf resolves the name.
- name: The EPEL repository is present
  ansible.builtin.package:
    name: epel-release
    state: present
  become: true

- name: Hardening packages are installed
  ansible.builtin.package:
    name: "{{ hardening_packages }}"
    state: present
  become: true
EOF

cat > "$ROLE/tasks/selinux.yml" <<'EOF'
---
# Day 13 with the manual steps removed. Note what this does NOT use:
# ansible.posix.selinux, which would be one task - because ansible-core ships
# no collections, and a lab that pretends otherwise fails on a fresh install.
# Doing it with builtin modules also shows what a module is: a read, a
# decision, and a write.
#
# Two halves, and they are genuinely different: the file is what the host
# boots with, setenforce is what it is doing right now.
- name: SELinux mode on disk
  ansible.builtin.lineinfile:
    path: /etc/selinux/config
    regexp: '^SELINUX='
    line: "SELINUX={{ hardening_selinux_state }}"
    state: present
  become: true

- name: What SELinux is doing right now
  ansible.builtin.command: getenforce
  register: hardening_getenforce
  changed_when: false
  check_mode: false

- name: Enforcing, without waiting for a reboot
  # changed_when is the whole trick: the command is only run when the state is
  # wrong, so the task is idempotent even though setenforce is not.
  ansible.builtin.command: setenforce 1
  when:
    - hardening_selinux_state == 'enforcing'
    - hardening_getenforce.stdout | lower != 'enforcing'
    - hardening_getenforce.stdout | lower != 'disabled'
  become: true

- name: Warn if SELinux is disabled rather than permissive
  # Disabled is the one state Ansible cannot fix live. The kernel has to be
  # asked at boot, so this is a reboot, not a task.
  ansible.builtin.debug:
    msg: >-
      SELinux is disabled on {{ inventory_hostname }}. The config file now says
      {{ hardening_selinux_state }}, but it takes a reboot to get there.
  when: hardening_getenforce.stdout | lower == 'disabled'
EOF

cat > "$ROLE/tasks/firewall.yml" <<'EOF'
---
# Day 11, as data. Every port is a line in group_vars instead of a command in
# somebody's shell history.
#
# Order matters here: ssh has to be allowed before firewalld is enforcing, or
# you are locked out of the host you are configuring. The stock public zone
# already allows ssh, so this is belt and braces - but on a host with a
# changed default zone it is the difference between a working node and a
# support call.
- name: firewalld is enabled and running
  ansible.builtin.service:
    name: firewalld
    state: started
    enabled: true
  become: true

- name: Which services the zone already allows
  ansible.builtin.command: >-
    firewall-cmd --permanent --zone={{ hardening_firewall_zone }} --list-services
  register: hardening_fw_services
  changed_when: false
  check_mode: false
  become: true

- name: Services are permitted, permanently
  ansible.builtin.command: >-
    firewall-cmd --permanent --zone={{ hardening_firewall_zone }}
    --add-service={{ item }}
  loop: "{{ hardening_firewall_services }}"
  when: item not in hardening_fw_services.stdout.split()
  become: true
  notify: Reload firewalld

- name: Which ports the zone already allows
  ansible.builtin.command: >-
    firewall-cmd --permanent --zone={{ hardening_firewall_zone }} --list-ports
  register: hardening_fw_ports
  changed_when: false
  check_mode: false
  become: true

- name: Ports are open, permanently
  # --permanent writes the saved policy; the runtime policy is untouched until
  # a reload. That split is Day 11's lesson, and the handler below is where
  # the reload belongs - once, at the end, and only if something changed.
  ansible.builtin.command: >-
    firewall-cmd --permanent --zone={{ hardening_firewall_zone }}
    --add-port={{ item }}
  loop: "{{ hardening_open_ports }}"
  when: item not in hardening_fw_ports.stdout.split()
  become: true
  notify: Reload firewalld
EOF

cat > "$ROLE/tasks/ssh.yml" <<'EOF'
---
# Day 12, and the most dangerous file in the role. Read the order before you
# read the tasks: the group exists, then the account is in it, and only then
# does sshd get told to allow that group and nobody else. Reverse two of these
# and the next connection to the host is refused - including Ansible's.
- name: The access group exists
  ansible.builtin.group:
    name: "{{ hardening_ssh_group }}"
    state: present
  become: true

- name: The accounts allowed to log in are in it
  # AllowGroups instead of AllowUsers for one boring, decisive reason: adding
  # a person becomes a group membership, not an sshd config change and reload.
  ansible.builtin.user:
    name: "{{ item }}"
    groups: "{{ hardening_ssh_group }}"
    append: true
  loop: "{{ hardening_ssh_users }}"
  become: true

- name: The hardening drop-in
  # validate runs sshd -t against the candidate file BEFORE it replaces the
  # real one. If it fails, the task fails and the old file is still in place -
  # which is the difference between a failed play and an unreachable host.
  ansible.builtin.template:
    src: sshd-hardening.conf.j2
    dest: "{{ hardening_sshd_dropin }}"
    owner: root
    group: root
    mode: "0600"
    validate: "{{ hardening_sshd_binary }} -t -f %s"
  become: true
  notify: Reload sshd

- name: What sshd is actually doing
  # -T prints the effective configuration, after every include, which is the
  # only honest answer. The file is intent; this is behaviour.
  ansible.builtin.command: "{{ hardening_sshd_binary }} -T"
  register: hardening_sshd_effective
  changed_when: false
  check_mode: false
  become: true

- name: Password authentication really is off
  # An assert, not a check. If some later drop-in overrides the policy, the
  # play should stop and say so rather than report success.
  ansible.builtin.assert:
    that:
      - "'passwordauthentication no' in hardening_sshd_effective.stdout_lines"
    fail_msg: >-
      sshd -T does not show 'passwordauthentication no' on {{ inventory_hostname }}.
      Something later in the include order overrides {{ hardening_sshd_dropin }} -
      list /etc/ssh/sshd_config.d/ and look for a file sorting after ours.
    success_msg: "sshd -T agrees with the drop-in"
  when: not hardening_ssh_password_auth
EOF

cat > "$ROLE/tasks/fail2ban.yml" <<'EOF'
---
- name: The jail
  ansible.builtin.template:
    src: jail-sshd.local.j2
    dest: "{{ hardening_f2b_jail }}"
    owner: root
    group: root
    mode: "0644"
  become: true
  notify: Restart fail2ban

- name: fail2ban is enabled and running
  ansible.builtin.service:
    name: fail2ban
    state: started
    enabled: true
  become: true
EOF

cat > "$ROLE/tasks/marker.yml" <<'EOF'
---
# Not hardening. This is how you see what the role decided, on the host,
# without reading five config files - and it is where the vault secret is
# used, so you can prove the decryption worked.
- name: The marker directory
  ansible.builtin.file:
    path: "{{ hardening_marker_dir }}"
    state: directory
    owner: root
    group: root
    mode: "0755"
  become: true

- name: The report
  ansible.builtin.template:
    src: hardening-report.conf.j2
    dest: "{{ hardening_marker_dir }}/hardening.conf"
    owner: root
    group: root
    mode: "0640"
  become: true
EOF
ok "$ROLE/tasks/ - main, packages, selinux, firewall, ssh, fail2ban, marker"

cat > "$ROLE/handlers/main.yml" <<'EOF'
---
# Handlers run once, at the end, and only if a task reported changed. Two
# things worth knowing before you rely on them:
#
#   - a failed play drops pending handlers, so a host can end up with new
#     config on disk and the old process still running
#   - --check notifies nothing real, so a dry run never shows you a restart
- name: Reload sshd
  # reload, not restart. Existing sessions - including the one Ansible is
  # using - survive either on modern OpenSSH, but reload is the habit that
  # keeps you employed.
  ansible.builtin.service:
    name: sshd
    state: reloaded
  become: true

- name: Restart fail2ban
  ansible.builtin.service:
    name: fail2ban
    state: restarted
  become: true

- name: Reload firewalld
  # This is what makes --permanent take effect. Without it the saved policy
  # and the running policy disagree until a reboot, which is the single most
  # common firewalld confusion.
  ansible.builtin.command: firewall-cmd --reload
  become: true
EOF
ok "$ROLE/handlers/main.yml"

cat > "$ROLE/templates/sshd-hardening.conf.j2" <<'EOF'
# Managed by Ansible: roles/hardening - {{ hardening_banner_owner }}
# Rendered for {{ inventory_hostname }}. Local edits are reverted.
#
# Included from /etc/ssh/sshd_config, whose Include line is at the top, and
# sshd keeps the FIRST value it reads for each keyword - so these win.
#   sudo sshd -T | sort      the effective result

PasswordAuthentication {{ 'yes' if hardening_ssh_password_auth else 'no' }}
KbdInteractiveAuthentication no
PermitRootLogin {{ hardening_ssh_permit_root }}
PermitEmptyPasswords no
AllowGroups {{ hardening_ssh_group }}
MaxAuthTries {{ hardening_ssh_max_auth_tries }}
LoginGraceTime {{ hardening_ssh_login_grace }}
EOF

cat > "$ROLE/templates/jail-sshd.local.j2" <<'EOF'
# Managed by Ansible: roles/hardening - {{ hardening_banner_owner }}
#
# Deliberately short. You are meant to trigger this on purpose and unban
# yourself, which nobody does when the ban lasts ten hours.
[sshd]
enabled  = true
backend  = systemd
maxretry = {{ hardening_f2b_maxretry }}
findtime = {{ hardening_f2b_findtime }}
bantime  = {{ hardening_f2b_bantime }}
EOF

cat > "$ROLE/templates/hardening-report.conf.j2" <<'EOF'
# Managed by Ansible: roles/hardening - {{ hardening_banner_owner }}
# Rendered {{ ansible_facts['hostname'] }} from {{ inventory_hostname }}
#
# Everything below came from a variable, not from a command somebody ran once.

groups          = {{ group_names | join(' ') }}
role_note       = {{ lab_role_note | default('unset') }}
selinux_target  = {{ hardening_selinux_state }}
selinux_now     = {{ hardening_getenforce.stdout | default('unknown') }}
ssh_group       = {{ hardening_ssh_group }}
ssh_password    = {{ 'yes' if hardening_ssh_password_auth else 'no' }}
open_ports      = {{ hardening_open_ports | join(' ') if hardening_open_ports else 'none' }}
f2b_bantime     = {{ hardening_f2b_bantime }}
admin_contact   = {{ hardening_admin_contact }}
# From the vault. If this line says the token, decryption worked; the file in
# git is ciphertext.
alert_token     = {{ hardening_alert_token }}
EOF
ok "$ROLE/templates/ - sshd drop-in, fail2ban jail, report"

# ---------------------------------------------------------------------------
# 6. the play
# ---------------------------------------------------------------------------
# This is what a role buys you. Everything the last three days did by hand,
# on any number of hosts, in six lines - and the six lines are readable by
# somebody who has never seen the role.
say "6. hardening.yml"

cat > hardening.yml <<'EOF'
---
# Day 15 - Days 11, 12 and 13 as one role, applied to every host in lab.
#
#   ansible-playbook hardening.yml --list-tags        what you can run alone
#   ansible-playbook hardening.yml --syntax-check
#   ansible-playbook hardening.yml --check --diff     what WOULD change
#   ansible-playbook hardening.yml                    do it
#   ansible-playbook hardening.yml                    changed=0, both hosts
#   ansible-playbook hardening.yml --limit node2      one host only
#
# Day 14's site.yml is still there and still works. Keeping the baseline and
# the hardening in separate playbooks is not tidiness: it means you can apply
# the policy to a host without also applying the lab's application state.

- name: Hardening baseline
  hosts: lab
  gather_facts: true

  roles:
    - role: hardening
      tags: [hardening]
EOF
ok "hardening.yml"

# ---------------------------------------------------------------------------
# 7. prove it, in the order you would prove anything
# ---------------------------------------------------------------------------
say "7. checking the work"

info "ansible-inventory --graph"
ansible-inventory --graph | sed 's/^/        /'

info "ansible lab -m ping"
ansible lab -m ping | sed 's/^/        /' || die "the ping module failed on at least one host - see above"

info "ansible-playbook hardening.yml --syntax-check"
ansible-playbook hardening.yml --syntax-check >/dev/null || die "hardening.yml does not parse"
ok "syntax is valid"

info "ansible-playbook hardening.yml --list-tags"
ansible-playbook hardening.yml --list-tags | sed 's/^/        /'

info "ansible-playbook hardening.yml --check --diff   (nothing changed yet)"
ansible-playbook hardening.yml --check --diff > /tmp/day15-check.log 2>&1 || true
grep -E '^(TASK|changed:|ok:|fatal:|node[12]|PLAY RECAP)' /tmp/day15-check.log | head -40 | sed 's/^/        /'
printf '\n'
note "full dry run in /tmp/day15-check.log"
note "a --check run on a clean host reports failures for tasks that read a file"
note "another task was supposed to create. That is check mode being honest, not a bug"

info "ansible-playbook hardening.yml   (for real)"
if ansible-playbook hardening.yml > /tmp/day15-run1.log 2>&1; then
	grep -E '^(node1|node2|PLAY RECAP)' /tmp/day15-run1.log | sed 's/^/        /'
	ok "first run finished on both hosts"
else
	tail -40 /tmp/day15-run1.log >&2
	die "the first run failed - the tail of /tmp/day15-run1.log is above"
fi

info "ansible-playbook hardening.yml   (again - the real test)"
ansible-playbook hardening.yml > /tmp/day15-run2.log 2>&1 || true
grep -E '^(node1|node2|PLAY RECAP)' /tmp/day15-run2.log | sed 's/^/        /'
if [[ "$(grep -c 'changed=0' /tmp/day15-run2.log)" -ge 2 ]]; then
	ok "changed=0 on both hosts - one role, two hosts, no drift"
else
	printf '  !!    a second run still reported changes. Find the task:\n'
	printf '        grep -B3 "^changed:" /tmp/day15-run2.log\n'
fi

# ---------------------------------------------------------------------------
# 8. the payload
# ---------------------------------------------------------------------------
say "8. installing lab-harden"

sudo install -m 0755 "$SCRIPT_DIR/lab-harden.sh" /usr/local/bin/lab-harden
ok "/usr/local/bin/lab-harden - the only root action in this script, and it is a file copy"

cat <<EOF

Done. node2 was never touched by hand and now matches node1's policy.

Next:
  lab-harden                                      both hosts, side by side
  lab-harden node2                                one host, in detail
  lab-harden drift                                what a run would change now
  ~/lab/days/day15/scripts/explore-roles.sh       twelve read-only stops
  ~/lab/days/day15/scripts/break-and-fix.sh       five ways a role lies to you
  ~/lab/days/day15/verify.sh                      eight checks, two for you

Run verify.sh as yourself. Not with sudo.
EOF
