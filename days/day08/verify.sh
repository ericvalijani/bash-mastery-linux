#!/usr/bin/env bash
#
# Day 08 — Running DNS: authoritative and recursive
# Run this on: Host: network namespaces
#
# Exits 0 only when every automatic check passes. Items printed as
# YOU are judgement calls and never affect the exit status.

set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=../../lab/verify-lib.sh
source "../../lab/verify-lib.sh"

vl_init "Day 08 — Running DNS: authoritative and recursive"
vl_need dig ip ss
vl_need_root

vl_check "something is listening on port 53 in the auth namespace" 'ip netns exec auth ss -ulpn | grep -q "10.10.2.2:53"'
vl_check "the zone answers with a SOA" 'ip netns exec client dig +short +time=2 +tries=1 SOA lab.test. @10.10.2.2 | grep -q "^ns.lab.test. admin.lab.test."'
vl_check "an A record resolves from the client" 'ip netns exec client dig +short +time=2 +tries=1 A www.lab.test @10.10.2.2 | grep -q "^10.10.2.10$"'
vl_check "the resolver namespace also answers for the zone" 'ip netns exec client dig +short +time=2 +tries=1 A www.lab.test @10.10.1.2 | grep -q "^10.10.2.10$"'
vl_check "an unknown name returns NXDOMAIN not an error" 'ip netns exec client dig +time=2 +tries=1 nope.lab.test @10.10.2.2 | grep -q "status: NXDOMAIN"'
vl_manual "you lowered a TTL and watched the cache expire"
vl_manual "you can name what REFUSED, SERVFAIL and NXDOMAIN each tell you"

vl_summary
