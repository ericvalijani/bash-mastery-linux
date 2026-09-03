#!/usr/bin/env bash
#
# Day 14 — Ansible fundamentals
# Run this on: control -> node1
#
# Exits 0 only when every automatic check passes. Items printed as
# YOU are judgement calls and never affect the exit status.

set -uo pipefail
cd "$(dirname "$0")"
# shellcheck source=../../lab/verify-lib.sh
source "../../lab/verify-lib.sh"

vl_init "Day 14 — Ansible fundamentals"
vl_need ansible-playbook

vl_check "the inventory parses" 'ansible-inventory --list >/dev/null'
vl_check "node1 answers a ping module" 'ansible node1 -m ping'
vl_check "the playbook has valid syntax" 'ansible-playbook site.yml --syntax-check'
vl_check "a first run completes with no failures" 'ansible-playbook site.yml | grep -q "failed=0"'
vl_check "a second run changes nothing" 'ansible-playbook site.yml | grep -q "changed=0"'
vl_manual "--check predicted the same changes the real run made"
vl_manual "you can explain which module was not idempotent and why"

vl_summary
