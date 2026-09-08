#!/usr/bin/env bash
#
# Day 03 - build a service that cannot take the machine down with it.
#
#   sudo ./scripts/setup.sh
#
# It creates:
#   file   /usr/local/bin/lab-cap                   the payload
#   unit   lab-cap.service                          MemoryMax=100M, CPUQuota=20%
#   user   labworker                                one account, its own limits
#   file   /etc/security/limits.d/90-lab-nofile.conf nofile for labworker only
#
# Safe to run again at any time: every step converges on the same end state
# rather than assuming a clean machine, so it is also the way back if
# break-and-fix.sh leaves you somewhere odd.
#
# Two different limit systems are set up here on purpose, because they are
# constantly confused for each other:
#
#   cgroups v2   applies to a UNIT, enforced by the kernel on the whole group
#                of processes, no login involved. MemoryMax, CPUQuota.
#   pam_limits   applies to a LOGIN SESSION, read from limits.d by PAM when a
#                user logs in. ulimit, nofile, nproc.
#
# The second one does not apply to services at all, which is the single most
# common wrong answer to "why is my daemon still hitting 1024 open files".
# break-and-fix.sh --hard demonstrates it.

set -euo pipefail

# This script changes system state, so it refuses to run anywhere but a
# disposable lab VM. See lab/on-lab-vm.sh for what counts as one.
# shellcheck source=../../../lab/on-lab-vm.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

SERVICE="lab-cap"
UNIT="/etc/systemd/system/$SERVICE.service"
BIN="/usr/local/bin/$SERVICE"
WORK_USER="labworker"
LIMITS="/etc/security/limits.d/90-lab-nofile.conf"
NOFILE_SOFT="8192"
NOFILE_HARD="16384"
MEM_MAX="100M"
CPU_QUOTA="20%"
CG="/sys/fs/cgroup"

HERE="$(cd "$(dirname "$0")" && pwd)"

