#!/usr/bin/env bash
#
# Day 03 - hit every cap on purpose, read the evidence, put it back.
#
#   sudo ./scripts/break-and-fix.sh          the three resource failures
#   sudo ./scripts/break-and-fix.sh --hard   also break the limits themselves
#
# The point: "the service is running" and "the service is working" are
# different claims, and resource limits are where they come apart. A killed
# service is loud. A throttled one is silent, healthy-looking, and slow. A
# service that hit a file-descriptor ceiling reports an error that names
# neither the ceiling nor the setting that caused it.
#
# Everything this breaks, it repairs. If you interrupt it halfway, run
# sudo ./scripts/setup.sh to get back to a known state.

set -euo pipefail

# This script changes system state, so it refuses to run anywhere but a
# disposable lab VM. See lab/on-lab-vm.sh for what counts as one.
# shellcheck source=../../../lab/on-lab-vm.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

SERVICE="lab-cap"
UNIT="/etc/systemd/system/$SERVICE.service"
WORK_USER="labworker"
LIMITS="/etc/security/limits.d/90-lab-nofile.conf"
CG="/sys/fs/cgroup"
SVC_CG="$CG/system.slice/$SERVICE.service"
DROPIN_DIR="/etc/systemd/system/$SERVICE.service.d"
DROPIN="$DROPIN_DIR/90-lab-override.conf"

HARD="no"
[[ "${1:-}" == "--hard" ]] && HARD="yes"

