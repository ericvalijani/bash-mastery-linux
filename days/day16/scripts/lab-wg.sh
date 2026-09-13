#!/usr/bin/env bash
#
# lab-wg - the tunnel, end to end.
#
#   lab-wg           interface, peer, handshake, traffic
#   lab-wg keys      what is public, what is not, and who can read it
#   lab-wg routes    AllowedIPs as the routing table it becomes
#   lab-wg watch     handshakes and byte counters, refreshed
#
# Read-only. Needs root, because wg(8) will not show a private key or a peer
# list to an unprivileged user - and that is the only reason.

set -uo pipefail

IFACE="${WG_IFACE:-wg0}"
WG_DIR="/etc/wireguard"
CONF="$WG_DIR/$IFACE.conf"

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
	printf 'needs root:  sudo %s %s\n' "$0" "${1:-}" >&2
	exit 1
}
command -v wg >/dev/null 2>&1 || {
	printf 'wg is missing:  sudo dnf install -y wireguard-tools\n' >&2
	exit 1
}

head2() { printf '\n\033[1m%s\033[0m\n%s\n' "$1" "$(printf '%*s' "${#1}" '' | tr ' ' '-')"; }
run()   { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/  /'; printf '\n'; }
note()  { printf '  %s\n' "$*"; }

handshake_age() {
	local hs
	hs="$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)"
	[[ -n "$hs" && "$hs" != "0" ]] || { printf 'never\n'; return; }
	printf '%ss ago\n' "$(( $(date +%s) - hs ))"
}

case "${1:-status}" in
status)
	head2 "the interface"
	if ! ip link show "$IFACE" >/dev/null 2>&1; then
		note "$IFACE does not exist. sudo wg-quick up $IFACE"
		exit 0
	fi
	run "ip -brief addr show $IFACE"
	run "ip -details link show $IFACE | head -4"
	note "link/none, no MAC, no ARP. It is a layer-3 interface - there is no"
	note "ethernet frame here to put an address on"

	head2 "the tunnel"
	run "wg show $IFACE"
	note "handshake: $(handshake_age)"
	note "a peer with no handshake looks exactly like a working one in ip addr."
	note "This is the only place the difference shows"

	head2 "is anything moving"
	run "wg show $IFACE transfer"
	note "received 0 with sent climbing means your packets leave and nothing"
	note "comes back: AllowedIPs too narrow on the far end, or its firewall"

	head2 "the unit"
	run "systemctl is-enabled wg-quick@$IFACE; systemctl is-active wg-quick@$IFACE"
	note "enabled = comes back after a reboot. active = up right now."
	note "An interface brought up by hand is active and not enabled, and it"
	note "disappears at the next boot with nothing in the logs to explain it"

	head2 "the port"
	run "ss -lunp | grep -E ':$(wg show "$IFACE" listen-port 2>/dev/null || echo 51820)' || echo '(no socket listed - wireguard sockets are kernel-owned and ss may not name them)'"
	run "firewall-cmd --permanent --list-ports"
	;;

keys)
	head2 "what is secret and what is not"
	run "ls -l $WG_DIR"
	note "wg0.key and wg0.conf are 0600 - the conf contains the private key"
	note "wg0.pub is 0644 and it does not matter who reads it"

	head2 "this host's public key"
	run "wg show $IFACE public-key"
	note "compare it with what the OTHER host has under [Peer]. They must match."
	note "Crossed keys are the most common reason a handshake never completes,"
	note "and nothing anywhere logs a word about it"

	head2 "the peer's key, as this host has it"
	run "wg show $IFACE peers"

	head2 "the private key never appears in wg show"
	run "wg show $IFACE private-key | cut -c1-8 | sed 's/$/... (asked for explicitly)/'"
	note "wg show alone omits it. You have to ask, which is a small mercy for"
	note "anyone who pastes terminal output into a ticket"

	head2 "and the preshared key, which is not set here"
	run "wg show $IFACE preshared-keys"
	note "(none) is fine. A PSK adds a post-quantum hedge on top of the"
	note "existing crypto; it is not a password and it is not required"
	;;

routes)
	head2 "AllowedIPs, as configured"
	run "wg show $IFACE allowed-ips"

	head2 "AllowedIPs, as it became a routing table"
	run "ip route show table all dev $IFACE"
	note "wg-quick turned each AllowedIPs entry into a route. That is all the"
	note "'VPN routing' there is - no daemon, no protocol, just ip route"

	head2 "which way a packet would actually go"
	for dst in 10.20.0.1 10.20.0.2 8.8.8.8; do
		run "ip route get $dst"
	done
	note "ip route get is the honest answer. Read it before you believe a"
	note "diagram, and especially before you believe yourself"

	head2 "the second job of the same line"
	cat <<'TXT'
  AllowedIPs does two things, and only one of them is routing:

    outbound   a route. Traffic for these addresses is sent to this peer.
    inbound    an ACL. A packet arriving from this peer whose SOURCE is
               not in this list is dropped. Silently. No counter you are
               likely to be looking at, no log line.

  So the two ends are not independent. Narrow AllowedIPs on one side only
  and traffic leaves fine and never comes back - and the end you would
  naturally debug is the one that is configured correctly.

  The rule: whatever addresses you want to reach through a peer must be
  listed on YOUR side, and your own addresses must be listed on THEIRS.
TXT
	;;

watch)
	head2 "handshakes and counters (5 samples, 2s apart)"
	for _ in 1 2 3 4 5; do
		printf '  %s  ' "$(date +%T)"
		wg show "$IFACE" transfer | awk '{printf "rx=%s tx=%s  ", $2, $3}'
		printf 'handshake %s\n' "$(handshake_age)"
		sleep 2
	done
	note "a handshake older than ~180s with traffic flowing means rekeying is"
	note "failing; with no traffic it just means nobody has sent anything"
	;;

*)
	printf 'usage: lab-wg [status|keys|routes|watch]\n' >&2
	exit 2
	;;
esac

printf '\n  config: %s   (mode %s)\n' "$CONF" "$(stat -c %a "$CONF" 2>/dev/null || echo 'missing')"
