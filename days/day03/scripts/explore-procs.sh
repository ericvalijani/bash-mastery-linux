#!/usr/bin/env bash
#
# Day 03 - a guided tour of processes, signals and cgroups. Read-only, safe to
# run as often as you like.
#
#   ./scripts/explore-procs.sh
#
# It reads state and starts one short-lived child of its own to demonstrate
# process states and signal delivery. It changes nothing on the machine.
#
# Two blocks want root and will say so if they do not have it: reading another
# unit's cgroup files, and systemd-cgtop. Run the whole tour with sudo if you
# would rather see everything at once.

set -euo pipefail

SERVICE="lab-cap"
CG="/sys/fs/cgroup"
SVC_CG="$CG/system.slice/$SERVICE.service"

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

# For the pipelines and redirections where the shell is the point.
run_sh() {
	printf '$ %s\n' "$1"
	bash -c "$1" 2>&1 | sed 's/^/  /' || true
	printf '\n'
}

heading "1. what a process actually is"

run_sh 'ps -eo pid,ppid,stat,rss,comm --sort=-rss | head -12'
note "STAT is the column people skip and then guess about. S sleeping, R running, D uninterruptible sleep, Z zombie, T stopped. A + suffix means foreground, s means session leader, l means multi-threaded"

run_sh 'ps -eo stat --no-headers | cut -c1 | sort | uniq -c | sort -rn'
note "almost everything on a healthy machine is S. a pile of D means storage or network is not answering, and no amount of kill will help - D cannot be interrupted, which is what the name means"

heading "2. the tree, and who inherits an orphan"

run_sh 'ps -eo pid,ppid,comm | awk "\$2 == 1" | head -10'
note "parent 1 means systemd adopted it. some were started by systemd; others are orphans whose real parent exited. you cannot tell which from here, which is why PPID is weaker evidence than people treat it as"

run_sh 'ps -o pid,ppid,stat,comm -p $$'
note "this tour's own shell. its parent is the shell you typed in"

heading "3. signals: the numbers, and the two you cannot catch"

run_sh 'kill -l | tr " " "\n" | head -20 | paste - - - -'
note "kill sends, it does not kill. 'kill -TERM' asks; 'kill -KILL' removes. SIGKILL (9) and SIGSTOP (19) are the two the kernel handles itself - a process is never told, so it cannot trap, ignore, or clean up"

printf '$ demonstration: a child that traps TERM, then does not survive KILL\n'
(
	# A child that announces the signal it received. Its own process group is
	# irrelevant here; what matters is that the trap runs for TERM and is
	# never reached for KILL.
	bash -c 'trap "echo \"  child: caught SIGTERM, exiting cleanly\"; exit 0" TERM; while true; do sleep 0.2; done' &
	child=$!
	sleep 0.5
	printf '  child pid %s, sending SIGTERM\n' "$child"
	kill -TERM "$child" 2>/dev/null || true
	wait "$child" 2>/dev/null || true

	bash -c 'trap "echo \"  child: caught SIGTERM\"; exit 0" TERM; while true; do sleep 0.2; done' &
	child=$!
	sleep 0.5
	printf '  new child pid %s, sending SIGKILL - expect silence\n' "$child"
	kill -KILL "$child" 2>/dev/null || true
	wait "$child" 2>/dev/null || true
	printf '  (nothing printed. there was nowhere for it to print from)\n'
) || true
printf '\n'

note "this is why 'kill -9' is not a fix. the process never gets to close a file, finish a write, or release a lock. reach for TERM, wait, and only then escalate"

heading "4. the unified hierarchy"

run_sh 'mount | grep cgroup'
note "one line, cgroup2, one mount point. cgroups v1 mounted a separate tree per controller and a process could sit in different places in each - which is the confusion v2 exists to remove"

run_sh 'cat /proc/self/cgroup'
note "the 0:: prefix is the v2 marker. one process, one cgroup, one path"

