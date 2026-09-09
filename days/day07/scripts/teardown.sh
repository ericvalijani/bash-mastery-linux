#!/usr/bin/env bash
#
# Day 07 teardown - stop the nameserver and remove the per-namespace files.
#
# This does NOT remove Day 06's namespaces. Days 08, 09 and 18 all stand on
# that topology, so it stays until you tear it down deliberately with
# ./days/day06/scripts/teardown.sh.

set -uo pipefail

say() { printf '\n==> %s\n' "$*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "needs root:  sudo $0" >&2; exit 1; }

PIDFILE="/run/lab-nameserver.pid"
LOGFILE="/var/log/lab-nameserver.log"

say "1. stopping the nameserver"

server_pid="$(cat "$PIDFILE" 2>/dev/null || true)"
if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
  # SIGCONT first: if you stopped it in break-and-fix and never resumed it,
  # a stopped process cannot act on SIGTERM.
  kill -CONT "$server_pid" 2>/dev/null || true
  kill "$server_pid" 2>/dev/null || true
  sleep 1
  if kill -0 "$server_pid" 2>/dev/null; then
    kill -KILL "$server_pid" 2>/dev/null || true
    echo "ok    pid $server_pid needed SIGKILL"
  else
    echo "ok    pid $server_pid stopped"
  fi
else
  echo "ok    nothing was running"
fi
rm -f "$PIDFILE"

say "2. removing the per-namespace configuration"

for f in /etc/netns/client/resolv.conf \
         /etc/netns/client/nsswitch.conf \
         /etc/netns/client/hosts \
         /etc/netns/resolver/resolv.conf \
         /etc/netns/resolver/hosts; do
  if [[ -e "$f" ]]; then
    rm -f "$f"
    echo "ok    removed $f"
  fi
done

# Only remove the directories if they are empty - somebody may have put
# something of their own in there.
for d in /etc/netns/client /etc/netns/resolver; do
  if [[ -d "$d" ]]; then
    rmdir "$d" 2>/dev/null && echo "ok    removed $d" || echo "kept  $d (not empty)"
  fi
done

say "3. removing the payload"

rm -f /usr/local/bin/lab-nameserver
echo "ok    removed /usr/local/bin/lab-nameserver"
rm -rf /root/day07-backup

say "4. proving the client is back to the host's resolver"

if ip netns list 2>/dev/null | grep -qw client; then
  echo "inside the client namespace, /etc/resolv.conf is now the host's own:"
  ip netns exec client cat /etc/resolv.conf 2>/dev/null | head -3 | sed 's/^/  /'
  echo
  echo "Nothing was unmounted to make that happen. The bind mount only existed"
  echo "for the duration of each 'ip netns exec', so deleting the file was"
  echo "enough - which is also why none of this survived a reboot anyway."
else
  echo "the client namespace is already gone - nothing left to check"
fi

say "what deliberately stays"

cat <<'EOF'
  - Day 06's four namespaces and their routing. Days 08, 09 and 18 need them.
  - /var/log/lab-nameserver.log, so you can still read which queries arrived.
  - the host's /etc/resolv.conf, /etc/hosts and /etc/nsswitch.conf, which this
    day never wrote to in the first place.
EOF

printf '\n'
echo "  To read which queries arrived:  sudo tail -20 $LOGFILE"
echo "  To remove it:                   sudo rm -f $LOGFILE"
