#!/usr/bin/env bash
#
# Day 02 - a guided tour of identity and permissions. Read-only, no root
# needed, safe to run as often as you like.
#
#   ./scripts/explore-perms.sh
#
# It reads state and demonstrates umask inside a temporary directory of its
# own, which it deletes. Nothing outside that directory is touched.
#
# Two commands here want root and will say so if they do not have it:
# 'sudo -l -U appsvc' (asking about another user's privileges is itself
# privileged) and getfacl on a directory you cannot read. Run the whole tour
# with sudo if you would rather see everything at once.

set -euo pipefail

SVC_USER="appsvc"
SHARED="/srv/shared"

heading() {
	printf '\n===============================================================\n'
	printf '  %s\n' "$1"
	printf '===============================================================\n'
}

note() { printf '  (%s)\n\n' "$1"; }

# Print the command, then its output, indented. Nothing may abort the tour, so
# every command is allowed to fail.
run() {
	printf '$ %s\n' "$*"
	"$@" 2>&1 | sed 's/^/  /' || true
	printf '\n'
}

# For the pipelines and redirections that need a shell to be the point.
run_sh() {
	printf '$ %s\n' "$1"
	bash -c "$1" 2>&1 | sed 's/^/  /' || true
	printf '\n'
}

heading "1. who am I, really?"
note "uid is what the kernel checks. the name is a lookup in /etc/passwd for your benefit, not the kernel's"
run id
note "euid vs uid matters the moment sudo or a setuid binary is involved"
run_sh 'id -u; id -un; id -Gn'

heading "2. the service account"
note "a system uid (below 1000 here) says 'not a person' by convention, and nothing more. the nologin shell is what actually stops a login"
run_sh "getent passwd $SVC_USER"
run_sh "id $SVC_USER"
note "try it: nologin prints a refusal and exits non-zero. that IS the security control"
run_sh "sudo -n -u $SVC_USER /sbin/nologin 2>&1 || true"

note "no password hash either. '!!' or '*' in the second field means no password can ever match"
run_sh "sudo -n getent shadow $SVC_USER 2>/dev/null | cut -d: -f1,2 || echo '  (needs root - run this tour with sudo to see it)'"

heading "3. what sudo will actually allow"
note "-l lists, -U asks about another user. this is the authoritative answer, not the sudoers file you think you wrote"
run_sh "sudo -n -l -U $SVC_USER 2>&1 || echo '  (needs root - sudo ./scripts/explore-perms.sh)'"
note "the aliases are expanded here. absolute paths, one target user, no wildcards - that is what least privilege looks like in this file"
run_sh "sudo -n cat /etc/sudoers.d/$SVC_USER 2>/dev/null || echo '  (needs root)'"

heading "4. the directory, and the three mechanisms stacked on it"
note "mode, owner and group are the first mechanism. the trailing + is the second. SELinux context is the third"
run ls -ld "$SHARED"
run_sh "stat -c '%A  %a  %U:%G  %n' $SHARED"
run_sh "ls -lZd $SHARED 2>/dev/null || ls -ld $SHARED"

note "getfacl is the only way to see the real answer. note the two blocks: access entries, then default: entries that new files inherit"
run_sh "getfacl -p $SHARED 2>&1 || echo '  (cannot read it as $(id -un))'"

note "mask:: is the ceiling. an entry of rwx under a mask of r-x grants r-x - the effective line spells it out, and this is where most ACL confusion lives"
run_sh "getfacl -p $SHARED 2>/dev/null | grep -E 'mask|effective' || echo '  (no mask line - nothing is being clamped)'"

heading "5. setgid, demonstrated rather than asserted"
note "files inside inherit the directory group. compare the group column with 'id -gn' - your own primary group"
run_sh "ls -l $SHARED 2>&1 | head -n 5 || true"
run_sh "id -gn"
note "so this file's group came from the directory, not from the process that created it. that is the setgid bit and nothing else"

heading "6. umask: the permissions you did not ask for"
note "umask is a mask of bits to REMOVE. 0022 clears group and other write; 0027 also clears other read"
run umask

tmp="$(mktemp -d)"
# Cleaned up on every exit path, including ctrl-c.
trap 'rm -rf "$tmp"' EXIT

run_sh "cd $tmp && umask 0022 && touch default-022 && mkdir dir-022 && ls -l | sed 's/^/  /'"
run_sh "cd $tmp && umask 0077 && touch private-077 && mkdir dir-077 && ls -l | sed 's/^/  /'"
note "note that files start from 666 and directories from 777, which is why a 022 umask gives 644 and 755. no file is ever created executable by the umask - only by chmod"

heading "7. the service, and the identity it runs under"
note "User= in the unit is the whole point of today. read the Main PID line: the process is appsvc, not root"
run_sh "systemctl show lab-app --property=Id,User,Group,ProtectSystem,ReadWritePaths,ActiveState,ExecMainPID 2>/dev/null || echo '  (lab-app not installed - run sudo ./scripts/setup.sh)'"
run_sh "ps -o user,group,pid,cmd -p \"\$(systemctl show lab-app --property=ExecMainPID --value 2>/dev/null)\" 2>/dev/null || echo '  (not running)'"

cat <<'NEXT'
===============================================================
  now do these by hand
===============================================================

  sudo -l -U appsvc
      then read every line and say out loud what it permits.
      that is the judgement item in verify.sh

  find / -xdev -perm -4000 -type f 2>/dev/null
      every setuid-root binary on the machine. each one is a
      program that runs as root no matter who starts it, so each
      one is a place a bug becomes a root exploit. the list should
      be short and boring - passwd, sudo, mount. anything you do
      not recognise is worth an afternoon

  find /srv/shared -xdev \( -perm -2 -o -perm -20 \) -ls
      world-writable or group-writable files. useful habit

  getent group appdata ; getent group appsvc
      membership is stored on the GROUP, not on the user, except
      for the primary group which lives in /etc/passwd. that split
      is why 'usermod -aG' forgetting the -a is so destructive:
      without it you REPLACE every supplementary group

  sudo -u appsvc id
      runs as the service account without needing a shell. compare
      with 'su - appsvc', which needs one and therefore fails

  systemd-analyze security lab-app.service
      scores the unit's sandboxing. Day 02's unit will not score
      well, and reading why is a better lesson than a good score

NEXT
