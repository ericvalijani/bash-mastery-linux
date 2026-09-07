#!/usr/bin/env bash
#
# The payload behind lab-app.service.
#
# Like Day 01's lab-demo it is deliberately boring, but with one difference
# that matters today: it WRITES somewhere. That single line is what turns
# permissions from a thing you read about into a thing that either works or
# does not.
#
# It runs as appsvc - a system account with no login shell - and appends to a
# directory owned by root:appdata that appsvc is not a member of. The only
# reason it can write there at all is the ACL that setup.sh grants it. Remove
# the ACL and this process starts failing within five seconds, which is the
# whole demonstration in break-and-fix.sh.

set -euo pipefail

SHARED="${LAB_SHARED_DIR:-/srv/shared}"
LOG="$SHARED/lab-app.log"

# Anything on stdout lands in the journal:  journalctl -u lab-app -f
echo "lab-app starting, pid $$, running as $(id -un) (uid $(id -u), groups: $(id -Gn))"
echo "writing to $LOG"

# systemctl stop sends SIGTERM. The trap only runs after the current
# foreground command finishes - ours is 'sleep 5' - so a stop can take up to
# five seconds to print this. Same surprise as Day 01, same reason.
trap 'echo "lab-app caught SIGTERM, exiting cleanly"; exit 0' TERM

count=0
while true; do
	count=$((count + 1))

	# No 'set -e' escape hatch here on purpose. If the write fails, the
	# service must DIE rather than carry on pretending, because a service
	# that silently stops recording is worse than one that is visibly down.
	# The failure you will see in the journal is:
	#   /srv/shared/lab-app.log: Permission denied
	printf '%s  tick %d  (uid %s)\n' "$(date --iso-8601=seconds)" "$count" "$(id -u)" >>"$LOG"

	echo "lab-app alive, pid $$, tick $count"
	sleep 5
done
