#!/usr/bin/env bash
#
# Day 12 setup - harden sshd, and put fail2ban in front of it.
#
# Leaves behind:
#   /etc/ssh/sshd_config.d/60-lab-hardening.conf   the policy you will read
#   group 'labssh' containing your login user       the allow list
#   /etc/fail2ban/jail.d/lab-sshd.local             a jail with a short ban
#   /usr/local/bin/lab-ssh                          the payload
#
# Everything here is idempotent. Run it twice; the second run should change
# nothing and say so.
#
# The one rule this script never breaks: it validates the configuration with
# 'sshd -t' BEFORE asking sshd to load it, and it reloads rather than
# restarts. A reload keeps your current session alive even if the new policy
# would have refused it. A restart plus a bad config is how people lose a
# remote machine.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

say()  { printf '\n==> %s\n' "$*"; }
die()  { echo "$*" >&2; exit 1; }
ok()   { printf 'ok    %s\n' "$*"; }
note() { printf '  (%s)\n\n' "$1"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "needs root:  sudo $0"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_SRC="$HERE/lab-ssh.sh"
PAYLOAD="/usr/local/bin/lab-ssh"

DROPIN="/etc/ssh/sshd_config.d/60-lab-hardening.conf"
JAIL="/etc/fail2ban/jail.d/lab-sshd.local"
GROUP="labssh"
SSHD="/usr/sbin/sshd"

# Who is doing this? SUDO_USER is the human behind the sudo, which is the
# account that must stay able to log in. Getting this wrong is the whole
# danger of the day.
LOGIN_USER="${SUDO_USER:-lab}"

# ---------------------------------------------------------------------------
# 0. the tools
# ---------------------------------------------------------------------------
say "0. checking the tools are here"

missing=""
for c in ssh-keygen systemctl; do
	command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
done
[[ -x "$SSHD" ]] || missing="$missing $SSHD"
[[ -n "$missing" ]] && die "missing:$missing
  sudo dnf install -y openssh-server fail2ban"

if ! command -v fail2ban-client >/dev/null 2>&1; then
	die "fail2ban-client is missing. It lives in EPEL on Rocky 9:
  sudo dnf install -y epel-release
  sudo dnf install -y fail2ban fail2ban-firewalld"
fi
ok "sshd, ssh-keygen and fail2ban-client all present"

# ---------------------------------------------------------------------------
# 1. a key, before we turn passwords off
# ---------------------------------------------------------------------------
# Order matters more here than anywhere else in the course. Disabling
# password authentication when the account has no authorized key is how you
# lock yourself out of a machine with one command.
say "1. making sure $LOGIN_USER can log in with a key"

USER_HOME="$(getent passwd "$LOGIN_USER" | cut -d: -f6)"
[[ -n "$USER_HOME" && -d "$USER_HOME" ]] || die "no home directory for $LOGIN_USER"
AUTH="$USER_HOME/.ssh/authorized_keys"

if [[ -s "$AUTH" ]]; then
	keys="$(grep -cvE '^\s*(#|$)' "$AUTH" || true)"
	ok "$LOGIN_USER has $keys key(s) in authorized_keys"
else
	die "$LOGIN_USER has no authorized_keys - refusing to disable passwords.
  You reached this VM over SSH, so a key exists on your laptop. Copy it:
    ssh-copy-id $LOGIN_USER@<this vm>
  or from the laptop:  ./lab/lab.sh ssh node1  and check ~/.ssh/authorized_keys"
fi

# ---------------------------------------------------------------------------
# 2. the allow list
# ---------------------------------------------------------------------------
# AllowGroups is better than AllowUsers for one boring reason: adding a person
# later is 'usermod -aG', not an edit to a config file that needs validating
# and reloading.
say "2. the allow list: group $GROUP"

if getent group "$GROUP" >/dev/null; then
	ok "group $GROUP already exists"
else
	groupadd "$GROUP"
	ok "group $GROUP created"
fi

if id -nG "$LOGIN_USER" | tr ' ' '\n' | grep -qx "$GROUP"; then
	ok "$LOGIN_USER is already in $GROUP"
else
	usermod -aG "$GROUP" "$LOGIN_USER"
	ok "$LOGIN_USER added to $GROUP"
fi
note "the allow list is built BEFORE it is enforced, never after"

# ---------------------------------------------------------------------------
# 3. the drop-in
# ---------------------------------------------------------------------------
# /etc/ssh/sshd_config on Rocky 9 starts with:  Include /etc/ssh/sshd_config.d/*.conf
# and sshd takes the FIRST value it sees for most keywords. Because the
# Include is at the top, a drop-in beats the main file - which is the opposite
# of what most people assume, and the subject of failure 1.
say "3. the hardening drop-in"

mkdir -p /etc/ssh/sshd_config.d
cat > "$DROPIN" <<EOF
# Day 12 - written by days/day12/scripts/setup.sh
#
# Included from /etc/ssh/sshd_config, which has its Include line at the top.
# sshd keeps the first value it reads for each keyword, so these win over
# anything set later in the main file. Read the effective result with:
#   sudo $SSHD -T | sort

PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
PermitEmptyPasswords no
AllowGroups $GROUP
MaxAuthTries 3
LoginGraceTime 20
EOF
chmod 600 "$DROPIN"
ok "wrote $DROPIN"

# ---------------------------------------------------------------------------
# 4. validate, THEN load
# ---------------------------------------------------------------------------
say "4. validating before loading"

if "$SSHD" -t; then
	ok "sshd -t: the configuration parses"
else
	rm -f "$DROPIN"
	die "sshd -t rejected the config - the drop-in has been removed and nothing was loaded"
fi

# -T prints the EFFECTIVE configuration: every keyword, resolved, after all
# includes. It is the only honest answer to 'what is sshd actually doing'.
for want in "passwordauthentication no" "permitrootlogin prohibit-password"; do
	"$SSHD" -T | grep -qx "$want" || die "sshd -T does not show '$want' - something later overrides it"
done
ok "sshd -T agrees with the file"

# -C asks the question for a specific user, which is how you check an allow
# list without logging out to test it.
if "$SSHD" -T -C "user=$LOGIN_USER,host=localhost,addr=127.0.0.1" >/dev/null 2>&1; then
	ok "sshd -T -C accepts a match test for $LOGIN_USER"
fi

systemctl reload sshd 2>/dev/null || systemctl reload-or-restart sshd
ok "sshd reloaded (reload, not restart - your session survives either way)"
note "validate, then load. Never the other way round on a remote machine"

# ---------------------------------------------------------------------------
# 5. fail2ban
# ---------------------------------------------------------------------------
# bantime is deliberately 2 minutes here. On a lab machine a 10-hour ban means
# you sit and wait, learn nothing, and eventually rebuild the VM.
say "5. fail2ban watching sshd"

mkdir -p /etc/fail2ban/jail.d
cat > "$JAIL" <<'EOF'
# Day 12 - written by days/day12/scripts/setup.sh
#
# Short, deliberately. You are meant to trigger this on purpose and then
# unban yourself, which is not a thing you will do if the ban lasts a day.
[sshd]
enabled  = true
backend  = systemd
maxretry = 3
findtime = 120
bantime  = 120
EOF
ok "wrote $JAIL"

systemctl enable --now fail2ban >/dev/null 2>&1 || true

# fail2ban takes a moment to build its jails. A check that races a daemon
# start has to retry - the same lesson as Day 11's listener.
ready="no"
for _ in $(seq 1 20); do
	if fail2ban-client status sshd >/dev/null 2>&1; then ready="yes"; break; fi
	sleep 0.5
done

if [[ "$ready" == "yes" ]]; then
	ok "jail 'sshd' is active"
	fail2ban-client status sshd | sed 's/^/      /'
else
	echo "      fail2ban did not report the sshd jail. Diagnostics:" >&2
	systemctl is-active fail2ban 2>&1 | sed 's/^/        /' >&2
	fail2ban-client status 2>&1 | sed 's/^/        /' >&2
	echo "      journalctl -u fail2ban -n 20   # for the reason" >&2
fi

# ---------------------------------------------------------------------------
# 6. the payload
# ---------------------------------------------------------------------------
# Installed LAST in file order but never gated behind a diagnostic: if step 5
# could not confirm the jail, you still get the tool that explains why.
say "6. installing lab-ssh"

[[ -r "$PAYLOAD_SRC" ]] || die "cannot find $PAYLOAD_SRC"
install -m 0755 "$PAYLOAD_SRC" "$PAYLOAD"
ok "$PAYLOAD"

cat <<EOF

Passwords off, root limited to keys, one group allowed in, and a jail
watching the log.

  sudo $PAYLOAD              # file policy, effective policy, and the jail
  sudo $PAYLOAD $LOGIN_USER        # what sshd decides for one user

Then the tour:  sudo ./days/day12/scripts/explore-ssh.sh
And break it:   sudo ./days/day12/scripts/break-and-fix.sh
                sudo ./days/day12/scripts/break-and-fix.sh --hard

Check yourself: sudo ./days/day12/verify.sh
EOF
