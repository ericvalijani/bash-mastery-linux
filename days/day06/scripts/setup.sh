#!/usr/bin/env bash
#
# setup.sh - build the Day 06 network by hand, one layer at a time.
#
# lab/lab.sh netns-up builds this same topology in one command. This script
# builds it in seven visible steps and says what each one does, because the
# point of today is not to have the network - it is to know why every piece of
# it is there. Days 07-10 and 18 all stand on what this builds.
#
# Same names and same addresses as lab.sh netns-up, deliberately: whichever
# way you build it, the later days find what they expect.
#
#   sudo ./setup.sh
#
# Idempotent. Run it twice; the second run repairs rather than complains.
#
# NOTE ON WHERE THIS RUNS. Every other day so far has refused to run outside a
# lab VM. This one does not, and that is not an oversight. A network namespace
# is a separate, empty copy of the kernel's whole network stack: its own
# interfaces, its own routing table, its own sysctls. Nothing here adds an
# address, a route or a rule to the namespace your laptop actually uses. That
# isolation is exactly why Days 06-10 cost 0 MB and need no VM at all - and it
# is also why CI can run this for real instead of only linting it.

set -euo pipefail

say() { printf '\n==> %s\n' "$*"; }
die() { echo "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "needs root:  sudo $0"

# --- the topology, in one place ---------------------------------------------
#
#   client 10.10.0.2  ---  10.10.0.1 router 10.10.1.1  ---  10.10.1.2 resolver
#                                    router 10.10.2.1  ---  10.10.2.2 auth
#
# Three /24s, one router with a leg in each. Nothing is bridged and nothing is
# NAT-ed: for the client to reach auth, a packet must genuinely be forwarded.

NS_LIST=(client router resolver auth)

# Each line: namespace  its-veth  its-address  router-veth  router-address
PAIRS=(
  "client   veth-cl 10.10.0.2/24 veth-rcl 10.10.0.1/24"
  "resolver veth-rs 10.10.1.2/24 veth-rrs 10.10.1.1/24"
  "auth     veth-au 10.10.2.2/24 veth-rau 10.10.2.1/24"
)

# --- 0. what this needs -----------------------------------------------------

say "0. checking the tools this day needs"

missing=""
for c in ip ping sysctl; do
  command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
done
if [[ -n "$missing" ]]; then
  echo "missing:$missing" >&2
  if command -v dnf >/dev/null 2>&1; then
    die "install them first:  sudo dnf install -y iproute iputils procps-ng"
  else
    die "install them first:  sudo apt-get install -y iproute2 iputils-ping procps"
  fi
fi
echo "  ip, ping and sysctl are present"

# Namespaces need /var/run/netns, which iproute2 creates on first use. If /run
# is mounted without shared propagation, 'ip netns exec' fails in a way whose
# error message names mount, not networking. Check it here instead.
[[ -d /proc/self/ns ]] || die "this kernel has no namespace support at all"

# --- 1. the namespaces ------------------------------------------------------

say "1. creating the four namespaces"

# 'ip netns add' makes a named network namespace and nothing else. A fresh one
# is not a blank machine with networking off - it is emptier than that. It has
# exactly one interface, lo, and even that starts DOWN, so a namespace cannot
# reach 127.0.0.1 until you say so. Half the confusion people have on their
# first namespace day is a service bound to localhost inside a namespace whose
# loopback was never brought up.
for ns in "${NS_LIST[@]}"; do
  if ip netns list | grep -qw "$ns"; then
    echo "  $ns already exists - leaving it"
  else
    ip netns add "$ns"
    echo "  created $ns"
  fi
  ip -n "$ns" link set lo up
done

# --- 2. the wires -----------------------------------------------------------

say "2. wiring veth pairs"

# A veth is created as a PAIR and always exists as a pair: two interfaces, a
# virtual cable between them, whatever goes in one end comes out the other.
# You cannot make one veth interface any more than you can make one end of a
# cable. The pair is created in this namespace and then each end is MOVED into
# where it belongs - and moving an interface into a namespace wipes its
# addresses, which is why addresses come after this step and not during it.
for line in "${PAIRS[@]}"; do
  # shellcheck disable=SC2086
  set -- $line
  ns="$1"; veth="$2"; addr="$3"; rveth="$4"; raddr="$5"

  if ip -n "$ns" link show "$veth" >/dev/null 2>&1 &&
     ip -n router link show "$rveth" >/dev/null 2>&1; then
    echo "  $veth <-> $rveth already in place"
    continue
  fi

  # A previous half-finished run can leave one end stranded in the root
  # namespace. Deleting either end deletes both, so this is enough.
  # Each of these can legitimately fail (nothing stranded), so none of them
  # may be the last command in the body of a 'set -e' loop without || true.
  ip link del "$veth"           2>/dev/null || true
  ip link del "$rveth"          2>/dev/null || true
  ip -n "$ns"  link del "$veth"  2>/dev/null || true
  ip -n router link del "$rveth" 2>/dev/null || true

  ip link add "$veth" type veth peer name "$rveth"
  ip link set "$veth"  netns "$ns"
  ip link set "$rveth" netns router
  echo "  $ns:$veth <-> router:$rveth"
done

# --- 3. addresses -----------------------------------------------------------

say "3. giving each end an address"

# 'addr replace' rather than 'addr add': add fails with EEXIST on a second run,
# replace is the idempotent form. The /24 matters more than the address does -
# it is the prefix length that tells the kernel which addresses are on-link and
# therefore reachable without a router, and it is what silently creates the
# connected route you will see in step 6.
for line in "${PAIRS[@]}"; do
  # shellcheck disable=SC2086
  set -- $line
  ns="$1"; veth="$2"; addr="$3"; rveth="$4"; raddr="$5"

  ip -n "$ns"  addr replace "$addr"  dev "$veth"
  ip -n router addr replace "$raddr" dev "$rveth"
  ip -n "$ns"  link set "$veth"  up
  ip -n router link set "$rveth" up
  echo "  $addr on $ns:$veth, $raddr on router:$rveth"
done

# --- 4. forwarding ----------------------------------------------------------

say "4. turning the router into a router"

# Until this line, 'router' is a host with three interfaces, which is not the
# same thing as a router. A Linux host receiving a packet addressed to someone
# else drops it, and drops it silently: no log, no ICMP, nothing in dmesg. The
# only symptom is that the ping does not come back.
#
# Note that this sysctl is per-namespace, like almost everything under
# net.ipv4. Setting it on your laptop would do nothing for the router, and
# setting it here does nothing to your laptop.
ip netns exec router sysctl -qw net.ipv4.ip_forward=1
echo "  net.ipv4.ip_forward=1 inside the router namespace only"
echo "  (your own machine's setting is untouched: $(sysctl -n net.ipv4.ip_forward))"

# --- 5. default routes ------------------------------------------------------

say "5. telling the leaves where to send everything else"

# Each leaf knows only its own /24 - that route appeared by itself in step 3.
# Anything outside it needs a next hop, and 'default' is the route of last
# resort. Without it the client's ping to 10.10.2.2 fails instantly with
# "Network is unreachable" from its own kernel - the packet never leaves the
# namespace. That error, and the difference between it and a timeout, is worth
# provoking on purpose: break-and-fix.sh does exactly that.
ip -n client   route replace default via 10.10.0.1
ip -n resolver route replace default via 10.10.1.1
ip -n auth     route replace default via 10.10.2.1
echo "  client -> 10.10.0.1, resolver -> 10.10.1.1, auth -> 10.10.2.1"

# The router needs no default route: it has a connected route for all three
# /24s, which is every address in this lab. Adding one would be cargo cult.

# --- 6. what you just built -------------------------------------------------

say "6. the routing table the client ended up with"

ip -n client route
echo
echo "  Two lines, and neither was typed as a route by you or by step 5 alone:"
echo "  the 10.10.0.0/24 line is the connected route the address created, and"
echo "  'default via 10.10.0.1' is step 5. Every packet the client sends is"
echo "  matched against these two, longest prefix first."

# --- 7. prove it ------------------------------------------------------------

say "7. asking whether a packet can cross the router"

if ip netns exec client ping -c1 -W2 10.10.2.2 >/dev/null 2>&1; then
  echo "  client -> auth works: the packet was forwarded, not bridged"
else
  echo "  client cannot reach auth. Nothing below this line is a guess:" >&2
  echo "    sudo ip netns exec client ip route" >&2
  echo "    sudo ip netns exec router sysctl net.ipv4.ip_forward" >&2
  echo "    sudo ip netns exec router ip -br addr" >&2
  die "topology incomplete"
fi

cat <<'EOF'

  client   10.10.0.2  --.
                        router  10.10.0.1 / 10.10.1.1 / 10.10.2.1
  resolver 10.10.1.2  --'
  auth     10.10.2.2  --'

Built. Next:

  sudo ./scripts/lab-netcheck.sh     the whole reachability matrix
  sudo ./scripts/explore-net.sh      the tour
  ./days/day06/verify.sh             (with sudo - every check enters a namespace)

This network is not persistent. Namespaces live in the running kernel, so a
reboot removes all four and every day from 07 onwards starts by rebuilding
them. That is a feature: it costs a second and it is never stale.
EOF
