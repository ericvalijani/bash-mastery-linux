#!/usr/bin/env bash
#
# The payload behind lab-cap.service.
#
# Day 01's payload just ticked. Day 02's payload wrote a file. This one is
# allowed to misbehave: on request it eats memory as fast as bash can allocate
# it, or burns a whole core doing nothing. That is the point. A cap you have
# never seen enforced is a cap you are only hoping is there.
#
#   lab-cap                  tick quietly (what the service does normally)
#   lab-cap hog-mem          allocate 10 MB a second until something stops it
#   lab-cap hog-cpu          spin flat out until something stops it
#
# Run by hand it will happily take the machine down with it - a 2 GB VM has
# no swap, so nothing here is polite. Run inside the cgroup that setup.sh
# builds, it cannot: MemoryMax kills it at 100 MB and CPUQuota holds it to a
# fifth of one core. Same program, two very different neighbours.

set -euo pipefail

MODE="${1:-${LAB_CAP_MODE:-tick}}"
CHUNK_MB="${LAB_CAP_CHUNK_MB:-10}"

# Anything on stdout lands in the journal:  journalctl -u lab-cap -f
echo "lab-cap starting, pid $$, mode $MODE, running as $(id -un)"

# Under cgroups v2 a process has exactly one cgroup, and this is how you ask
# which. The '0::' prefix is the v2 marker - v1 printed one numbered line per
# controller, which is most of why v1 was confusing.
if [[ -r /proc/self/cgroup ]]; then
	echo "my cgroup: $(cat /proc/self/cgroup)"
fi

# systemctl stop sends SIGTERM, and this is where it arrives. Same delay as
# Day 01 and Day 02: a trap only runs once the current foreground command
# returns, so a stop can wait for the sleep below.
trap 'echo "lab-cap caught SIGTERM after ${SECONDS}s, exiting cleanly"; exit 0' TERM
trap 'echo "lab-cap caught SIGINT (ctrl-c), exiting cleanly"; exit 0' INT

# There is deliberately no trap for SIGKILL, and adding one is not an
# oversight you can correct. The kernel never delivers SIGKILL to the process;
# it removes the process. Nothing runs afterwards - no trap, no cleanup, no
# flush of a half-written file. That is also true of the OOM kill you are
# about to trigger, which is why 'hog-mem' below prints its progress as it
# goes rather than summarising at the end: there is no end.

case "$MODE" in
tick)
	count=0
	while true; do
		count=$((count + 1))
		echo "lab-cap alive, pid $$, tick $count, ${SECONDS}s"
		sleep 5
	done
	;;

hog-mem)
	echo "allocating ${CHUNK_MB} MB per second. watch for the kill:"
	echo "  journalctl -u lab-cap -f"
	chunks=()
	total=0
	while true; do
		# A bash variable is ordinary heap memory, so this is a genuine
		# allocation and not a sparse-file trick. tr turns the NULs into
		# 'x' because bash cannot hold a NUL byte in a variable.
		chunk=$(head -c "$((CHUNK_MB * 1024 * 1024))" /dev/zero | tr '\0' 'x')
		chunks+=("$chunk")
		total=$((total + CHUNK_MB))
		echo "allocated ${total} MB in ${#chunks[@]} chunks, ${SECONDS}s"
		sleep 1
	done
	;;

hog-cpu)
	echo "spinning. this is one busy loop in bash, so it is one core at most:"
	echo "  systemd-cgtop -1 --depth=2"
	echo "  cat /sys/fs/cgroup/system.slice/lab-cap.service/cpu.stat"
	spins=0
	while true; do
		# 200k iterations of nothing, then one line of output. Without the
		# report you would have no way to see throttling take effect, and
		# with a report every iteration the journal would be the bottleneck
		# rather than the CPU quota.
		for ((i = 0; i < 200000; i++)); do :; done
		spins=$((spins + 1))
		echo "completed $spins x 200k iterations in ${SECONDS}s of wall clock"
	done
	;;

*)
	echo "unknown mode: $MODE" >&2
	echo "usage: $(basename "$0") [tick|hog-mem|hog-cpu]" >&2
	exit 1
	;;
esac
