#!/usr/bin/env bash
#
# Day 09 tour - twelve looks at the same network, each with a tool that can
# only answer one kind of question. The skill of this day is knowing which
# question you are asking.
#
# Read-only. Nothing here changes anything.

set -uo pipefail

say()  { printf '\n=== %s ===\n\n' "$*"; }
note() { printf '  (%s)\n\n' "$1"; }
run()  { printf '$ %s\n' "$*"; "$@" 2>&1 | sed 's/^/  /' || true; printf '\n'; }
run_sh() { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/  /' || true; printf '\n'; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "needs root:  sudo $0" >&2; exit 1; }
ip netns list | grep -qw client ||
  { echo "no 'client' namespace - run: sudo ./days/day09/scripts/setup.sh" >&2; exit 1; }

say "1. the routing table is a set of rules"
run_sh "ip netns exec client ip route"
note "Three lines to read and apply in your head, in the right order"

say "2. ip route get is the kernel doing it for you"
run_sh "ip netns exec client ip route get 10.10.2.2"
run_sh "ip netns exec client ip route get 8.8.8.8"
note "One asks a question about a destination; the answer names dev and src"

say "3. an interface can be up and still have no address"
run_sh "ip netns exec client ip -brief addr"
note "UP is a link state; the address is a separate fact on the same line"

say "4. who is my neighbour"
run_sh "ip netns exec client ip neigh"
note "ARP resolves an address to a MAC; REACHABLE here means it answered"

say "5. one capture, watched from the middle"
run_sh "ip netns exec router timeout 3 tcpdump -ni veth-rcl -c 2 icmp & sleep 1; ip netns exec client ping -c2 -W2 10.10.2.2 >/dev/null; wait"
note "tcpdump was started FIRST - it cannot capture what already happened"

say "6. the same traffic, counted rather than printed"
run_sh "ip netns exec router ip -s link show veth-rcl | tail -4"
note "Counters survive; a capture only exists while something is listening"

say "7. sockets are not packets"
run_sh "ip netns exec resolver ss -ulpn"
note "Empty here means nothing is waiting - arriving packets get refused"

say "8. ss summarises the whole namespace"
run_sh "ip netns exec client ss -s"
note "Useful when the question is 'how many' rather than 'which'"

say "9. a filter is a language, not a search box"
run_sh "ip netns exec router tcpdump -nr /var/log/lab-trace/day09.pcap icmp"
note "The same filter syntax works live and against a saved file"

say "10. TTL is how far a packet is allowed to go"
run_sh "ip netns exec client ping -c1 -W2 -t 1 10.10.2.2"
note "One hop of budget, two hops of path: the router has to reject it"

say "11. what fits in one packet"
run_sh "ip netns exec client ip -brief link show veth-cl"
run_sh "ip netns exec client ping -c1 -W2 -M do -s 1400 10.10.2.2"
note "1400 bytes plus headers still fits under an MTU of 1500"

say "12. the payload puts the three tools together"
run_sh "lab-trace 10.10.2.2 | tail -12"
note "Route, wire and reply in one answer - that is the day"

cat <<'EOF'
The order those tools go in matters more than any single one of them.

  ip route get   before capturing: it tells you WHERE to capture.
  tcpdump        in the middle: it separates "never sent" from "never arrived".
  ss             at the far end: a packet can arrive and still find nobody home.
  counters       afterwards: they were being kept while you were not looking.

Next:  sudo ./days/day09/scripts/break-and-fix.sh
EOF
