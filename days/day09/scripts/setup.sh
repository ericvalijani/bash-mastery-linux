#!/usr/bin/env bash
#
# Day 09 setup - make Day 06's topology observable.
#
# Nothing new is built today. The network already exists; what is missing is
# the ability to prove anything about it. Today installs the evidence tools
# and takes one capture, so that every claim in this day can be checked
# against a file rather than against a memory.
#
#   client   10.10.0.2   sends
#   router   10.10.0.1 / 10.10.1.1 / 10.10.2.1   forwards, and is where we watch
#   auth     10.10.2.2   answers
#
# The router's leg towards the client is called veth-rcl. Capturing THERE and
# not at either end is the point of the day: the middle of a path is the only
# place that can tell "never sent" apart from "never arrived".
#
# Run it on the machine you are reading this on. No VM today.
#
# Idempotent: run it as many times as you like.

set -euo pipefail

HERE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say()  { printf '\n==> %s\n' "$*"; }
die()  { echo "$*" >&2; exit 1; }

NS_CLIENT="client"
NS_ROUTER="router"
NS_RESOLVER="resolver"
NS_AUTH="auth"

CLIENT_IP="10.10.0.2"
AUTH_IP="10.10.2.2"

CLIENT_LEG="veth-cl"      # the client's own interface
ROUTER_LEG="veth-rcl"     # the router's end of the same veth pair

CAP_DIR="/var/log/lab-trace"
BASE_CAP="$CAP_DIR/day09.pcap"

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "needs root:  sudo $0"

# ---------------------------------------------------------------------------
say "0. checking what this day needs"

missing=""
for t in ip tcpdump ss ping; do
  command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
if [[ -n "$missing" ]]; then
  echo "missing:$missing" >&2
  echo >&2
  echo "  RHEL family:     sudo dnf install -y tcpdump iproute iputils" >&2
  echo "  Debian/Ubuntu:   sudo apt-get install -y tcpdump iproute2 iputils-ping" >&2
  die "install those and run this again"
fi
echo "ok    ip, tcpdump, ss and ping are all present"

# ---------------------------------------------------------------------------
say "1. making sure Day 06's topology is up"

# Namespaces live in the running kernel and never survive a reboot, so a
# missing topology is the normal case and not an error. Build it rather than
# complaining about it. Day 06's setup.sh is idempotent.
DAY06_SETUP="$HERE_DIR/../../day06/scripts/setup.sh"

need_topology="no"
for ns in "$NS_CLIENT" "$NS_ROUTER" "$NS_RESOLVER" "$NS_AUTH"; do
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
  say "1b. back in Day 09 - the topology is up"
fi

for ns in "$NS_CLIENT" "$NS_ROUTER" "$NS_RESOLVER" "$NS_AUTH"; do
  ip netns list | grep -qw "$ns" || die "still no '$ns' namespace after building"
done

ip netns exec "$NS_CLIENT" ping -c1 -W2 "$AUTH_IP" >/dev/null 2>&1 ||
  die "the client cannot reach $AUTH_IP - Day 06's routing is broken.
  Check it with:  sudo ./days/day06/scripts/lab-netcheck.sh"

echo "ok    all four namespaces exist, and the client can reach $AUTH_IP"

# ---------------------------------------------------------------------------
say "2. finding the interface to watch"

# There is no guessing step here, and there should not be one in your own
# debugging either. Ask the kernel which interface this destination uses.
routed="$(ip netns exec "$NS_CLIENT" ip route get "$AUTH_IP" | head -1)"
dev="$(printf '%s' "$routed" | sed -n 's/.* dev \([^ ]*\).*/\1/p')"
[[ -n "$dev" ]] || die "the client has no route to $AUTH_IP at all - see Day 06"
[[ "$dev" == "$CLIENT_LEG" ]] ||
  echo "      note: the client uses '$dev', not the expected '$CLIENT_LEG'"

echo "ok    packets to $AUTH_IP leave the client by $dev"

# The other end of that pair is on the router, and that is where we listen.
ip netns exec "$NS_ROUTER" ip link show "$ROUTER_LEG" >/dev/null 2>&1 ||
  die "the router has no '$ROUTER_LEG' interface - rebuild Day 06's topology"
