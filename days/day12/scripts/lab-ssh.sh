#!/usr/bin/env bash
#
# lab-ssh - installed by Day 12 setup.sh as /usr/local/bin/lab-ssh
#
#   sudo /usr/local/bin/lab-ssh          policy on disk, policy in effect, and the jail
#   sudo /usr/local/bin/lab-ssh lab      what sshd decides for one named user
#
# sudo on Rocky uses its own secure_path, which does not include
# /usr/local/bin. Type the full path - that is not a typo in the README.
#
# The point of this tool is one distinction: what a file says, and what sshd
# has actually loaded. They agree far less often than people expect, because
# of includes, first-value-wins precedence, and Match blocks.

set -uo pipefail

SSHD="/usr/sbin/sshd"
DROPIN_DIR="/etc/ssh/sshd_config.d"
MAIN="/etc/ssh/sshd_config"

hr()   { printf '\n--- %s ---\n\n' "$*"; }
note() { printf '\n  (%s)\n' "$1"; }

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
	echo "needs root:  sudo /usr/local/bin/lab-ssh ${1:-}" >&2
	exit 1
fi

USER_ARG="${1:-}"

# ---------------------------------------------------------------------------
# one user
# ---------------------------------------------------------------------------
if [ -n "$USER_ARG" ]; then
	printf -- '--- what sshd decides for %s ---\n\n' "$USER_ARG"

	if ! id "$USER_ARG" >/dev/null 2>&1; then
		echo "no such user on this machine: $USER_ARG"
		echo "(sshd still has an answer for it - an allow list rejects unknown names too)"
		echo
	fi

	echo "groups:"
	id -nG "$USER_ARG" 2>/dev/null | sed 's/^/  /' || echo "  (none - user does not exist)"
	echo

	# -C runs the Match evaluation for a hypothetical connection. This is how
	# you test an allow list without logging out to find out.
	echo "effective config for that user (sshd -T -C):"
	if eff=$("$SSHD" -T -C "user=$USER_ARG,host=localhost,addr=127.0.0.1" 2>&1); then
		echo "$eff" | grep -E '^(passwordauthentication|pubkeyauthentication|permitrootlogin|allowgroups|allowusers|denyusers|denygroups|maxauthtries) ' | sed 's/^/  /'
	else
		echo "$eff" | sed 's/^/  /'
		echo
		echo "  sshd refused to evaluate that user. On most builds this IS the answer:"
		echo "  the user does not match the allow list and would be rejected at login."
	fi
	echo

	allowg=$("$SSHD" -T 2>/dev/null | grep '^allowgroups ' | cut -d' ' -f2-)
	if [ -n "$allowg" ]; then
		echo "allow list: $allowg"
		verdict="REFUSED - not in any allowed group"
		for g in $allowg; do
			if id -nG "$USER_ARG" 2>/dev/null | tr ' ' '\n' | grep -x "$g" >/dev/null; then
				verdict="allowed - member of $g"
			fi
		done
		echo "verdict:    $verdict"
	else
		echo "allow list: none - every account with a shell may attempt to log in"
	fi
	echo

	echo "keys:"
	home=$(getent passwd "$USER_ARG" 2>/dev/null | cut -d: -f6)
	if [ -n "$home" ] && [ -s "$home/.ssh/authorized_keys" ]; then
		n=$(grep -cvE '^\s*(#|$)' "$home/.ssh/authorized_keys")
		echo "  $n in $home/.ssh/authorized_keys"
		perm=$(stat -c '%a' "$home/.ssh/authorized_keys")
		echo "  mode $perm  (sshd ignores the file if it is group or world writable)"
	else
		echo "  none. With passwordauthentication no, this account cannot log in at all."
	fi
	echo
	exit 0
fi

# ---------------------------------------------------------------------------
# the whole machine
# ---------------------------------------------------------------------------
hr "what the files say"

echo "  $MAIN"
grep -nE '^\s*(Include|PasswordAuthentication|PermitRootLogin|AllowGroups|AllowUsers)' "$MAIN" 2>/dev/null | sed 's/^/    /' || echo "    (nothing relevant uncommented)"
echo
if [ -d "$DROPIN_DIR" ]; then
	# Read in the order sshd reads them: glob order, which is lexical.
	for f in "$DROPIN_DIR"/*.conf; do
		[ -e "$f" ] || continue
		echo "  $f"
		grep -vE '^\s*(#|$)' "$f" | sed 's/^/    /'
		echo
	done
fi
note "read top to bottom: for most keywords sshd keeps the FIRST value it sees"

hr "what sshd has actually loaded"
"$SSHD" -T 2>/dev/null | grep -E '^(passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|permitrootlogin|permitemptypasswords|allowgroups|allowusers|maxauthtries|logingracetime|port) ' | sort | sed 's/^/  /'
note "this is the only answer that matters. The files are how it got here"

hr "where the file and the effective config disagree"
found="no"
while read -r key val; do
	[ -n "$key" ] || continue
	lk=$(echo "$key" | tr 'A-Z' 'a-z')
	eff=$("$SSHD" -T 2>/dev/null | grep "^$lk " | cut -d' ' -f2- | head -1)
	lv=$(echo "$val" | tr 'A-Z' 'a-z')
	if [ -n "$eff" ] && [ "$eff" != "$lv" ]; then
		echo "  $key: file says '$val', sshd is using '$eff'"
		found="yes"
	fi
done < <(grep -hE '^\s*(PasswordAuthentication|PermitRootLogin|AllowGroups|MaxAuthTries|PermitEmptyPasswords)' "$MAIN" 2>/dev/null | awk '{print $1, $2}')
[ "$found" = "no" ] && echo "  none - every keyword in $MAIN survived the includes"
echo

hr "the jail"
if command -v fail2ban-client >/dev/null 2>&1; then
	if fail2ban-client status sshd 2>/dev/null | sed 's/^/  /'; then
		:
	else
		echo "  the sshd jail is not running. fail2ban service:"
		systemctl is-active fail2ban 2>&1 | sed 's/^/    /'
	fi
else
	echo "  fail2ban-client not installed"
fi
echo

hr "recent refusals in the log"
# The jail reads this same journal. Seeing the raw lines makes the jail stop
# being magic.
journalctl -u sshd --since '-1h' 2>/dev/null |
	grep -iE 'failed|invalid user|refused|not allowed' | tail -5 | sed 's/^/  /' ||
	echo "  nothing in the last hour"
echo

echo "One user in detail:  sudo /usr/local/bin/lab-ssh <username>"
