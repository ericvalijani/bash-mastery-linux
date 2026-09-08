#!/usr/bin/env bash
#
# break-and-fix.sh - break this network in the ways real networks break, and
# repair each one before moving on.
#
#   sudo ./break-and-fix.sh          three failures, three fixes
#   sudo ./break-and-fix.sh --hard   two more that look like working config
#
# Every failure here is restored before the script exits, so verify.sh is green
# again afterwards. If you interrupt it half way, run setup.sh - it repairs.
#
# The point is not the breakage. It is that these five failures produce four
# DIFFERENT symptoms, and that reading the symptom tells you where to look.

set -uo pipefail

die()  { echo "$*" >&2; exit 1; }
step() { printf '\n\n########## %s\n\n' "$*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "needs root:  sudo $0"
ip netns list | grep -qw client || die "no namespaces - run 'sudo ./setup.sh' first"

HARD="no"; [[ "${1:-}" == "--hard" ]] && HARD="yes"

# --- day-specific helpers ---------------------------------------------------

# Prints the exact outcome of one ping in one line: ok, the kernel's own error
# text, or a timeout. The distinction between the last two is the whole lesson.
ping_try() {
  local ns="$1" dst="$2" out
  if out=$(ip netns exec "$ns" ping -c1 -W2 "$dst" 2>&1); then
    printf '  %-8s -> %-11s ok\n' "$ns" "$dst"
  else
    local reason
    reason=$(printf '%s\n' "$out" | grep -m1 -i 'unreachable\|100% packet loss\|Name or service' || true)
    printf '  %-8s -> %-11s FAILED: %s\n' "$ns" "$dst" "${reason:-no reply}"
  fi
}

show() { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/    /' || true; printf '\n'; }

# --- 1. forwarding off ------------------------------------------------------

step "1. the router stops forwarding"

echo "Working, before anything is touched:"
ping_try client 10.10.0.1
ping_try client 10.10.2.2

echo
echo "Now one sysctl, inside the router namespace:"
ip netns exec router sysctl -qw net.ipv4.ip_forward=0
show "ip netns exec router sysctl net.ipv4.ip_forward"

ping_try client 10.10.0.1
ping_try client 10.10.2.2

cat <<'EOF'
Read those two lines together, because the pair is the diagnosis.

The router itself still answers - the wire is fine, the addresses are fine,
ARP is fine. Only traffic THROUGH it stopped. And notice how it stopped: no
error, no ICMP, no log line anywhere. A Linux host that receives a packet
addressed to somebody else and is not forwarding simply drops it in silence.

That silence is why 'is forwarding on' is the second thing to check on any
router, immediately after 'do the interfaces have addresses'. Nothing else in
this lab produces a clean timeout with a reachable next hop.
EOF

echo "Fixing:"
ip netns exec router sysctl -qw net.ipv4.ip_forward=1
ping_try client 10.10.2.2

# --- 2. no default route ----------------------------------------------------

step "2. the client loses its default route"

show "ip -n client route"
ip -n client route del default
show "ip -n client route"

ping_try client 10.10.0.1
ping_try client 10.10.2.2

cat <<'EOF'
Compare that failure with failure 1, because they are the same broken
connection with completely different evidence.

Failure 1 timed out after two seconds: the packet left the client, crossed the
cable, and died at the router. This one failed instantly, and the error came
from the client's OWN kernel - "Network is unreachable" means no route matched,
so nothing was ever transmitted. Nothing appeared on the wire at all.

Instant error with a message = routing, locally. Silence and a timeout =
something further away. You can tell those apart before you touch tcpdump, and
on a bad day that is twenty minutes.
EOF

echo "Fixing:"
ip -n client route replace default via 10.10.0.1
ping_try client 10.10.2.2

# --- 3. the return path -----------------------------------------------------

step "3. the far end cannot reply"

echo "This time nothing about the client or the router changes. Watch auth:"
show "ip -n auth route"
ip -n auth route del default
show "ip -n auth route"

ping_try client 10.10.2.2

echo "But the packet is arriving. Ask auth what it received:"
show "ip netns exec auth timeout 3 tcpdump -c2 -ni veth-au icmp 2>&1 | tail -4 & \
      sleep 1; ip netns exec client ping -c1 -W2 10.10.2.2 >/dev/null 2>&1; wait"

echo "And ask auth to reach the client directly:"
ping_try auth 10.10.0.2

cat <<'EOF'
This is the failure that wastes whole afternoons. The symptom appears at the
client. The cause is three hops away, at the destination, and the destination
is not misconfigured in any way you would notice: its address is right, its
interface is up, it answers its own neighbours.

It simply has no route back. The echo request arrives; the echo reply has
nowhere to go, and 'ping' at the client can only report that nothing came back.
A ping proves a ROUND TRIP, so a failed ping never tells you which direction
failed. This is the second YOU on today's checklist: you have now seen a
one-way network, and you know the tool that showed you it was one-way was
tcpdump at the far end, not ping at the near one.
EOF

echo "Fixing:"
ip -n auth route replace default via 10.10.2.1
ping_try client 10.10.2.2

if [[ "$HARD" != "yes" ]]; then
  cat <<'EOF'


##########

Three failures, three symptoms:

  timeout, next hop reachable    -> forwarding, or something in the middle
  instant "unreachable"          -> the local routing table
  timeout, requests arriving     -> the return path at the far end

For two more that look exactly like working configuration:

  sudo ./break-and-fix.sh --hard
EOF
  exit 0
fi

# --- 4. the link is down, the address is still there ------------------------

step "4. a correct address on a dead link"

ip -n client link set veth-cl down

echo "Everything you would check in a hurry still looks right:"
show "ip -n client addr show veth-cl | grep 'inet '"

echo "But the routing table lost a line you never typed:"
show "ip -n client route"

ping_try client 10.10.0.1

cat <<'EOF'
The address is still configured. 'ip addr' shows it, a config file would show
it, Ansible would report the host as compliant. And there is no route to
anywhere, because the kernel withdraws the connected route when the link goes
down - it will not route out of an interface that has no carrier.

So "the address is correct" and "the address is usable" are different claims,
and only one of them is visible in 'ip addr'. Read the flags, not the inet
line: state DOWN and NO-CARRIER are printed right there, and are the single
most skipped-over field in this whole area.
EOF

echo "Fixing:"
ip -n client link set veth-cl up
sleep 1
ping_try client 10.10.2.2

# --- 5. the wrong prefix length ---------------------------------------------

step "5. one wrong number in the netmask"

echo "The address itself is unchanged - only the prefix length moves, /24 to /16:"
ip -n client addr replace 10.10.0.2/16 dev veth-cl
show "ip -n client -br addr show veth-cl"
show "ip -n client route"

ping_try client 10.10.0.1
ping_try client 10.10.2.2
ping_try client 10.10.1.2

echo "Ask the client to explain its own decision:"
show "ip -n client route get 10.10.1.2"

cat <<'EOF'
The router is still reachable, so the first check anybody runs still passes.
But the client now believes 10.10.0.0/16 is on-link - a range that swallows
the resolver and auth networks whole - so for those destinations it stops
using the router and starts shouting ARP requests onto a cable where nobody
can answer for them. Longest prefix wins, and /16 is longer than default.

Note the failure mode: not "unreachable", but a timeout, from a host whose
address, link, route table and gateway are all technically present. This is
what a mistyped netmask does in production, and it is why 'ip route get' is
worth more than 'ip route' - it tells you what the kernel decided instead of
letting you infer it.
EOF

echo "Fixing:"
ip -n client addr flush dev veth-cl
ip -n client addr replace 10.10.0.2/24 dev veth-cl
ip -n client route replace default via 10.10.0.1
sleep 1
ping_try client 10.10.2.2
ping_try client 10.10.1.2

cat <<'EOF'


##########

Five failures, and only two of them would have shown up in a config review.
The other three - forwarding off, no return route, a /16 where a /24 belonged
- all look like a working machine from the outside.

All of it is restored. Prove that rather than believe it:

  sudo ./scripts/lab-netcheck.sh
  sudo ./days/day06/verify.sh
EOF
