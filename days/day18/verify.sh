#!/usr/bin/env bash
#
# Day 18 - bridges, VLANs and link aggregation.
#
# Run this on the machine that ran scripts/setup.sh. No VM involved.
#
# Exits 0 only when every automatic check passes. Items printed as YOU are
# judgement calls and never affect the exit status.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../../lab/verify-lib.sh"

vl_init "Day 18 - bridges, VLANs and link aggregation"
vl_need ip bridge ping
vl_need_root

SW="sw18"
BR="br0"
VLAN_A="${LAB_VLAN_A:-10}"
VLAN_B="${LAB_VLAN_B:-20}"

# --- the topology exists --------------------------------------------------
vl_check "all six namespaces are up" \
	'for n in sw18 h18a h18b h18c h18t h18d; do ip netns list | grep -qw "$n" || exit 1; done'

vl_check "a bridge exists in the switch namespace" \
	"ip -n $SW -details link show type bridge | grep -q $BR"

# The flag, not the tables. Tables can be perfect and inert.
vl_check "VLAN filtering is ON, so the tables actually apply" \
	"ip -n $SW -details link show $BR | grep -q 'vlan_filtering 1'"

vl_check "at least four ports are enslaved to the bridge" \
	"[ \"\$(ip -n $SW link show master $BR | grep -c '^[0-9]')\" -ge 4 ]"

# --- access ports ---------------------------------------------------------
vl_check "sw-a is an access port: VLAN $VLAN_A, PVID, untagged" \
	"bridge -n $SW vlan show dev sw-a | grep -E '\\b$VLAN_A\\b' | grep -q PVID"

vl_check "sw-c is an access port in the other VLAN ($VLAN_B)" \
	"bridge -n $SW vlan show dev sw-c | grep -E '\\b$VLAN_B\\b' | grep -q PVID"

# VLAN 1 is added to every new bridge port automatically - and to the bridge
# device itself, whose row needs the 'self' flag to remove. It is the quiet
# way two isolated VLANs end up sharing a third one. The sed strips the port
# column so continuation lines are checked too.
vl_check "VLAN 1 was removed from every port, including the bridge itself" \
	"! bridge -n $SW vlan show | sed 's/^[^ ]* *//' | grep -qE '^1([[:space:]]|\$)'"

# --- the trunk ------------------------------------------------------------
vl_check "sw-t is a trunk: both VLANs, tagged, no PVID" \
	"bridge -n $SW vlan show dev sw-t | grep -qE '\\b$VLAN_A\\b' && bridge -n $SW vlan show dev sw-t | grep -qE '\\b$VLAN_B\\b' && ! bridge -n $SW vlan show dev sw-t | grep -q Untagged"

vl_check "the trunk host carries an 802.1Q subinterface for each VLAN" \
	"ip -n h18t -details link show t-eth0.$VLAN_A | grep -q 'id $VLAN_A' && ip -n h18t -details link show t-eth0.$VLAN_B | grep -q 'id $VLAN_B'"

vl_check "the trunk's own link has no address - it carries tags only" \
	"! ip -n h18t addr show dev t-eth0 | grep -q 'inet '"

vl_check "the access host has no VLAN interface at all" \
	"! ip -n h18a -details link show | grep -q 'vlan protocol'"

# --- what the VLANs do ----------------------------------------------------
vl_check "two hosts in VLAN $VLAN_A reach each other" \
	"ip netns exec h18a ping -c1 -W2 10.30.$VLAN_A.3"

vl_check "VLAN $VLAN_A reaches the trunk host's tagged address" \
	"ip netns exec h18a ping -c1 -W2 10.30.$VLAN_A.4"

vl_check "VLAN $VLAN_B reaches the trunk host on its own tag" \
	"ip netns exec h18c ping -c1 -W2 10.30.$VLAN_B.4"

vl_check "a host in VLAN $VLAN_A cannot reach VLAN $VLAN_B" \
	"! ip netns exec h18a ping -c1 -W2 10.30.$VLAN_B.3"

vl_check "and it cannot reach the trunk host's other VLAN either" \
	"! ip netns exec h18a ping -c1 -W2 10.30.$VLAN_B.4"

# --- the isolation is layer 2, not policy ---------------------------------
vl_check "the bridge has no IP address, so nothing could route between them" \
	"! ip -n $SW addr show dev $BR | grep -q 'inet '"

# Read the file, not 'sysctl': sysctl lives in /sbin on some distributions
# and is missing from a minimal image, and a missing binary would look like
# forwarding being on.
vl_check "forwarding is off in the switch namespace" \
	"[ \"\$(ip netns exec $SW cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)\" = 0 ]"

vl_check "the switch learned MAC addresses per VLAN" \
	"bridge -n $SW fdb show br $BR | grep -q \"vlan $VLAN_A\""

# --- the bond -------------------------------------------------------------
# Bonding is a kernel module and some stripped-down kernels do not have it.
# setup.sh drops a marker when it built the bond; without that marker these
# checks pass without asserting anything, which is honest rather than red.
# The VLAN work above does not depend on the bond.
vl_check "the bond has both legs enslaved" \
	"[ ! -f /run/day18/bond.enabled ] || [ \"\$(ip -n h18d link show master bond0 | grep -c '^[0-9]')\" -eq 2 ]"

vl_check "the bonded host answers on one address across two cables" \
	"[ ! -f /run/day18/bond.enabled ] || ip netns exec h18a ping -c1 -W2 10.30.$VLAN_A.5"

vl_check "the address is on bond0 and not on either leg" \
	"[ ! -f /run/day18/bond.enabled ] || { ip -n h18d addr show dev bond0 | grep -q 'inet ' && ! ip -n h18d addr show dev d-eth0 | grep -q 'inet '; }"

vl_manual "you can read tagged versus untagged straight off 'bridge vlan show' and say which port is which"
vl_manual "you took down the active bond leg, watched the traffic continue, and can say why the address never moved"

vl_summary
