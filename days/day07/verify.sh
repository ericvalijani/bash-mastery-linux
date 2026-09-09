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
vl_need ip getent dig
vl_need_root

# Read from INSIDE the namespace, always. The host's /etc/nsswitch.conf is a
# different file, and checking it would pass whether the day was done or not.
vl_check "nsswitch consults files before dns" 'ip netns exec client grep -qE "^hosts:[[:space:]]+files[[:space:]]+dns" /etc/nsswitch.conf'

# The hosts entry and DNS deliberately disagree about this name, so the
# address is the whole check - a non-empty answer would prove nothing.
vl_check "a hosts entry beats DNS for the same name" 'ip netns exec client getent hosts www.lab.test | grep -q "^10.10.0.99"'

# Naming the address matters: "nameserver" anywhere in the file would also be
# matched by a comment, and by the host's own resolver configuration.
vl_check "the client has a nameserver configured" 'ip netns exec client grep -qE "^nameserver[[:space:]]+10.10.1.2" /etc/resolv.conf'

vl_check "the nameserver answers from the resolver namespace" 'ip netns exec client dig +short +time=2 +tries=1 auth.lab.test | grep -q "^10.10.2.2"'

vl_check "dig and getent are both available to compare" 'command -v dig && command -v getent'

vl_manual "you can explain why dig ignored /etc/hosts and getent did not"
vl_manual "you followed one name from application call to authoritative answer"

vl_summary
