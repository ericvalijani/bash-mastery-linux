#!/usr/bin/env bash
#
# Day 08 tour - read-only. Twelve looks at two servers answering the same
# questions differently. Nothing here changes anything; run it as often as
# you like, and read the commands, not just the output.

set -uo pipefail

AUTH_IP="10.10.2.2"
RESOLVER_IP="10.10.1.2"
ZONE="lab.test"
LOG_DIR="/var/log/lab-dns"

heading() { printf '\n\n=== %s ===\n\n' "$*"; }
note()    { printf '  (%s)\n\n' "$1"; }
run()     { printf '$ %s\n' "$*"; "$@" 2>&1 | sed 's/^/  /' || true; printf '\n'; }
run_sh()  { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/  /' || true; printf '\n'; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "needs root:  sudo $0" >&2; exit 1; }
ip netns list | grep -qw client || { echo "no client namespace - run setup.sh first" >&2; exit 1; }

heading "1. two processes, two namespaces, same port"
run_sh "ip netns exec auth ss -ulpn | grep ':53'"
run_sh "ip netns exec resolver ss -ulpn | grep ':53'"
note "both own port 53. Neither can see the other's socket, and neither
   collides with whatever your laptop runs on 53"

heading "2. the zone's own record about itself"
run_sh "ip netns exec client dig +noall +answer SOA $ZONE. @$AUTH_IP"
note "serial refresh retry expire minimum. The last number, 60, is the
   negative TTL: how long a NO is allowed to be remembered"

heading "3. the zone naming its nameserver"
run_sh "ip netns exec client dig +noall +answer NS $ZONE. @$AUTH_IP"
run_sh "ip netns exec client dig +noall +answer A ns.$ZONE. @$AUTH_IP"
note "an NS record points at a NAME, so the address of that name has to be
   published too, or nobody can act on the delegation"

heading "4. the same question to both servers"
run_sh "ip netns exec client dig +short A www.$ZONE @$AUTH_IP"
run_sh "ip netns exec client dig +short A www.$ZONE @$RESOLVER_IP"
note "identical answers. Nothing in +short tells you they came from two
   completely different kinds of server"

heading "5. the flags, which is where the difference actually lives"
run_sh "ip netns exec client dig A www.$ZONE @$AUTH_IP | grep -E '^;; flags|^;; ->>'"
run_sh "ip netns exec client dig A www.$ZONE @$RESOLVER_IP | grep -E '^;; flags|^;; ->>'"
note "aa = authoritative answer: from its own data.
   ra = recursion available: it will go and find things.
   The zone has aa and no ra. The resolver has ra and no aa"

heading "6. the cache, visible as a falling number"
run_sh "ip netns exec client dig +noall +answer A www.$ZONE @$RESOLVER_IP"
run_sh "sleep 3; ip netns exec client dig +noall +answer A www.$ZONE @$RESOLVER_IP"
run_sh "ip netns exec client dig +noall +answer A www.$ZONE @$AUTH_IP"
note "the resolver's TTL fell by about three. The zone's did not move at all,
   because the zone is not serving a copy - it IS the copy"

heading "7. a CNAME answers with a name, not an address"
run_sh "ip netns exec client dig +noall +answer A web.$ZONE @$RESOLVER_IP"
run_sh "ip netns exec client dig +short A www.$ZONE @$RESOLVER_IP"
note "you asked for an address and got an alias. Somebody now has to ask a
   second question - a full recursive resolver chases it for you, a static
   zone like this one hands you the alias and stops. Either way the lookup
   cost two round trips, which is why CNAME is banned at a zone apex"

heading "8. a name in the zone that does not exist"
run_sh "ip netns exec client dig nope.$ZONE @$AUTH_IP | grep -E '^;; ->>|^$ZONE|SOA'"
note "NXDOMAIN, and the SOA comes back with it. That SOA is what tells the
   resolver how long it may remember the NO - negative caching"

heading "9. a name OUTSIDE the zone, asked of the wrong server"
run_sh "ip netns exec client dig +short A example.com @$AUTH_IP"
run_sh "ip netns exec client dig A example.com @$AUTH_IP | grep -E '^;; ->>'"
note "REFUSED. Not NXDOMAIN. The zone is not saying the name is missing, it is
   saying the question is none of its business. Three different rejections -
   REFUSED, NXDOMAIN, SERVFAIL - mean three different things"

heading "10. what the client gets with no server named at all"
run_sh "cat /etc/netns/client/resolv.conf"
run_sh "ip netns exec client dig +short A www.$ZONE"
note "no @server, so it used resolv.conf and went to the resolver. This is the
   path an actual application takes - nobody's application passes @10.10.2.2"

heading "11. the servers' own view of what you just asked"
run_sh "tail -n 8 $LOG_DIR/resolver.log"
run_sh "tail -n 8 $LOG_DIR/auth.log"
note "log-queries: yes. When an answer is wrong, the first question is whether
   the query arrived at all - guessing at that is the slowest way to debug DNS"

heading "12. the two configurations, side by side"
run_sh "grep -E 'local-zone|local-data' /etc/unbound/lab/auth.conf | head -12"
run_sh "grep -vE '^\\s*#|^\\s*$' /etc/unbound/lab/resolver.conf | tail -14"
note "the authoritative half is almost entirely DATA. The recursive half has
   no data at all - just one rule about where to send a name"

printf '\n\nThat is the tour. Now break it:  sudo ./days/day08/scripts/break-and-fix.sh\n\n'
