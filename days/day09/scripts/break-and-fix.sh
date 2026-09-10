#!/usr/bin/env bash
#
# Day 09 break-and-fix - five ways a path fails, and what each one looks like
# from the middle of it.
#
# The point of every case below is the SHAPE of the evidence, not the repair:
#
#   no packet on the wire              the sender never sent it
#   requests but no replies            it arrived; the return path is broken
#   small packets fine, big ones gone  an MTU, and nothing else
#
# Everything is restored before this script exits, including on Ctrl-C.
#
#   ./break-and-fix.sh          three failures that announce themselves
#   ./break-and-fix.sh --hard   two that do not

set -uo pipefail

say()  { printf '\n=== %s ===\n\n' "$*"; }
die()  { echo "$*" >&2; exit 1; }
note() { printf '  (%s)\n\n' "$1"; }
run_sh() { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/  /' || true; printf '\n'; }

NS_CLIENT="client"
NS_ROUTER="router"
NS_AUTH="auth"
CLIENT_IP="10.10.0.2"
AUTH_IP="10.10.2.2"
CLIENT_LEG="veth-cl"
ROUTER_LEG="veth-rcl"
CAP_DIR="/var/log/lab-trace"

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "needs root:  sudo $0"
ip netns list | grep -qw "$NS_CLIENT" || die "no client namespace - run: sudo ./days/day09/scripts/setup.sh"
command -v tcpdump >/dev/null 2>&1 || die "tcpdump is missing - run setup.sh"

HARD="no"
[[ "${1:-}" == "--hard" ]] && HARD="yes"

mkdir -p "$CAP_DIR"

# Every break below is undone here, so an interrupted run cannot leave you
# with a network that is broken for reasons you have forgotten.
restore() {
  ip -n "$NS_CLIENT" link set "$CLIENT_LEG" up 2>/dev/null || true
  ip -n "$NS_CLIENT" link set "$CLIENT_LEG" mtu 1500 2>/dev/null || true
  ip -n "$NS_ROUTER" link set "$ROUTER_LEG" mtu 1500 2>/dev/null || true
  ip -n "$NS_CLIENT" route replace default via 10.10.0.1 2>/dev/null || true
  ip -n "$NS_AUTH"   route replace default via 10.10.2.1 2>/dev/null || true
  # 'neigh flush all' does NOT remove a PERMANENT entry, so the bogus one
  # from case 5 has to be deleted by name or it outlives this script.
  ip -n "$NS_CLIENT" neigh del 10.10.0.1 dev "$CLIENT_LEG" 2>/dev/null || true
  ip -n "$NS_CLIENT" neigh flush all 2>/dev/null || true
}
trap restore EXIT INT TERM

# capture_probe FILE -> ping while capturing, then report the counts. This is
# the measurement the whole script is built on, so it is one function used
# five times rather than five slightly different copies.
capture_probe() {
  local cap="$1" pid recv req rep
  rm -f "$cap"
  ip netns exec "$NS_ROUTER" tcpdump -ni "$ROUTER_LEG" -c 6 -w "$cap" "icmp" >/dev/null 2>&1 &
  pid=$!
  sleep 1
  recv="$(ip netns exec "$NS_CLIENT" ping -c2 -W2 "$AUTH_IP" 2>&1 | sed -n 's/.* \([0-9]*\) received.*/\1/p' | head -1)"
  sleep 1
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null || true; fi
  wait "$pid" 2>/dev/null || true
  req="$(ip netns exec "$NS_ROUTER" tcpdump -nr "$cap" 2>/dev/null | grep -c 'echo request' || true)"
  rep="$(ip netns exec "$NS_ROUTER" tcpdump -nr "$cap" 2>/dev/null | grep -c 'echo reply' || true)"
  printf '  at router:%s   requests %s   replies %s   ping received %s\n\n' "$ROUTER_LEG" "${req:-0}" "${rep:-0}" "${recv:-0}"
}

# ---------------------------------------------------------------------------
say "1. the interface is down"

ip -n "$NS_CLIENT" link set "$CLIENT_LEG" down
capture_probe "$CAP_DIR/break1.pcap"
run_sh "ip netns exec client ping -c1 -W2 $AUTH_IP"
note "Network is unreachable, and the capture is empty: nothing was sent"

echo "  An empty capture at the router with a loud error at the client is the"
echo "  easiest shape to read. The sender knew it had failed."
ip -n "$NS_CLIENT" link set "$CLIENT_LEG" up
sleep 1
echo "  fixed."

# ---------------------------------------------------------------------------
say "2. no route to the destination"

ip -n "$NS_CLIENT" route del default 2>/dev/null || true
capture_probe "$CAP_DIR/break2.pcap"
run_sh "ip netns exec client ip route get $AUTH_IP"
note "ip route get fails before any packet exists - there is nothing to capture"

echo "  This is the failure a capture can never show you, and the reason"
echo "  'ip route get' comes first in the order of tools."
ip -n "$NS_CLIENT" route replace default via 10.10.0.1
echo "  fixed."

# ---------------------------------------------------------------------------
say "3. the far end has no route back"

ip -n "$NS_AUTH" route del default 2>/dev/null || true
capture_probe "$CAP_DIR/break3.pcap"
note "Requests on the wire, no replies, and ping reports total loss"

echo "  Read that shape carefully, because it is the one people get wrong."
echo "  Requests ARRIVED. Nothing is wrong with the side you are sitting on,"
echo "  or with the router, or with the wire. The destination received your"
echo "  packet and could not answer, because it has no route to $CLIENT_IP."
echo "  A one-way path looks exactly like a dead one from the sender."
ip -n "$NS_AUTH" route replace default via 10.10.2.1
echo "  fixed."

if [[ "$HARD" != "yes" ]]; then
  cat <<'EOF'

Three failures, all of them noisy.

The two that are not are behind --hard. They leave a network that pings
perfectly and still loses real traffic:

  sudo ./days/day09/scripts/break-and-fix.sh --hard
EOF
  exit 0
fi

# ---------------------------------------------------------------------------
say "4. --hard: an MTU that only breaks big packets"

ip -n "$NS_CLIENT" link set "$CLIENT_LEG" mtu 1280
ip -n "$NS_ROUTER" link set "$ROUTER_LEG" mtu 1280

run_sh "ip netns exec client ping -c2 -W2 $AUTH_IP | tail -2"
note "Ping is perfect. Ping sends 64 bytes."

run_sh "ip netns exec client ping -c1 -W2 -M do -s 1400 $AUTH_IP"
note "1400 bytes with DF set: the same path, refused"

run_sh "ip netns exec client ip -brief link show $CLIENT_LEG"

echo "  Every check you own probably sends small packets. Ping is small. A"
echo "  health endpoint returning 'ok' is small. A TLS handshake, a database"
echo "  result set and a file upload are not, and those are what fail - which"
echo "  is why an MTU problem gets reported as 'the app is slow sometimes'"
echo "  rather than 'the network is down'."
echo
echo "  The number to compare against is on the interface itself, not in any"
echo "  log: mtu 1280 above, against the 1500 the rest of the path expects."
ip -n "$NS_CLIENT" link set "$CLIENT_LEG" mtu 1500
ip -n "$NS_ROUTER" link set "$ROUTER_LEG" mtu 1500
sleep 1
run_sh "ip netns exec client ping -c1 -W2 -M do -s 1400 $AUTH_IP | tail -2"
echo "  fixed."

# ---------------------------------------------------------------------------
say "5. --hard: the right answer from the wrong neighbour"

# A static ARP entry pointing the gateway's address at a MAC that nobody
# owns. Nothing is misconfigured in any file, every address is correct, and
# the packets are handed to a machine that does not exist.
bogus="02:00:00:00:00:99"
ip -n "$NS_CLIENT" neigh replace 10.10.0.1 lladdr "$bogus" dev "$CLIENT_LEG" nud permanent

run_sh "ip netns exec client ip route get $AUTH_IP"
note "The route is right. It was always right."

capture_probe "$CAP_DIR/break5.pcap"
run_sh "ip netns exec client ip neigh"

echo "  The routing table is correct, the interface is up, the addresses are"
echo "  correct, and packets leave the client addressed to a MAC that belongs"
echo "  to nobody. Layer 3 is perfect and layer 2 is lying."
echo
echo "  Notice which tool found it. Not ping, not the routing table, not a"
echo "  capture at the sender - 'ip neigh', showing a PERMANENT entry where"
echo "  every other line says REACHABLE. Permanent means someone typed it."
ip -n "$NS_CLIENT" neigh del 10.10.0.1 dev "$CLIENT_LEG" 2>/dev/null || true
ip -n "$NS_CLIENT" neigh flush all 2>/dev/null || true
sleep 1
run_sh "ip netns exec client ping -c1 -W2 $AUTH_IP | tail -2"
echo "  fixed."

cat <<'EOF'

Five failures, all repaired.

The first three announced themselves. The last two left a network that
answered ping correctly while losing the traffic that mattered, and neither
of them appears in any log file. The evidence was on an interface and in a
neighbour table, and you only find it by asking.

Check yourself:  sudo ./days/day09/verify.sh
EOF
