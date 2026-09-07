#!/usr/bin/env bash
#
# Day 02 - break the permissions on purpose, read the failure, put it back.
#
#   sudo ./scripts/break-and-fix.sh          the three permission failures
#   sudo ./scripts/break-and-fix.sh --hard   also break sudo itself, then repair
#
# The point: "Permission denied" is not a diagnosis. Four different mistakes
# produce it, they look identical from the application, and each has a
# different fix. Today is about telling them apart.
#
# Everything this breaks, it repairs. If you interrupt it halfway, run
# sudo ./scripts/setup.sh to get back to a known state.

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
SUDOERS="/etc/sudoers.d/$SVC_USER"

HARD="no"
[[ "${1:-}" == "--hard" ]] && HARD="yes"

die() {
	echo "$*" >&2
	exit 1
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "needs root:  sudo $0 ${1:-}"

id "$SVC_USER" >/dev/null 2>&1 || die "$SVC_USER does not exist - run 'sudo ./scripts/setup.sh' first"
[[ -d "$SHARED" ]] || die "$SHARED does not exist - run 'sudo ./scripts/setup.sh' first"
systemctl cat "$SERVICE" >/dev/null 2>&1 || die "$SERVICE is not installed - run 'sudo ./scripts/setup.sh' first"

step() {
	printf '\n---------------------------------------------------------------\n'
	printf '  %s\n' "$1"
	printf -- '---------------------------------------------------------------\n'
}

# Run something AS the service account. sudo execs the command directly rather
# than through a login shell, which is the only reason this works at all on an
# account whose shell is /sbin/nologin. 'su - appsvc' would fail for exactly
# that reason, and people conclude the account is broken when it is correct.
as_svc() { sudo -n -u "$SVC_USER" "$@"; }

prop() { systemctl show "$SERVICE" --property="$1" --value; }

# ============================================================ 1. sudo limits
step "1. what the service account may and may not do with sudo"

echo "allowed - the one command in $SUDOERS:"
printf '$ sudo -u %s sudo -n systemctl is-active %s\n' "$SVC_USER" "$SERVICE"
if as_svc sudo -n systemctl is-active "$SERVICE" 2>&1 | sed 's/^/  /'; then
	echo "  -> allowed, as designed"
else
	echo "  -> unexpected refusal. check:  sudo -l -U $SVC_USER"
fi

echo
echo "denied - a service it was never granted:"
printf '$ sudo -u %s sudo -n systemctl restart sshd\n' "$SVC_USER"
if as_svc sudo -n systemctl restart sshd 2>&1 | sed 's/^/  /'; then
	die "that should have been refused. $SUDOERS is too permissive - look at it now."
else
	echo "  -> refused, as designed"
fi

echo
echo "denied - the escalation everyone tries first:"
printf '$ sudo -u %s sudo -n -i\n' "$SVC_USER"
as_svc sudo -n -i 2>&1 | sed 's/^/  /' || echo "  -> refused, as designed"

cat <<EOF

  Read the refusal text: "a password is required" or "not allowed to execute".
  The first means sudo would let it through with a password - and $SVC_USER has
  none, so it is a permanent no. The second means the rule does not exist at
  all. Different sentences, different fixes.

  Note also what a restriction to 'systemctl restart lab-app.service' does NOT
  restrict: nothing stops $SVC_USER from asking systemd for that restart over
  and over. Least privilege is about what can be reached, not about rate.
EOF

# ================================================== 2. the ACL is load-bearing
step "2. removing the ACL - the failure that has no visible cause"

echo "before: the service is writing happily."
echo "  state    : $(prop ActiveState) ($(prop SubState))"
before_lines="$(wc -l <"$SHARED/lab-app.log" 2>/dev/null || echo 0)"
echo "  log lines: $before_lines"

echo
echo "now remove the single ACL entry that grants $SVC_USER access."
echo "-x removes an entry. Nothing else changes: same owner, same group, same"
echo "mode. 'ls -ld' will look almost identical."
echo
printf '$ setfacl -x u:%s %s\n' "$SVC_USER" "$SHARED"
setfacl -x "u:$SVC_USER" "$SHARED"
ls -ld "$SHARED" | sed 's/^/  /'
echo "  ^ the '+' is still there, because the DEFAULT entries remain. The"
echo "    access entry is gone. ls cannot tell you which."

# The existing log file keeps its own ACL, so the service must be pushed into
# creating a new one for the directory permission to matter.
mv -f "$SHARED/lab-app.log" "$SHARED/lab-app.log.prev"

echo
echo "restarting the service so it has to create the file again:"
systemctl restart "$SERVICE" || true
sleep 4

echo
echo "  state    : $(prop ActiveState) ($(prop SubState))"
echo "  Result   : $(prop Result)"
echo
echo "what the journal says - this is the whole lesson:"
journalctl -u "$SERVICE" --no-pager --lines=8 | sed 's/^/  /'

cat <<'EOF'

  "Permission denied" and nothing else. The process is running as the right
  user, the directory has the right owner, the right group and the right mode,
  and it still cannot write. Nothing in ls -l explains it.

  This is why 'getfacl' belongs in your reflexes next to 'ls -l'. On a machine
  that uses ACLs, ls is not a complete answer and does not warn you.
EOF

step "2b. putting the ACL back"
printf '$ setfacl -m u:%s:rwx %s\n' "$SVC_USER" "$SHARED"
setfacl -m "u:$SVC_USER:rwx" "$SHARED"
getfacl -p "$SHARED" | sed 's/^/  /'

systemctl reset-failed "$SERVICE" 2>/dev/null || true
systemctl restart "$SERVICE"
sleep 4

echo
echo "  state    : $(prop ActiveState) ($(prop SubState))"
ls -l "$SHARED" | sed 's/^/  /'
rm -f "$SHARED/lab-app.log.prev"

[[ "$(prop ActiveState)" == "active" ]] || die "the service did not recover. look at:  journalctl -u $SERVICE -n 30"
echo "  recovered."

# ================================================= 3. setgid is load-bearing
step "3. removing the setgid bit - the failure that appears tomorrow"

echo "this is the nastiest of the three, because nothing fails today."
echo
printf '$ chmod g-s %s\n' "$SHARED"
chmod g-s "$SHARED"
ls -ld "$SHARED" | sed 's/^/  /'

echo
echo "now create a file as root, the way a careless admin would:"
rm -f "$SHARED/handover.txt"
touch "$SHARED/handover.txt"
ls -l "$SHARED/handover.txt" | sed 's/^/  /'
echo "  ^ group is root's primary group, not $DATA_GROUP. Every member of"
echo "    $DATA_GROUP has just lost access to this file, and nobody will notice"
echo "    until one of them tries to open it."

echo
echo "put it back and repeat the experiment:"
printf '$ chmod g+s %s\n' "$SHARED"
chmod g+s "$SHARED"
rm -f "$SHARED/handover.txt"
touch "$SHARED/handover.txt"
ls -l "$SHARED/handover.txt" | sed 's/^/  /'
echo "  ^ group is $DATA_GROUP again, inherited from the directory."
echo
echo "note that chmod g+s did NOT fix the file created while it was off. Losing"
echo "the bit means every file made in that window is still wrong, and finding"
echo "them is a job for:  find $SHARED ! -group $DATA_GROUP -ls"
rm -f "$SHARED/handover.txt"

if [[ "$HARD" != "yes" ]]; then
	cat <<NEXT

---------------------------------------------------------------
  try this yourself
---------------------------------------------------------------

  Over-grant on purpose, then see it with the tool that would
  have caught it in review:

      sudo usermod -aG $DATA_GROUP $SVC_USER
      id $SVC_USER
      sudo -u $SVC_USER ls -l $SHARED     # works - via the group now
      sudo gpasswd -d $SVC_USER $DATA_GROUP

  The access looks the same from the application and is much
  wider: group membership applies to every file with that group
  anywhere on the machine, not just this directory. An ACL is
  scoped to the object you set it on. That difference is the
  reason ACLs exist.

  Then break the mask, which is the ACL mistake people actually
  make in production:

      sudo setfacl -m m::r-x $SHARED
      getfacl -p $SHARED                  # read the 'effective' lines
      sudo -u $SVC_USER touch $SHARED/x   # denied, despite u:$SVC_USER:rwx
      sudo setfacl -m m::rwx $SHARED

  An entry granting rwx under a mask of r-x grants r-x. getfacl
  tells you in a comment that is easy to skim past, and chmod on
  a file with ACLs rewrites that mask - which is how permissions
  "randomly" tighten after someone runs a chmod.

  Then run this again with --hard, to break sudo itself. Safely.

NEXT
	exit 0
fi

# ---------------------------------------------------------------- hard mode
step "--hard: the lockout, and why visudo exists"

cat <<'EOF'
A syntax error anywhere under /etc/sudoers.d makes sudo refuse to run AT ALL.
Not the broken rule - all of it. On a cloud VM with no root password and no
console, that is a machine you cannot administer any more.

So we are going to write a broken file to a TEMPORARY path and let visudo
reject it there. Nothing is installed. This is the habit: build, check,
install - never edit in place.
EOF

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# A missing '=' - a real typo, not a contrived one.
cat >"$tmp" <<BROKEN
appsvc ALL(root) NOPASSWD: /usr/bin/systemctl restart lab-app.service
BROKEN

echo
echo "the file:"
sed 's/^/  /' "$tmp"
echo
printf '$ visudo -cf %s\n' "$tmp"
if visudo -cf "$tmp" 2>&1 | sed 's/^/  /'; then
	echo "  -> visudo accepted it, which it should not have. Read it again."
else
	echo "  -> rejected, with a line number. This is the check that saves you."
fi
rm -f "$tmp"
trap - EXIT

step "--hard: now break the real one, and recover from it"

echo "backing up first, because this one IS installed:"
cp -a "$SUDOERS" "$SUDOERS.bak"
ls -l "$SUDOERS.bak" | sed 's/^/  /'

# A permissions mistake rather than a syntax one: sudo silently ignores any
# file under sudoers.d that is group- or world-writable. No error, no warning,
# the rule simply is not there.
echo
echo "this time the mistake is the MODE, not the syntax:"
printf '$ chmod 0644 %s\n' "$SUDOERS"
chmod 0644 "$SUDOERS"
ls -l "$SUDOERS" | sed 's/^/  /'

echo
echo "the file is still perfectly valid sudoers syntax. Ask sudo what it thinks:"
printf '$ sudo -l -U %s\n' "$SVC_USER"
sudo -l -U "$SVC_USER" 2>&1 | sed 's/^/  /' || true

cat <<EOF

  The rule is gone, and sudo said nothing about why. 0644 is group- and
  world-readable but, more importantly, it is not 0440 - sudo requires that
  files under sudoers.d are not writable by group or other, and skips any that
  are without complaint on the happy path.

  You will find it in the journal, though, which is the lesson:
    journalctl -t sudo --since "5 minutes ago"
EOF
echo
journalctl -t sudo --no-pager --since "5 minutes ago" 2>/dev/null | tail -n 5 | sed 's/^/  /' || true

step "--hard: repairing"
install -m 0440 -o root -g root "$SUDOERS.bak" "$SUDOERS"
rm -f "$SUDOERS.bak"
visudo -cf "$SUDOERS" | sed 's/^/  /'
ls -l "$SUDOERS" | sed 's/^/  /'
echo
sudo -l -U "$SVC_USER" 2>&1 | sed 's/^/  /'

sudo -l -U "$SVC_USER" 2>/dev/null | grep -q "systemctl restart" \
	|| die "repair failed - the rule is still missing. run: sudo ./scripts/setup.sh"

cat <<'NEXT'

---------------------------------------------------------------
  the takeaway
---------------------------------------------------------------

  Four ways to get "Permission denied", and how to tell them apart:

  mode / owner wrong    ls -l shows it. the easy case
  ACL missing           ls -l looks FINE. only getfacl shows it,
                        and the '+' is the only hint
  setgid missing        nothing fails now. files created from now
                        on have the wrong group
  sudoers ignored       correct syntax, wrong file mode. sudo -l
                        is the authority, not the file you wrote

  And on this VM there is a fifth, which Day 13 is entirely about:
  SELinux denies an access that every one of the four above permits.
  When all four look right and it still fails, that is your cue:

      sudo ausearch -m avc -ts recent

NEXT
