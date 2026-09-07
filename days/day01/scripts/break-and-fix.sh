#!/usr/bin/env bash
#
# Day 01 - break the service on purpose, watch systemd react, put it back.
#
#   sudo ./scripts/break-and-fix.sh          crash it, watch Restart= work
#   sudo ./scripts/break-and-fix.sh --hard   also break the unit FILE, then repair
#
# The point: a crashed process and a bad unit file look completely different in
# systemctl status, and telling them apart is most of the diagnosis.
#
# Everything this breaks, it repairs. If you interrupt it halfway, run
# sudo ./scripts/setup.sh to get back to a known state.

set -euo pipefail

# This script changes system state, so it refuses to run anywhere but a
# disposable lab VM. See lab/on-lab-vm.sh for what counts as one.
# shellcheck source=../../../lab/on-lab-vm.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

SERVICE="lab-demo"
UNIT="/etc/systemd/system/$SERVICE.service"

HARD="no"
[[ "${1:-}" == "--hard" ]] && HARD="yes"

die() { echo "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "needs root:  sudo $0 ${1:-}"

systemctl cat "$SERVICE" >/dev/null 2>&1 \
	|| die "$SERVICE is not installed - run 'sudo ./scripts/setup.sh' first"

step() {
	printf '\n---------------------------------------------------------------\n'
	printf '  %s\n' "$1"
	printf -- '---------------------------------------------------------------\n'
}

# --value prints the value with no Key= prefix.
prop() { systemctl show "$SERVICE" --property="$1" --value; }

step "before"
pid_before="$(prop ExecMainPID)"
restarts_before="$(prop NRestarts)"
echo "main PID  : $pid_before"
echo "NRestarts : $restarts_before"
echo "state     : $(prop ActiveState) ($(prop SubState))"

# Guard, and not a paranoid one: systemd reports ExecMainPID as 0 when a
# service is not running, and 'kill -9 0' signals EVERY process in the caller's
# process group. As root over ssh that means killing your own session, and
# possibly more. Never pass an unchecked PID to kill.
case "$pid_before" in
	"" | 0)
		die "$SERVICE is not running (ExecMainPID=$pid_before), so there is nothing to kill.
 Start it first:  sudo systemctl start $SERVICE
 Or check why it is down:  journalctl -u $SERVICE -n 30" ;;
esac

step "killing PID $pid_before with SIGKILL"
echo "SIGKILL cannot be caught, so the trap in lab-demo.sh will NOT run."
echo "To systemd this is indistinguishable from a real crash - which is"
echo "exactly what makes it a useful test."
echo
kill -9 "$pid_before"

# RestartSec=2, so give systemd a moment. Polling beats a blind sleep: we stop
# as soon as a different PID is up.
waited=0
while [[ $waited -lt 20 ]]; do
	[[ "$(prop ActiveState)" == "active" && "$(prop ExecMainPID)" != "$pid_before" ]] && break
	sleep 1
	waited=$((waited + 1))
done

step "after"
pid_after="$(prop ExecMainPID)"
echo "main PID  : $pid_after   (was $pid_before)"
echo "NRestarts : $(prop NRestarts)   (was $restarts_before)"
echo "state     : $(prop ActiveState) ($(prop SubState))"
echo "back in about ${waited}s - RestartSec=2 plus systemd's reaction time"

if [[ "$pid_after" == "$pid_before" || "$pid_after" == "0" ]]; then
	die "that did not work. look at:  journalctl -u $SERVICE -n 30"
fi

step "what the journal recorded"
echo "Look for the 'Main process exited' / 'Scheduled restart' pair - that is"
echo "systemd narrating the decision it just made."
echo
journalctl -u "$SERVICE" --no-pager --lines=15 | sed 's/^/  /'

if [[ "$HARD" != "yes" ]]; then
	cat <<'NEXT'

---------------------------------------------------------------
  try this yourself
---------------------------------------------------------------

  Kill it repeatedly and fast:

      for i in 1 2 3 4 5 6; do
          sudo kill -9 $(systemctl show lab-demo -p ExecMainPID --value)
          sleep 1
      done
      systemctl status lab-demo

  Sooner or later you get "start request repeated too quickly" and systemd
  gives up entirely. That is StartLimitBurst / StartLimitIntervalSec - the
  rate limit that stops a crash loop becoming a denial of service against
  your own machine.

  So Restart=always does NOT mean "will always be running". Knowing that
  difference is the whole point of today.

  Clear it with:  sudo systemctl reset-failed lab-demo

  Then run this again with --hard, to see a broken unit FILE instead - a
  different failure with a different fix.

NEXT
	exit 0
fi

# ------------------------------------------------------------- hard mode
step "--hard: pointing ExecStart at a binary that does not exist"
cp -a "$UNIT" "$UNIT.bak"
echo "backed up to $UNIT.bak"
sed -i 's|^ExecStart=.*|ExecStart=/usr/local/bin/lab-demo-typo|' "$UNIT"
grep '^ExecStart=' "$UNIT" | sed 's/^/  now: /'

echo
echo "systemd has not read that yet - nothing has changed for the running"
echo "service. This is the moment people forget daemon-reload."
systemctl daemon-reload
echo "reloaded."

step "restarting into the broken config"
systemctl restart "$SERVICE" || echo "(restart returned non-zero, as expected)"
sleep 3

step "what a misconfiguration looks like"
echo "Compare this with the crash above. No useful restart loop, because the"
echo "binary will never exist, and the status line names the real problem."
echo
systemctl status "$SERVICE" --no-pager --lines=10 | sed 's/^/  /' || true
echo
echo "  Result         : $(prop Result)"
echo "  ExecMainStatus : $(prop ExecMainStatus)   <- 203 means could not execute"

step "the tool that would have caught this before any restart"
printf '$ systemd-analyze verify %s\n' "$UNIT"
systemd-analyze verify "$UNIT" 2>&1 | sed 's/^/  /' || true

step "repairing"
mv -f "$UNIT.bak" "$UNIT"
systemctl daemon-reload
# reset-failed clears both the failure state and the start-limit counter. A
# unit that tripped the limit will not start even once it is fixed.
systemctl reset-failed "$SERVICE" || true
systemctl start "$SERVICE"
sleep 2

grep '^ExecStart=' "$UNIT" | sed 's/^/  restored: /'
echo "  state    : $(prop ActiveState) ($(prop SubState))"
echo "  main PID : $(prop ExecMainPID)"

[[ "$(prop ActiveState)" == "active" ]] || die "repair failed. run: sudo ./scripts/setup.sh"

cat <<'NEXT'

---------------------------------------------------------------
  the takeaway
---------------------------------------------------------------

  crash           -> Result=exit-code, NRestarts climbs, systemd keeps trying
  bad ExecStart   -> status=203/EXEC, no useful loop, fix the file
  bad unit syntax -> systemd-analyze verify tells you; systemctl often will not

  Three failures, three signatures, three fixes. Naming which one you are
  looking at within ten seconds of systemctl status is the skill today buys.

NEXT
