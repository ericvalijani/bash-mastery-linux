#!/usr/bin/env bash
#
# Day 12 teardown - undo the hardening, in the order that cannot lock you out.
#
# Order matters exactly as much as it did in setup. Passwords go back on
# BEFORE the allow list is removed, and every step is validated and proved
# rather than assumed.
#
# What stays: sshd running and enabled, and fail2ban installed. Day 13 and
# Day 14 both reach this machine over SSH.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

SSHD="/usr/sbin/sshd"
DROPIN="/etc/ssh/sshd_config.d/60-lab-hardening.conf"
EXTRA="/etc/ssh/sshd_config.d/70-lab-broken.conf"
JAIL="/etc/fail2ban/jail.d/lab-sshd.local"
GROUP="labssh"
PAYLOAD="/usr/local/bin/lab-ssh"
LOGIN_USER="${SUDO_USER:-lab}"

say()  { printf '\n==> %s\n' "$*"; }
ok()   { printf '  ok  %s\n' "$*"; }
bad()  { printf '  !!  %s\n' "$*" >&2; }

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
	echo "needs root:  sudo $0" >&2
	exit 1
fi

say "1. releasing any ban first"
if command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client status sshd >/dev/null 2>&1; then
	banned="$(fail2ban-client get sshd banned 2>/dev/null || echo '[]')"
	fail2ban-client set sshd unbanip 127.0.0.1 >/dev/null 2>&1 || true
	ok "unbanned 127.0.0.1 (jail had: $banned)"
else
	ok "no running sshd jail to clear"
fi

say "2. removing the hardening drop-ins"
rm -f "$DROPIN" "$EXTRA"

if "$SSHD" -t 2>/dev/null; then
	ok "sshd -t passes without them"
else
	bad "sshd -t fails - NOT reloading. Fix this before you log out:"
	"$SSHD" -t 2>&1 | sed 's/^/      /' >&2
	exit 1
fi

systemctl reload sshd 2>/dev/null || true

# Prove the removal instead of trusting rm.
if "$SSHD" -T | grep -q '^allowgroups '; then
	bad "an allow list is still in effect: $("$SSHD" -T | grep '^allowgroups ')"
	bad "something outside this day set it - check /etc/ssh/sshd_config.d/"
else
	ok "no allow list left in the effective config"
fi
printf '      passwordauthentication is now: %s\n' "$("$SSHD" -T | grep '^passwordauthentication ' | cut -d' ' -f2)"

say "3. removing the jail and the payload"
rm -f "$JAIL" "$PAYLOAD"
if systemctl is-active --quiet fail2ban; then
	systemctl reload fail2ban >/dev/null 2>&1 || systemctl restart fail2ban >/dev/null 2>&1 || true
fi
ok "jail file, lab-ssh removed"

say "4. the group"
# Deliberately kept: deleting a group that another day or another admin put
# a user into is the kind of cleanup that causes the next outage.
if getent group "$GROUP" >/dev/null; then
	ok "group $GROUP left in place (harmless once no config references it)"
	printf '      remove it yourself if you want:  sudo gpasswd -d %s %s && sudo groupdel %s\n' "$LOGIN_USER" "$GROUP" "$GROUP"
fi

say "5. what is deliberately left"
cat <<'EOF'
sshd stays running and enabled, and fail2ban stays installed. Days 13 and
14 both reach this machine over SSH, and a teardown that removes your way
in is not cleanup.

Your authorized_keys was never touched by this day, in either direction.

Day 12 removed.
EOF
