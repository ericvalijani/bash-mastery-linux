#!/usr/bin/env bash
#
# Day 15 — Ansible roles: your hardening baseline
# Run this on: control -> node1 + node2
#
# Exits 0 only when every automatic check passes. Items printed as
# YOU are judgement calls and never affect the exit status.

set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=../../lab/verify-lib.sh
source "../../lab/verify-lib.sh"

vl_init "Day 15 — Ansible roles: your hardening baseline"
vl_need ansible-playbook

vl_check "the role has the standard layout" '[ -d roles/hardening/tasks ] && [ -f roles/hardening/tasks/main.yml ]'
vl_check "it applies to both nodes without failures" 'ansible-playbook site.yml -l node1,node2 | grep -q "failed=0"'
vl_check "a second run is a no-op on both" '[ "$(ansible-playbook site.yml -l node1,node2 | grep -c "changed=0")" -ge 2 ]'
vl_check "node2 ends up enforcing SELinux too" 'ansible node2 -a "getenforce" | grep -q "Enforcing"'
vl_check "node2 ends up with password auth disabled" 'ansible node2 -a "sshd -T" | grep -qx "passwordauthentication no"'
vl_manual "you broke a setting on node1 by hand and --check found the drift"
vl_manual "secrets live in vault, not in the repo"

vl_summary
