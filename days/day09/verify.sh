#!/usr/bin/env bash
#
# Day 09 — Packet-level debugging
# Run this on: Host: network namespaces
#
# Exits 0 only when every automatic check passes. Items printed as
# YOU are judgement calls and never affect the exit status.

set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=../../lab/verify-lib.sh
source "../../lab/verify-lib.sh"

vl_init "Day 09 — Packet-level debugging"
vl_need tcpdump ip
vl_need_root

vl_check "tcpdump can capture on a router interface" 'ip netns exec router timeout 3 tcpdump -c1 -ni any -w /tmp/lab.pcap; [ -s /tmp/lab.pcap ]'
vl_check "the capture contains packets" 'tcpdump -r /tmp/lab.pcap 2>/dev/null | grep -q .'
vl_check "ss reports the DNS listener" 'ip netns exec auth ss -ulpn | grep -q ":53"'
vl_check "ip route get names the outgoing interface" 'ip netns exec client ip route get 10.10.2.2 | grep -q "dev"'
vl_manual "you attributed a dropped packet to a specific hop"
vl_manual "you lowered an MTU, broke a transfer, and diagnosed it from the capture"

vl_summary
