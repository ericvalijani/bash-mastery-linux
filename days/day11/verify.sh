#!/usr/bin/env bash
#
# Day 11 — firewalld, and the nftables underneath it
# Run this on: VM: node1
#
# Exits 0 only when every automatic check passes. Items printed as
# YOU are judgement calls and never affect the exit status.

set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=../../lab/verify-lib.sh
source "../../lab/verify-lib.sh"

vl_init "Day 11 — firewalld, and the nftables underneath it"
vl_need firewall-cmd nft
vl_need_root

vl_check "firewalld is running and enabled" 'systemctl is-active firewalld && systemctl is-enabled firewalld'
vl_check "your service port is open" 'firewall-cmd --list-ports | grep -qE "(8080|443)/tcp"'
vl_check "the rule is permanent, not runtime only" 'firewall-cmd --permanent --list-ports | grep -qE "(8080|443)/tcp"'
vl_check "firewalld built a real nftables table" 'nft list tables | grep -q "table inet firewalld"'
vl_check "the default zone is not trusted" '[ "$(firewall-cmd --get-default-zone)" != "trusted" ]'
vl_manual "you reloaded and the rules survived, and you can point to each chain"

vl_summary
