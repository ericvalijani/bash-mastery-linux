#!/usr/bin/env bash
#
# lab-netcheck.sh - the payload for Day 06.
#
# Prints a reachability matrix for the namespace lab: every namespace, tried
# against every address in the topology. One line per source namespace.
#
# There is no daemon today. On a networking day the thing worth having running
# is not a service but a question you can ask repeatedly and get a stable
# answer to - so this is the script you leave in one terminal and re-run after
# every change in the other. break-and-fix.sh calls it, and so should you.
#
#   sudo ./lab-netcheck.sh            # the whole matrix
#   sudo ./lab-netcheck.sh client     # one source namespace only
#
# Needs root, because entering a network namespace does.

set -uo pipefail

# Deliberately NOT set -e. A reachability probe whose whole job is to report
# failures must not exit on the first one.

NS_LIST=(client router resolver auth)
TARGETS=(10.10.0.1 10.10.0.2 10.10.1.1 10.10.1.2 10.10.2.1 10.10.2.2)

die() { echo "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "needs root:  sudo $0 $*"
command -v ip >/dev/null 2>&1 || die "missing ip - install iproute2 (Debian) or iproute (RHEL)"
command -v ping >/dev/null 2>&1 || die "missing ping - install iputils-ping (Debian) or iputils (RHEL)"

sources=("${NS_LIST[@]}")
if [[ $# -gt 0 ]]; then
  case "$1" in
    client|router|resolver|auth) sources=("$1") ;;
    *) die "unknown namespace '$1' - one of: ${NS_LIST[*]}" ;;
  esac
fi

ip netns list | grep -qw client || die "no namespaces yet - run: sudo ./setup.sh"

# Header: the target addresses, printed vertically-ish so the matrix lines up.
printf '\n%-10s' "from \\ to"
for t in "${TARGETS[@]}"; do printf '%-12s' "$t"; done
printf '\n'
printf '%-10s' ""
for _ in "${TARGETS[@]}"; do printf '%-12s' "------------"; done
printf '\n'

fails=0

for src in "${sources[@]}"; do
  printf '%-10s' "$src"
  for t in "${TARGETS[@]}"; do
    if ip netns exec "$src" ping -c1 -W1 "$t" >/dev/null 2>&1; then
      printf '%-12s' "ok"
    else
      printf '%-12s' "--"
      fails=$((fails + 1))
    fi
  done
  printf '\n'
done

printf '\n'

if [[ $fails -eq 0 ]]; then
  echo "every address reachable from every namespace"
else
  echo "$fails of the probes failed"
  echo "'--' is not always wrong: ask whether a route exists for that direction."
fi

# Exit status reflects the network, not the script: 0 when everything answered.
[[ $fails -eq 0 ]]
