#!/usr/bin/env bash
#
# lab-vlan - read the switch instead of guessing what it is doing.
#
#   lab-vlan status        namespaces, ports, addresses
#   lab-vlan vlans         per-port VLAN membership: tagged vs untagged
#   lab-vlan test          every pair that should work, and every pair that
#                          should not, with the verdict on each
#   lab-vlan bond          which leg is carrying the traffic right now
#
# Installed by Day 18's setup.sh as /usr/local/bin/lab-vlan.

set -uo pipefail

SW="sw18"
BR="br0"
VLAN_A="${LAB_VLAN_A:-10}"
VLAN_B="${LAB_VLAN_B:-20}"

say()  { printf '\n%s\n' "$1"; printf '%s\n' "$(printf '%*s' "${#1}" '' | tr ' ' '-')"; }
run()  { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/  /' || true; printf '\n'; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "needs root:  sudo $0 ${1:-status}" >&2; exit 1; }
ip netns list 2>/dev/null | grep -qw "$SW" ||
	{ echo "no '$SW' namespace - run: sudo ./days/day18/scripts/setup.sh" >&2; exit 1; }

cmd_status() {
	say "namespaces"
	run "ip netns list | sort"
	say "ports on the switch"
	run "ip -n $SW -brief link show master $BR"
	say "addresses on the hosts"
	for ns in h18a h18b h18c h18t h18d; do
		ip netns list | grep -qw "$ns" || continue
		run "ip -n $ns -brief addr show"
	done
}

cmd_vlans() {
	say "per-port VLAN membership"
	if command -v bridge >/dev/null 2>&1; then
		run "bridge -n $SW vlan show"
		echo "  How to read it:"
		echo "    PVID              untagged frames arriving here get this VLAN"
		echo "    Egress Untagged   frames leaving here have the tag removed"
		echo "    neither           the port is a trunk for that VLAN: tagged"
		echo
		echo "  An access port shows one VLAN, PVID, Egress Untagged. A trunk"
		echo "  shows several VLANs and no PVID. That difference is the entire"
		echo "  configuration of a switch port."
	else
		echo "  no 'bridge' command here - install iproute2/iproute"
	fi
	say "is filtering actually on"
	run "ip -n $SW -details link show $BR | grep -o 'vlan_filtering [01]'"
	echo "  vlan_filtering 0 means every table above is decoration."
	say "can this switch route between the VLANs"
	run "ip -n $SW addr show $BR | grep -c 'inet ' ; ip netns exec $SW cat /proc/sys/net/ipv4/ip_forward"
	echo "  No address on the bridge and forwarding 0: it cannot, by design."
	say "what the switch has learned"
	run "bridge -n $SW fdb show br $BR | grep -v permanent | head -20"
	echo "  A switch forwards by learned MAC address, per VLAN. The vlan"
	echo "  column is why the same MAC can be reachable in one VLAN and"
	echo "  invisible in another."
}

# try <description> <expect: yes|no> <namespace> <address>
try() {
	local desc="$1" expect="$2" ns="$3" ip="$4" got="no"
	ip netns exec "$ns" ping -c1 -W2 "$ip" >/dev/null 2>&1 && got="yes"
	if [[ "$got" == "$expect" ]]; then
		printf '  ok     %-46s (%s)\n' "$desc" "reached: $got"
	else
		printf '  WRONG  %-46s (wanted %s, got %s)\n' "$desc" "$expect" "$got"
	fi
}

cmd_test() {
	say "what should work"
	try "h18a -> h18b, both VLAN $VLAN_A"        yes h18a "10.30.$VLAN_A.3"
	try "h18a -> trunk host, VLAN $VLAN_A"      yes h18a "10.30.$VLAN_A.4"
	try "h18c -> trunk host, VLAN $VLAN_B"      yes h18c "10.30.$VLAN_B.4"
	if ip netns list | grep -qw h18d && ip -n h18d link show bond0 >/dev/null 2>&1; then
		try "h18a -> bonded host, VLAN $VLAN_A"    yes h18a "10.30.$VLAN_A.5"
	fi

	say "what must not work"
	try "h18a -> h18c, VLAN $VLAN_A to $VLAN_B"  no h18a "10.30.$VLAN_B.3"
	try "h18c -> h18a, VLAN $VLAN_B to $VLAN_A"  no h18c "10.30.$VLAN_A.2"
	try "h18a -> trunk host on VLAN $VLAN_B"     no h18a "10.30.$VLAN_B.4"
	echo
	echo "  Nothing above is enforced by a firewall. There is no firewall in"
	echo "  this topology, and the bridge has no IP address, so there is"
	echo "  nothing that could route between the two VLANs even if asked."
}

cmd_bond() {
	say "the bond"
	if ! ip -n h18d link show bond0 >/dev/null 2>&1; then
		echo "  no bond0 - this kernel has no bonding module, or setup skipped it"
		return 0
	fi
	run "ip -n h18d -brief link show type bond"
	run "ip -n h18d -details link show bond0 | sed -n '1,4p'"
	say "the legs"
	run "ip -n h18d -brief link show master bond0"
	say "which leg is carrying traffic"
	run "ip netns exec h18d cat /proc/net/bonding/bond0"
	echo "  'Currently Active Slave' is the answer. In active-backup only one"
	echo "  leg transmits; the other is a spare that costs nothing until the"
	echo "  first one stops. Pull the active one and watch this line change."
}

case "${1:-status}" in
status) cmd_status ;;
vlans)  cmd_vlans ;;
test)   cmd_test ;;
bond)   cmd_bond ;;
*)
	echo "usage: $0 {status|vlans|test|bond}" >&2
	exit 2
	;;
esac
