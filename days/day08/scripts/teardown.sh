#!/usr/bin/env bash
#
# Day 08 teardown - stop both servers and remove today's configuration.
#
# It deliberately leaves Day 06's namespaces up: Days 09 and 18 stand on the
# same topology, and rebuilding it costs nothing but is one more thing to go
# wrong.
#
# Nothing here is required. Days 09-20 do not conflict with anything Day 08
# leaves behind.

set -uo pipefail

say() { printf '\n==> %s\n' "$*"; }

CONF_DIR="/etc/unbound/lab"
RUN_DIR="/run/lab-dns"
LOG_DIR="/var/log/lab-dns"
ZONE="lab.test"
RESOLVER_IP="10.10.1.2"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "needs root:  sudo $0" >&2; exit 1; }

say "stopping both servers"
for name in auth resolver; do
  pidfile="$RUN_DIR/$name.pid"
  if [[ -f "$pidfile" ]]; then
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      sleep 1
      echo "ok    stopped $name (pid $pid)"
    else
      echo "ok    $name was not running"
    fi
    rm -f "$pidfile"
  else
    echo "ok    no pidfile for $name"
  fi
done

say "what the client gets now"
# The client's resolv.conf still names the resolver, which no longer exists.
# This is worth seeing once: the failure of a nameserver that is gone rather
# than wrong.
if ip netns list 2>/dev/null | grep -qw client; then
  printf '$ ip netns exec client dig +time=2 +tries=1 +short A www.%s\n' "$ZONE"
  # Capture it instead of asserting what it will say. What you get depends on
  # what is still standing, and the honest lesson is in reading the result -
  # not in a paragraph that was written before the command ran.
  gone_answer="$(ip netns exec client dig +time=2 +tries=1 +short A "www.$ZONE" 2>/dev/null || true)"
  if [[ -n "$gone_answer" ]]; then
    printf '  %s\n' "$gone_answer"
  fi
  echo
  if [[ -z "$gone_answer" ]]; then
    echo "  Nothing, after a two second wait. There is no server on $RESOLVER_IP"
    echo "  any more, so the query is not refused or denied - it goes unanswered."
    echo "  A timeout is the one DNS failure that costs the caller real time."
  else
    echo "  You still got an address, and that is worth more than a timeout would"
    echo "  have been. The resolver on $RESOLVER_IP is stopped, so this answer came"
    echo "  from somewhere else: another nameserver listed in the client's"
    echo "  resolv.conf, or a stub resolver of its own that kept a copy. A name"
    echo "  that still resolves after you turned the server off is the most"
    echo "  misleading state in DNS - the thing you decommissioned looks fine"
    echo "  until the last cached copy expires."
    echo
    echo "  Find out who answered:"
    echo "    ip netns exec client cat /etc/resolv.conf"
    echo "    ip netns exec client dig A www.$ZONE | sed -n '/SERVER/p'"
  fi
fi

say "removing today's files"
rm -f "$CONF_DIR/auth.conf" "$CONF_DIR/resolver.conf" \
      "$CONF_DIR/auth.conf.orig" "$CONF_DIR/resolver.conf.orig"
rmdir "$CONF_DIR" 2>/dev/null || true
rm -f /usr/local/bin/lab-dnsq
rmdir "$RUN_DIR" 2>/dev/null || true
echo "ok    removed the configs and /usr/local/bin/lab-dnsq"
echo "ok    left $LOG_DIR alone - the query logs are worth reading after"

say "what is deliberately left"
cat <<'EOF'
Day 06's namespaces are still up. Days 09 and 18 need them, and Day 09 in
particular is much more interesting with a DNS server to point tcpdump at.

To remove them anyway:
  sudo ./days/day06/scripts/teardown.sh     # or: sudo ./lab/lab.sh netns-down

Day 07's per-namespace resolv.conf under /etc/netns/client is also left in
place, because it is what makes a query with no @server work at all.
EOF
