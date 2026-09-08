#!/usr/bin/env bash
#
# Day 03 teardown - remove everything setup.sh created.
#
#   sudo ./scripts/teardown.sh
#
# You do not have to run this. Nothing in Days 04-20 conflicts with lab-cap or
# labworker. It exists so that "create, inspect, remove, prove it is gone" is a
# complete loop, and because two of the things it removes are easy to leave
# behind by accident:
#
#   - a drop-in under /etc/systemd/system/lab-cap.service.d/, which survives
#     deleting the unit file and then makes a future unit of the same name
#     behave strangely
#   - a file in /etc/security/limits.d/, which applies to every future login
#     of that account and is read by nothing you would think to check
#
# Guarded by require_lab_vm like Day 02's, because it deletes an account and
# writes under /etc.

set -euo pipefail

# shellcheck source=../../../lab/on-lab-vm.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

SERVICE="lab-cap"
UNIT="/etc/systemd/system/$SERVICE.service"
DROPIN_DIR="/etc/systemd/system/$SERVICE.service.d"
CONTROL_DIR="/etc/systemd/system.control/$SERVICE.service.d"
BIN="/usr/local/bin/$SERVICE"
WORK_USER="labworker"
LIMITS="/etc/security/limits.d/90-lab-nofile.conf"

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

say "removing the unit, its drop-ins, and the payload"
rm -fv "$UNIT" "$BIN" 2>/dev/null || true

# The two override directories, which live in different places for different
# reasons: .d is where you and break-and-fix.sh write drop-ins by hand;
# system.control is where 'systemctl set-property' writes them for you.
for d in "$DROPIN_DIR" "$CONTROL_DIR"; do
	if [[ -d "$d" ]]; then
		rm -rfv "${d:?}"
	else
		echo "(no $d)"
	fi
done
systemctl daemon-reload

say "removing the login limit"
rm -fv "$LIMITS" 2>/dev/null || true

say "removing the account"
if id "$WORK_USER" >/dev/null 2>&1; then
	# -r takes the home directory and mail spool with it. Without it you
	# leave /home/labworker behind owned by a uid with no name, which the
	# next account created will inherit.
	userdel -r "$WORK_USER" 2>/dev/null || userdel "$WORK_USER"
	echo "deleted $WORK_USER"
else
	echo "($WORK_USER was not present)"
fi

say "confirming"
left=0
if systemctl cat "$SERVICE" >/dev/null 2>&1; then
	echo "still present: $SERVICE unit or a drop-in" >&2
	left=$((left + 1))
fi
if [[ -e "$BIN" ]]; then
	echo "still present: $BIN" >&2
	left=$((left + 1))
fi
if [[ -e "$LIMITS" ]]; then
	echo "still present: $LIMITS" >&2
	left=$((left + 1))
fi
if id "$WORK_USER" >/dev/null 2>&1; then
	echo "still present: user $WORK_USER" >&2
	left=$((left + 1))
fi
if [[ -d "/sys/fs/cgroup/system.slice/$SERVICE.service" ]]; then
	echo "still present: the service cgroup" >&2
	left=$((left + 1))
fi

if [[ $left -gt 0 ]]; then
	echo
	echo "$left item(s) survived. That is a finding, not a bug - go and read why." >&2
	exit 1
fi

echo "unit, drop-ins, payload, limit file and account are all gone. clean."
echo
echo "the cgroup went with the service and left no trace, because cgroups are"
echo "kernel state, not files on disk. nothing under /sys/fs/cgroup was ever"
echo "something you had to clean up:"
echo "  ls /sys/fs/cgroup/system.slice/ | head"
echo
echo "the journal keeps the whole history on purpose, including the oom kills:"
echo "  journalctl -u $SERVICE --no-pager | tail -20"
