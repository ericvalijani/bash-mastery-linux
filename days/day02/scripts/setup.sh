#!/usr/bin/env bash
#
# Day 02 - build the least-privilege setup this day is about.
#
#   sudo ./scripts/setup.sh
#
# It creates:
#   group  appdata          the shared-data group
#   user   appsvc           system account, no login shell, own primary group
#   dir    /srv/shared      root:appdata, 2770, with ACLs for appsvc
#   file   /etc/sudoers.d/appsvc   one command, and nothing else
#   unit   lab-app.service  runs as appsvc and writes into /srv/shared
#
# Safe to run again at any time: every step is written to converge on the same
# end state rather than to assume a clean machine. That is also what makes it
# the way back if you break something later.

set -euo pipefail

# This script changes system state, so it refuses to run anywhere but a
# disposable lab VM. See lab/on-lab-vm.sh for what counts as one.
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
SVC_HOME="/var/lib/$SVC_USER"

HERE="$(cd "$(dirname "$0")" && pwd)"

die() {
	echo "$*" >&2
	exit 1
}
say() { printf '\n==> %s\n' "$*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "this creates users and a system service, so it needs root:  sudo $0"

command -v setfacl >/dev/null 2>&1 || die "setfacl is missing. install it first:  sudo dnf install -y acl"

# ---------------------------------------------------------------- the group
say "the shared-data group: $DATA_GROUP"

# A group is the cheapest way to let several accounts share files. Create it
# before the directory, because the directory needs to be owned by it.
if getent group "$DATA_GROUP" >/dev/null; then
	echo "$DATA_GROUP already exists - leaving it alone"
else
	groupadd --system "$DATA_GROUP"
	echo "created $DATA_GROUP"
fi
getent group "$DATA_GROUP"

# The human account gets to be a member so you can drop files in by hand.
# Note what this does NOT do: it does not put appsvc in this group. That is
# the point of the ACL further down.
HUMAN="${SUDO_USER:-}"
if [[ -n "$HUMAN" ]] && id "$HUMAN" >/dev/null 2>&1; then
	usermod -aG "$DATA_GROUP" "$HUMAN"
	echo "added $HUMAN to $DATA_GROUP"
	echo "(your CURRENT shell does not have it yet - group membership is read at"
	echo " login, so run 'newgrp $DATA_GROUP' or log out and back in)"
fi

# ----------------------------------------------------------------- the user
say "the service account: $SVC_USER"

# --system  : a UID below SYS_UID_MAX (999 here), which by convention means
#             "not a person". Nothing enforces that; it is a signal to you.
# --shell   : /sbin/nologin is the whole point. Even if a password were
#             somehow set, a login attempt prints a refusal and exits. There
#             is no shell to hand out.
# --home-dir: services want a home for state and caches, even headless ones.
if id "$SVC_USER" >/dev/null 2>&1; then
	echo "$SVC_USER already exists - re-asserting its shell and home"
	usermod --shell /sbin/nologin --home "$SVC_HOME" "$SVC_USER"
else
	useradd --system \
		--shell /sbin/nologin \
		--home-dir "$SVC_HOME" \
		--create-home \
		--comment "Bash Mastery Linux Day 02 service account" \
		"$SVC_USER"
	echo "created $SVC_USER"
fi

install -d -m 0750 -o "$SVC_USER" -g "$SVC_USER" "$SVC_HOME"

echo
getent passwd "$SVC_USER"
id "$SVC_USER"
echo
echo "read that id output carefully: $SVC_USER is NOT in $DATA_GROUP."
echo "It will still write into $SHARED. The ACL below is why."

# ------------------------------------------------------------ the directory
say "the shared directory: $SHARED"

install -d "$SHARED"
chown root:"$DATA_GROUP" "$SHARED"

# 2770 = rwx for owner, rwx for group, nothing for everyone else, plus the
# leading 2: the setgid bit.
#
# On a DIRECTORY, setgid means "every file created in here inherits the
# directory's group, not the creating user's primary group". Without it, two
# people in appdata create files owned by their own groups and cannot edit
# each other's - the single most common cause of "but we are both in the
# group". Note setgid on a directory has nothing to do with setgid on a
# binary, which is a privilege escalation mechanism. Same bit, different
# meaning, and the manual pages do not go out of their way to say so.
chmod 2770 "$SHARED"

ls -ld "$SHARED"
echo "the 's' in drwxrws--- is setgid. If you see an uppercase 'S' the group"
echo "execute bit is missing, which makes the directory unusable - look again."

# ------------------------------------------------------------------ the ACL
say "the ACL: one user, without touching owner or group"

# Unix permissions have exactly three slots: owner, group, everyone. That is
# fine until you need "and also this one account", which is a genuinely common
# requirement and has no fourth slot. The usual bad answers are to make appsvc
# a member of appdata (over-granting - it now reaches every appdata file
# everywhere) or to chown the directory to appsvc (which takes it away from
# the humans). An ACL is the correct answer: an extra entry, nothing else
# disturbed.
#
# -m : modify. rwx here because the service creates and rotates its own file.
setfacl -m "u:$SVC_USER:rwx" "$SHARED"

# -d : the DEFAULT ACL, which is not an access rule at all. It is a template
# copied onto anything created inside this directory later. Without it appsvc
# can write in the directory but cannot reopen a file the humans created, and
# you get a bug that only appears for new files. The -m entry and the -d entry
# are separate; setting one does not set the other.
setfacl -d -m "u:$SVC_USER:rwx" "$SHARED"
setfacl -d -m "g:$DATA_GROUP:rwx" "$SHARED"

echo
getfacl -p "$SHARED"
echo "the '+' at the end of the mode in 'ls -ld' is the only hint ls gives you"
echo "that any of this exists. That is why permission problems on a machine"
echo "with ACLs waste so much time."
ls -ld "$SHARED"

# SELinux is a separate mechanism again, and it is enforcing on this VM. It
# has no opinion on ACLs and ACLs have no opinion on it - a denial from one
# looks identical to a denial from the other at the application level. Day 13
# is where that stops being a footnote.
if command -v restorecon >/dev/null 2>&1; then
	restorecon -R "$SHARED" || true
fi

# -------------------------------------------------------------- the sudoers
say "sudo: exactly one command"

# Never edit a sudoers file in place with a plain editor. A syntax error in
# /etc/sudoers or anything under /etc/sudoers.d makes sudo refuse to run AT
# ALL, on a machine where sudo is how you become root. That is a genuine
# lockout, and it is why we build the file in a temporary location, ask visudo
# to parse it, and only then install it.
tmp="$(mktemp)"
# Deleted on any exit path, including the failure below.
trap 'rm -f "$tmp"' EXIT

cat >"$tmp" <<SUDOERS
# Day 02 - $SVC_USER may restart one service, and nothing else.
#
# Cmnd_Alias groups commands under a name. Worth it even for a short list,
# because the alias documents the intent and 'sudo -l' still expands it.
#
# Absolute paths only. A bare 'systemctl' would match any systemctl on the
# user's PATH, which is a trivial escalation: drop a script called systemctl
# somewhere writable and sudo runs it as root.
Cmnd_Alias LAB_APP_CTL = /usr/bin/systemctl restart $SERVICE.service, \\
                         /usr/bin/systemctl status $SERVICE.service, \\
                         /usr/bin/systemctl is-active $SERVICE.service

# Read the fields: user  host = (run-as user)  commands
#
#   (root)    it may run these AS root - and only root. '(ALL)' would let it
#             pick any target user, which includes root plus every other
#             account on the box, so it is strictly worse for no benefit.
#   NOPASSWD  no password prompt. Correct here because $SVC_USER HAS no
#             password and no shell, so a prompt could never be answered -
#             it would just be a broken permission. Not something to reach
#             for on a human account.
$SVC_USER ALL=(root) NOPASSWD: LAB_APP_CTL
SUDOERS

# -c checks, -f names the file to check. This is the gate.
if ! visudo -cf "$tmp"; then
	die "the generated sudoers file did not parse - NOT installing it. Look at $tmp"
fi

# 0440 and root:root are required: sudo ignores any file under sudoers.d that
# is group- or world-writable, and it does so quietly.
install -m 0440 -o root -g root "$tmp" "$SUDOERS"
rm -f "$tmp"
trap - EXIT

echo "installed $SUDOERS"
ls -l "$SUDOERS"

# ------------------------------------------------------------- the service
say "the service that proves it: $SERVICE"

install -m 0755 "$HERE/$SERVICE.sh" "$BIN"
if command -v restorecon >/dev/null 2>&1; then
	restorecon -v "$BIN" || true
fi

cat >"$UNIT" <<UNIT
[Unit]
Description=Bash Mastery Linux Day 02 app service (runs as $SVC_USER)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN
Restart=always
RestartSec=2

# This is Day 02's whole argument in two lines. The service does not need
# root, so it does not get root.
User=$SVC_USER
Group=$SVC_USER

NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
# 'full' makes /usr, /boot and /etc read-only but leaves /srv writable.
# Day 01 used 'strict', which makes the WHOLE filesystem read-only - that
# would block this service's only job, so it is paired with ReadWritePaths.
ProtectSystem=full
ReadWritePaths=$SHARED

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl reset-failed "$SERVICE" 2>/dev/null || true
systemctl enable --now "$SERVICE"

# Give it long enough to write at least one line.
sleep 3

say "state"
systemctl status "$SERVICE" --no-pager --lines=5 || true

say "what the service wrote, and who owns it"
ls -l "$SHARED"
echo
echo "group is $DATA_GROUP even though $SVC_USER is not in that group: setgid on"
echo "the directory did that. The write itself was allowed by the ACL."
echo
tail -n 3 "$SHARED/lab-app.log" 2>/dev/null || echo "(nothing written yet - check journalctl -u $SERVICE)"

[[ -s "$SHARED/lab-app.log" ]] || die "the service did not write anything. That is the day's failure mode - look at:  journalctl -u $SERVICE -n 30"

cat <<NEXT

==> built. Now look at what you made:

  sudo -l -U $SVC_USER              # exactly what sudo will allow
  getfacl -p $SHARED
  ls -ld $SHARED                   # note the trailing '+'
  journalctl -u $SERVICE -f          # ctrl-c to stop following

Then:  ./scripts/explore-perms.sh
Then:  sudo ./scripts/break-and-fix.sh
Then:  sudo ./verify.sh

NEXT
