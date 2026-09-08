#!/usr/bin/env bash
#
# explore-net.sh - a read-only tour of the network you just built.
#
# Changes nothing. Every command here is one you should be able to type from
# memory by the end of the phase, because Days 07-10 and 18 are all debugged
# with these six commands and nothing more.
#
#   sudo ./explore-net.sh
#
# Root is not optional today: entering a network namespace is a privileged
# operation, so without it there is nothing to look at.

set -uo pipefail

heading() { printf '\n\n===== %s =====\n\n' "$*"; }
note()    { printf '  (%s)\n\n' "$1"; }
run()     { printf '$ %s\n' "$*"; "$@" 2>&1 | sed 's/^/  /' || true; printf '\n'; }
run_sh()  { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/  /' || true; printf '\n'; }

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "needs root:  sudo $0" >&2
  exit 1
fi

if ! ip netns list | grep -qw client; then
  echo "no namespaces to explore - run 'sudo ./setup.sh' first" >&2
  exit 1
fi

heading "1. what exists"
run ip netns list
note "these are names in /var/run/netns; each one is a whole network stack"

heading "2. inside the client"
run ip -n client -br addr
note "-br is brief: one line per interface. Note lo is UP because setup.sh said so"
run_sh "ip -br addr | head -5"
note "the same command outside any namespace: your own machine, untouched"

heading "3. a veth is a pair, and the kernel knows it"
run_sh "ip -n client -d link show veth-cl | sed -n '1,4p'"
note "read the 'veth' line: it names the peer and the namespace it sits in"
run_sh "ip -n router -br link | grep veth"
note "the router end of all three cables, in the router namespace"

heading "4. the client's whole routing table"
run ip -n client route
note "two lines. One you never typed - the address created it. One is the default"

heading "5. the question the kernel actually answers"
run_sh "ip -n client route get 10.10.2.2"
note "'route get' is the routing decision itself: chosen route, source address, device"
run_sh "ip -n client route get 10.10.0.1"
note "same command, on-link destination: no 'via', because no router is involved"
run_sh "ip -n client route get 8.8.8.8"
note "outside the lab: still matches default, still points at the router, which drops it"

heading "6. the router's three legs"
run ip -n router -br addr
run_sh "ip netns exec router sysctl net.ipv4.ip_forward"
note "this is the line that makes it a router rather than a host with three NICs"
run_sh "sysctl net.ipv4.ip_forward"
note "and this is your own machine's setting - a different value, in a different namespace"
run ip -n router route
note "three connected routes, no default. It needs none: it is on every network here"

heading "7. who answered"
run_sh "ip -n client neigh"
note "the ARP table. It is populated by traffic, so it is empty until something is sent"
run_sh "ip netns exec client ping -c1 -W1 10.10.0.1 >/dev/null; ip -n client neigh"
note "one ping later, the router's MAC is known. REACHABLE decays to STALE on its own"

heading "8. what the client cannot see"
run_sh "ip -n client -br link | wc -l"
run_sh "ip -br link | wc -l"
note "interface counts: the namespace sees two, your machine sees all of its own"
run_sh "ip netns exec client ip route get 10.10.1.2 2>&1 | head -2"
note "it reaches the resolver network only through the router - there is no direct wire"

heading "9. running something real in there"
run_sh "ip netns exec client hostname"
note "the hostname is shared: only the NETWORK namespace changed, nothing else did"
run_sh "ip netns exec client ss -tuln | head -5"
note "an empty socket table. Nothing listens in here yet - Day 08 changes that"

heading "10. worth doing by hand next"
cat <<'EOF'
  sudo ip netns exec router tcpdump -ni any icmp
      then ping from the client in another terminal, and watch the same
      packet appear twice: once arriving, once leaving. That is forwarding,
      seen rather than assumed. Day 09 is built on this.

  sudo ip netns exec client ip -s link show veth-cl
      per-interface counters. When a ping fails, the question "did it even
      leave" is answered here and almost nowhere else.

  sudo ip netns exec client ip route del default
      then ping the resolver and read the error text exactly. Put it back
      with 'ip -n client route add default via 10.10.0.1'.

Sit with this one before you move on:

  sudo ip netns exec client ping -c1 10.10.1.2

Three /24s, one router, and a packet that had to be forwarded twice - once
each way - for that single line of output to appear.
EOF

printf '\n'