die() {
	echo "$*" >&2
	exit 1
}
say() { printf '\n==> %s\n' "$*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "this installs a unit and an account, so it needs root:  sudo $0"

# ------------------------------------------------------- the hierarchy first
say "checking this machine really is on cgroups v2"

# Everything below assumes the unified hierarchy. On a v1 or hybrid machine
# the files this day reads (memory.max, cpu.max, memory.events) do not exist
# under those names, and systemd's resource settings behave differently. Rocky
# 9 is v2 by default; check rather than assume, because a machine that was
# booted with systemd.unified_cgroup_hierarchy=0 looks normal until you look.
if mount | grep -q "cgroup2 on $CG"; then
	echo "cgroup2 is mounted on $CG - unified hierarchy, good"
else
	echo "cgroup2 is NOT mounted on $CG. this machine is on cgroups v1 or hybrid." >&2
	echo "check the kernel command line for systemd.unified_cgroup_hierarchy=0:" >&2
	echo "  cat /proc/cmdline" >&2
	die "day 03 needs the unified hierarchy"
fi

echo
echo "controllers this machine can delegate:"
cat "$CG/cgroup.controllers"
echo "(memory and cpu must both be in that list, or the caps below are ignored"
echo " silently - systemd accepts the setting either way)"

# ------------------------------------------------------------- the payload
say "installing the payload: $BIN"

[[ -f "$HERE/lab-cap.sh" ]] || die "cannot find $HERE/lab-cap.sh - run this from days/day03"
install -m 0755 "$HERE/lab-cap.sh" "$BIN"
echo "installed $BIN"

# --------------------------------------------------------------- the unit
say "writing $UNIT"

# Note what is NOT here: no User=. This service runs as root, unlike Day 02's,
# because the point today is that a cap does not depend on who you are. Root
# inside a cgroup with MemoryMax=100M gets killed at 100 MB exactly like
# anybody else. Privilege and resource limits are separate mechanisms, and
# people reach for the wrong one all the time.
cat >"$UNIT" <<EOF
[Unit]
Description=Day 03 capped worker
Documentation=file://$BIN

[Service]
Type=simple
Environment=LAB_CAP_MODE=tick
ExecStart=$BIN \${LAB_CAP_MODE}
Restart=on-failure
RestartSec=2

# The cap that kills. Enforced by the kernel on every process in this unit's
# cgroup, added together - not per process.
MemoryMax=$MEM_MAX

# Without this the kernel would swap rather than kill, and on a machine with
# swap you would wait a long time to see anything. Setting it to 0 makes the
# limit a hard wall, which is what you want to observe once on purpose.
MemorySwapMax=0

# The cap that slows. 20% of ONE core per second of wall clock. This one
# never kills anything: the process is stopped and resumed, which is why a
# throttled service looks healthy in systemctl status and terrible to users.
CPUQuota=$CPU_QUOTA

# systemd's own file-descriptor limit for the service. This is the setting
# that actually applies to a daemon. limits.d below does NOT.
LimitNOFILE=4096

# Report the accounting even when no cap is hit, so memory.current and
# cpu.stat are populated from the start.
MemoryAccounting=yes
CPUAccounting=yes
TasksAccounting=yes

[Install]
WantedBy=multi-user.target
EOF

echo "unit written. systemd has not read it yet:"
systemctl daemon-reload
echo "  daemon-reload done"

say "enabling and starting $SERVICE"
systemctl enable --now "$SERVICE"

# Restart rather than trust whatever was running from an earlier run: this
# script is meant to be re-runnable, and a stale process would still be
# carrying the OLD caps. cgroup settings are applied when the cgroup is
# created, and a daemon-reload does not move a running process into a new one.
systemctl restart "$SERVICE"
sleep 2

systemctl is-active "$SERVICE" >/dev/null 2>&1 \
	|| die "$SERVICE did not start. read the reason:  systemctl status $SERVICE; journalctl -u $SERVICE -n 30"
echo "$SERVICE is active"

# ------------------------------------------------- prove the caps landed
say "what systemd thinks the caps are"
systemctl show "$SERVICE" -p MemoryMax -p MemorySwapMax -p CPUQuotaPerSecUSec -p LimitNOFILE

say "what the KERNEL thinks the caps are"

# These two lists must agree. When they do not, the setting was accepted by
# systemd and dropped by the kernel - usually a missing delegated controller,
# occasionally a typo systemd parsed as a unit it does not enforce. Reading
# both is the habit worth taking from today.
SVC_CG="$CG/system.slice/$SERVICE.service"
if [[ -d "$SVC_CG" ]]; then
	for f in memory.max memory.swap.max cpu.max memory.current pids.current; do
		if [[ -r "$SVC_CG/$f" ]]; then
			printf '  %-18s %s\n' "$f" "$(cat "$SVC_CG/$f")"
		fi
	done
	echo
	echo "memory.max is $MEM_MAX in bytes. cpu.max is 'quota period' in"
	echo "microseconds: 20000 100000 means 20 ms of CPU per 100 ms, which is"
	echo "the $CPU_QUOTA you asked for, expressed the way the kernel stores it."
else
	echo "no cgroup directory at $SVC_CG" >&2
	echo "(a service that exits immediately leaves no cgroup behind to look at)" >&2
fi

# ------------------------------------------------------ the login-side limit
say "the other limit system: one account, its own nofile"

if id "$WORK_USER" >/dev/null 2>&1; then
	echo "$WORK_USER already exists - leaving it alone"
else
	# This one gets a real shell, unlike Day 02's appsvc. pam_limits is read
	# at LOGIN, so an account that cannot log in cannot demonstrate it.
	useradd --create-home --shell /bin/bash --comment "Day 03 limits demo" "$WORK_USER"
	echo "created $WORK_USER with /bin/bash"
fi

cat >"$LIMITS" <<EOF
# Day 03 - raise the open-file limit for one account and nobody else.
#
# Fields: <domain> <type> <item> <value>
#   domain  a user, or @group, or * for everyone
#   type    soft (the default, raisable by the user up to hard) or hard
#   item    nofile, nproc, memlock, core, ...
#
# The file is read by pam_limits during login. Order matters: the LAST
# matching line wins, which is why a '*' rule in an earlier file can be
# overridden here, and why 90- sorts late on purpose.
$WORK_USER soft nofile $NOFILE_SOFT
$WORK_USER hard nofile $NOFILE_HARD
EOF
chmod 0644 "$LIMITS"
echo "wrote $LIMITS"
cat "$LIMITS"

say "proving it applies to that account and only that account"

# 'su -' is a login shell, so PAM runs and pam_limits is consulted. Without
# the dash you get a non-login shell, PAM does not run, and you would see the
# system default and conclude the file was ignored. That single character is
# the whole difference.
echo "$WORK_USER, login shell:"
su - "$WORK_USER" -c 'printf "  soft nofile: %s\n  hard nofile: %s\n" "$(ulimit -Sn)" "$(ulimit -Hn)"'

echo "root, this shell:"
printf '  soft nofile: %s\n  hard nofile: %s\n' "$(ulimit -Sn)" "$(ulimit -Hn)"

echo
echo "same machine, two different answers. that is the point of limits.d."

# ----------------------------------------------------------------- summary
say "done"
cat <<EOF
Installed:
  $BIN
  $UNIT              MemoryMax=$MEM_MAX  CPUQuota=$CPU_QUOTA  LimitNOFILE=4096
  $LIMITS   nofile $NOFILE_SOFT/$NOFILE_HARD for $WORK_USER
  account $WORK_USER

Next:
  sudo ./scripts/explore-procs.sh      the tour: processes, signals, cgroups
  sudo ./scripts/break-and-fix.sh      hit the caps on purpose
  ./verify.sh                          the automatic checks (no root needed)
EOF
