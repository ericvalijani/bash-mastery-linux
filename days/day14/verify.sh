#!/usr/bin/env bash
#
# Day 14 — Ansible fundamentals
# Run this on: control -> node1
#
# Exits 0 only when every automatic check passes. Items printed as
# YOU are judgement calls and never affect the exit status.
#
# Run this as the lab user. NOT with sudo: as root, ~/.ssh is /root/.ssh,
# the inventory's key is not there, and every check fails as UNREACHABLE for
# a reason that has nothing to do with your work.

set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=../../lab/verify-lib.sh
source "../../lab/verify-lib.sh"

PROJECT="${ANSIBLE_LAB_DIR:-$HOME/ansible-lab}"

vl_init "Day 14 — Ansible fundamentals"
vl_need ansible ansible-playbook ansible-inventory
[[ -d "$PROJECT" ]] || VL_MISSING+=("$PROJECT")

vl_check "you are running this as yourself, not as root" '[ "$(id -u)" -ne 0 ]'
vl_check "the inventory parses" 'cd "'"$PROJECT"'" && ansible-inventory --list'
vl_check "node1 answers a ping module" 'cd "'"$PROJECT"'" && ansible node1 -m ping'
vl_check "the playbook has valid syntax" 'cd "'"$PROJECT"'" && ansible-playbook site.yml --syntax-check'
vl_check "a first run completes with no failures" 'cd "'"$PROJECT"'" && ansible-playbook site.yml > /tmp/day14-verify-1.log 2>&1 && grep -F "failed=0" /tmp/day14-verify-1.log'
vl_check "a second run changes nothing" 'cd "'"$PROJECT"'" && ansible-playbook site.yml > /tmp/day14-verify-2.log 2>&1 && grep -F "changed=0" /tmp/day14-verify-2.log'
vl_manual "--check predicted the same changes the real run made"
vl_manual "you can explain which module was not idempotent and why"

vl_summary
