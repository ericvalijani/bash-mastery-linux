#!/usr/bin/env bash
#
# Day 01 teardown - remove everything setup.sh installed.
#
#   sudo ./scripts/teardown.sh
#
# You do not have to run this. Later days do not conflict with lab-demo, and
# leaving it running is a fine way to have something to look at. It is here so
# that "install, inspect, remove, verify it is gone" is a complete loop you can
# repeat - and because knowing how to cleanly remove a unit is a real skill.

set -euo pipefail

SERVICE="lab-demo"
UNIT="/etc/systemd/system/$SERVICE.service"
BIN="/usr/local/bin/$SERVICE"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
	echo "needs root:  sudo $0" >&2
	exit 1
fi

say() { printf '\n==> %s\n' "$*"; }

say "stopping and disabling $SERVICE"
# Both are allowed to fail: this script must work on a machine where the
# service was never installed, or was already half-removed.
systemctl disable --now "$SERVICE" 2>/dev/null || echo "(was not enabled)"
systemctl reset-failed "$SERVICE" 2>/dev/null || true

say "removing files"
rm -fv "$UNIT" "$UNIT.bak" "$BIN" 2>/dev/null || true

say "reloading systemd"
systemctl daemon-reload
# Drops the unit from systemd's memory once nothing references it. Without
# this, 'systemctl status lab-demo' can still show a stale not-found entry.
systemctl reset-failed 2>/dev/null || true

say "confirming it is gone"
if systemctl cat "$SERVICE" >/dev/null 2>&1; then
	echo "still present - something else installed a $SERVICE unit:" >&2
	systemctl cat "$SERVICE" | head -3 >&2
	exit 1
fi
echo "systemctl cat $SERVICE  ->  no such unit. clean."
echo
echo "the journal keeps its history on purpose. this still works:"
echo "  journalctl -u $SERVICE --no-pager | tail -5"