echo "ok    the router's end of that pair is $ROUTER_LEG - the place to watch"

# ---------------------------------------------------------------------------
say "3. installing lab-trace"

install -d -m 0755 "$CAP_DIR"
install -m 0755 "$HERE_DIR/lab-trace.sh" /usr/local/bin/lab-trace
echo "ok    /usr/local/bin/lab-trace, captures under $CAP_DIR"

# ---------------------------------------------------------------------------
say "4. taking one capture, to prove capturing works"

# tcpdump must be listening BEFORE the traffic exists. Starting it afterwards
# and seeing nothing is not evidence of a broken network; it is evidence of a
# late tcpdump. Everything below is arranged around that one fact.
rm -f "$BASE_CAP"
ip netns exec "$NS_ROUTER" tcpdump -ni "$ROUTER_LEG" -c 4 -w "$BASE_CAP" \
  "icmp and host $CLIENT_IP" >/dev/null 2>&1 &
cap_pid=$!

# Give it a moment to open the socket. One second is generous here and still
# shorter than the time you would spend doubting the result.
sleep 1

ip netns exec "$NS_CLIENT" ping -c2 -W2 "$AUTH_IP" >/dev/null 2>&1 || true
sleep 1

if kill -0 "$cap_pid" 2>/dev/null; then
  kill "$cap_pid" 2>/dev/null || true
fi
wait "$cap_pid" 2>/dev/null || true

[[ -s "$BASE_CAP" ]] || die "tcpdump wrote nothing to $BASE_CAP.
  A capture file that does not exist and a capture file with no packets are
  different problems: check that tcpdump ran as root inside the namespace."

pkts="$(ip netns exec "$NS_ROUTER" tcpdump -nr "$BASE_CAP" 2>/dev/null | wc -l | tr -d ' ')"
[[ "${pkts:-0}" -ge 1 ]] || die "$BASE_CAP exists but holds no packets.
  The file is a valid empty capture, which means tcpdump was listening on the
  wrong interface or the filter matched nothing."

echo "ok    $BASE_CAP holds $pkts packets"
echo "ok    the first two lines of it:"
ip netns exec "$NS_ROUTER" tcpdump -nr "$BASE_CAP" 2>/dev/null | head -2 | sed 's/^/        /'

# ---------------------------------------------------------------------------
say "5. what ss says about sockets, not packets"

# tcpdump answers "did it arrive". ss answers "is anything waiting for it".
# Confusing those two costs more debugging time than any other pair of tools
# in this list: a packet can arrive perfectly and still be refused because
# nothing is listening.
echo "ok    sockets in the client namespace:"
ip netns exec "$NS_CLIENT" ss -s 2>/dev/null | head -2 | sed 's/^/        /'

if ip netns exec "$NS_RESOLVER" ss -ulpn 2>/dev/null | grep -q ":53"; then
  echo "ok    Day 08's resolver is still listening on :53 - today is better with it"
else
  echo "ok    nothing on :53 in the resolver namespace"
  echo "      Day 09 works without it, but DNS is the most interesting traffic"
  echo "      to capture. To have some:  sudo ./days/day08/scripts/setup.sh"
fi

# ---------------------------------------------------------------------------
cat <<EOF

The network is unchanged. What is new is that you can now prove things
about it.

  ip route get     the kernel's decision, for one destination
  tcpdump          what was actually on the wire, in the middle
  ss               whether anything was waiting to receive it

Start here:

  sudo lab-trace                    # the path to $AUTH_IP, end to end
  sudo lab-trace 10.10.9.9          # a destination that does not exist

Then take the tour:  sudo ./days/day09/scripts/explore-packets.sh
And break it:        sudo ./days/day09/scripts/break-and-fix.sh
                     sudo ./days/day09/scripts/break-and-fix.sh --hard

Captures are kept under $CAP_DIR so you can re-read them
after the traffic is long gone. That is the whole advantage of -w.

Check yourself:  sudo ./days/day09/verify.sh
EOF
