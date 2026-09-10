#!/usr/bin/env bash
#
# Day 08 break-and-fix - five ways a working DNS service stops working, each
# one repaired before the next begins.
#
#   sudo ./break-and-fix.sh          three failures
#   sudo ./break-and-fix.sh --hard   plus two that look like correct config
#
# Every failure here is a real one, and the point of each is the SYMPTOM.
# SERVFAIL, REFUSED, NXDOMAIN and a stale-but-plausible answer are four
# different diagnoses, and telling them apart is the whole skill.

set -uo pipefail

die()  { echo "$*" >&2; exit 1; }
step() { printf '\n\n=== %s ===\n\n' "$*"; }
run_sh() { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/  /' || true; printf '\n'; }

AUTH_IP="10.10.2.2"
RESOLVER_IP="10.10.1.2"
ZONE="lab.test"
CONF_DIR="/etc/unbound/lab"
RUN_DIR="/run/lab-dns"
LOG_DIR="/var/log/lab-dns"

HARD="no"; [[ "${1:-}" == "--hard" ]] && HARD="yes"

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "needs root:  sudo $0"
ip netns list | grep -qw client || die "no client namespace - run setup.sh first"
[[ -f "$CONF_DIR/auth.conf" ]] || die "no $CONF_DIR/auth.conf - run setup.sh first"

# Restarting a server inside its namespace, by pidfile. Used after every edit,
# because unbound reads its configuration once, at start.
restart() {
  local ns="$1" conf="$2" pidfile="$3" pid
  if [[ -f "$pidfile" ]]; then
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      sleep 1
    fi
    rm -f "$pidfile"
  fi
  ip netns exec "$ns" unbound -c "$conf" || true
  sleep 1
}

ask() { ip netns exec client dig +time=2 +tries=1 "$@" 2>&1; }
status_of() { ask "$@" | sed -n 's/.*status: \([A-Z]*\).*/\1/p' | head -1; }

cp -a "$CONF_DIR/auth.conf"     "$CONF_DIR/auth.conf.orig"
cp -a "$CONF_DIR/resolver.conf" "$CONF_DIR/resolver.conf.orig"

# ---------------------------------------------------------------------------
step "1. the stub points somewhere nothing answers"

# One digit. The resolver still runs, still listens, still answers other
# questions - and cannot answer for our zone at all.
sed -i "s/stub-addr: $AUTH_IP/stub-addr: 10.10.2.99/" "$CONF_DIR/resolver.conf"
restart resolver "$CONF_DIR/resolver.conf" "$RUN_DIR/resolver.pid"

# The cache may still hold www from earlier, so ask for a name nobody has
# asked for yet. A cached answer would hide the fault completely - which is
# itself the lesson.
run_sh "ip netns exec client dig client.$ZONE @$RESOLVER_IP | grep -E '^;; ->>|^;; flags'"
printf '  status through the resolver: %s\n' "$(status_of "client.$ZONE" "@$RESOLVER_IP")"
printf '  status straight to the zone: %s\n\n' "$(status_of "client.$ZONE" "@$AUTH_IP")"

cat <<'EOF'
  SERVFAIL from the resolver, NOERROR from the zone.

  SERVFAIL is the resolver saying "I tried and I could not get an answer".
  That is not NXDOMAIN - the name is not being denied, the lookup is failing.
  Whenever one server fails and another succeeds for the same name, the fault
  is between them, not in the data.
EOF

run_sh "tail -n 3 $LOG_DIR/resolver.log"

sed -i "s/stub-addr: 10.10.2.99/stub-addr: $AUTH_IP/" "$CONF_DIR/resolver.conf"
restart resolver "$CONF_DIR/resolver.conf" "$RUN_DIR/resolver.pid"
printf '  fixed. status now: %s\n' "$(status_of "client.$ZONE" "@$RESOLVER_IP")"

# ---------------------------------------------------------------------------
step "2. the authoritative server is stopped, and the cache lies for a while"

# Warm the cache first, deliberately.
ask "+short" "A" "auth.$ZONE" "@$RESOLVER_IP" >/dev/null

if [[ -f "$RUN_DIR/auth.pid" ]]; then
  apid="$(cat "$RUN_DIR/auth.pid" 2>/dev/null || true)"
  if [[ -n "${apid:-}" ]] && kill -0 "$apid" 2>/dev/null; then
    kill "$apid" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$RUN_DIR/auth.pid"
fi

run_sh "ip netns exec auth ss -ulpn | grep ':53' || echo 'nothing listening on 53'"
printf '  a name already in the cache:  %s -> %s\n' "auth.$ZONE" \
  "$(ask '+short' 'A' "auth.$ZONE" "@$RESOLVER_IP" | head -1)"
printf '  a name that is not cached:    %s -> %s\n\n' "web.$ZONE" \
  "$(status_of "web.$ZONE" "@$RESOLVER_IP")"

cat <<'EOF'
  The server is completely dead, and the resolver still answers correctly for
  anything it happens to be holding. Users report "DNS is broken" and "DNS is
  fine" at the same time, truthfully, and which one you are depends only on
  what you asked for and when.

  This is why a monitoring check that queries a caching resolver proves almost
  nothing about the authoritative server behind it.
EOF

ip netns exec auth unbound -c "$CONF_DIR/auth.conf" || true
sleep 1
printf '  restarted. web.%s now: %s\n' "$ZONE" "$(status_of "web.$ZONE" "@$RESOLVER_IP")"

# ---------------------------------------------------------------------------
step "3. the client is not allowed to ask"

# access-control is not a firewall and does not drop the packet. It replies.
sed -i "s|access-control: 10.10.0.0/16 allow|access-control: 10.10.0.0/16 refuse|" "$CONF_DIR/auth.conf"
restart auth "$CONF_DIR/auth.conf" "$RUN_DIR/auth.pid"

run_sh "ip netns exec client dig auth.$ZONE @$AUTH_IP | grep -E '^;; ->>|^;; flags'"
printf '  status: %s\n\n' "$(status_of "auth.$ZONE" "@$AUTH_IP")"

cat <<'EOF'
  REFUSED, and it arrived immediately.

  Compare the three rejections you have now seen:
    NXDOMAIN  the name does not exist          (authority, answering)
    SERVFAIL  I could not complete the lookup  (a path problem)
    REFUSED   I will not answer you            (policy)

  A REFUSED that comes back instantly also tells you the packet arrived and
  the port is open, which a dropped packet never would.
EOF

cp -a "$CONF_DIR/auth.conf.orig" "$CONF_DIR/auth.conf"
restart auth "$CONF_DIR/auth.conf" "$RUN_DIR/auth.pid"
printf '  fixed. status now: %s\n' "$(status_of "auth.$ZONE" "@$AUTH_IP")"

if [[ "$HARD" != "yes" ]]; then
  rm -f "$CONF_DIR/auth.conf.orig" "$CONF_DIR/resolver.conf.orig"
  cat <<EOF


Three failures, three distinguishable symptoms, everything repaired.

Run it again with --hard for two more, both of which read as correct
configuration and neither of which prints an error:

  sudo ./days/day08/scripts/break-and-fix.sh --hard
EOF
  exit 0
fi

# ---------------------------------------------------------------------------
step "4. --hard: a TTL that is technically fine and operationally awful"

# Nothing here is a mistake. Every value is legal, the config passes
# unbound-checkconf, and the service works perfectly.
sed -i "s|local-data: \"www.$ZONE. 30 IN A 10.10.2.10\"|local-data: \"www.$ZONE. 86400 IN A 10.10.2.10\"|" "$CONF_DIR/auth.conf"
restart auth "$CONF_DIR/auth.conf" "$RUN_DIR/auth.pid"

run_sh "unbound-checkconf $CONF_DIR/auth.conf"
ask "+short" "A" "www.$ZONE" "@$RESOLVER_IP" >/dev/null
run_sh "ip netns exec client dig +noall +answer A www.$ZONE @$RESOLVER_IP"

# Now change the address, as you would during a real migration.
sed -i "s|local-data: \"www.$ZONE. 86400 IN A 10.10.2.10\"|local-data: \"www.$ZONE. 86400 IN A 10.10.2.77\"|" "$CONF_DIR/auth.conf"
restart auth "$CONF_DIR/auth.conf" "$RUN_DIR/auth.pid"

printf '  the zone now says:      %s\n' "$(ask '+short' 'A' "www.$ZONE" "@$AUTH_IP" | head -1)"
printf '  the resolver still says: %s\n\n' "$(ask '+short' 'A' "www.$ZONE" "@$RESOLVER_IP" | head -1)"

cat <<'EOF'
  Two servers, two different answers, and neither is malfunctioning.

  The migration is done and correct at the source. The resolver is obeying
  the TTL it was given: 86400 seconds, so up to a day. Nothing logs an error,
  no check fails, and the only fix is to wait - which is why you lower a TTL
  BEFORE a migration, not during one. A TTL is a promise about how long you
  are willing to be wrong.
EOF

cp -a "$CONF_DIR/auth.conf.orig" "$CONF_DIR/auth.conf"
restart auth "$CONF_DIR/auth.conf" "$RUN_DIR/auth.pid"
printf '  fixed at the source. The cached copy expires on its own.\n'

# ---------------------------------------------------------------------------
step "5. --hard: the missing trailing dot"

# local-data: "www.lab.test 30 IN A ..." - no final dot. This is not rejected.
# Relative names get the zone appended, so the record quietly becomes
# www.lab.test.lab.test.
sed -i "s|local-data: \"www.$ZONE. 30 IN A 10.10.2.10\"|local-data: \"www.$ZONE 30 IN A 10.10.2.10\"|" "$CONF_DIR/auth.conf"
restart auth "$CONF_DIR/auth.conf" "$RUN_DIR/auth.pid"

run_sh "unbound-checkconf $CONF_DIR/auth.conf"
run_sh "grep 'www' $CONF_DIR/auth.conf"
printf '  www.%s          -> %s\n' "$ZONE" "$(status_of "www.$ZONE" "@$AUTH_IP")"
printf '  www.%s.%s -> %s\n\n' "$ZONE" "$ZONE" "$(ask '+short' 'A' "www.$ZONE.$ZONE" "@$AUTH_IP" | head -1)"

cat <<'EOF'
  The configuration is valid. The server started. The record exists.
  It is just attached to a name nobody will ever ask for.

  NXDOMAIN for the name you wanted, a working answer for a name you did not
  write, and no error anywhere. Every DNS configuration format on earth has
  this trap, which is why zone files are read from the right-hand end.
EOF

cp -a "$CONF_DIR/auth.conf.orig" "$CONF_DIR/auth.conf"
restart auth "$CONF_DIR/auth.conf" "$RUN_DIR/auth.pid"
rm -f "$CONF_DIR/auth.conf.orig" "$CONF_DIR/resolver.conf.orig"

printf '  fixed. www.%s -> %s\n' "$ZONE" "$(ask '+short' 'A' "www.$ZONE" "@$AUTH_IP" | head -1)"

cat <<'EOF'


Five failures, all repaired.

The three that printed an error were the easy ones. The two under --hard
printed nothing at all, passed unbound-checkconf, and left a service that
was running perfectly and answering wrongly. Those are the ones that reach
production.

Check yourself:  sudo ./days/day08/verify.sh
EOF
