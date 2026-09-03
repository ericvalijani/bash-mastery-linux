#!/usr/bin/env bash
#
# Day 01 — systemd and the boot path
# Run this on: VM: control
#
# Exits 0 only when every automatic check passes. Items printed as
# YOU are judgement calls and never affect the exit status.

set -uo pipefail
cd "$(dirname "$0")"
# shellcheck source=../../lab/verify-lib.sh
source "../../lab/verify-lib.sh"

vl_init "Day 01 — systemd and the boot path"
vl_need systemctl

vl_check "a custom unit is installed and enabled" 'systemctl is-enabled lab-demo.service'
vl_check "that unit is running" 'systemctl is-active lab-demo.service'
vl_check "the machine boots with no failed units" '[ "$(systemctl list-units --failed --no-legend | wc -l)" -eq 0 ]'
vl_check "the unit restarts itself after being killed" 'grep -qE "^Restart=" /etc/systemd/system/lab-demo.service'
vl_manual "you can read systemd-analyze critical-chain and name the slowest unit"

vl_summary
