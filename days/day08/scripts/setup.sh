#!/usr/bin/env bash
#
# Day 08 setup - run two DNS servers of two different kinds on Day 06's
# topology, and make the difference between them visible.
#
#   auth namespace     10.10.2.2   unbound serving lab.test from its own data
#   resolver namespace 10.10.1.2   unbound caching, sending lab.test to auth
#   client namespace   10.10.0.2   asks either one and compares the answers
#
# Yesterday's sixty-line Python server proved that a DNS answer is a byte
# layout. Today a real server does it, and the interesting part moves: not
# "can something answer" but "which of these two answered, and from where".
#
# Run it on the machine you are reading this on. No VM today.
#
# Idempotent: run it as many times as you like.

set -euo pipefail

HERE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say()  { printf '\n==> %s\n' "$*"; }
die()  { echo "$*" >&2; exit 1; }

NS_CLIENT="client"
NS_RESOLVER="resolver"
NS_AUTH="auth"

AUTH_IP="10.10.2.2"
RESOLVER_IP="10.10.1.2"
CLIENT_IP="10.10.0.2"

ZONE="lab.test"
WWW_IP="10.10.2.10"

CONF_DIR="/etc/unbound/lab"
RUN_DIR="/run/lab-dns"
LOG_DIR="/var/log/lab-dns"

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "needs root:  sudo $0"

# ---------------------------------------------------------------------------
say "0. checking what this day needs"

# Name the packages. A missing binary is only useful as an error if it comes
# with the command that installs it.
missing=""
for t in ip dig unbound unbound-checkconf ss; do
  command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
if [[ -n "$missing" ]]; then
  echo "missing:$missing" >&2
  echo >&2
  echo "  RHEL family:     sudo dnf install -y unbound bind-utils iproute" >&2
  echo "  Debian/Ubuntu:   sudo apt-get install -y unbound dnsutils iproute2" >&2
  die "install those and run this again"
fi
echo "ok    ip, dig, unbound, unbound-checkconf and ss are all present"

# ---------------------------------------------------------------------------
say "1. making sure Day 06's topology is up"

# Same rule as Day 07: namespaces live in the running kernel and never survive
# a reboot, so a missing topology is the normal case and not an error. Build it
# rather than complaining about it. Day 06's setup.sh is idempotent.
DAY06_SETUP="$HERE_DIR/../../day06/scripts/setup.sh"

need_topology="no"
for ns in "$NS_CLIENT" "$NS_RESOLVER" "$NS_AUTH"; do
  ip netns list | grep -qw "$ns" || need_topology="yes"
done

if [[ "$need_topology" == "yes" ]]; then
  echo "a namespace is missing - building Day 06's topology first."
  echo "That is what a reboot removes, so this is expected, not a fault."
  echo
  if [[ -x "$DAY06_SETUP" ]]; then
    bash "$DAY06_SETUP" || die "Day 06's setup.sh failed - fix that first:
  sudo ./days/day06/scripts/setup.sh"
  elif [[ -x "$HERE_DIR/../../../lab/lab.sh" ]]; then
    bash "$HERE_DIR/../../../lab/lab.sh" netns-up ||
      die "could not build the topology with lab.sh netns-up"
  else
    die "no '$NS_CLIENT' namespace, and Day 06's setup.sh is not where it
  should be. Build the topology first:
  sudo ./days/day06/scripts/setup.sh"
  fi
  say "1b. back in Day 08 - the topology is up"
fi

for ns in "$NS_CLIENT" "$NS_RESOLVER" "$NS_AUTH"; do
  ip netns list | grep -qw "$ns" || die "still no '$ns' namespace after building"
done

# A namespace existing is not the same as a packet crossing.
ip netns exec "$NS_CLIENT" ping -c1 -W2 "$AUTH_IP" >/dev/null 2>&1 ||
  die "the client cannot reach $AUTH_IP - Day 06's routing is broken.
  Check it with:  sudo ./days/day06/scripts/lab-netcheck.sh"

echo "ok    client, resolver and auth exist, and the client can reach $AUTH_IP"

# ---------------------------------------------------------------------------
say "2. clearing Day 07's nameserver out of the way"

# Day 07 left a Python server bound to 10.10.1.2:53. Two things cannot hold
# the same port, and the error unbound would print - "address already in use" -
# would send you looking for a bug in today's configuration instead of
# yesterday's leftovers.
if [[ -f /run/lab-nameserver.pid ]]; then
  pid="$(cat /run/lab-nameserver.pid 2>/dev/null || true)"
  if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 1
    echo "ok    stopped Day 07's nameserver (pid $pid) - it owned $RESOLVER_IP:53"
  else
    echo "ok    Day 07's pidfile was stale; nothing was running"
  fi
  rm -f /run/lab-nameserver.pid
else
  echo "ok    nothing from Day 07 is holding port 53"