die() {
	echo "$*" >&2
	exit 1
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "needs root:  sudo $0 ${1:-}"

systemctl cat "$SERVICE" >/dev/null 2>&1 || die "$SERVICE is not installed - run 'sudo ./scripts/setup.sh' first"

step() {
	printf '\n---------------------------------------------------------------\n'
	printf '  %s\n' "$1"
	printf -- '---------------------------------------------------------------\n'
}

prop() { systemctl show "$SERVICE" --property="$1" --value; }

# Read one field out of a cgroup file, or print a dash. Every read here is
# allowed to fail: a service that is down has no cgroup, and that is a state
# this script must survive rather than crash on.
cg_read() {
	if [[ -r "$SVC_CG/$1" ]]; then
		cat "$SVC_CG/$1"
	else
		echo "-"
	fi
}

cg_field() {
	local file="$1" key="$2" out=""
	out=$(cg_read "$file" | awk -v k="$key" '$1 == k {print $2; exit}') || true
	echo "${out:-0}"
}

# Switch the service into one of lab-cap's misbehaving modes. The mode lives
# in a drop-in rather than in the unit, so the unit file written by setup.sh
# stays exactly as you read it.
set_mode() {
	mkdir -p "$DROPIN_DIR"
	cat >"$DROPIN" <<EOF
[Service]
Environment=LAB_CAP_MODE=$1
EOF
	systemctl daemon-reload
	systemctl restart "$SERVICE"
}

clear_mode() {
	rm -f "$DROPIN"
	rmdir "$DROPIN_DIR" 2>/dev/null || true
	systemctl daemon-reload
	systemctl reset-failed "$SERVICE" 2>/dev/null || true
	systemctl restart "$SERVICE"
}

# ==================================================== 1. the memory cap kills
step "1. MemoryMax: the cap that kills"

echo "the cap, from both sides:"
printf '  systemd:  MemoryMax=%s\n' "$(prop MemoryMax)"
printf '  kernel:   memory.max=%s\n' "$(cg_read memory.max)"
echo
echo "oom kills recorded so far: $(cg_field memory.events oom_kill)"
echo
echo "now switching the payload to hog-mem. it allocates 10 MB a second, and"
echo "the cap is 100 MB, so this takes about ten seconds to end badly."

set_mode hog-mem

# Watch rather than sleep blindly, so the output shows the climb. 25 seconds
# is comfortably past the kill; the loop stops as soon as it sees one.
kills_before=$(cg_field memory.events oom_kill)
for _ in $(seq 1 25); do
	sleep 1
	printf '  memory.current=%-12s oom_kill=%s\n' "$(cg_read memory.current)" "$(cg_field memory.events oom_kill)"
	if [[ "$(cg_field memory.events oom_kill)" != "$kills_before" ]]; then
		break
	fi
done

echo
echo "what the journal says:"
journalctl -u "$SERVICE" -n 12 --no-pager || true

echo
echo "  ^ read the last lines carefully. the payload printed its allocations"
echo "    right up to the end and then stopped mid-sentence. there is no"
echo "    'shutting down' line and there never can be: an OOM kill inside a"
echo "    cgroup is a SIGKILL, so the trap in lab-cap.sh was never reached."
echo
echo "the receipt is in the kernel's counter, not in the log:"
printf '  memory.events oom_kill = %s\n' "$(cg_field memory.events oom_kill)"
printf '  memory.peak            = %s\n' "$(cg_read memory.peak)"
echo
echo "note what did NOT happen: the machine stayed responsive, nothing else"
echo "was killed, and no other service noticed. that is the difference between"
echo "a cgroup OOM and the global one - the kernel had a smaller set of"
echo "processes to choose a victim from, and chose inside it."
echo
echo "also note Restart=on-failure did its job, which is its own trap:"
systemctl show "$SERVICE" -p NRestarts
echo "  a service that is being killed and restarted every ten seconds shows"
echo "  as 'active (running)'. NRestarts is where the truth is."

step "1b. the fix, and why raising the cap is usually the wrong one"

echo "back to the quiet payload first:"
clear_mode
sleep 2
systemctl is-active "$SERVICE" >/dev/null 2>&1 && echo "  $SERVICE is active again"

echo
echo "raising the cap on a RUNNING service, without editing the unit file:"
systemctl set-property "$SERVICE" MemoryMax=200M
printf '  systemd:  MemoryMax=%s\n' "$(prop MemoryMax)"
printf '  kernel:   memory.max=%s\n' "$(cg_read memory.max)"
echo
echo "that took effect immediately, with no restart, because it writes the"
echo "kernel file directly. where it wrote the persistent copy is the part"
echo "worth knowing:"
ls -l /etc/systemd/system.control/"$SERVICE".service.d/ 2>/dev/null || true
echo "  ^ NOT your unit file. 'systemctl cat $SERVICE' shows both; reading"
echo "    $UNIT alone would now mislead you."

echo
echo "putting it back where setup.sh had it:"
systemctl revert "$SERVICE" >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl restart "$SERVICE"
sleep 1
printf '  systemd:  MemoryMax=%s\n' "$(prop MemoryMax)"
echo
echo "the honest fix for a service that hits its cap is almost never a bigger"
echo "cap. it is to find out what grew: a leak, a queue that stopped draining,"
echo "or a cache with no bound of its own. the cap did not cause the problem,"
echo "it reported it - loudly, and before the rest of the machine suffered."

# =============================================== 2. the cpu cap throttles
step "2. CPUQuota: the cap that does not kill, and does not show up"

printf '  systemd:  CPUQuotaPerSecUSec=%s\n' "$(prop CPUQuotaPerSecUSec)"
printf '  kernel:   cpu.max=%s   (quota period, microseconds)\n' "$(cg_read cpu.max)"
echo
echo "throttling so far:"
printf '  nr_throttled=%s  throttled_usec=%s\n' "$(cg_field cpu.stat nr_throttled)" "$(cg_field cpu.stat throttled_usec)"
echo
echo "switching to hog-cpu for 15 seconds. it spins as hard as bash can."

set_mode hog-cpu
sleep 15

echo
echo "after 15 seconds of a process trying to take a whole core:"
printf '  nr_throttled=%s  throttled_usec=%s\n' "$(cg_field cpu.stat nr_throttled)" "$(cg_field cpu.stat throttled_usec)"
printf '  usage_usec=%s\n' "$(cg_field cpu.stat usage_usec)"
echo
echo "and what the service looks like while that is happening:"
systemctl is-active "$SERVICE"
echo "  ^ 'active'. no failure, no restart, nothing in the journal, nothing in"
echo "    systemctl status. the process is being stopped and resumed hundreds"
echo "    of times a second and the only place that is visible is cpu.stat."
echo
echo "the payload's own output shows it from the inside:"
journalctl -u "$SERVICE" -n 5 --no-pager || true
echo "  ^ compare the iteration count against the wall-clock seconds. it did"
echo "    roughly a fifth of the work the same loop does unconstrained,"
echo "    because 20% of one core is exactly what it was given."

echo
echo "back to the quiet payload:"
clear_mode
sleep 2

echo
echo "this is the failure mode to remember from today. a latency complaint"
echo "with no error anywhere, on a service that every dashboard calls healthy,"
echo "is worth one look at cpu.stat before you look at anything else."

# ===================================== 3. the signal you cannot trap
step "3. SIGTERM against SIGKILL, on a real service"

echo "a clean stop. lab-cap.sh traps TERM and says so:"
systemctl restart "$SERVICE"
sleep 2
systemctl stop "$SERVICE"
journalctl -u "$SERVICE" -n 6 --no-pager || true
echo "  ^ 'caught SIGTERM, exiting cleanly'. note it can take a few seconds:"
echo "    the trap only runs when the current 'sleep 5' returns. systemd waits"
echo "    up to TimeoutStopSec ($(prop TimeoutStopUSec)) before losing patience."

echo
echo "now the same service, killed:"
systemctl start "$SERVICE"
sleep 2

# systemctl kill, not kill. 'kill $(systemctl show -p ExecMainPID --value)'
# is a well-known way to destroy a machine: a stopped service reports
# ExecMainPID=0, and 'kill -9 0' signals every process in your own process
# group. Let systemd resolve the target.
systemctl kill -s SIGKILL "$SERVICE"
sleep 2
journalctl -u "$SERVICE" -n 8 --no-pager || true
echo "  ^ no exit line. the last thing in the log is whatever it happened to"
echo "    be saying. systemd reports the unit as failed with signal KILL, and"
echo "    that report comes from systemd - not from the process, which had no"
echo "    opportunity to say anything."

echo
systemctl reset-failed "$SERVICE" 2>/dev/null || true
systemctl restart "$SERVICE"
sleep 1
echo "service restarted and healthy: $(systemctl is-active "$SERVICE")"

if [[ "$HARD" != "yes" ]]; then
	step "done"
	cat <<EOF
Three failures, three fixes, everything back where setup.sh left it.

The harder pair is behind --hard: a limit that is set correctly and does
nothing, and a cap so low the service can never start at all.

  sudo ./scripts/break-and-fix.sh --hard

Then:
  ./verify.sh
EOF
	exit 0
fi

# ============================ 4. the limit that is set and does not apply
step "4. --hard: limits.d is set correctly, and the service ignores it"

echo "the file says $WORK_USER may open a lot of files:"
grep -v '^#' "$LIMITS" | grep -v '^$' || true
echo
echo "and at a login it is obeyed:"
su - "$WORK_USER" -c 'printf "  su - %s:  soft nofile %s\n" "$(id -un)" "$(ulimit -Sn)"' || true

echo
echo "now the same account, reached the way a service is started:"
systemd-run --uid="$WORK_USER" --wait --collect --quiet \
	--property=StandardOutput=journal \
	/bin/bash -c 'echo "  systemd-run as $(id -un):  soft nofile $(ulimit -Sn)"' 2>/dev/null \
	|| echo "  (systemd-run unavailable - read the unit's LimitNOFILE below instead)"

echo
echo "different number, same account, same machine, same limits.d file."
echo
echo "the reason: limits.d is read by pam_limits, and PAM runs during LOGIN."
echo "systemd does not log anybody in to start a service - there is no PAM"
echo "session, so the file is never consulted. the setting that applies is the"
echo "unit's own:"
printf '  LimitNOFILE=%s\n' "$(prop LimitNOFILE)"
echo
echo "this is the most expensive misunderstanding in this whole day. the usual"
echo "shape of it: a daemon hits its descriptor ceiling, someone raises nofile"
echo "in limits.d, verifies it with 'su - user; ulimit -n', sees the new"
echo "number, declares it fixed, and the daemon keeps failing. both"
echo "observations were correct. they were about different things."

step "4b. the fix: put the limit where the service will read it"

mkdir -p "$DROPIN_DIR"
cat >"$DROPIN" <<'EOF'
[Service]
LimitNOFILE=16384
EOF
systemctl daemon-reload
systemctl restart "$SERVICE"
sleep 1
printf '  LimitNOFILE=%s\n' "$(prop LimitNOFILE)"
echo "  ^ a drop-in, not an edit to the unit file. survives a package upgrade"
echo "    that replaces the unit, and 'systemctl cat $SERVICE' shows both."

echo
echo "reverting:"
clear_mode
sleep 1
printf '  LimitNOFILE=%s\n' "$(prop LimitNOFILE)"

# ================================ 5. a cap so low nothing can start
step "5. --hard: a cap the service cannot even start under"

echo "setting MemoryMax=1M. bash itself needs more than that."
mkdir -p "$DROPIN_DIR"
cat >"$DROPIN" <<'EOF'
[Service]
MemoryMax=1M
MemorySwapMax=0
EOF
systemctl daemon-reload
systemctl reset-failed "$SERVICE" 2>/dev/null || true

# This restart is EXPECTED to end in a failed unit, so it must not abort the
# script. Restart=on-failure means systemd will try, hit the wall, try again,
# and eventually give up with 'start request repeated too quickly'.
systemctl restart "$SERVICE" 2>&1 | sed 's/^/  /' || true
sleep 3

echo
echo "state now:"
systemctl is-active "$SERVICE" || true
systemctl show "$SERVICE" -p Result -p NRestarts -p ExecMainStatus
echo
journalctl -u "$SERVICE" -n 12 --no-pager || true
echo
echo "  ^ this is the one that wastes an afternoon. the error does not say"
echo "    'memory limit'. it says the start request repeated too quickly, or"
echo "    reports a signal, and the actual cause is three lines further up in"
echo "    a message about the cgroup. when a service will not start at all,"
echo "    check its limits before you re-read its config:"
echo "      systemctl show $SERVICE -p MemoryMax -p TasksMax -p LimitNOFILE"

step "5b. the fix"

clear_mode
sleep 2
systemctl is-active "$SERVICE" >/dev/null 2>&1 \
	&& echo "  $SERVICE is active again on the caps setup.sh wrote:" \
	|| echo "  $SERVICE still not active - run 'sudo ./scripts/setup.sh'" >&2
systemctl show "$SERVICE" -p MemoryMax -p CPUQuotaPerSecUSec -p LimitNOFILE

step "done"
cat <<EOF
Five failures, five fixes. The unit file is exactly as setup.sh wrote it -
every override went into a drop-in and every drop-in has been removed.

Confirm nothing is left behind:
  systemctl cat $SERVICE          # unit only, no drop-ins listed
  ls /etc/systemd/system/$SERVICE.service.d/ 2>/dev/null || echo none
  ls /etc/systemd/system.control/ 2>/dev/null || echo none

Then:
  ./verify.sh
EOF
