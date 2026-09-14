#!/usr/bin/env bash
#
# Day 18 setup - one bridge, two VLANs, one bond. No VM.
#
#   sudo ./scripts/setup.sh
#
# Everything today lives in network namespaces on the machine you are reading
# this on, which is why this day costs 0 MB. Namespaces are kernel objects:
# they vanish on reboot, so re-running this is normal and not a repair.
#
# The topology, which is one switch with five things plugged into it:
#
#   h18a  10.30.10.2  --- sw-a   (access, VLAN 10 untagged)
#   h18b  10.30.10.3  --- sw-b   (access, VLAN 10 untagged)
#   h18c  10.30.20.3  --- sw-c   (access, VLAN 20 untagged)
#   h18t  .10 + .20   --- sw-t   (trunk,  VLAN 10 and 20 tagged)
#   h18d  10.30.10.5  --- sw-d0 + sw-d1   (bond, VLAN 10 untagged)
#
# One bridge. One broadcast domain per VLAN. h18a and h18c are on the same
# wire, in the same switch, and cannot reach each other - and no firewall is
# involved in that. That is the whole day.
#
# It does not touch Day 06's client/router/resolver/auth namespaces, so both
# topologies can be up at once.
#
# Idempotent: run it as often as you like.

set -euo pipefail