fi

# Day 07's per-namespace resolv.conf pointed the client at the resolver. That
# is still exactly what we want today, so it is left alone if it is there -
# and written if it is not, because Day 08 must stand up on its own.
install -d -m 0755 "/etc/netns/$NS_CLIENT"
printf 'nameserver %s\noptions timeout:2 attempts:1\n' "$RESOLVER_IP" \
  > "/etc/netns/$NS_CLIENT/resolv.conf"
echo "ok    /etc/netns/$NS_CLIENT/resolv.conf points at $RESOLVER_IP"

# ---------------------------------------------------------------------------
say "3. writing the authoritative zone"

install -d -m 0755 "$CONF_DIR" "$RUN_DIR" "$LOG_DIR"

# unbound is best known as a recursive resolver, but a `local-zone: static`
# makes it authoritative for one name space and nothing else. "static" is the
# word that earns check five: for a name inside the zone that has no data,
# unbound answers NXDOMAIN - "that name does not exist" - rather than going
# looking for it. That is what being authoritative MEANS: the right to say no.
#
# The trailing dots are not decoration. lab.test. is a fully qualified name;
# lab.test would be treated as relative and is a classic silent mistake.
cat > "$CONF_DIR/auth.conf" <<EOF
# Day 08 - the authoritative half. Serves $ZONE and refuses everything else.
server:
  # Namespaces already isolate this process, so the usual chroot and
  # privilege drop would only add moving parts to a teaching lab.
  username: ""
  chroot: ""
  directory: "$CONF_DIR"
  pidfile: "$RUN_DIR/auth.pid"
  logfile: "$LOG_DIR/auth.log"
  use-syslog: no
  verbosity: 2
  log-queries: yes

  interface: $AUTH_IP
  port: 53
  do-ip6: no
  access-control: 0.0.0.0/0 refuse
  access-control: 10.10.0.0/16 allow

  # No recursion here. An authoritative server knows its own zone and is not
  # in the business of finding anything else.
  local-zone: "." refuse

  # And here is the zone itself.
  local-zone: "$ZONE." static

  # SOA: who is in charge, and the five timers every zone must carry.
  # serial refresh retry expire minimum(negative TTL)
  local-data: "$ZONE. 3600 IN SOA ns.$ZONE. admin.$ZONE. 1 3600 600 86400 60"

  # NS: the zone naming its own nameserver, plus that name's address.
  local-data: "$ZONE. 3600 IN NS ns.$ZONE."
  local-data: "ns.$ZONE. 3600 IN A $AUTH_IP"

  # The records you will actually query. www has a deliberately short TTL so
  # the cache in front of it can be watched expiring in under a minute.
  local-data: "www.$ZONE. 30 IN A $WWW_IP"
  local-data: "auth.$ZONE. 3600 IN A $AUTH_IP"
  local-data: "client.$ZONE. 3600 IN A $CLIENT_IP"

  # A CNAME is an alias: it answers with a NAME, not an address, so whoever
  # asked has to ask again. A recursive server usually chases that for you;
  # a static local-zone does not, so here you get the bare alias back and see
  # the second lookup that a CNAME always costs somebody.
  local-data: "web.$ZONE. 3600 IN CNAME www.$ZONE."
EOF

unbound-checkconf "$CONF_DIR/auth.conf" >/dev/null ||
  die "unbound rejected $CONF_DIR/auth.conf - run unbound-checkconf on it to see why"
echo "ok    $CONF_DIR/auth.conf (SOA, NS, three A records, one CNAME)"

# ---------------------------------------------------------------------------
say "4. writing the recursive resolver"

# The resolver holds no zone data at all. A stub-zone says: for anything under
# $ZONE, ask $AUTH_IP and treat its answer as final. Everything else follows
# the normal path to the root servers, which is why this half is the one that
# needs the outside world - and the one that caches.
cat > "$CONF_DIR/resolver.conf" <<EOF
# Day 08 - the recursive half. Owns no zone; caches everything it learns.
server:
  username: ""
  chroot: ""
  directory: "$CONF_DIR"
  pidfile: "$RUN_DIR/resolver.pid"
  logfile: "$LOG_DIR/resolver.log"
  use-syslog: no
  verbosity: 2
  log-queries: yes

  interface: $RESOLVER_IP
  port: 53
  do-ip6: no
  access-control: 0.0.0.0/0 refuse
  access-control: 10.10.0.0/16 allow

  # These two exist only because this lab uses private addresses. Unbound
  # discards RFC1918 answers by default to protect you from DNS rebinding,
  # which would silently blank every reply from $AUTH_IP.
  private-domain: "$ZONE."
  do-not-query-localhost: no

  # And this one is the trap that cost a real debugging session. .test is a
  # RESERVED top-level domain (RFC 6761), and unbound ships a built-in
  # local-zone for it that answers NXDOMAIN for everything underneath -
  # before your stub-zone is ever consulted. Your configuration is correct,
  # the authoritative server is up and answering, and the resolver still
  # says the name does not exist, with an SOA naming "localhost.".
  # "nodefault" removes the built-in zone; "transparent" then says explicitly
  # that names here are to be looked up normally - which means the stub-zone
  # below. Both the parent (test.) and our own zone are listed, because the
  # built-in entry is on the PARENT and a resolver matches the closest
  # enclosing zone it knows about.
  local-zone: "test." nodefault
  local-zone: "$ZONE." transparent

  # The lab's zone is not signed and hangs off no real root, so do not try
  # to validate it if this build of unbound has a trust anchor configured.
  domain-insecure: "$ZONE."

  # Small caps so a cache is something you can reason about rather than
  # a black box. cache-min-ttl 0 means the zone's own TTLs are respected
  # exactly - a 30 second record really does expire in 30 seconds.
  cache-min-ttl: 0
  cache-max-ttl: 3600
  msg-cache-size: 4m
  rrset-cache-size: 8m

