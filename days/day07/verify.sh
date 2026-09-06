#!/usr/bin/env bash
#
# Day 07 — The DNS resolution path
# Run this on: Host: network namespaces
#
# Exits 0 only when every automatic check passes. Items printed as
# YOU are judgement calls and never affect the exit status.

set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=../../lab/verify-lib.sh
source "../../lab/verify-lib.sh"

vl_init "Day 07 — The DNS resolution path"
vl_need getent
vl_need_root

vl_check "nsswitch consults files before dns" 'grep -qE "^hosts:[[:space:]]+files" /etc/nsswitch.conf'
vl_check "a hosts entry beats DNS for the same name" 'ip netns exec client getent hosts lab.test | grep -q .'
vl_check "the client has a nameserver configured" 'ip netns exec client grep -q "nameserver" /etc/resolv.conf || ip netns exec client cat /etc/resolv.conf'
vl_check "dig and getent are both available to compare" 'command -v dig && command -v getent'
vl_manual "you can explain why dig ignored /etc/hosts and getent did not"
vl_manual "you followed one name from application call to authoritative answer"

vl_summary
