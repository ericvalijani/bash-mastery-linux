#!/usr/bin/env bash
#
# Day 12 break-and-fix - three SSH policies that fail, and their repairs.
#   --hard  adds the two that lock people out of real machines.
#
# Safety, because this day can end a session:
#   * Nothing here ever restarts sshd. Every change is validated with
#     'sshd -t' and loaded with 'systemctl reload sshd', which keeps your
#     current connection alive even when the new policy would refuse it.
#   * restore() runs on EXIT, INT and TERM, puts the original drop-in back,
#     reloads, and then PROVES the result instead of assuming it.
#   * The genuinely unrecoverable failure is described and not executed.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

SSHD="/usr/sbin/sshd"
DROPIN="/etc/ssh/sshd_config.d/00-lab-hardening.conf"
EXTRA="/etc/ssh/sshd_config.d/70-lab-broken.conf"
BACKUP="/root/.day12-dropin.bak"
GROUP="labssh"
LOGIN_USER="${SUDO_USER:-lab}"

say()  { printf '\n=== %s ===\n\n' "$*"; }
note() { printf '  %s\n' "$*"; }
run_sh() { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/  /' || true; printf '\n'; }

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
	echo "needs root:  sudo $0" >&2
	exit 1
fi
[ -r "$DROPIN" ] || { echo "no $DROPIN - run scripts/setup.sh first" >&2; exit 1; }

HARD="no"; [[ "${1:-}" == "--hard" ]] && HARD="yes"

cp -a "$DROPIN" "$BACKUP"

reload() {
	if "$SSHD" -t 2>/dev/null; then
		systemctl reload sshd 2>/dev/null || true
		return 0
	fi
	return 1
}

restore() {
	printf '\n--- putting it back ---\n'
	rm -f "$EXTRA"
	[ -r "$BACKUP" ] && cp -a "$BACKUP" "$DROPIN"
	rm -f "$BACKUP"

	if ! reload; then
		echo "  sshd -t STILL fails. Do not log out. Fix it here:" >&2
		"$SSHD" -t 2>&1 | sed 's/^/    /' >&2
		return
	fi

	# Prove it, do not assume it. A teardown that does not check its own
	# result is an assumption with a nice name.
	state="ok"
	"$SSHD" -T | grep -x "passwordauthentication no" >/dev/null || state="passwords back on"
	"$SSHD" -T | grep "^allowgroups .*$GROUP" >/dev/null || state="allow list lost $GROUP"
	id -nG "$LOGIN_USER" | tr ' ' '\n' | grep -x "$GROUP" >/dev/null || state="$LOGIN_USER not in $GROUP"

	if command -v fail2ban-client >/dev/null 2>&1; then
		fail2ban-client set sshd unbanip 127.0.0.1 >/dev/null 2>&1 || true
	fi

	if [ "$state" = "ok" ]; then
		note "policy restored: passwords off, $GROUP allowed, $LOGIN_USER still in it"
	else
		echo "  WARNING: $state" >&2
	fi
	note "local login test: $( "$SSHD" -T -C "user=$LOGIN_USER,host=localhost,addr=127.0.0.1" >/dev/null 2>&1 && echo 'sshd would evaluate this user' || echo 'sshd refused to evaluate - read the warning above')"
}
trap restore EXIT INT TERM

# ---------------------------------------------------------------------------
say "1. the drop-in that loses"

# 70- sorts after 00-, so it is read second. For most keywords sshd keeps the
# first value, so this file is ignored - the exact opposite of what the
# person who wrote it intended.
cat > "$EXTRA" <<'EOF'
# a well-meaning change, added later
PasswordAuthentication yes
MaxAuthTries 10
EOF
reload || true

run_sh "grep -r PasswordAuthentication /etc/ssh/sshd_config.d/"
run_sh "$SSHD -T | grep -E '^(passwordauthentication|maxauthtries) '"

note "Two files, two answers, and the effective config follows NEITHER by"
note "filename intuition. sshd kept the first value it read, which came"
note "from 00-, because 00 sorts before 70."
note ""
note "The engineer who added 70- will swear the change is live. grep proves"
note "the file exists. Only sshd -T proves what is loaded."
note ""
note "  fixed by editing the file that actually wins, or renaming this one"
note "  to 10- so it is read first."
rm -f "$EXTRA"
reload || true

# ---------------------------------------------------------------------------
say "2. the allow list that excludes you"

# This is the classic. It is also completely safe as long as you never
# restart sshd and you test with -C instead of with your own logout.
sed -i "s/^AllowGroups .*/AllowGroups wheel-only-typo/" "$DROPIN"
reload || true

run_sh "$SSHD -T | grep '^allowgroups '"
run_sh "$SSHD -T -C user=$LOGIN_USER,host=localhost,addr=127.0.0.1 >/dev/null 2>&1 && echo 'would be evaluated' || echo 'sshd refuses this user'"
run_sh "id -nG $LOGIN_USER"

note "The config is valid. sshd -t is happy. The service is active and"
note "enabled. And the next person to log in - including you, tomorrow -"
note "is refused with 'not listed in AllowGroups'."
note ""
note "Your existing session survives because authentication already"
note "happened. That delay between the mistake and the consequence is what"
note "makes this failure expensive."
note ""
note "  fixed by comparing 'id -nG you' against 'sshd -T | grep allowgroups'"
note "  BEFORE logging out. Always."
cp -a "$BACKUP" "$DROPIN"
reload || true

# ---------------------------------------------------------------------------
say "3. banning yourself"

if command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client status sshd >/dev/null 2>&1; then
	fail2ban-client set sshd banip 127.0.0.1 >/dev/null 2>&1 || true
	run_sh "fail2ban-client status sshd"

	note "127.0.0.1 is banned. On a real machine this is your office IP after"
	note "three fumbled logins, and the symptom is a connection that hangs or"
	note "is refused while the service is demonstrably healthy."
	note ""
	note "sshd will tell you nothing. The ban is a firewall rule, not an SSH"
	note "setting - which is why Day 11 came first."
	note ""
	note "  fixed with:  sudo fail2ban-client set sshd unbanip 127.0.0.1"
	fail2ban-client set sshd unbanip 127.0.0.1 >/dev/null 2>&1 || true
	run_sh "fail2ban-client status sshd | grep -i banned"
else
	note "fail2ban is not running, so this failure is described only:"
	note "  fail2ban-client set sshd banip 127.0.0.1     # ban"
	note "  fail2ban-client status sshd                  # see it"
	note "  fail2ban-client set sshd unbanip 127.0.0.1   # release"
fi

if [ "$HARD" != "yes" ]; then
	cat <<'EOF'

Three failures, three fixes. Two more are waiting behind --hard: the one
where a Match block quietly re-enables what you turned off, and the one
where the machine is simply gone.

  sudo ./days/day12/scripts/break-and-fix.sh --hard
EOF
	exit 0
fi

# ---------------------------------------------------------------------------
say "4. the Match block that undoes the policy"

# Match is the one place where 'first value wins' stops applying: inside a
# matching block, the value is replaced. A single Match at the bottom of a
# file can reverse the entire hardening above it, and sshd -T without -C
# will not show it.
cat > "$EXTRA" <<EOF
# 'just for the deploy account, temporarily'
Match User $LOGIN_USER
    PasswordAuthentication yes
    MaxAuthTries 20
EOF
reload || true

run_sh "$SSHD -T | grep -E '^(passwordauthentication|maxauthtries) '"
run_sh "$SSHD -T -C user=$LOGIN_USER,host=localhost,addr=127.0.0.1 | grep -E '^(passwordauthentication|maxauthtries) '"

note "Look at those two outputs again. The first says passwords are off."
note "The second, for the user who actually logs in, says they are on."
note "Both are sshd -T. Both are correct."
note ""
note "An audit that runs 'sshd -T | grep passwordauthentication' and files"
note "a green report has checked the case nobody attacks."
note ""
note "  fixed by auditing with -C for every account that can log in, and by"
note "  treating 'temporary' Match blocks as permanent, because they are."
rm -f "$EXTRA"
reload || true

# ---------------------------------------------------------------------------
say "5. the one that is not survivable (described, not executed)"

cat <<'EOF'
  Not run here. Reading it is the exercise.

    # passwords off, and no key in place for the only allowed user
    sudo rm ~/.ssh/authorized_keys
    sudo systemctl restart sshd

  Every individual command succeeds. sshd -t passes - the config is
  perfectly valid. The service comes back active and enabled. And there is
  now no credential on earth that opens this machine over the network.

  A cloud VM still has a serial console, so this costs an hour. A machine
  in a rack you do not have a badge for costs a day and a favour.

  Three habits that cost nothing:

    sudo sshd -t                     before every reload
    systemctl reload sshd            not restart - reload keeps your session
    ssh -o BatchMode=yes you@host    from a SECOND terminal, before logging
                                     out of the first one

  The second terminal is the whole trick. Keep your working session open
  and prove a NEW login works before you close it. Everyone learns this
  eventually; the only question is whether it is on a lab VM or a Friday.
EOF

cat <<'EOF'

Five failures.

  drop-in order      first value wins, and 00 sorts before 70
  allow list         valid config, healthy service, and you are locked out
  self-ban           the block lives in the firewall, not in sshd
  Match block        sshd -T is green, sshd -T -C is not
  no way back        every command succeeded and the machine is gone

Only the first two are visible in a config file review.

Check yourself:  sudo ./days/day12/verify.sh
EOF
