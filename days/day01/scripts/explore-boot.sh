#!/usr/bin/env bash
#
# Day 01 - a guided tour of the boot path. Read-only, no root needed, safe to
# run as often as you like.
#
#   ./scripts/explore-boot.sh
#
# Every command here is one you should end up typing from memory. The script
# only puts them in a sensible order and says what you are looking at.

set -euo pipefail

heading() {
	printf '\n===============================================================\n'
	printf '  %s\n' "$1"
	printf '===============================================================\n'
}

note() { printf '  (%s)\n\n' "$1"; }

# Print the command, then its output, indented. Nothing is allowed to abort
# the tour, so every command may fail - be much stricter than this in scripts
# that actually do something.
run() {
	printf '$ %s\n' "$*"
	"$@" 2>&1 | sed 's/^/  /' || true
	printf '\n'
}

# Same, but for commands with long output.
run_top() {
	local lines="$1"; shift
	printf '$ %s\n' "$*"
	"$@" 2>&1 | sed 's/^/  /' | head -n "$lines" || true
	printf '  ... (first %s lines - run it yourself for the rest)\n\n' "$lines"
}

heading "1. how long did this boot take?"
note "kernel time is firmware handing over; userspace is systemd own work"
run systemd-analyze time

heading "2. the slowest units, worst first"
note "honest but misleading: slow units often ran in PARALLEL, so fixing the top entry may not shorten the boot at all"
run_top 12 systemd-analyze blame

heading "3. the critical chain - the part that actually gates boot"
note "@ means started-at, + means took-this-long. THIS is the list to optimise, not blame"
run systemd-analyze critical-chain

heading "4. did anything fail?"
note "a healthy machine prints 0 loaded units here. if it does not, that is your afternoon"
run systemctl list-units --failed --no-pager

heading "5. errors from this boot only"
note "-b is this boot, -p err is error and worse. the single most useful journalctl there is"
run_top 20 journalctl -b -p err --no-pager

heading "6. what does the default target pull in?"
note "targets are not scripts, they are grouping points"
run systemctl get-default
run_top 15 systemctl list-dependencies multi-user.target --no-pager

heading "7. our own service, three ways"
note "cat = the unit file as systemd parsed it, including any drop-ins"
run systemctl cat lab-demo.service

note "status = current state plus the tail of the journal"
run systemctl status lab-demo.service --no-pager --lines=5

note "show = the properties you set, alongside the ones you inherited"
run systemctl show lab-demo.service --property=Id,Type,Restart,RestartSec,User,NRestarts,ExecMainPID,ActiveState,SubState,UnitFileState

heading "8. the cgroup our service lives in"
note "every service gets one. this is the hook that makes Day 03 possible: limits are set on the cgroup, and systemd owns the cgroup"
run systemctl show lab-demo.service --property=ControlGroup
run systemd-cgls --no-pager /system.slice/lab-demo.service

cat <<'NEXT'
===============================================================
  now do these by hand
===============================================================

  systemd-analyze critical-chain sshd.service
      the chain for one unit instead of the whole target

  systemctl list-units --type=service --state=running
      what is actually running on this machine right now

  journalctl -u lab-demo --since "10 minutes ago"
      also accepts "today", "yesterday", "2 hours ago"

  systemctl list-unit-files --state=enabled
      everything that starts at next boot. anything you do not
      recognise is worth ten minutes

  systemd-analyze verify /etc/systemd/system/lab-demo.service
      a linter for unit files. it catches typos that systemd
      itself will ignore in complete silence

NEXT
