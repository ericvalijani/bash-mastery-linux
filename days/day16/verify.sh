#!/usr/bin/env bash
#
# Day 16 — WireGuard: a private network between hosts
# Run this on: control (or node1), WITH sudo
#
# Exits 0 only when every automatic check passes. Items printed as
# YOU are judgement calls and never affect the exit status.

set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=../../lab/verify-lib.sh
source "../../lab/verify-lib.sh"

IFACE="${WG_IFACE:-wg0}"
CONF="/etc/wireguard/$IFACE.conf"
PORT="${WG_PORT:-51820}"

vl_init "Day 16 — WireGuard: a private network between hosts"
vl_need wg wg-quick ip
vl_need_root

# The peer's tunnel address is whichever of the two this host is not.
PEER_TUN=10.20.0.2
ip -4 -brief addr show "$IFACE" 2>/dev/null | grep -q '10\.20\.0\.2/' && PEER_TUN=10.20.0.1

vl_check "the kernel half of WireGuard is loaded" '[ -d /sys/module/wireguard ]'
vl_check "$IFACE exists with a 10.20.0.x address" "ip -4 -brief addr show $IFACE | grep -q '10\\.20\\.0\\.'"
vl_check "$CONF is 0600 - it holds a private key" "[ \"\$(stat -c %a $CONF)\" = 600 ]"
vl_check "the private key file is 0600 too" "[ \"\$(stat -c %a /etc/wireguard/$IFACE.key)\" = 600 ]"
vl_check "a peer is configured, and it is not this host itself" "[ -n \"\$(wg show $IFACE peers)\" ] && [ \"\$(wg show $IFACE peers | head -1)\" != \"\$(wg show $IFACE public-key)\" ]"
vl_check "a handshake has actually completed" "ping -c1 -W2 $PEER_TUN >/dev/null 2>&1; [ \"\$(wg show $IFACE latest-handshakes | awk '{print \$2}' | head -1)\" != 0 ]"
vl_check "$PEER_TUN answers inside the tunnel" "ping -c2 -W3 $PEER_TUN"
vl_check "AllowedIPs covers the peer, and became a route" "ip route get $PEER_TUN | grep -q \"dev $IFACE\""
vl_check "a full-size packet gets through, so the MTU is right" "ping -c2 -W3 -M do -s 1300 $PEER_TUN"
# Compare the settings, not the formatting. 'wg-quick strip' echoes the file
# with its own order, spacing and comments; 'wg showconf' prints normalized,
# reordered output from the kernel. A raw diff of the two never matches, so
# collapse whitespace, keep only the peer settings, and sort.
WG_NORM="sed -E 's/[[:space:]]+/ /g' | grep -E '^(PublicKey|PresharedKey|AllowedIPs|Endpoint|PersistentKeepalive) = ' | sort"
vl_check "the file and the kernel agree - no unapplied edits" "diff <(wg-quick strip $IFACE | $WG_NORM) <(wg showconf $IFACE | $WG_NORM)"
# firewall-cmd --permanent needs the daemon; firewall-offline-cmd reads the
# same XML without it. Accept either, because a stopped firewalld is a normal
# state on a freshly built VM.
vl_check "$PORT/udp is open permanently, not just until reload" "firewall-cmd --permanent --query-port=$PORT/udp || firewall-offline-cmd --query-port=$PORT/udp"
vl_check "wg-quick@$IFACE is enabled, so the tunnel survives a reboot" "systemctl is-enabled --quiet wg-quick@$IFACE"
vl_manual "you can explain what AllowedIPs does in each direction"
vl_manual "you rebooted this VM and the tunnel came back on its own"

if [[ ${#VL_MISSING[@]} -gt 0 ]]; then
	printf '\n  missing: %s\n' "${VL_MISSING[*]}"
	printf '  run this on a lab VM, with sudo, after:\n'
	printf '    sudo dnf install -y wireguard-tools\n'
	printf '    sudo ./days/day16/scripts/setup.sh\n'
fi

vl_summary
