#!/usr/bin/env bash
#
# Day 20 - Backup, restore and the restore drill
# Run this on: node1, with sudo (control only holds the repository)
#
# Exits 0 only when every automatic check passes. Items printed as
# YOU are judgement calls and never affect the exit status.

set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=../../lab/verify-lib.sh
source "../../lab/verify-lib.sh"

vl_init "Day 20 - Backup, restore and the restore drill"
vl_need restic
vl_need_root

# The checks below run restic, so they need the same environment the service
# gets. Sourcing it here is deliberate: if this file is missing or wrong, every
# repository check fails, which is exactly the right answer.
if [[ -r /etc/restic/env ]]; then
	set -a
	# shellcheck disable=SC1091
	source /etc/restic/env
	set +a
fi

# The timer fires every ten minutes. While a scheduled backup writes, restic
# holds a lock on the repository, and `forget --prune` holds an exclusive one -
# which makes `restic snapshots` fail and leaves a lock in `restic list locks`.
# Verifying two seconds after a scheduled run would then report two failures
# for the healthiest possible reason. Wait for the live run to finish first.
if systemctl is-active --quiet restic-backup.service 2>/dev/null; then
	printf '  ..    a scheduled backup is running - waiting for it to finish\n'
	for _i in $(seq 1 60); do
		systemctl is-active --quiet restic-backup.service 2>/dev/null || break
		sleep 2
	done
fi

# --- the configuration -----------------------------------------------------
vl_check 'the repository environment file exists and is root-only' '[ -f /etc/restic/env ] && [ $(stat -c %a /etc/restic/env) = 600 ]'
vl_check 'the repository is on another host, not this one' 'grep -q ^RESTIC_REPOSITORY=sftp: /etc/restic/env'
vl_check 'the environment names a password file, not a password' 'grep -q ^RESTIC_PASSWORD_FILE= /etc/restic/env && ! grep -q ^RESTIC_PASSWORD= /etc/restic/env'
vl_check 'the password file exists and is 0600 root:root' '[ -s $RESTIC_PASSWORD_FILE ] && [ $(stat -c %a:%U:%G $RESTIC_PASSWORD_FILE) = 600:root:root ]'
vl_check 'the data being protected still exists' '[ -d /srv/data ] && [ $(find /srv/data -type f | wc -l) -ge 5 ]'

# --- the repository --------------------------------------------------------
# This one runs first, and on purpose. `restic check` below takes an
# EXCLUSIVE lock on the repository while it runs, so a check placed after it
# can end up reporting the lock this script took itself. Ask the question
# before doing anything that locks.
#
# Two traps in the check itself: `restic list locks` prints a blank line
# before its list, so `wc -l` says 1 when there are no locks at all - count
# lock IDs instead. And a lock belonging to a run that has just exited takes
# a moment to disappear, so retry for ten seconds before calling it stale.
vl_check 'no stale lock is holding the repository' 'for _i in 1 2 3 4 5; do [ "$(restic list locks 2>/dev/null | grep -cE "^[0-9a-f]{8,}$")" -eq 0 ] && exit 0; sleep 2; done; exit 1'
vl_check 'the repository exists and is readable' 'restic snapshots >/dev/null'
vl_check 'at least one snapshot exists' '[ $(restic snapshots --json | grep -c short_id) -ge 1 ]'
vl_check 'the repository passes an integrity check' 'restic check'
vl_check 'the latest snapshot contains the data path' 'restic ls latest | grep -q ^/srv/data'
vl_check 'the latest snapshot is not empty' '[ $(restic ls latest | grep -c ^/srv/data/) -ge 5 ]'

# --- the schedule ----------------------------------------------------------
vl_check 'the backup payload is installed and executable' '[ -x /usr/local/bin/lab-backup ]'
vl_check 'a retention policy is configured' 'grep -rq keep-daily /etc/systemd/system/ /usr/local/bin/ 2>/dev/null'
vl_check 'the retention policy prunes, not just forgets' 'grep -rq -- --prune /etc/systemd/system/ /usr/local/bin/ 2>/dev/null'
vl_check 'the backup service unit exists' '[ -f /etc/systemd/system/restic-backup.service ]'
vl_check 'the unit carries the repository in its own environment' 'systemctl cat restic-backup.service | grep -q ^EnvironmentFile='
vl_check 'the scheduled service has run and exited 0' '[ -n "$(systemctl show restic-backup.service -p ExecMainStartTimestamp --value)" ] && [ $(systemctl show restic-backup.service -p ExecMainStatus --value) = 0 ]'
vl_check 'backups run on a timer' 'systemctl is-enabled restic-backup.timer'
vl_check 'the timer is loaded and running right now' 'systemctl is-active restic-backup.timer'
vl_check 'the timer has actually fired at least once' 'systemctl show restic-backup.timer -p LastTriggerUSec | grep -qv =0$'

# --- the restore, which is the only proof that counts ----------------------
vl_check 'a restore reproduces the source tree exactly' 'diff -r /srv/data /var/tmp/restore/srv/data'
vl_check 'the restore preserved file permissions' '[ $(stat -c %a /srv/data/conf/token) = $(stat -c %a /var/tmp/restore/srv/data/conf/token) ]'

vl_manual 'you timed a full restore and can state the number in minutes'
vl_manual 'the repository password is not stored next to the repository'

vl_summary