stub-zone:
  name: "$ZONE."
  stub-addr: $AUTH_IP
  # stub-first: no  -> if $AUTH_IP is down, fail. Do not quietly go and ask
  # the internet about a name that is ours. That fallback is a real feature
  # and a real footgun; break-and-fix shows you the failure it prevents.
  stub-first: no
EOF

unbound-checkconf "$CONF_DIR/resolver.conf" >/dev/null ||
  die "unbound rejected $CONF_DIR/resolver.conf - run unbound-checkconf on it to see why"
echo "ok    $CONF_DIR/resolver.conf (stub-zone for $ZONE. -> $AUTH_IP)"

# ---------------------------------------------------------------------------
say "5. starting both servers"

# Stop anything left from a previous run of THIS script before starting, so a
# second run is a restart rather than a port collision.
stop_one() {
  local pidfile="$1"
  [[ -f "$pidfile" ]] || return 0
  local pid
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$pidfile"
}

stop_one "$RUN_DIR/auth.pid"
stop_one "$RUN_DIR/resolver.pid"

# A pidfile only knows about processes THIS script started and recorded. If an
# earlier run died before writing one, or you edited the config and started a
# second copy by hand, an old unbound can still be sitting on :53 inside the
# namespace with the OLD configuration loaded. Two daemons on one address is
# the worst failure mode in this whole day: the kernel hands each query to
# whichever one answers, so identical commands give different answers at
# random - and one of those answers is from a config file you already fixed.
# Kill by namespace, not by pidfile, so a stray copy cannot survive.
for ns in "$NS_AUTH" "$NS_RESOLVER"; do
  stray="$(ip netns pids "$ns" 2>/dev/null || true)"
  for pid in $stray; do
    [[ -r "/proc/$pid/comm" ]] || continue
    if [[ "$(cat "/proc/$pid/comm" 2>/dev/null || true)" == "unbound" ]]; then
      echo "      stopping a stray unbound (pid $pid) in $ns"
      kill "$pid" 2>/dev/null || true
    fi
  done
done
sleep 1

# unbound daemonises itself, so there is no backgrounding to do here. Each one
# is started INSIDE its namespace: the process is ordinary, its network is not.
ip netns exec "$NS_AUTH" unbound -c "$CONF_DIR/auth.conf" ||
  die "the authoritative server would not start - see $LOG_DIR/auth.log"
ip netns exec "$NS_RESOLVER" unbound -c "$CONF_DIR/resolver.conf" ||
  die "the resolver would not start - see $LOG_DIR/resolver.log"

# Give them a moment to bind, then require the listener to be real. "the
# process is running" and "the port is open" are different claims.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if ip netns exec "$NS_AUTH" ss -ulpn 2>/dev/null | grep -q ":53" &&
     ip netns exec "$NS_RESOLVER" ss -ulpn 2>/dev/null | grep -q ":53"; then
    break
  fi
  sleep 1
done

ip netns exec "$NS_AUTH" ss -ulpn | grep -q ":53" ||
  die "nothing is listening on $AUTH_IP:53 - see $LOG_DIR/auth.log"
ip netns exec "$NS_RESOLVER" ss -ulpn | grep -q ":53" ||
  die "nothing is listening on $RESOLVER_IP:53 - see $LOG_DIR/resolver.log"

echo "ok    authoritative on $AUTH_IP:53, resolver on $RESOLVER_IP:53"

install -m 0755 "$HERE_DIR/lab-dnsq.sh" /usr/local/bin/lab-dnsq
echo "ok    /usr/local/bin/lab-dnsq"

# ---------------------------------------------------------------------------
say "6. proving it, and proving the two answers differ"

q() { ip netns exec "$NS_CLIENT" dig +time=2 +tries=1 "$@"; }

