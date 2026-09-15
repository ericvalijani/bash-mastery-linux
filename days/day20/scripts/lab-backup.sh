#!/usr/bin/env bash
#
# lab-backup - one place for today's backup, its schedule and its drill.
#
#   lab-backup status      repository, schedule, last run, last restore time
#   lab-backup run         take a snapshot, then apply the retention policy
#   lab-backup snapshots   what is in the repository
#   lab-backup drill       restore into a scratch tree, diff it, and time it
#   lab-backup check       ask restic to verify the repository's integrity
#   lab-backup forget      apply the retention policy on its own
#   lab-backup unlock      remove a stale lock left by a killed run
#
# Installed by setup.sh as /usr/local/bin/lab-backup. Also the ExecStart of
# restic-backup.service, which is why 'run' has to work with no terminal, no
# shell environment and no interactive password prompt.

set -uo pipefail

DATA="/srv/data"
CONF_DIR="/etc/restic"
ENV_FILE="$CONF_DIR/env"
RESTORE="/var/tmp/restore"
TIMING="/var/lib/lab-backup/last-restore-seconds"
HOSTTAG="$(hostname -s)"

hdr()  { printf '\n== %s\n\n' "$*"; }
line() { printf '  %s\n' "$*"; }

need_root() {
	if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
		printf 'needs root: sudo lab-backup %s\n' "${1:-}" >&2
		exit 1
	fi
}

# The environment comes from the file, not from whoever's shell called this.
# systemd passes it through EnvironmentFile; a human at a prompt has nothing.
load_env() {
	if [[ ! -r "$ENV_FILE" ]]; then
		printf 'no %s - run scripts/setup.sh first\n' "$ENV_FILE" >&2
		exit 1
	fi
	set -a
	# shellcheck disable=SC1090
	source "$ENV_FILE"
	set +a
}

cmd_status() {
	need_root status
	load_env

	hdr "the repository"
	line "RESTIC_REPOSITORY   : ${RESTIC_REPOSITORY:-unset}"
	line "RESTIC_PASSWORD_FILE: ${RESTIC_PASSWORD_FILE:-unset}"
	if [[ -n "${RESTIC_PASSWORD_FILE:-}" && -f "${RESTIC_PASSWORD_FILE}" ]]; then
		line "password file       : $(stat -c '%a %U:%G' "$RESTIC_PASSWORD_FILE")"
	fi
	if restic snapshots >/dev/null 2>&1; then
		line "reachable           : yes"
	else
		line "reachable           : NO - try: sudo lab-backup snapshots"
	fi

	hdr "what is protected"
	line "$DATA: $(find "$DATA" -type f 2>/dev/null | wc -l) files, $(du -sh "$DATA" 2>/dev/null | cut -f1)"

	hdr "snapshots"
	restic snapshots --compact 2>/dev/null | tail -8 | sed 's/^/  /'

	hdr "the schedule"
	line "timer enabled : $(systemctl is-enabled restic-backup.timer 2>/dev/null)"
	line "timer active  : $(systemctl is-active restic-backup.timer 2>/dev/null)"
	line "last trigger  : $(systemctl show restic-backup.timer -p LastTriggerUSec --value 2>/dev/null)"
	line "last run exit : $(systemctl show restic-backup.service -p ExecMainStatus --value 2>/dev/null)"
	systemctl list-timers restic-backup.timer --no-pager 2>/dev/null | sed -n '1,3p' | sed 's/^/  /'

	hdr "the number that matters"
	if [[ -r "$TIMING" ]]; then
		line "last measured restore: $(cat "$TIMING")s for $(du -sh "$DATA" 2>/dev/null | cut -f1)"
	else
		line "no restore has ever been timed here. Run: sudo lab-backup drill"
	fi
}

cmd_run() {
	need_root run
	load_env

	hdr "backing up $DATA"
	# --tag is not decoration: it is how you find this host's snapshots in a
	# repository that several hosts write to.
	restic backup "$DATA" --tag day20 --tag "$HOSTTAG" --host "$HOSTTAG" || return 1

	hdr "retention"
	# Retention is part of the backup, not a chore for later. Without it the
	# repository grows until the disk it lives on fills, and a full disk is
	# how a working backup stops being one.
	restic forget \
		--keep-last 3 \
		--keep-daily 7 \
		--keep-weekly 4 \
		--keep-monthly 6 \
		--prune || return 1
}

cmd_snapshots() {
	need_root snapshots
	load_env
	hdr "snapshots in ${RESTIC_REPOSITORY:-the repository}"
	restic snapshots 2>&1 | sed 's/^/  /'
}

cmd_check() {
	need_root check
	load_env
	hdr "integrity"
	line "restic check reads the metadata and verifies it hangs together."
	line "Add --read-data to read every byte back - slow, and the only"
	line "version of this that proves the storage is not lying to you."
	printf '\n'
	restic check 2>&1 | sed 's/^/  /'
}

cmd_forget() {
	need_root forget
	load_env
	hdr "applying the retention policy"
	restic forget --keep-last 3 --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune 2>&1 | sed 's/^/  /'
}