run "cat" "$CG/cgroup.controllers"
note "what this machine can delegate. if memory or cpu is missing here, MemoryMax and CPUQuota are accepted by systemd and then quietly not enforced"

run_sh 'systemd-cgls --no-pager -l 2>/dev/null | head -25'
note "the same tree systemd sees. note the slices: system.slice for services, user.slice for logins. a slice is a cgroup you can put limits on too, so you can cap ALL services at once"

heading "5. this day's capped service, from both sides"

run_sh "systemctl show $SERVICE -p MemoryMax -p MemorySwapMax -p CPUQuotaPerSecUSec -p LimitNOFILE -p MemoryCurrent 2>/dev/null"
note "systemd's view. infinity means no cap - if you see it here after running setup.sh, the setting did not take"

if [[ -d "$SVC_CG" ]]; then
	for f in memory.max memory.swap.max memory.current memory.peak cpu.max cpu.stat memory.events pids.current; do
		if [[ -r "$SVC_CG/$f" ]]; then
			printf '$ cat %s\n' "$SVC_CG/$f"
			sed 's/^/  /' "$SVC_CG/$f" || true
			printf '\n'
		fi
	done
	note "the kernel's view, and the one to trust. cpu.max is 'quota period' in microseconds. memory.events counts oom_kill, so it is the receipt that a cap was enforced rather than merely configured"
else
	printf '  no cgroup at %s\n' "$SVC_CG"
	note "either setup.sh has not run, or the service is not running, or you are not root and cannot read it. try: sudo $0"
fi

heading "6. where a cap comes from when you did not set one"

run_sh 'systemctl show -p DefaultMemoryMax -p DefaultTasksMax 2>/dev/null'
run_sh 'cat /sys/fs/cgroup/system.slice/memory.max 2>/dev/null || echo "(no cap on the whole slice)"'
note "limits nest. a unit can be held down by its slice even when the unit itself says infinity, and TasksMax has a default that surprises people running fork-heavy workloads"

heading "7. the OTHER limit system: ulimit and pam_limits"

run_sh 'ulimit -a'
note "this is your LOGIN SESSION, not a cgroup. it was decided by PAM when you logged in and is inherited by everything you start from this shell"

run_sh 'ls -1 /etc/security/limits.d/ 2>/dev/null; echo "---"; cat /etc/security/limits.d/*.conf 2>/dev/null'
note "the files PAM reads at login. last matching line wins, so numeric prefixes are how you control precedence"

run_sh 'grep -rn "pam_limits" /etc/pam.d/ | head -5'
note "the module that does it. if this line is missing from a service's PAM stack, limits.d has no effect for that path in - and sshd, su and login each have their own stack"

if command -v prlimit >/dev/null 2>&1; then
	run_sh 'prlimit --pid $$ | head -8'
	note "prlimit reads and CHANGES limits of a running process. that is the escape hatch when a long-running daemon needs a higher limit and you cannot restart it"
fi

heading "8. worth doing by hand next"

cat <<'EOF'
  systemd-run --scope -p MemoryMax=50M --pty bash
      an interactive shell in a throwaway cgroup with a cap. try to
      allocate past it and watch the shell die. no unit file, no reload

  systemd-cgtop -1 --depth=2
      top, but grouped the way the kernel accounts for it. the column to
      learn is %CPU against a quota you set yourself

  cat /sys/fs/cgroup/system.slice/lab-cap.service/cpu.stat
      nr_throttled and throttled_usec. a service being held at its quota
      shows up here and nowhere in systemctl status

  systemctl set-property lab-cap.service MemoryMax=200M
      change a cap on a RUNNING service. writes a drop-in under
      /etc/systemd/system.control/ - which is why your unit file will not
      mention it and 'systemctl cat' will

  journalctl -k | grep -iE "oom|killed process"
      the kernel side of an OOM kill. the cgroup one is quieter than the
      global one, on purpose

  ps -eo pid,ni,pri,comm --sort=ni | head
      nice values. the old, per-process way of saying the same thing
      cgroups now say per service - and still useful for one-off jobs
EOF
