#!/usr/bin/env bash
#
# Day 12 tour - twelve read-only stops through the SSH server's policy.
#
# Nothing here changes anything. Run it, read the output, and stop at the
# stops that surprise you. The comments between the commands are the day.

set -uo pipefail

SSHD="/usr/sbin/sshd"
LOGIN_USER="${SUDO_USER:-lab}"

say()  { printf '\n=== %s ===\n\n' "$*"; }
note() { printf '  %s\n' "$*"; }
run_sh() { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/  /' || true; printf '\n'; }

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
	echo "needs root:  sudo $0" >&2
	exit 1
fi

say "1. is the server even running, and on what port"
run_sh "systemctl is-active sshd; systemctl is-enabled sshd"
run_sh "$SSHD -T | grep -E '^(port|listenaddress|addressfamily) '"
note "'port 22' here is the effective value, not a guess from a file."

say "2. the main file, and the line that changes everything"
run_sh "grep -nE '^\\s*Include' /etc/ssh/sshd_config"
note "On Rocky 9 that Include sits at the TOP of the file. Remember that."
note "For most keywords sshd keeps the FIRST value it reads, so a drop-in"
note "included at the top beats anything written lower in the main file."
note "Most people assume the opposite, the way Apache or nginx behave."

say "3. the drop-ins, in the order sshd reads them"
run_sh "ls -1 /etc/ssh/sshd_config.d/"
note "Glob order is lexical, which is why these files are numbered. 50- is"
note "the vendor's, 60- is ours. Ours is read second and therefore loses"
note "any keyword the vendor file already set - check before you assume."

say "4. what is actually loaded"
run_sh "$SSHD -T | sort | head -25"
note "sshd -T prints the effective configuration: every keyword, resolved."
note "There is no 'default' left in it. This is the file you wish existed."

say "5. the four keywords that decide who gets in"
run_sh "$SSHD -T | grep -E '^(passwordauthentication|pubkeyauthentication|permitrootlogin|permitemptypasswords) '"
note "permitrootlogin prohibit-password means root may still log in - with a"
note "key. That is not the same as 'no', and scanners know the difference."

say "6. the allow list"
run_sh "$SSHD -T | grep -E '^(allowusers|allowgroups|denyusers|denygroups) '"
run_sh "getent group labssh"
note "An allow list is evaluated before authentication. A user outside it"
note "cannot log in with a perfect key, and the log says 'not allowed'."

say "7. asking the question for one user"
run_sh "$SSHD -T -C user=$LOGIN_USER,host=localhost,addr=127.0.0.1 | grep -E '^(passwordauthentication|allowgroups|maxauthtries) '"
note "-C evaluates Match blocks for a hypothetical connection. This is how"
note "you test a policy change without logging out to find out the hard way."

say "8. the client side of the same conversation"
run_sh "ssh -G -o ConnectTimeout=1 node1 2>/dev/null | grep -E '^(user|port|proxyjump|identityfile|stricthostkeychecking) ' | head"
note "ssh -G is the client's sshd -T. It prints what YOUR ssh would use,"
note "after ~/.ssh/config and /etc/ssh/ssh_config. When a connection goes"
note "somewhere unexpected, this tells you why before tcpdump does."

say "9. host keys - the other half of trust"
run_sh "ls -1 /etc/ssh/ssh_host_*_key.pub"
run_sh "ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub"
note "That fingerprint is what your client compares against known_hosts."
note "Rebuild the VM and it changes, which is the warning you have been"
note "trained to click through. On a real host it means someone is between."

say "10. what the log actually records"
run_sh "journalctl -u sshd --since '-1h' | tail -8"
note "'Accepted publickey', 'Failed password', 'User x not allowed because"
note "not listed in AllowUsers'. fail2ban reads exactly these lines."

say "11. the jail"
run_sh "fail2ban-client status"
run_sh "fail2ban-client status sshd"
note "'Currently failed' counts attempts inside findtime. 'Currently banned'"
note "is the number that matters. Banned addresses live in a firewall rule,"
note "not in sshd - which is why Day 11 comes before this one."

say "12. the whole picture in one command"
run_sh "/usr/local/bin/lab-ssh 2>/dev/null | head -30"
note "Then: sudo /usr/local/bin/lab-ssh $LOGIN_USER"

cat <<'EOF'

The tour is over. Three commands are worth memorising today:

  sudo sshd -T                  what the server has loaded
  sudo sshd -T -C user=NAME     what it would decide for one person
  sudo sshd -t                  does this config parse (before you reload)

EOF
