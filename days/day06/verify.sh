#!/usr/bin/env bash
#
# Day 06 — Interfaces, routing and building the namespace lab
# Run this on: Host: network namespaces
#
# Exits 0 only when every automatic check passes. Items printed as
# YOU are judgement calls and never affect the exit status.

set -uo pipefail
cd "$(dirname "$0")"
# shellcheck source=../../lab/verify-lib.sh
source "../../lab/verify-lib.sh"

vl_init "Day 06 — Interfaces, routing and building the namespace lab"
vl_need ip
vl_need_root

vl_check "all four namespaces exist" 'for n in client router resolver auth; do ip netns list | grep -qw "$n" || exit 1; done'
vl_check "the client has an address on 10.10.0.0/24" 'ip netns exec client ip -br addr | grep -q "10.10.0.2"'
vl_check "the router forwards IPv4" '[ "$(ip netns exec router sysctl -n net.ipv4.ip_forward)" = "1" ]'
vl_check "the client reaches the auth network through the router" 'ip netns exec client ping -c1 -W2 10.10.2.2'
vl_check "the client has a default route" 'ip netns exec client ip route | grep -q "^default"'
vl_manual "you can draw the topology from ip route output alone"

vl_summary
