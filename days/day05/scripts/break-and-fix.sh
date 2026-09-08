#!/usr/bin/env bash
#
# Day 05 - break logging and time on purpose, three times, and repair each.
#
#   sudo ./scripts/break-and-fix.sh
#   sudo ./scripts/break-and-fix.sh --hard
#
# The three:
#
#   1. a rotated log that keeps growing, and a new one that stays empty
#   2. a journal that quietly deletes your history
#   3. a clock two hours in the future, and the log lines you cannot find
#
# --hard adds two more:
#
#   4. a rule that is perfect and never runs
#   5. journald dropping messages on the floor, and telling you so in a line
#      you were never going to read
#
# Every one of these is repaired before the script exits. Nothing here needs
# undoing afterwards.

set -uo pipefail

# shellcheck source=../../../lab/on-lab-vm.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

die() {
	echo "$*" >&2
	exit 1
}
step() {
	printf '\n---------------------------------------------------------------\n'
	printf '  %s\n' "$1"
	printf -- '---------------------------------------------------------------\n'
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "needs root:  sudo $0"

HARD="no"
[[ "${1:-}" == "--hard" ]] && HARD="yes"

SERVICE="lab-noisy.service"
APP_DIR="/var/log/lab-app"
APP_LOG="$APP_DIR/app.log"
ROTATE_RULE="/etc/logrotate.d/lab-app"
JOURNALD_CONF="/etc/systemd/journald.conf"
MAX_USE="200M"

[ -f "$ROTATE_RULE" ] || die "no $ROTATE_RULE - run setup.sh first"
systemctl is-active "$SERVICE" >/dev/null 2>&1 || die "$SERVICE is not running - run setup.sh first"

# --- small helpers, used to show state rather than assert it ---------------

log_size() { stat -c %s "$1" 2>/dev/null || echo 0; }
log_inode() { stat -c %i "$1" 2>/dev/null || echo "-"; }
journal_usage() { journalctl --disk-usage 2>/dev/null | tr -d '\n'; }
writer_pid() { systemctl show "$SERVICE" --property=ExecMainPID --value; }

# ===========================================================================
step "1. the rotated log that keeps growing"
# ===========================================================================
#
# This is the most common logrotate failure there is, and it looks exactly
# like logrotate being broken. It is not. It is doing what it was told.
#
# The rule setup.sh wrote has copytruncate. We take it out, which leaves
# logrotate using its default strategy: rename the file, create a new empty
# one. Renaming a file does not affect anyone who already has it open - a
# descriptor points at an inode, not at a name.
#
# lab-noisy opened its log once, on fd 3, and never reopens it. So after the
# rotation it is still writing to the same inode under a different name. The
# file you are tailing stays empty while the disk keeps filling.

echo
echo "the rule as it stands:"
grep -E 'copytruncate|size|rotate' "$ROTATE_RULE" | sed 's/^/  /'

echo
echo "take copytruncate out, so logrotate renames instead of truncating:"
sed -i '/copytruncate/d' "$ROTATE_RULE"
echo "  removed. the rest of the rule is unchanged."

echo
echo "fill the log past the 100k rotation threshold:"
/usr/local/bin/lab-noisy burst 1200 "$APP_LOG" >/dev/null 2>&1 || true
echo "  $APP_LOG is now $(log_size "$APP_LOG") bytes, inode $(log_inode "$APP_LOG")"

echo
echo "force the rotation:"
logrotate -f "$ROTATE_RULE" 2>&1 | sed 's/^/  /' || true
sleep 3

echo
echo "now look at what you have:"
ls -l "$APP_DIR" | sed 's/^/  /'
echo
echo "  app.log    $(log_size "$APP_LOG") bytes, inode $(log_inode "$APP_LOG")"
echo "  app.log.1  $(log_size "${APP_LOG}.1") bytes, inode $(log_inode "${APP_LOG}.1")"
echo
echo "wait three seconds and look again - the service writes once a second:"
sleep 3
echo "  app.log    $(log_size "$APP_LOG") bytes"
echo "  app.log.1  $(log_size "${APP_LOG}.1") bytes   <-- this is the one growing"

echo
echo "and here is the proof, found the same way as Day 04's ghost file:"
pid="$(writer_pid)"
if [ -n "$pid" ] && [ "$pid" != "0" ] && [ -d "/proc/$pid" ]; then
	ls -l "/proc/$pid/fd/3" 2>/dev/null | sed 's/^/  /'
	echo
	echo "  fd 3 of pid $pid still points at the OLD inode. the rename never"
	echo "  reached the process, because a rename cannot reach a process."
else
	echo "  (could not read the service pid - try: sudo lsof +D $APP_DIR)"
fi

echo
echo "THE FIX - put copytruncate back:"
#
# copytruncate copies the contents aside and then truncates the original
# file in place. The inode never changes, so the writer's descriptor stays
# valid and its next write lands in the file you are actually reading.
#
# The cost is a real race: anything written between the copy and the
# truncate is lost. When a daemon can be told to reopen its log - httpd,
# nginx and rsyslog all can - a postrotate stanza that signals it is the
# better answer:
#
#     postrotate
#         systemctl kill -s HUP lab-noisy.service
#     endscript
#
awk '/^}/ && !done { print "    copytruncate"; done = 1 } { print }' \
	"$ROTATE_RULE" >"${ROTATE_RULE}.new" && mv "${ROTATE_RULE}.new" "$ROTATE_RULE"
chmod 0644 "$ROTATE_RULE"
echo "  restored:"
grep -n 'copytruncate' "$ROTATE_RULE" | sed 's/^/    /'

systemctl restart "$SERVICE"
sleep 2
rm -f "${APP_LOG}.1" "${APP_LOG}".*.gz 2>/dev/null || true
echo "  service restarted, old rotations cleaned up"
echo "  $APP_LOG is $(log_size "$APP_LOG") bytes and growing again"

# ===========================================================================
step "2. the journal that deletes your history"
# ===========================================================================
#
# SystemMaxUse is not a warning threshold. It is a hard cap enforced by
# deleting the oldest entries, silently, while everything reports healthy.
#
# Nothing fails. No error appears. You find out weeks later, when you go
# looking for last Tuesday and last Tuesday is not there.

echo
echo "how much the journal is using right now:"
echo "  $(journal_usage)"
echo
echo "the cap in force:"
grep -E '^SystemMaxUse=' "$JOURNALD_CONF" | sed 's/^/  /'
echo
echo "oldest entry currently retained:"
journalctl -o short-full --no-pager 2>/dev/null | head -1 | sed 's/^/  /'

echo
echo "now drop the cap to 5M and restart journald:"
sed -i -E 's|^SystemMaxUse=.*|SystemMaxUse=5M|' "$JOURNALD_CONF"
systemctl restart systemd-journald
sleep 2

echo
echo "nothing failed. nothing warned. but:"
echo "  $(journal_usage)"
echo
echo "oldest entry retained NOW:"
journalctl -o short-full --no-pager 2>/dev/null | head -1 | sed 's/^/  /'
echo
echo "  compare those two timestamps. the history between them is gone, and"
echo "  nothing told you so. a cap is a retention decision, not a disk-space"
echo "  decision."

echo
echo "THE FIX - restore the cap:"
sed -i -E "s|^SystemMaxUse=.*|SystemMaxUse=${MAX_USE}|" "$JOURNALD_CONF"
systemctl restart systemd-journald
sleep 1
grep -E '^SystemMaxUse=' "$JOURNALD_CONF" | sed 's/^/  /'
echo
echo "  raising the cap does not bring anything back. deleted is deleted."
echo "  the only lever is setting it correctly before you need the history."
echo
echo "  the manual equivalents, for when the disk is full right now:"
echo "    journalctl --vacuum-size=50M"
echo "    journalctl --vacuum-time=7d"

# ===========================================================================
step "3. the clock two hours in the future"
# ===========================================================================
#
# A wrong clock does not break logging. It breaks READING logs, which is
# worse: everything looks fine and your conclusions are wrong.

echo
echo "where the clock is now:"
timedatectl | sed 's/^/  /'

echo
echo "turn off synchronisation and push the clock forward two hours:"
timedatectl set-ntp false 2>/dev/null || true
systemctl stop chronyd 2>/dev/null || true
date -s '+2 hours' >/dev/null 2>&1 || echo "  (could not set the clock - continuing)"
echo "  now: $(date)"

sleep 2
/usr/local/bin/lab-noisy burst 3 "$APP_LOG" >/dev/null 2>&1 || true
sleep 1

echo
echo "the entries just written, next to the ones from before the jump:"
journalctl -t lab-noisy -n 5 --no-pager -o short-full 2>/dev/null | sed 's/^/  /'

echo
echo "now the trap. ask for the last five minutes:"
echo "  journalctl -t lab-noisy --since '5 min ago'"
count="$(journalctl -t lab-noisy --since '5 min ago' --no-pager 2>/dev/null | grep -c 'message' || true)"
echo "  $count matching lines"
echo
echo "  everything written before the jump is now two hours 'ago' and falls"
echo "  outside the window. the entries exist. your query cannot see them."
echo "  on one machine that is annoying. across four machines during an"
echo "  incident it makes correlation impossible, and you will believe a"
echo "  false ordering of events."

echo
echo "THE FIX - hand the clock back to chronyd:"
systemctl start chronyd 2>/dev/null || true
timedatectl set-ntp true 2>/dev/null || true
#
# chronyd normally SLEWS a small error - speeds the clock up or slows it
# down until it catches up - rather than jumping it, because time going
# backwards breaks things badly: make, databases, certificate validity.
# makestep tells it to jump anyway, which is right exactly once: when you
# already know the clock is grossly wrong.
#
chronyc makestep >/dev/null 2>&1 || true
sleep 3
echo "  now: $(date)"
chronyc tracking 2>/dev/null | grep -E 'Reference ID|System time|Leap status' | sed 's/^/  /'
echo
echo "  if this VM has no outbound NTP the clock may still be wrong. that is"
echo "  a real finding, not a bug in this script: read 'chronyc sources -v',"
echo "  and fix it by hand with 'sudo date -s ...' if you have to."

if [ "$HARD" = "no" ]; then
	step "back to a known state"
	cat <<EOF
nothing above needs undoing. the rule has copytruncate again, the journal
cap is back to $MAX_USE, and chronyd owns the clock.

confirm the day:
  ./verify.sh

when you are ready for the two that are less obvious:
  sudo $0 --hard
EOF
	exit 0
fi

# ===========================================================================
step "4. (--hard) the rule that is perfect and never runs"
# ===========================================================================
#
# Everyone debugs the rule. Almost nobody checks whether anything is calling
# logrotate at all. 'logrotate -d' will happily tell you the rule is correct
# while the timer that would run it is disabled.

echo
echo "the rule is fine - logrotate says so itself:"
logrotate -d "$ROTATE_RULE" 2>&1 | tail -6 | sed 's/^/  /'

echo
echo "now stop the thing that actually runs it:"
systemctl stop logrotate.timer 2>/dev/null || true
systemctl disable logrotate.timer >/dev/null 2>&1 || true
echo "  logrotate.timer disabled"

echo
echo "the rule is still perfect. ask when it will next run:"
systemctl list-timers logrotate.timer --no-pager 2>&1 | sed 's/^/  /'
echo
echo "  no next run. a file in /etc/logrotate.d is a request, not a"
echo "  schedule. this is a disk-full outage whose config file reviews"
echo "  perfectly in a pull request."

echo
echo "THE FIX:"
systemctl enable --now logrotate.timer >/dev/null 2>&1 || true
systemctl list-timers logrotate.timer --no-pager 2>&1 | sed 's/^/  /'
echo
echo "  the two checks worth remembering, on any machine:"
echo "    systemctl list-timers --all | grep logrotate"
echo "    head /var/lib/logrotate/logrotate.status"
echo
echo "  that status file is logrotate's memory of when each file last"
echo "  rotated. a date months old next to a file that is still growing is"
echo "  the same finding, found faster."

# ===========================================================================
step "5. (--hard) journald dropping messages on the floor"
# ===========================================================================
#
# journald rate-limits per service: by default about 10000 messages every 30
# seconds. Past that it discards, and it tells you - in a single line, inside
# the log you are already failing to read.
#
# This matters because the moment a service starts logging fast is exactly
# the moment something is going wrong, which is exactly when you cannot
# afford to lose lines.

echo
echo "tighten the limit hard so you can watch it happen:"
grep -qE '^#?RateLimitIntervalSec=' "$JOURNALD_CONF" &&
	sed -i -E 's|^#?RateLimitIntervalSec=.*|RateLimitIntervalSec=30s|' "$JOURNALD_CONF" ||
	echo 'RateLimitIntervalSec=30s' >>"$JOURNALD_CONF"
grep -qE '^#?RateLimitBurst=' "$JOURNALD_CONF" &&
	sed -i -E 's|^#?RateLimitBurst=.*|RateLimitBurst=50|' "$JOURNALD_CONF" ||
	echo 'RateLimitBurst=50' >>"$JOURNALD_CONF"
systemctl restart systemd-journald
sleep 1
echo "  RateLimitBurst=50 per 30s"

echo
echo "write 400 messages as fast as we can:"
/usr/local/bin/lab-noisy burst 400 "$APP_LOG" >/dev/null 2>&1 || true
sleep 3

echo
echo "how many of the 400 the journal kept:"
kept="$(journalctl -t lab-noisy --since '1 min ago' --no-pager 2>/dev/null | grep -c 'message' || true)"
echo "  $kept"
echo
echo "and the line that admits it:"
journalctl --since '1 min ago' --no-pager 2>/dev/null | grep -i 'suppress' | tail -3 | sed 's/^/  /' ||
	echo "  (none found yet - try: journalctl -b | grep -i suppress)"

echo
echo "now count the same messages in the FILE, which nothing rate-limits:"
echo "  $(grep -c 'message' "$APP_LOG" 2>/dev/null || echo 0) lines in $APP_LOG"
echo
echo "  same process, same loop, two destinations, different totals. if you"
echo "  had checked only the journal you would have concluded the service"
echo "  had stopped logging."

echo
echo "THE FIX - restore the defaults:"
sed -i -E 's|^RateLimitBurst=.*|RateLimitBurst=10000|' "$JOURNALD_CONF"
sed -i -E 's|^RateLimitIntervalSec=.*|RateLimitIntervalSec=30s|' "$JOURNALD_CONF"
systemctl restart systemd-journald
sleep 1
grep -E '^RateLimit' "$JOURNALD_CONF" | sed 's/^/  /'
echo
echo "  the real answer for a service that legitimately logs that fast is"
echo "  RateLimitBurst=0 in a drop-in for that unit alone - not raising it"
echo "  globally, which removes the protection stopping one broken service"
echo "  from evicting every other service's history."

step "back to a known state"
cat <<EOF
everything is restored: copytruncate is in the rule, the journal cap is
$MAX_USE, rate limiting is back to the defaults, logrotate.timer is enabled
and chronyd owns the clock.

the two sequences to remember from today:

  ROTATION   a rename does not reach an open descriptor. use copytruncate,
             or signal the daemon to reopen. never neither.

  RETENTION  SystemMaxUse deletes silently. set it before you need the
             history, because raising it later brings nothing back.

confirm the day:
  ./verify.sh
EOF