cmd_unlock() {
	need_root unlock
	load_env
	hdr "locks"
	restic list locks 2>&1 | sed 's/^/  /'

	# A lock is a small file naming the host, the pid and whether it is
	# exclusive. Print that before removing anything: it answers "whose lock
	# is this", which decides whether removing it is safe or reckless.
	for _id in $(restic list locks 2>/dev/null | grep -E '^[0-9a-f]{8,}$' || true); do
		line "lock ${_id:0:8} belongs to:"
		restic cat lock "$_id" 2>/dev/null | sed 's/^/    /'
	done
	line "removing stale locks"
	restic unlock 2>&1 | sed 's/^/  /'

	# `restic unlock` only removes locks it can prove are stale: same host,
	# and a pid that is no longer running. A lock written by a process that
	# restic cannot rule out - another host, or a pid that has since been
	# reused - survives, and then every backup after it refuses. Escalating
	# needs a decision, so make it explicitly rather than pretending the
	# first unlock worked.
	LEFT="$(restic list locks 2>/dev/null | grep -c . || true)"
	[[ -n "$LEFT" ]] || LEFT=0
	if [[ "$LEFT" -eq 0 ]]; then
		line "no locks left"
		return 0
	fi

	line "$LEFT lock(s) survived - restic will not call them stale"
	if systemctl is-active --quiet restic-backup.service 2>/dev/null; then
		line "restic-backup.service is running right now, so that lock is"
		line "real. Wait for it to finish rather than removing it."
		return 0
	fi

	# A lock with a live owner is not stale and must not be removed: the
	# owner will simply take it again, and meanwhile `restic check` and every
	# scheduled run fail. Look for the process before removing anything.
	if pgrep -f "restic backup" >/dev/null 2>&1; then
		line "a restic backup is running on this host right now:"
		pgrep -af restic | sed 's/^/  /'
		line "that lock has a live owner, so it is not stale. Wait for it, or"
		line "end that process first - removing the lock under a running backup"
		line "just gets it re-taken a second later."
		return 0
	fi

	line "nothing is backing up on this host, so the lock owns nothing"
	line "removing every lock (restic unlock --remove-all)"
	restic unlock --remove-all 2>&1 | sed 's/^/  /'
	restic list locks 2>&1 | sed 's/^/  /'
	line "only do that when you know no backup is in flight anywhere -"
	line "on a shared repository, another host may hold a live lock."
}

cmd_drill() {
	need_root drill
	load_env

	hdr "the restore drill"
	line "source : $DATA"
	line "target : $RESTORE"

	# Restore into an empty tree every time. Restoring on top of an old
	# restore is how a missing file passes a diff.
	rm -rf "$RESTORE"
	mkdir -p "$RESTORE"

	START="$(date +%s)"
	if ! restic restore latest --target "$RESTORE" >/tmp/lab-backup-restore.log 2>&1; then
		sed 's/^/  /' /tmp/lab-backup-restore.log
		line "the restore itself failed - nothing to compare"
		return 1
	fi
	END="$(date +%s)"
	SECS=$((END - START))

	line "restored in ${SECS}s"

	hdr "does it actually match"
	# restic restores the absolute path, so the copy of /srv/data lands at
	# $RESTORE/srv/data. diff -r compares content; the exit status is the
	# only opinion that counts.
	if diff -r "$DATA" "$RESTORE$DATA" >/tmp/lab-backup-diff.log 2>&1; then
		line "identical: every file, every byte"
	else
		line "DIFFERENT - this is what an untested backup looks like:"
		sed 's/^/    /' /tmp/lab-backup-diff.log | head -20
		return 1
	fi

	# Permissions are data too. A restore that gets the bytes right and the
	# mode wrong hands you a world-readable secret.
	SRC_MODE="$(stat -c '%a %U:%G' "$DATA/conf/token" 2>/dev/null)"
	DST_MODE="$(stat -c '%a %U:%G' "$RESTORE$DATA/conf/token" 2>/dev/null)"
	if [[ "$SRC_MODE" == "$DST_MODE" ]]; then
		line "permissions preserved: $DST_MODE"
	else
		line "PERMISSIONS CHANGED: $SRC_MODE became $DST_MODE"
		return 1
	fi

	install -d -m 0755 "$(dirname "$TIMING")"
	printf '%s\n' "$SECS" >"$TIMING"

	hdr "the answer to the only question asked during an outage"
	line "$(du -sh "$DATA" | cut -f1) came back in ${SECS}s."
	line "Written to $TIMING so you can quote it, and so the next drill can"
	line "be compared with this one."
	return 0
}

case "${1:-status}" in
status)    cmd_status ;;
run)       cmd_run ;;
snapshots) cmd_snapshots ;;
check)     cmd_check ;;
forget)    cmd_forget ;;
unlock)    cmd_unlock ;;
drill)     cmd_drill ;;
*) printf 'usage: lab-backup [status|run|snapshots|drill|check|forget|unlock]\n' >&2; exit 2 ;;
esac
