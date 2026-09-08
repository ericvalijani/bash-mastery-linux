#!/usr/bin/env bash
#
# Day 05 - the payload behind lab-noisy.service.
#
#   lab-noisy run [logfile]       append one line per second, forever
#   lab-noisy burst N [logfile]   append N lines as fast as it can, then exit
#
# It writes to two places on purpose:
#
#   * a plain file under /var/log/lab-app  - logrotate's problem
#   * the journal, through logger(1)       - journald's problem
#
# The whole day is about the difference between those two, so the payload
# feeds both from the same loop and tags them identically.
#
# One detail matters more than it looks. The log file is opened ONCE, on
# file descriptor 3, and held for the life of the process:
#
#   exec 3>>"$LOG"
#
# That is what a real daemon does. It is also the reason a rotated log can
# keep growing after logrotate has renamed it: the rename changed the
# directory entry, not the descriptor this process is still writing down.
# break-and-fix.sh shows you exactly that, and it only works because of
# this line.

set -uo pipefail

TAG="lab-noisy"
MODE="${1:-run}"

usage() {
	echo "usage: $0 run [logfile]" >&2
	echo "       $0 burst <count> [logfile]" >&2
	exit 2
}

# Emit one line to both destinations. $1 is the sequence number.
emit() {
	printf '%s %s[%d]: message %d - the quick brown fox jumps over the lazy dog\n' \
		"$(date --iso-8601=seconds)" "$TAG" "$$" "$1" >&3
	logger -t "$TAG" "message $1"
}

case "$MODE" in
run)
	LOG="${2:-/var/log/lab-app/app.log}"
	mkdir -p "$(dirname "$LOG")" || exit 1

	# Open once, keep it. See the comment at the top of this file.
	exec 3>>"$LOG" || {
		echo "cannot write to $LOG" >&2
		exit 1
	}

	# Single-quoted so the trap body is expanded when the signal arrives,
	# not when the trap is installed (SC2064).
	trap 'echo "stopping" >&3; exec 3>&-; exit 0' TERM INT

	n=0
	while :; do
		n=$((n + 1))
		emit "$n"
		sleep 1
	done
	;;
burst)
	COUNT="${2:-}"
	[[ "$COUNT" =~ ^[0-9]+$ ]] || usage
	LOG="${3:-/var/log/lab-app/app.log}"
	mkdir -p "$(dirname "$LOG")" || exit 1

	exec 3>>"$LOG" || {
		echo "cannot write to $LOG" >&2
		exit 1
	}

	n=0
	while [ "$n" -lt "$COUNT" ]; do
		n=$((n + 1))
		emit "$n"
	done

	exec 3>&-
	echo "wrote $COUNT lines to $LOG and $COUNT to the journal"
	;;
*)
	usage
	;;
esac
