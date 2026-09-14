#!/usr/bin/env bash
#
# Day 18 tour - twelve looks at one bridge. Read-only: nothing here changes
# anything, so run it as often as you like.
#
#   sudo ./scripts/explore-vlans.sh

set -uo pipefail

SW="sw18"
BR="br0"

say()  { printf '\n=== %s ===\n\n' "$*"; }
note() { printf '  (%s)\n\n' "$1"; }
run()  { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/  /' || true; printf '\n'; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "needs root:  sudo $0" >&2; exit 1; }
ip netns list 2>/dev/null | grep -qw "$SW" ||
	{ echo "no '$SW' namespace - run: sudo ./days/day18/scripts/setup.sh" >&2; exit 1; }

say "1. a bridge is a switch in software"
run "ip -n $SW -brief link show type bridge"
note "One device. Everything plugged into it shares its forwarding logic"

say "2. the ports"
run "ip -n $SW -brief link show master $BR"
note "An enslaved port has no address of its own - it is a socket on a switch"

say "3. the flag that makes it a VLAN switch"
run "ip -n $SW -details link show $BR | grep -o 'vlan_filtering [01]'"
note "vlan_filtering 0 and every table below is written down and ignored"

say "4. per-port membership: the whole configuration of a switch"
run "bridge -n $SW vlan show"
note "PVID = tag applied on the way in; Untagged = tag stripped on the way out"

say "5. an access host has no idea it is in a VLAN"
run "ip -n h18a -brief addr show"
run "ip -n h18a -details link show a-eth0 | grep -c 'vlan protocol' || true"
note "No VLAN interface, no tag, no configuration. The switch does it all"

say "6. a trunk host does the tagging itself"
run "ip -n h18t -brief addr show"
run "ip -n h18t -details link show t-eth0.10 | sed -n '2p'"
note "One link, two subinterfaces, two addresses - this is router-on-a-stick"

say "7. same wire, same switch, no route between them"
run "ip netns exec h18a ping -c1 -W1 10.30.10.3; echo \"exit=\$?\""
run "ip netns exec h18a ping -c1 -W1 10.30.20.3; echo \"exit=\$?\""
note "The second one is the day. No firewall rule was consulted"

say "8. why it fails: the frame has nowhere to go"
run "ip netns exec h18a ip route get 10.30.20.3"
run "ip netns exec h18a ip neigh"
note "h18a thinks 10.30.20.3 is on its own link, ARPs, and hears nothing"

say "9. the switch forwards by learned MAC, per VLAN"
run "bridge -n $SW fdb show br $BR | grep -v permanent | head -12"
note "The vlan column is the isolation: a MAC learned in 10 is not in 20"

say "10. watch a tagged frame arrive"
run "ip netns exec h18t timeout 3 tcpdump -nei t-eth0 -c 2 arp 2>/dev/null & sleep 1; ip netns exec h18c ping -c2 -W1 10.30.20.4 >/dev/null 2>&1; wait"
note "If tcpdump is installed you will see 'vlan 20' in the frame itself"

say "11. the bond, if this kernel has one"
run "ip -n h18d -brief link show 2>/dev/null || echo 'no h18d'"
run "ip netns exec h18d grep -E 'Mode|Currently Active|MII Status' /proc/net/bonding/bond0 2>/dev/null || echo 'no bond0 on this kernel'"
note "Two legs, one address, one of them actually carrying traffic"

say "12. nothing here is a router"
run "ip -n $SW addr show $BR | grep -c 'inet ' || true"
run "ip netns exec $SW cat /proc/sys/net/ipv4/ip_forward"
note "No address and no forwarding: the isolation cannot be a firewall rule"

printf '\nNext: sudo ./scripts/break-and-fix.sh, then sudo ./verify.sh\n'
