#!/usr/bin/env bash
#
# Day 03 — Processes, signals, cgroups v2 and limits
# Run this on: VM: node1
#
# Exits 0 only when every automatic check passes. Items printed as
# YOU are judgement calls and never affect the exit status.

set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=../../lab/verify-lib.sh
source "../../lab/verify-lib.sh"

vl_init "Day 03 — Processes, signals, cgroups v2 and limits"
vl_need systemctl

vl_check "cgroups v2 is the unified hierarchy" 'mount | grep -q "cgroup2 on /sys/fs/cgroup"'
vl_check "a service is capped with MemoryMax" 'systemctl show lab-cap.service -p MemoryMax | grep -qv "infinity"'
vl_check "the same service is capped with CPUQuota" 'systemctl show lab-cap.service -p CPUQuotaPerSecUSec | grep -qv "infinity"'
vl_check "a nofile limit is raised for one account only" 'grep -rqE "nofile" /etc/security/limits.d/'
vl_manual "you triggered the memory cap and found the kill in the journal"
vl_manual "you can explain why SIGKILL cannot be trapped"

vl_summary
