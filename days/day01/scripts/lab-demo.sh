#!/usr/bin/env bash
#
# The payload behind lab-demo.service.
#
# Deliberately boring. Today is about the unit wrapped around it, not about
# what it does. It only has to be long-running, so systemd has something to
# supervise, kill and restart.
#
# Anything a service writes to stdout or stderr lands in the journal, which is
# why these echoes are findable with:  journalctl -u lab-demo -f

set -euo pipefail

# $$ is our own PID. Printing it at startup is what lets us prove later that a
# restart produced a genuinely different process.
echo "lab-demo starting, pid $$"

# systemctl stop sends SIGTERM, which we can catch. kill -9 sends SIGKILL,
# which nobody can catch. You will see both today.
#
# Note the delay: bash runs a trap only after the current foreground command
# finishes, and ours is 'sleep 5'. So a stop can take up to five seconds to
# print this line. That surprises people, and it is worth seeing once.
trap 'echo "lab-demo caught SIGTERM, exiting cleanly"; exit 0' TERM

count=0
while true; do
	count=$((count + 1))
	echo "lab-demo alive, pid $$, tick $count"
	sleep 5
done