say()  { printf '\n==> %s\n\n' "$*"; }
die()  { printf '\nfailed: %s\n' "$*" >&2; exit 1; }
ok()   { printf '  ok    %s\n' "$*"; }
note() { printf '        %s\n' "$*"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_SRC="$HERE/lab-vlan.sh"
PAYLOAD="/usr/local/bin/lab-vlan"

SW="sw18"
BR="br0"
VLAN_A="${LAB_VLAN_A:-10}"
VLAN_B="${LAB_VLAN_B:-20}"
STATE="/run/day18"

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "needs root:  sudo $0 $*"

# ---------------------------------------------------------------------------
# 0. what this needs
# ---------------------------------------------------------------------------
say "0. the tools"

missing=""
for t in ip ping; do
	command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
if [[ -n "$missing" ]]; then
	printf 'missing:%s\n\n' "$missing" >&2
	echo "  RHEL family:    sudo dnf install -y iproute iputils" >&2
	echo "  Debian/Ubuntu:  sudo apt-get install -y iproute2 iputils-ping" >&2
	die "install those and run this again"
fi
ok "ip and ping are here"

# `bridge` ships in the same package as `ip` but is a separate binary, and it
# is the only tool that can show per-port VLAN membership. Without it you can
# build this day but you cannot read it.
if command -v bridge >/dev/null 2>&1; then
	ok "bridge is here - this is the tool that shows VLAN membership"
else
	note "no 'bridge' command; setup will work, but you will not see the"
	note "tagged/untagged tables that are the point of today"
fi

# 8021q does VLAN subinterfaces; bonding does link aggregation. Both are
# modules, and on a stripped-down kernel either can be absent. Missing
# bonding is survivable - the VLAN half of the day is the important half -
# so record what we got rather than dying.
mkdir -p "$STATE"
rm -f "$STATE/bond.enabled"
modprobe 8021q >/dev/null 2>&1 || true
modprobe bonding >/dev/null 2>&1 || true
if [[ -d /sys/module/8021q ]] || ip link help 2>&1 | grep -q vlan; then
	ok "802.1Q is available"
else
	die "no 802.1Q support in this kernel - the trunk cannot be built"
fi
if [[ -d /sys/module/bonding ]]; then
	ok "bonding is available"
	BOND=yes
else
	note "no bonding module - the aggregation section will be skipped"
	note "the VLAN work does not depend on it"
	BOND=no
fi

# ---------------------------------------------------------------------------
# 1. namespaces
# ---------------------------------------------------------------------------
say "1. the namespaces"

for ns in "$SW" h18a h18b h18c h18t h18d; do
	if ip netns list | grep -qw "$ns"; then
		ok "$ns already exists"
	else
		ip netns add "$ns"
		ok "created $ns"
	fi
	ip -n "$ns" link set lo up
done

# ---------------------------------------------------------------------------
# 2. the switch
# ---------------------------------------------------------------------------
say "2. the bridge, with VLAN filtering ON"

if ip -n "$SW" link show "$BR" >/dev/null 2>&1; then
	ok "$BR already exists"
else
	# vlan_filtering 1 is the difference between a bridge and a VLAN-aware
	# switch. Without it, every 'bridge vlan' table you set is recorded and
	# then ignored: frames are forwarded regardless of tag, the isolation
	# silently does not exist, and the configuration still looks right.
	ip -n "$SW" link add "$BR" type bridge vlan_filtering 1
	ok "created $BR with vlan_filtering 1"
fi
ip -n "$SW" link set "$BR" type bridge vlan_filtering 1
ip -n "$SW" link set "$BR" up

# The bridge device is itself an entry in the VLAN tables - its own row needs
# the 'self' flag - and it is given VLAN 1 like every other port. Leave it and
# the switch keeps a foot in a VLAN nobody configured.
if command -v bridge >/dev/null 2>&1; then
	bridge -n "$SW" vlan del dev "$BR" vid 1 self 2>/dev/null || true
	ok "removed the default VLAN 1 from $BR itself"
fi

# Forwarding is off in a fresh namespace on most kernels, but "most" is not a
# guarantee - the initial value can come from the host, where Docker, a VPN or
# an old sysctl.d file may have turned it on. Today's isolation must not
# depend on a setting nobody checked, so set it rather than assume it.
ip netns exec "$SW" sh -c 'echo 0 > /proc/sys/net/ipv4/ip_forward' 2>/dev/null || true
ok "forwarding is off in $SW - this switch cannot route, by construction"

# A switch has no IP address. Leaving one off is deliberate: it proves the
# isolation below is layer 2, because there is nothing here that could route.
note "no address on $BR - a switch is not a router"

# ---------------------------------------------------------------------------
# 3. the cables
# ---------------------------------------------------------------------------
say "3. the veth pairs"

# plug <namespace> <host-side-name> <switch-side-name>
plug() {
	local ns="$1" far="$2" near="$3"
	if ip -n "$SW" link show "$near" >/dev/null 2>&1; then
		ok "$near is already plugged into $BR"
	else
		# Build the pair in the switch namespace, then move one end. A veth
		# pair is created in one namespace and split afterwards; there is no
		# way to create it already spanning two.
		ip -n "$SW" link add "$near" type veth peer name "$far"
		ip -n "$SW" link set "$far" netns "$ns"
		ok "cable: $ns/$far <-> $SW/$near"
	fi
	ip -n "$SW" link set "$near" master "$BR"
	ip -n "$SW" link set "$near" up
	ip -n "$ns" link set "$far" up
}

plug h18a a-eth0 sw-a
plug h18b b-eth0 sw-b
plug h18c c-eth0 sw-c
plug h18t t-eth0 sw-t
if [[ "$BOND" == "yes" ]]; then
	plug h18d d-eth0 sw-d0
	plug h18d d-eth1 sw-d1
fi

# ---------------------------------------------------------------------------
# 4. VLAN membership, per port
# ---------------------------------------------------------------------------
say "4. which port is in which VLAN"

# access <port> <vid>   untagged, and nothing else
access() {
	local port="$1" vid="$2"
	command -v bridge >/dev/null 2>&1 || return 0
	# pvid: frames arriving with no tag are treated as this VLAN.
	# untagged: frames leaving have the tag stripped again.
	# The host on the far end never sees a tag and needs no VLAN config -
	# that is what "access port" means, and why the host cannot tell.
	bridge -n "$SW" vlan add dev "$port" vid "$vid" pvid untagged
	# VLAN 1 is added to every new port automatically. Leave it and your
	# two isolated VLANs share a third one that nobody configured.
	bridge -n "$SW" vlan del dev "$port" vid 1 2>/dev/null || true
	ok "$port: access, VLAN $vid, untagged"
}

# trunk <port> <vid> <vid>...   tagged, no pvid
trunk() {
	local port="$1"; shift
	local vid
	command -v bridge >/dev/null 2>&1 || return 0
	for vid in "$@"; do
		bridge -n "$SW" vlan add dev "$port" vid "$vid"
	done
	bridge -n "$SW" vlan del dev "$port" vid 1 2>/dev/null || true
	ok "$port: trunk, VLANs $* tagged"
	note "no pvid here: an untagged frame arriving on a trunk belongs"
	note "to no VLAN, and is dropped"
}

access sw-a "$VLAN_A"
access sw-b "$VLAN_A"
access sw-c "$VLAN_B"
trunk  sw-t "$VLAN_A" "$VLAN_B"
if [[ "$BOND" == "yes" ]]; then
	access sw-d0 "$VLAN_A"
	access sw-d1 "$VLAN_A"
fi

# ---------------------------------------------------------------------------
# 5. the plain hosts
# ---------------------------------------------------------------------------
say "5. addresses on the access hosts"

addr() {
	local ns="$1" dev="$2" cidr="$3"
	if ip -n "$ns" addr show dev "$dev" | grep -q "inet ${cidr%/*}/"; then
		ok "$ns/$dev already has ${cidr}"
	else
		ip -n "$ns" addr add "$cidr" dev "$dev"
		ok "$ns/$dev <- $cidr"
	fi
}

addr h18a a-eth0 "10.30.$VLAN_A.2/24"
addr h18b b-eth0 "10.30.$VLAN_A.3/24"
addr h18c c-eth0 "10.30.$VLAN_B.3/24"
note "h18a and h18b share a subnet; h18c is in another. They also share"
note "a switch, which is the part that stops mattering in a moment"

# ---------------------------------------------------------------------------
# 6. the trunk host
# ---------------------------------------------------------------------------
say "6. one interface, two VLANs"

# On a trunk the tag survives to the host, so the host has to do the
# tagging itself: one subinterface per VLAN, each with its own address, on
# one physical link. This is exactly how a hypervisor or a router-on-a-stick
# reaches many VLANs down one cable.
for vid in "$VLAN_A" "$VLAN_B"; do
	if ip -n h18t link show "t-eth0.$vid" >/dev/null 2>&1; then
		ok "t-eth0.$vid already exists"
	else
		ip -n h18t link add link t-eth0 name "t-eth0.$vid" type vlan id "$vid"
		ok "created t-eth0.$vid (802.1Q id $vid)"
	fi
	ip -n h18t link set "t-eth0.$vid" up
	addr h18t "t-eth0.$vid" "10.30.$vid.4/24"
done
note "t-eth0 itself has no address. It carries tagged frames only"

# ---------------------------------------------------------------------------
# 7. the bond
# ---------------------------------------------------------------------------
say "7. two cables, one interface"

if [[ "$BOND" == "yes" ]]; then
	if ip -n h18d link show bond0 >/dev/null 2>&1; then
		ok "bond0 already exists"
	else
		# active-backup is the mode that needs nothing from the switch. The
		# balancing modes (802.3ad especially) require the switch to agree,
		# and a bond configured for LACP against a switch that is not doing
		# LACP is worse than no bond at all.
		ip netns exec h18d ip link add bond0 type bond mode active-backup miimon 100
		ok "created bond0, mode active-backup, miimon 100"
	fi
	# Slaves must be DOWN to be enslaved, and lose their own addresses.
	for leg in d-eth0 d-eth1; do
		if [[ "$(ip -n h18d -details link show "$leg" | grep -c 'master bond0')" -gt 0 ]]; then
			ok "$leg is already in the bond"
		else
			ip -n h18d link set "$leg" down
			ip -n h18d link set "$leg" master bond0
			ip -n h18d link set "$leg" up
			ok "enslaved $leg"
		fi
	done
	ip -n h18d link set bond0 up
	addr h18d bond0 "10.30.$VLAN_A.5/24"
	touch "$STATE/bond.enabled"
	note "the address is on bond0, never on a leg. Legs are cable, not host"
else
	note "skipped - no bonding module. Everything else on this day is real"
fi

# ---------------------------------------------------------------------------
# 8. the payload
# ---------------------------------------------------------------------------
say "8. installing lab-vlan"

if [[ -f "$PAYLOAD_SRC" ]]; then
	install -m 0755 "$PAYLOAD_SRC" "$PAYLOAD"
	ok "installed $PAYLOAD"
	note "lab-vlan status | vlans | test | bond"
else
	note "lab-vlan.sh not found next to this script - skipping"
fi

# ---------------------------------------------------------------------------
# 9. does it do what the tables say
# ---------------------------------------------------------------------------
say "9. proving it, rather than assuming it"

if ip netns exec h18a ping -c1 -W2 "10.30.$VLAN_A.3" >/dev/null 2>&1; then
	ok "h18a reaches h18b - same VLAN, same switch"
else
	die "h18a cannot reach h18b. Both are VLAN $VLAN_A access ports:
  bridge -n $SW vlan show"
fi

if ip netns exec h18a ping -c1 -W2 "10.30.$VLAN_B.3" >/dev/null 2>&1; then
	die "h18a reached h18c, and it must not. VLAN filtering is not doing
  anything - check that it is on:
  ip -n $SW -details link show $BR | grep vlan_filtering"
else
	ok "h18a cannot reach h18c - different VLAN, and no firewall said so"
fi

if ip netns exec h18c ping -c1 -W2 "10.30.$VLAN_B.4" >/dev/null 2>&1; then
	ok "h18c reaches the trunk host on VLAN $VLAN_B"
else
	die "h18c cannot reach t-eth0.$VLAN_B - the trunk is not carrying VLAN $VLAN_B"
fi

say "done"
note "Look at the tables:   sudo lab-vlan vlans"
note "Take the tour:        sudo ./scripts/explore-vlans.sh"
note "Break it on purpose:  sudo ./scripts/break-and-fix.sh"
note "Check yourself:       sudo ./verify.sh"
echo
note "Worth doing first: ping from h18a to h18c and watch it fail, then run"
note "'bridge -n $SW vlan show' and find the reason in the table."
