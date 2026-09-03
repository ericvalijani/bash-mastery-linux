#!/usr/bin/env bash
#
# Day 20 — Backup, restore and the restore drill
# Run this on: VM: control + node1
#
# Exits 0 only when every automatic check passes. Items printed as
# YOU are judgement calls and never affect the exit status.

set -uo pipefail
cd "$(dirname "$0")"
# shellcheck source=../../lab/verify-lib.sh
source "../../lab/verify-lib.sh"

vl_init "Day 20 — Backup, restore and the restore drill"
vl_need restic

vl_check "the repository exists and is readable" 'restic snapshots >/dev/null'
vl_check "at least one snapshot exists" '[ "$(restic snapshots --json | grep -c short_id)" -ge 1 ]'
vl_check "the repository passes an integrity check" 'restic check'
vl_check "a restore reproduces the source tree exactly" 'diff -r /srv/data /var/tmp/restore/srv/data'
vl_check "backups run on a timer" 'systemctl is-enabled restic-backup.timer'
vl_check "the timer has actually fired at least once" 'systemctl show restic-backup.timer -p LastTriggerUSec | grep -qv "=0$"'
vl_check "a retention policy is configured" 'grep -rq "keep-daily" /etc/systemd/system/ /usr/local/bin/ 2>/dev/null'
vl_manual "you timed a full restore and can state the number in minutes"
vl_manual "the repository password is not stored next to the repository"

vl_summary
