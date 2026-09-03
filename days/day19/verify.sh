#!/usr/bin/env bash
#
# Day 19 — Intrusion detection and audit alerting
# Run this on: VM: node1
#
# Exits 0 only when every automatic check passes. Items printed as
# YOU are judgement calls and never affect the exit status.

set -uo pipefail
cd "$(dirname "$0")"
# shellcheck source=../../lab/verify-lib.sh
source "../../lab/verify-lib.sh"

vl_init "Day 19 — Intrusion detection and audit alerting"
vl_need suricata auditctl

vl_check "suricata config passes its own test" 'suricata -T -c /etc/suricata/suricata.yaml >/dev/null'
vl_check "suricata is running and enabled" 'systemctl is-active suricata && systemctl is-enabled suricata'
vl_check "at least one alert has been written" 'grep -q "alert" /var/log/suricata/eve.json'
vl_check "auditd watches a sensitive file" 'auditctl -l | grep -q "/etc/shadow"'
vl_check "the audit rule is persistent" 'grep -rq "/etc/shadow" /etc/audit/rules.d/'
vl_check "an audit event was actually recorded" 'ausearch -k shadow_watch 2>/dev/null | grep -q "type=SYSCALL"'
vl_manual "you triggered your own rule on purpose and found the alert"
vl_manual "you tuned out one false positive and can justify it"

vl_summary
