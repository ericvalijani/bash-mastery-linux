#!/usr/bin/env bash
#
# Day 05 - remove what setup.sh created, in the order that works.
#
#   sudo ./scripts/teardown.sh
#
# Removes: the service and its unit, the payload, /var/log/lab-app and its
# rotations, and the logrotate rule.
#
# Deliberately does NOT remove: /var/log/journal, or the journald settings.
# Making the journal persistent is not "this day's mess" - it is a machine
# improvement, every later day benefits from it, and deleting a journal is
# the one thing in this repo you cannot undo. If you genuinely want it gone,
# the last section tells you how and makes you type it yourself.

set -uo pipefail

# shellcheck source=../../../lab/on-lab-vm.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

say() { printf '\n==> %s\n' "$*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
	echo "needs root:  sudo $0" >&2
	exit 1
}

SERVICE="lab-noisy.service"
UNIT="/etc/systemd/system/$SERVICE"
PAYLOAD="/usr/local/bin/lab-noisy"
APP_DIR="/var/log/lab-app"
ROTATE_RULE="/etc/logrotate.d/lab-app"

survivors=0

# ---------------------------------------------------------------------------
say "1. stop the writer first"
#
# Order matters here for the same reason it mattered on Day 04. Delete the
# log directory while the service still holds fd 3 open and you get the
# ghost-file situation on purpose: the blocks stay allocated until the
# process exits. Stop the writer, then remove its files.
# ---------------------------------------------------------------------------
if systemctl is-active "$SERVICE" >/dev/null 2>&1; then
	systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
	echo "  $SERVICE stopped and disabled"
else
	systemctl disable "$SERVICE" >/dev/null 2>&1 || true
	echo "  $SERVICE was not running"
fi

# ---------------------------------------------------------------------------
say "2. the unit and the payload"
# ---------------------------------------------------------------------------
if [ -f "$UNIT" ]; then
	rm -f "$UNIT"
	systemctl daemon-reload
	echo "  removed $UNIT"
else
	echo "  $UNIT already gone"
fi

if [ -f "$PAYLOAD" ]; then
	rm -f "$PAYLOAD"
	echo "  removed $PAYLOAD"
else
	echo "  $PAYLOAD already gone"
fi

# ---------------------------------------------------------------------------
say "3. the file log and its rotations"
# ---------------------------------------------------------------------------
if [ -d "$APP_DIR" ]; then
	echo "  what is there:"
	ls -l "$APP_DIR" | sed 's/^/    /'
	# SC2115: never a bare "$x/" - an empty variable would make this rm -rf /
	rm -rf "${APP_DIR:?}"
	echo "  removed $APP_DIR"
else
	echo "  $APP_DIR already gone"
fi

if [ -f "$ROTATE_RULE" ]; then
	rm -f "$ROTATE_RULE"
	echo "  removed $ROTATE_RULE"
else
	echo "  $ROTATE_RULE already gone"
fi

# logrotate keeps a note about every file it has ever rotated. Leaving a
# stale entry there is harmless, but it is worth seeing that the memory is
# separate from the rule.
if grep -q 'lab-app' /var/lib/logrotate/logrotate.status 2>/dev/null; then
	echo
	echo "  note: logrotate still remembers this file in its status database:"
	grep 'lab-app' /var/lib/logrotate/logrotate.status | sed 's/^/    /'
	echo "  harmless. it is cleaned up the next time logrotate runs."
fi

# ---------------------------------------------------------------------------
say "4. prove it is gone"
# ---------------------------------------------------------------------------
check_gone() {
	if [ -e "$1" ]; then
		echo "  STILL THERE: $1"
		survivors=$((survivors + 1))
	else
		echo "  gone: $1"
	fi
}

check_gone "$UNIT"
check_gone "$PAYLOAD"
check_gone "$APP_DIR"
check_gone "$ROTATE_RULE"

if systemctl list-unit-files "$SERVICE" 2>/dev/null | grep -q "$SERVICE"; then
	echo "  STILL THERE: $SERVICE is still known to systemd"
	survivors=$((survivors + 1))
else
	echo "  gone: systemd no longer knows $SERVICE"
fi

# ---------------------------------------------------------------------------
say "what deliberately survives"
# ---------------------------------------------------------------------------
cat <<'EOF'

  /var/log/journal              the journal itself, and all its history
  /etc/systemd/journald.conf    Storage=persistent, SystemMaxUse=200M
  chronyd, the timezone         the clock stays correct

Those are not leftovers, they are the parts of today worth keeping, and
Days 06-20 all read logs. Note the consequence: everything the noisy service
ever logged is STILL in the journal, even though the service, its unit and
its file log are all gone.

  journalctl -t lab-noisy | tail -3

That is the difference between the two systems in one command. Deleting a
program does not delete its journal.

If you really want the journal history gone as well - and on a real machine
think hard first, because this is not recoverable:

  sudo journalctl --rotate
  sudo journalctl --vacuum-time=1s
EOF

echo
if [ "$survivors" -eq 0 ]; then
	say "clean"
else
	say "$survivors item(s) survived teardown"
	echo "  That is a finding, not a bug - go and read why."
	echo "  Start with: systemctl status $SERVICE"
fi
