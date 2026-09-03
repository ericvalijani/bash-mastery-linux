#!/usr/bin/env bash
#
# Day 01 - install lab-demo.service.
#
#   sudo ./scripts/setup.sh
#
# Safe to run again at any time. It overwrites its own files, so it is also the
# way back to a known-good state if you break something.

set -euo pipefail

# /usr/local/bin: the correct home for scripts an admin installed by hand. No
# package manager will ever touch it.
#
# /etc/systemd/system: for units YOU wrote. Package units live in
# /usr/lib/systemd/system. When the same name exists in both, /etc wins.
BIN_DIR="/usr/local/bin"
UNIT_DIR="/etc/systemd/system"
SERVICE="lab-demo"
UNIT="$UNIT_DIR/$SERVICE.service"

HERE="$(cd "$(dirname "$0")" && pwd)"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
	echo "this installs a system service, so it needs root:  sudo $0" >&2
	exit 1
fi

say() { printf '\n==> %s\n' "$*"; }

say "installing the payload"
install -m 0755 "$HERE/lab-demo.sh" "$BIN_DIR/$SERVICE"
ls -l "$BIN_DIR/$SERVICE"

# SELinux gives a new file the type of its parent directory, which is usually
# right. This makes it certainly right, and costs nothing. Day 13 is where
# this stops being a one-liner you copy and starts being something you read.
if command -v restorecon >/dev/null; then
	restorecon -v "$BIN_DIR/$SERVICE" || true
fi

say "writing $UNIT"

# The heredoc is unquoted so $BIN_DIR/$SERVICE expands. Comments in here are
# short on purpose: they end up inside the installed unit, and a real unit
# file should stay readable. The long explanations live in this script.
cat > "$UNIT" <<UNIT
[Unit]
Description=Bash Mastery Linux demo service (Day 01)
# After= is ordering only. If you truly need the network, add Wants= too -
# and we do, because Wants without After would let us start too early.
After=network-online.target
Wants=network-online.target

[Service]
# simple: the process we start IS the service. Active as soon as it forks.
Type=simple
ExecStart=$BIN_DIR/$SERVICE
# Without Restart=, a crashed service stays dead and nothing tells you.
Restart=always
RestartSec=2
# No reason for this to be root. "It works as root" is where incidents begin.
User=nobody
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes

[Install]
WantedBy=multi-user.target
UNIT

# Note what is NOT in that unit: Group=. User=nobody already brings nobody's
# primary group with it, and hardcoding a group name is one more thing that can
# differ between distributions for no benefit.

say "reloading systemd"
# systemd has no idea the file changed until you say this. Editing a unit and
# then wondering why nothing happened is a rite of passage.
systemctl daemon-reload

# If a previous run left the unit failed - or you tripped its start limit with
# break-and-fix.sh - it will refuse to start until the failure is cleared.
systemctl reset-failed "$SERVICE" 2>/dev/null || true

say "enabling and starting"
# --now does both halves at once, but they are separate ideas: enabled means
# "start at boot", active means "running right now". Either without the other
# is a normal state, and both surprise people.
systemctl enable --now "$SERVICE"

say "state"
systemctl status "$SERVICE" --no-pager --lines=5 || true

say "the symlink that is all \"enabled\" really means"
ls -l "$UNIT_DIR/multi-user.target.wants/$SERVICE.service" || true

cat <<NEXT

==> installed. Look at your own work before moving on:

  systemctl status $SERVICE
  journalctl -u $SERVICE -f      # ctrl-c to stop following
  systemctl cat $SERVICE         # the unit as systemd parsed it
  systemctl show $SERVICE | wc -l  # every property, including defaults

Then:  ./scripts/explore-boot.sh
Then:  sudo ./scripts/break-and-fix.sh

NEXT
