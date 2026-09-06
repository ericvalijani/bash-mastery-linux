#!/usr/bin/env bash
#
# Day 18 — Bridges, VLANs and link aggregation
# Run this on: Host: network namespaces
#
# Exits 0 only when every automatic check passes. Items printed as
# YOU are judgement calls and never affect the exit status.

set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=../../lab/verify-lib.sh
source "../../lab/verify-lib.sh"

vl_init "Day 18 — Bridges, VLANs and link aggregation"
vl_need ip
vl_need_root

vl_check "a bridge exists in the router namespace" 'ip netns exec router ip -d link show type bridge | grep -q "br0"'
vl_check "a VLAN interface with a tag exists" 'ip netns exec router ip -d link show | grep -q "vlan id 10"'
vl_check "two hosts in the same VLAN can reach each other" 'ip netns exec client ping -c1 -W2 10.30.10.3'
vl_check "a host in a different VLAN cannot" '! ip netns exec client ping -c1 -W2 10.30.20.3'
vl_check "the bridge has interfaces enslaved to it" 'ip netns exec router ip link show master br0 | grep -q .'
vl_manual "you can explain tagged versus untagged from the bridge vlan output"

vl_summary
