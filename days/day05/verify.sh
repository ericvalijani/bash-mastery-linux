#!/usr/bin/env bash
#
# Day 05 — Logs and time: journald, logrotate and chrony
# Run this on: VM: node1
#
# Exits 0 only when every automatic check passes. Items printed as
# YOU are judgement calls and never affect the exit status.

set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=../../lab/verify-lib.sh
source "../../lab/verify-lib.sh"

vl_init "Day 05 — Logs and time: journald, logrotate and chrony"
vl_need chronyc

vl_check "the journal is persistent across reboots" '[ -d /var/log/journal ]'
vl_check "journal size is bounded" 'grep -qE "^SystemMaxUse=" /etc/systemd/journald.conf'
vl_check "the clock is synchronised" 'chronyc tracking | grep -q "Leap status.*Normal"'
vl_check "the timezone is set deliberately" 'timedatectl show -p Timezone --value | grep -q .'
vl_check "a logrotate rule exists for your own log" 'ls /etc/logrotate.d/ | grep -q .'
vl_manual "logrotate -d showed your rule doing what you intended"

vl_summary
