#!/usr/bin/env bash
#
# explore-wg.sh - twelve read-only stops through the tunnel you just built.
#
# Nothing here changes anything. Run it with sudo, because wg(8) will not
# show a peer list to an unprivileged user.

set -uo pipefail

IFACE="${WG_IFACE:-wg0}"
CONF="/etc/wireguard/$IFACE.conf"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { printf 'needs root:  sudo %s\n' "$0" >&2; exit 1; }
command -v wg >/dev/null 2>&1 || { printf 'wg is missing\n' >&2; exit 1; }
ip link show "$IFACE" >/dev/null 2>&1 || {
	printf '%s does not exist - run scripts/setup.sh first\n' "$IFACE" >&2
	exit 1
}

stop() { printf '\n\033[1m%s\033[0m\n%s\n' "$1" "$(printf '%*s' "${#1}" '' | tr ' ' '-')"; }
run()  { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/  /'; printf '\n'; }
note() { printf '  %s\n' "$*"; }

PEER_TUN="$(ip -4 -brief addr show "$IFACE" | grep -q '10.20.0.1/' && echo 10.20.0.2 || echo 10.20.0.1)"

stop "1. the whole configuration fits on a screen"
run "grep -vE '^\\s*#|^\\s*$' $CONF | sed 's/^PrivateKey.*/PrivateKey = <redacted>/'"
note "no certificate authority, no cipher suite negotiation, no daemon."
note "Compare this with an OpenVPN config you have met"

stop "2. what the kernel is holding, which is not the file"
run "wg showconf $IFACE | sed 's/^PrivateKey.*/PrivateKey = <redacted>/'"
note "wg showconf prints live state. Diff it against the file and you find"
note "every hand-edit somebody forgot to apply - or forgot to save"

stop "3. the interface is layer 3 and has no MAC"
run "ip -details link show $IFACE"
note "link/none, NOARP. There is no ethernet here, so there is nothing to"
note "ARP for and no broadcast domain. DHCP would have nothing to talk to"

stop "4. the handshake is the only proof"
run "wg show $IFACE latest-handshakes"
run "wg show $IFACE transfer"
note "0 means never. An interface with an address, a peer and no handshake"
note "is indistinguishable from a working tunnel in ip addr"

stop "5. AllowedIPs became routes"
run "wg show $IFACE allowed-ips"
run "ip route show dev $IFACE"
run "ip route get $PEER_TUN"
note "that is the entire routing mechanism: wg-quick read AllowedIPs and ran"
note "ip route add. Nothing is dynamic, nothing is negotiated"

stop "6. and AllowedIPs is also an inbound filter"
note "outbound: a route. inbound: a source-address ACL - a packet from this"
note "peer whose source is not listed is dropped silently."
note "So the two ends are coupled. Narrow one side only and traffic leaves"
note "and never returns, while the end you would debug is the correct one"

stop "7. the crypto is not configurable"
run "wg show $IFACE preshared-keys"
note "no cipher list, no TLS version, no downgrade to negotiate. Curve25519,"
note "ChaCha20-Poly1305, BLAKE2s, fixed. You cannot misconfigure them, which"
note "removes an entire category of VPN bug"
note "the cost: a break in any of them means a new protocol version, not a"
note "config change"

stop "8. it is silent to anything that cannot authenticate"
run "ss -lun | head -5"
note "an unauthenticated packet gets no reply at all - no reset, no error."
note "Good against scanning; unhelpful when you are the one debugging, which"
note "is why the only diagnostic that means anything is the handshake time"

stop "9. roaming: the endpoint is not fixed"
run "wg show $IFACE endpoints"
note "whichever side speaks first pins the other's address, and it updates"
note "when a peer moves. Only one end needs a configured Endpoint"
note "this is why WireGuard survives a laptop changing networks mid-session"
note "and a DHCP lease change on the far end"

stop "10. MTU, and the silence it causes"
run "ip -brief link show $IFACE | awk '{print \$0}' ; ip link show $IFACE | grep -o 'mtu [0-9]*'"
run "ip link show | grep -o 'mtu [0-9]*' | sort | uniq -c"
note "1420 is 1500 minus WireGuard's 80 bytes of overhead. Set it too high"
note "and small packets work perfectly while anything large hangs - ping is"
note "fine, ssh logs in, scp stalls at 0%. The classic mid-size failure"

stop "11. the unit, and what wg-quick actually is"
run "systemctl cat wg-quick@$IFACE | grep -E '^(ExecStart|ExecStop|Description|WantedBy)'"
run "wg-quick strip $IFACE | sed 's/^PrivateKey.*/PrivateKey = <redacted>/'"
note "wg-quick is a shell script. 'strip' shows you the part wg(8) accepts -"
note "Address, MTU and PostUp are wg-quick's own, not WireGuard's"

stop "12. reload without dropping the tunnel"
note "wg syncconf $IFACE <(wg-quick strip $IFACE)"
note "applies the file to a running interface. wg-quick down && up also works"
note "and takes the tunnel with it - on a management VPN, that is your"
note "session. setup.sh uses syncconf for exactly this reason"

cat <<'TXT'

The four questions, in the order they answer a broken tunnel:

  1. wg show wg0             is there a handshake? If never, nothing else
                             you check matters.
  2. wg show wg0 transfer    sent climbing, received zero = the far end's
                             AllowedIPs or its firewall.
  3. ip route get <addr>     is the packet even going into the tunnel?
  4. systemctl is-enabled    will this still be true after a reboot?

TXT
