#!/usr/bin/env bash
#
# lab-trace - answer one question about one destination:
#
#   which interface does this packet leave by, does it arrive at the router,
#   and does a reply come back?
#
# Three facts, each from a different tool, printed together:
#
#   ip route get     the kernel's own decision about where this packet goes.
#                    Not a guess from reading the routing table - the actual
#                    lookup, for this exact destination address.
#   tcpdump          what appeared on the wire in the middle. The only
#                    evidence that settles "I sent it" against "I never got
#                    it".
#   ping             whether a reply came back at all.
#
# Usage:  lab-trace [DEST]        default 10.10.2.2 (the auth namespace)
#
# Runs in the client namespace and captures on the router's client-side leg.

set -uo pipefail

DEST="${1:-10.10.2.2}"

NS_CLIENT="client"
ROUTER_LEG="veth-rcl"        # the router's end of the client's veth pair
CAP_DIR="/var/log/lab-trace"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "needs root:  sudo $0 $*" >&2; exit 1; }
ip netns list | grep -qw "$NS_CLIENT" ||
  { echo "no '$NS_CLIENT' namespace - run: sudo ./days/day09/scripts/setup.sh" >&2; exit 1; }

mkdir -p "$CAP_DIR"
cap="$CAP_DIR/trace-$DEST.pcap"

printf '\ntracing %s from the %s namespace\n\n' "$DEST" "$NS_CLIENT"

# ---- 1. the kernel's routing decision -------------------------------------
# "ip route" shows you the rules. "ip route get" applies them. When those two
# disagree in your head, this command is right and you are wrong.
routed="$(ip netns exec "$NS_CLIENT" ip route get "$DEST" 2>&1 | head -1)"
dev="$(printf '%s' "$routed" | sed -n 's/.* dev \([^ ]*\).*/\1/p')"
src="$(printf '%s' "$routed" | sed -n 's/.* src \([^ ]*\).*/\1/p')"

printf '  route     %s\n' "$routed"
if [[ -z "$dev" ]]; then
  printf '\n  There is no route to %s at all. Nothing was sent, so there is\n' "$DEST"
  printf '  nothing to capture. This is the one failure a capture cannot show\n'
  printf '  you: the packet never reached an interface.\n\n'
  exit 1
fi
printf '  leaves by %s with source %s\n\n' "$dev" "${src:-unknown}"

# ---- 2. capture in the middle while sending -------------------------------
# tcpdump has to be listening BEFORE the packet is sent, which is why it goes
# to the background and gets a moment to start. Capturing after the fact is
# the single most common mistake with this tool.
rm -f "$cap"
ip netns exec router tcpdump -ni "$ROUTER_LEG" -c 4 -w "$cap" \
  "icmp and host $DEST" >/dev/null 2>&1 &
cap_pid=$!
sleep 1

ping_out="$(ip netns exec "$NS_CLIENT" ping -c2 -W2 "$DEST" 2>&1 || true)"

# Give tcpdump a moment to write what it saw, then stop it. -c 4 usually ends
# it on its own; killing it is the case where fewer packets arrived than we
# asked for, which is exactly the case worth reporting.
sleep 1
if kill -0 "$cap_pid" 2>/dev/null; then
  kill "$cap_pid" 2>/dev/null || true
fi
wait "$cap_pid" 2>/dev/null || true

seen="$(ip netns exec router tcpdump -nr "$cap" 2>/dev/null | wc -l | tr -d ' ')"
requests="$(ip netns exec router tcpdump -nr "$cap" 2>/dev/null | grep -c 'echo request' || true)"
replies="$(ip netns exec router tcpdump -nr "$cap" 2>/dev/null | grep -c 'echo reply' || true)"

printf '  on the wire at router:%s\n' "$ROUTER_LEG"
printf '    packets captured  %s\n' "${seen:-0}"
printf '    echo requests     %s\n' "${requests:-0}"
printf '    echo replies      %s\n' "${replies:-0}"

recv="$(printf '%s' "$ping_out" | sed -n 's/.* \([0-9]*\) received.*/\1/p' | head -1)"
printf '    ping replies      %s\n\n' "${recv:-0}"

# ---- 3. say what the combination means ------------------------------------
# Four states, and each one points at a different half of the network. This is
# the whole reason to capture in the middle instead of only at the ends.
if [[ "${requests:-0}" -eq 0 ]]; then
  printf '  Nothing left the client. The route says %s, but no packet reached\n' "$dev"
  printf '  the router. Suspect the interface itself: down, wrong address, or\n'
  printf '  the veth peer is not where you think it is.\n'
elif [[ "${replies:-0}" -eq 0 ]]; then
  printf '  Requests arrived, replies did not. The packet is getting there and\n'
  printf '  the problem is on the RETURN path or at the far end - not on the\n'
  printf '  side you were probably looking at. Check the destination has a\n'
  printf '  route back to %s.\n' "${src:-the client}"
elif [[ "${recv:-0}" -eq 0 ]]; then
  printf '  Replies were on the wire at the router but ping saw none. Something\n'
  printf '  between the router and the client dropped them on the way back.\n'
else
  printf '  Requests out, replies back, ping satisfied. This path works, and\n'
  printf '  you now have a capture that proves it rather than a belief.\n'
fi

printf '\n  capture kept at %s\n' "$cap"
printf '  read it with:   sudo ip netns exec router tcpdump -nr %s\n\n' "$cap"
