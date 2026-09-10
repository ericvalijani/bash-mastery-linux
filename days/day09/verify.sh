#!/usr/bin/env bash
#
# Day 09 - prove where a packet stops, instead of guessing.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../../lab/verify-lib.sh"

vl_init "Day 09 - packet-level debugging"
vl_need ip tcpdump ss ping
vl_need_root

CAP="/var/log/lab-trace/day09.pcap"

vl_check "all four namespaces from Day 06 are up" \
  'for n in client router resolver auth; do ip netns list | grep -qw "$n" || exit 1; done'

vl_check "the client reaches the auth namespace at 10.10.2.2" \
  'ip netns exec client ping -c1 -W2 10.10.2.2 >/dev/null 2>&1'

vl_check "ip route get names veth-cl as the way out of the client" \
  'ip netns exec client ip route get 10.10.2.2 | head -1 | grep -q "dev veth-cl"'

vl_check "the saved capture holds at least one ICMP packet" \
  'test -s '"$CAP"' && ip netns exec router tcpdump -nr '"$CAP"' icmp 2>/dev/null | grep -q "ICMP"'

vl_check "lab-trace reports requests and replies on the router leg" \
  'lab-trace 10.10.2.2 2>/dev/null | grep -qE "echo replies +[1-9]"'

vl_manual "you attributed a dropped packet to a specific hop, using a capture rather than a guess"
vl_manual "you lowered an MTU, broke a large transfer, and read the cause off the interface"

vl_summary