# The zone answers for itself.
soa="$(q +short SOA "$ZONE." "@$AUTH_IP" || true)"
[[ -n "$soa" ]] || die "the zone did not return a SOA - see $LOG_DIR/auth.log"
echo "ok    SOA from $AUTH_IP:  $soa"

# The same name, through the resolver, which does not own it.
via_auth="$(q +short A "www.$ZONE" "@$AUTH_IP" || true)"
# The resolver has just started with an empty cache, so this is its first
# recursion ever: it has to open a socket to $AUTH_IP and wait. A cold cache
# can return NOERROR with an EMPTY answer if the query times out before that
# round trip finishes. That is not a misconfiguration, it is a race, and it
# would have failed this script for a reason that fixes itself. Ask a few
# times before believing the bad news.
via_res=""
for _ in 1 2 3 4 5; do
  via_res="$(q +short A "www.$ZONE" "@$RESOLVER_IP" || true)"
  [[ "$via_res" == "$WWW_IP" ]] && break
  sleep 1
done
[[ "$via_auth" == "$WWW_IP" ]] || die "www.$ZONE from the zone gave '$via_auth', expected $WWW_IP"
if [[ "$via_res" != "$WWW_IP" ]]; then
  res_status="$(q "A" "www.$ZONE" "@$RESOLVER_IP" | sed -n 's/.*status: \([A-Z]*\).*/\1/p' | head -1)"
  echo "www.$ZONE through the resolver gave '$via_res' (status: ${res_status:-none})," >&2
  echo "expected $WWW_IP. The zone itself is fine, so this is the resolver." >&2
  if [[ "${res_status:-}" == "NXDOMAIN" ]]; then
    echo >&2
    echo "NXDOMAIN from a resolver whose stub-zone is correct almost always means" >&2
    echo "unbound's built-in local-zone for the reserved TLD .test is answering" >&2
    echo "before your stub-zone is consulted. Confirm it with:" >&2
    echo >&2
    echo "  ip netns exec client dig SOA www.$ZONE @$RESOLVER_IP | grep -A1 AUTHORITY" >&2
    echo >&2
    echo "An SOA naming 'localhost.' is that built-in zone. The config this script" >&2
    echo "writes disables it; if you still see it, check that these two lines are" >&2
    echo "present in $CONF_DIR/resolver.conf:" >&2
    echo >&2
    echo "  local-zone: \"test.\" nodefault" >&2
    echo "  local-zone: \"$ZONE.\" transparent" >&2
  fi
  die "see $LOG_DIR/resolver.log for the resolver's own account"
fi
echo "ok    www.$ZONE is $WWW_IP from both servers"

# Same answer, different authority. This is the day in two lines.
aa_flags="$(q A "www.$ZONE" "@$AUTH_IP" | sed -n 's/^;; flags: \([a-z ]*\);.*/\1/p' | head -1)"
ra_flags="$(q A "www.$ZONE" "@$RESOLVER_IP" | sed -n 's/^;; flags: \([a-z ]*\);.*/\1/p' | head -1)"
echo "ok    the zone answers with flags: $aa_flags"
echo "ok    the resolver answers with flags: $ra_flags"
case "$aa_flags" in
  *aa*) : ;;
  *) echo "note  the zone's answer has no 'aa' flag, which it should - check local-zone static" ;;
esac

# A name inside the zone that does not exist. The point of authority.
if q "nope.$ZONE" "@$AUTH_IP" | grep -q "NXDOMAIN"; then
  echo "ok    nope.$ZONE returns NXDOMAIN, not an error and not a timeout"
else
  die "nope.$ZONE did not return NXDOMAIN - the zone is not 'static'"
fi

# The cache, twice.
first="$(q A "www.$ZONE" "@$RESOLVER_IP" | awk '$4 == "A" {print $2; exit}')"
sleep 2
second="$(q A "www.$ZONE" "@$RESOLVER_IP" | awk '$4 == "A" {print $2; exit}')"
echo "ok    the resolver's TTL for www.$ZONE went $first -> $second (it is counting down)"

cat <<EOF

Both servers are up.

  $AUTH_IP      authoritative for $ZONE, refuses everything else
  $RESOLVER_IP  recursive and caching, sends $ZONE to $AUTH_IP

Ask them both the same question:

  sudo lab-dnsq www.$ZONE          # run it twice - watch one TTL fall
  sudo lab-dnsq web.$ZONE          # a CNAME: an answer that is a name, not an address
  sudo lab-dnsq $ZONE SOA

Then take the tour:   sudo ./days/day08/scripts/explore-dns-server.sh
And break it:         sudo ./days/day08/scripts/break-and-fix.sh

Logs, with every query in them:
  $LOG_DIR/auth.log
  $LOG_DIR/resolver.log
EOF
