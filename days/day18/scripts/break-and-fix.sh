#!/usr/bin/env bash
#
# Day 18 break-and-fix - four ways a VLAN switch lies to you.
#
#   sudo ./scripts/break-and-fix.sh          break it, show it, fix it
#   sudo ./scripts/break-and-fix.sh --hard   break it and LEAVE it broken
#
# Every failure here is a real configuration that looks correct in at least
# one place. The skill is knowing which command contradicts the other.
#
# The good configuration is saved first, so --hard is always recoverable
# with: sudo ./scripts/setup.sh

set -uo pipefail

SW="sw18"
BR="br0"
VLAN_A="${LAB_VLAN_A:-10}"
VLAN_B="${LAB_VLAN_B:-20}"
BACKUP_DIR="/tmp/day18-broken"

say()  { printf '\n%s\n' "$1"; printf '%s\n' "$(printf '%*s' "${#1}" '' | tr ' ' '-')"; }
note() { printf '        %s\n' "$*"; }
ok()   { printf '  ok    %s\n' "$*"; }
run()  { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/  /' || true; printf '\n'; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "needs root:  sudo $0 ${1:-}" >&2; exit 1; }
ip netns list 2>/dev/null | grep -qw "$SW" ||
	{ echo "no '$SW' namespace - run: sudo ./days/day18/scripts/setup.sh" >&2; exit 1; }
command -v bridge >/dev/null 2>&1 ||
	{ echo "needs the 'bridge' command (iproute2/iproute)" >&2; exit 1; }

HARD=no
[[ "${1:-}" == "--hard" ]] && HARD=yes

mkdir -p "$BACKUP_DIR"
bridge -n "$SW" vlan show >"$BACKUP_DIR/vlan.good" 2>/dev/null || true
ok "saved the working VLAN tables to $BACKUP_DIR/vlan.good"

# reach <ns> <ip>   -> prints yes or no
reach() {
	if ip netns exec "$1" ping -c1 -W2 "$2" >/dev/null 2>&1; then echo yes; else echo no; fi
}

# ---------------------------------------------------------------------------
say "1. the port that is in no VLAN at all"

note "Removing a port's only VLAN does not remove the port. The link stays"
note "UP, the address stays, the cable is fine - and nothing arrives."
echo
bridge -n "$SW" vlan del dev sw-b vid "$VLAN_A"
run "bridge -n $SW vlan show dev sw-b"
printf '  h18a -> h18b now: %s\n' "$(reach h18a "10.30.$VLAN_A.3")"
run "ip -n h18b -brief link show b-eth0"
note "The host sees UP. The switch sees a port with no VLAN membership, so"
note "every frame is dropped on arrival. 'ip link' cannot see this at all -"
note "only 'bridge vlan show' can."

if [[ "$HARD" == "no" ]]; then
	bridge -n "$SW" vlan add dev sw-b vid "$VLAN_A" pvid untagged
	ok "put sw-b back in VLAN $VLAN_A: $(reach h18a "10.30.$VLAN_A.3")"
fi

# ---------------------------------------------------------------------------
say "2. the right VLAN, the wrong PVID"

note "A port can be a member of a VLAN and still put incoming frames in a"
note "different one. Membership and PVID are two separate settings."
echo
bridge -n "$SW" vlan add dev sw-a vid "$VLAN_B" pvid untagged
run "bridge -n $SW vlan show dev sw-a"
printf '  h18a -> h18b (VLAN %s): %s\n' "$VLAN_A" "$(reach h18a "10.30.$VLAN_A.3")"
printf '  h18a -> h18c (VLAN %s): %s\n' "$VLAN_B" "$(reach h18a "10.30.$VLAN_B.3")"
note "h18a is still listed in VLAN $VLAN_A, and its traffic is now in"
note "VLAN $VLAN_B, because untagged frames follow the PVID. It did not lose"
note "connectivity - it gained the wrong connectivity, which is worse: the"
note "isolation you documented is gone and every ping still works."

if [[ "$HARD" == "no" ]]; then
	bridge -n "$SW" vlan del dev sw-a vid "$VLAN_B"
	bridge -n "$SW" vlan add dev sw-a vid "$VLAN_A" pvid untagged
	ok "PVID $VLAN_A restored on sw-a"
	ok "h18a -> h18c is $(reach h18a "10.30.$VLAN_B.3") again"
fi

# ---------------------------------------------------------------------------
say "3. the trunk that was configured as an access port"

note "Make the trunk untagged and the tags are stripped on the way out. The"
note "host's subinterfaces are then listening for frames that no longer"
note "carry a tag, and hear nothing."
echo
bridge -n "$SW" vlan add dev sw-t vid "$VLAN_B" untagged
run "bridge -n $SW vlan show dev sw-t"
printf '  h18c -> trunk host on VLAN %s: %s\n' "$VLAN_B" "$(reach h18c "10.30.$VLAN_B.4")"
note "This is the classic 'works for one VLAN, not the other' report: the"
note "native/untagged VLAN keeps working while the tagged ones go dark."

if [[ "$HARD" == "no" ]]; then
	bridge -n "$SW" vlan add dev sw-t vid "$VLAN_B"
	ok "sw-t is tagged for VLAN $VLAN_B again: $(reach h18c "10.30.$VLAN_B.4")"
fi

# ---------------------------------------------------------------------------
say "4. pulling a cable out of the bond"

if ip -n h18d link show bond0 >/dev/null 2>&1; then
	ACTIVE="$(ip netns exec h18d sed -n 's/^Currently Active Slave: //p' /proc/net/bonding/bond0)"
	note "Active leg right now: ${ACTIVE:-unknown}"
	echo
	if [[ -n "$ACTIVE" ]]; then
		ip -n h18d link set "$ACTIVE" down
		sleep 1
		run "ip netns exec h18d grep -E 'Currently Active|MII Status' /proc/net/bonding/bond0"
		printf '  h18a -> bonded host: %s\n' "$(reach h18a "10.30.$VLAN_A.5")"
		note "This is the one failure today that is SUPPOSED to keep working."
		note "The address never moved: it is on bond0, not on a leg, so the"
		note "failover is invisible to everything above it."
		if [[ "$HARD" == "no" ]]; then
			ip -n h18d link set "$ACTIVE" up
			sleep 1
			ok "$ACTIVE is back up - and it did not become active again"
			note "active-backup does not fail back. A quiet spare is the point"
		fi
	fi
else
	note "no bond0 on this kernel - skipping"
fi

# ---------------------------------------------------------------------------
if [[ "$HARD" == "yes" ]]; then
	# The one that is genuinely hard: the tables stay perfect and stop
	# meaning anything. This is why verify.sh checks the flag and not just
	# the membership.
	say "5. --hard: filtering off, tables intact"
	ip -n "$SW" link set "$BR" type bridge vlan_filtering 0
	run "bridge -n $SW vlan show dev sw-a"
	printf '  h18a -> h18c (must not work): %s\n' "$(reach h18a "10.30.$VLAN_B.3")"
	note "Every VLAN table is still exactly right. The switch is ignoring all"
	note "of them. If you only ever read 'bridge vlan show', this host looks"
	note "correctly segmented while being one flat network."
	echo
	say "left broken on purpose"
	note "Four faults are live: sw-b has no VLAN, sw-a has the wrong PVID,"
	note "sw-t is untagged for VLAN $VLAN_B, and filtering is off."
	note "Find them with: sudo lab-vlan vlans  and  sudo ./verify.sh"
	note "Fix them all with: sudo ./scripts/setup.sh"
	exit 0
fi

say "everything is back"
run "lab-vlan test 2>/dev/null || echo 'run: sudo lab-vlan test'"
note "Nothing above needed a firewall, a route or a reboot. VLAN membership"
note "is the whole mechanism, and 'ip link' cannot show you any of it."
