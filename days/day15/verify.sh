#!/usr/bin/env bash
#
# Day 15 — Ansible roles: your hardening baseline
# Run this on: control -> node1 + node2, as yourself, WITHOUT sudo
#
# Exits 0 only when every automatic check passes. Items printed as
# YOU are judgement calls and never affect the exit status.

set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=../../lab/verify-lib.sh
source "../../lab/verify-lib.sh"

PROJECT="${ANSIBLE_LAB_DIR:-$HOME/ansible-lab}"
P="cd '$PROJECT' &&"

vl_init "Day 15 — Ansible roles: your hardening baseline"
vl_need ansible-playbook ansible-inventory ansible-vault

# Same first check as Day 14, same reason: run this with sudo and every
# command below looks for the project and the key in /root.
vl_check "you are running this as yourself, not as root" '[ "${EUID:-$(id -u)}" -ne 0 ]'
vl_check "the role has the standard layout" "$P [ -f roles/hardening/tasks/main.yml ] && [ -f roles/hardening/defaults/main.yml ] && [ -f roles/hardening/handlers/main.yml ] && [ -d roles/hardening/templates ] && [ -f roles/hardening/meta/main.yml ]"
vl_check "both nodes answer a ping module" "$P ansible lab -m ping | grep -c SUCCESS | grep -qx 2"
vl_check "the playbook has valid syntax" "$P ansible-playbook hardening.yml --syntax-check"
vl_check "it applies to both nodes without failures" "$P ansible-playbook hardening.yml > /tmp/day15-verify1.log 2>&1 && [ \"\$(grep -c 'failed=0' /tmp/day15-verify1.log)\" -ge 2 ]"
vl_check "a second run is a no-op on both" "$P ansible-playbook hardening.yml > /tmp/day15-verify2.log 2>&1 && [ \"\$(grep -c 'changed=0' /tmp/day15-verify2.log)\" -ge 2 ]"
vl_check "node2 ends up enforcing SELinux too" "$P ansible node2 -m command -a getenforce | grep -q Enforcing"
vl_check "node2 ends up with password auth disabled" "$P ansible node2 -b -m shell -a 'sshd -T' | grep -qx 'passwordauthentication no'"
vl_check "the secret in the repo is ciphertext" "$P head -1 group_vars/lab/vault.yml | grep -q '^\\\$ANSIBLE_VAULT'"
vl_manual "you broke a setting on node1 by hand and --check found the drift"
vl_manual "you can explain why editing defaults/main.yml did not change node1's ports"

if [[ ${#VL_MISSING[@]} -gt 0 ]]; then
	printf '\n  missing: %s\n' "${VL_MISSING[*]}"
	printf '  run this on control, after: sudo dnf install -y ansible-core\n'
fi

vl_summary
