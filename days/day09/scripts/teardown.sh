#!/usr/bin/env bash
#
# Day 09 teardown - remove today's tooling and captures.
#
# The network itself belongs to Day 06 and is left alone. Today added an
# observer, not a topology, so there is very little to take away.

set -uo pipefail

say() { printf '\n==> %s\n' "$*"; }

CAP_DIR="/var/log/lab-trace"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "needs root:  sudo $0" >&2; exit 1; }

say "1. stopping any tcpdump left running in the namespaces"

# A capture started by hand and forgotten keeps writing to a file forever.
# Pidfiles are no help here because these were never started by a script, so
# we look at what is actually running inside each namespace.
found="no"
for ns in client router resolver auth; do
  ip netns list 2>/dev/null | grep -qw "$ns" || continue
  for pid in $(ip netns pids "$ns" 2>/dev/null || true); do
    [[ -r "/proc/$pid/comm" ]] || continue
    if [[ "$(cat "/proc/$pid/comm")" == "tcpdump" ]]; then
      echo "  stopping tcpdump (pid $pid) in $ns"
      kill "$pid" 2>/dev/null || true
      found="yes"
    fi
  done
done
[[ "$found" == "yes" ]] || echo "  ok  no tcpdump was running"

say "2. removing lab-trace"
if [[ -e /usr/local/bin/lab-trace ]]; then
  rm -f /usr/local/bin/lab-trace
  echo "  removed /usr/local/bin/lab-trace"
else
  echo "  ok  it was not installed"
fi

say "3. the captures"
if [[ -d "$CAP_DIR" ]]; then
  count="$(find "$CAP_DIR" -maxdepth 1 -name '*.pcap' 2>/dev/null | wc -l | tr -d ' ')"
  size="$(du -sh "$CAP_DIR" 2>/dev/null | cut -f1)"
  rm -rf "$CAP_DIR"
  echo "  removed $CAP_DIR - $count capture files, $size"
  echo
  echo "  Worth knowing why that mattered: a capture with no -c limit and no"
  echo "  rotation fills a disk quietly, and the machine you were debugging"
  echo "  then has a second problem that you caused."
else
  echo "  ok  nothing to remove"
fi

say "4. what is deliberately left behind"

# Nothing today touched the topology, and the point of saying so is that a
# teardown you cannot predict is worse than no teardown at all.
if ip netns list 2>/dev/null | grep -qw client; then
  echo "  Day 06's namespaces are still up. Today only watched them."
  echo "  To remove those as well:  sudo ./days/day06/scripts/teardown.sh"
else
  echo "  The namespaces are already gone."
fi

if ip netns exec resolver ss -ulpn 2>/dev/null | grep -q ":53"; then
  echo "  Day 08's DNS servers are still running, which is fine."
  echo "  To stop them:  sudo ./days/day08/scripts/teardown.sh"
fi

printf '\nDay 09 removed. The network is exactly as Day 06 left it.\n\n'
