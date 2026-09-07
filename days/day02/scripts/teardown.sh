#!/usr/bin/env bash
#
# Day 02 teardown - remove everything setup.sh created.
#
#   sudo ./scripts/teardown.sh
#
# You do not have to run this. Nothing in Days 03-20 conflicts with appsvc,
# /srv/shared or lab-app, and leaving them in place gives you a real service
# account to practise on. It exists so that "create, inspect, remove, prove it
# is gone" is a complete loop - and because removing an account cleanly is a
# skill in its own right. Half-deleted users leave files owned by a bare
# numeric uid, which the NEXT account created inherits by accident.
#
# Unlike Day 01's teardown, this one IS guarded by require_lab_vm. Day 01
# removed a unit file and a script; this deletes a user, a group and a
# directory tree, and /srv/shared is a plausible path on a real machine.

set -euo pipefail

# shellcheck source=../../../lab/on-lab-vm.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

SVC_USER="appsvc"
DATA_GROUP="appdata"
SHARED="/srv/shared"
SERVICE="lab-app"
UNIT="/etc/systemd/system/$SERVICE.service"
BIN="/usr/local/bin/$SERVICE"
SUDOERS="/etc/sudoers.d/$SVC_USER"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
	echo "needs root:  sudo $0" >&2
	exit 1
fi

say() { printf '\n==> %s\n' "$*"; }

say "stopping and disabling $SERVICE"
# Every step below is allowed to fail: this must work on a machine where
# setup.sh never finished, or was already half-undone.
systemctl disable --now "$SERVICE" 2>/dev/null || echo "(was not enabled)"
systemctl reset-failed "$SERVICE" 2>/dev/null || true

say "removing the unit and the payload"
rm -fv "$UNIT" "$UNIT.bak" "$BIN" 2>/dev/null || true
systemctl daemon-reload

say "removing the sudo rule"
# Order matters slightly: drop the privilege before deleting the account, so
# there is never a window where a rule names a uid that could be reissued.
rm -fv "$SUDOERS" "$SUDOERS.bak" 2>/dev/null || true

say "removing $SHARED"
ls -ld "$SHARED" 2>/dev/null || true
rm -rf "$SHARED"

say "removing the account"
if id "$SVC_USER" >/dev/null 2>&1; then
	# -r removes the home directory and mail spool too. Without it you leave
	# /var/lib/appsvc behind owned by a uid with no name.
	userdel -r "$SVC_USER" 2>/dev/null || userdel "$SVC_USER"
	echo "deleted $SVC_USER"
else
	echo "($SVC_USER was not present)"
fi

say "removing the group"
# groupdel refuses while the group is still someone's PRIMARY group, which is
# the correct behaviour and the reason the user goes first.
if getent group "$DATA_GROUP" >/dev/null; then
	groupdel "$DATA_GROUP" 2>/dev/null && echo "deleted $DATA_GROUP" \
		|| echo "could not delete $DATA_GROUP - it still has members:  getent group $DATA_GROUP"
else
	echo "($DATA_GROUP was not present)"
fi

say "confirming"
left=0
if id "$SVC_USER" >/dev/null 2>&1; then
	echo "still present: user $SVC_USER" >&2
	left=$((left + 1))
fi
if [[ -e "$SHARED" ]]; then
	echo "still present: $SHARED" >&2
	left=$((left + 1))
fi
if [[ -e "$SUDOERS" ]]; then
	echo "still present: $SUDOERS" >&2
	left=$((left + 1))
fi
if systemctl cat "$SERVICE" >/dev/null 2>&1; then
	echo "still present: $SERVICE unit" >&2
	left=$((left + 1))
fi

if [[ $left -gt 0 ]]; then
	echo
	echo "$left item(s) survived. That is a finding, not a bug - go and read why." >&2
	exit 1
fi

echo "user, group, directory, sudo rule and unit are all gone. clean."
echo
echo "note that deleting the group also deleted your own membership of it -"
echo "membership is stored on the group, not on the user. Your current shell"
echo "still lists it until you log out, because groups are read at login:"
echo "  id -Gn        # this shell, from login time"
echo "  id -Gn \$USER  # re-read now"
echo
echo "the journal keeps the service's history on purpose. this still works:"
echo "  journalctl -u $SERVICE --no-pager | tail -5"
