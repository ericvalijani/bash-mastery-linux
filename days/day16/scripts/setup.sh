#!/usr/bin/env bash
#
# Day 16 setup - one end of a WireGuard tunnel.
#
# Run this on BOTH VMs, with sudo. Twice on each, because keys are exchanged
# out of band and that is the point:
#
#   pass 1:  sudo ./scripts/setup.sh
#              generates this host's keys, writes wg0.conf with no peer,
#              and prints the exact command to run on the other host
#
#   pass 2:  sudo ./scripts/setup.sh <peer-public-key> <peer-endpoint-ip>
#              adds the peer, opens the port, enables the unit, brings it up
#
# Nobody hands you a VPN where both ends were configured by one command. A
# private key that travelled to the other host is not a private key.
#
# Leaves behind:
#   /etc/wireguard/wg0.conf       the whole configuration, 0600
#   /etc/wireguard/wg0.key/.pub   this host's keypair, 0600 / 0644
#   wg-quick@wg0 enabled          so the tunnel survives a reboot
#   51820/udp open in firewalld   permanently
#   /usr/local/bin/lab-wg         the payload
#
# Addresses, fixed so both hosts agree without being told:
#   control  10.20.0.1/24
#   node1    10.20.0.2/24
#
# Idempotent. Run it as often as you like.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

say()  { printf '\n==> %s\n\n' "$*"; }
die()  { printf '\nfailed: %s\n' "$*" >&2; exit 1; }
ok()   { printf '  ok    %s\n' "$*"; }
note() { printf '        %s\n' "$*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "needs root:  sudo $0 $*"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_SRC="$HERE/lab-wg.sh"
PAYLOAD="/usr/local/bin/lab-wg"

WG_DIR="/etc/wireguard"
IFACE="wg0"
CONF="$WG_DIR/$IFACE.conf"
PRIV="$WG_DIR/$IFACE.key"
PUB="$WG_DIR/$IFACE.pub"
PORT="${WG_PORT:-51820}"

PEER_KEY="${1:-}"
PEER_ENDPOINT="${2:-}"

# ---------------------------------------------------------------------------
# 0. which end am I?
# ---------------------------------------------------------------------------
# The lab names its VMs, so the host can work this out for itself. Override
# with ROLE=control or ROLE=node1 if you renamed something.
say "0. which end of the tunnel is this"

ROLE="${ROLE:-$(hostname -s)}"
case "$ROLE" in
control) MY_TUN="10.20.0.1"; PEER_TUN="10.20.0.2"; PEER_NAME="node1" ;;
node1)   MY_TUN="10.20.0.2"; PEER_TUN="10.20.0.1"; PEER_NAME="control" ;;
*)
	die "cannot tell which host this is (hostname -s said '$ROLE').
  Run it as:  sudo ROLE=control $0 $*
         or:  sudo ROLE=node1   $0 $*"
	;;
esac
ok "this host is $ROLE, tunnel address $MY_TUN"
note "the other end is $PEER_NAME at $PEER_TUN inside the tunnel"

# ---------------------------------------------------------------------------
# 1. the tools, and the module
# ---------------------------------------------------------------------------
say "1. wireguard-tools, and the kernel half"

if ! command -v wg >/dev/null 2>&1; then
	die "wg is missing:  sudo dnf install -y wireguard-tools"
fi
ok "wg present: $(wg --version)"

# Two halves, and people conflate them. wireguard-tools is userspace: wg and
# wg-quick, a config parser and a wrapper around ip(8). The data path is in
# the kernel, and since 5.6 it is built in - no DKMS, no elrepo, nothing to
# compile. This is most of why WireGuard is small enough to read.
if [[ -d /sys/module/wireguard ]]; then
	ok "the wireguard module is loaded"
elif modprobe wireguard 2>/dev/null; then
	ok "loaded the wireguard module"
else
	die "no wireguard module. This kernel is older than 5.6, or it was
  stripped. Check: modprobe wireguard ; dmesg | tail"
fi
note "kernel $(uname -r) - the data path is in there, not in wg(8)"

command -v firewall-cmd >/dev/null 2>&1 ||
	die "firewall-cmd is missing:  sudo dnf install -y firewalld"

# ---------------------------------------------------------------------------
# 2. keys, generated here and never moved
# ---------------------------------------------------------------------------
say "2. this host's keypair"

install -d -m 0700 "$WG_DIR"

if [[ -s "$PRIV" ]]; then
	ok "keypair already exists - keeping it"
	note "regenerating would invalidate the key the other host already trusts"
else
	# umask before generation, not chmod after. Between creating a file 0644
	# and chmod 0600 there is a window where any local user can read it, and
	# a private key read once is compromised forever.
	( umask 077; wg genkey > "$PRIV" )
	wg pubkey < "$PRIV" > "$PUB"
	chmod 0600 "$PRIV"
	chmod 0644 "$PUB"
	ok "generated $PRIV (0600) and $PUB (0644)"
	note "umask 077 before genkey, not chmod afterwards - the gap between the"
	note "two is small, and a private key only has to leak once"
fi

MY_PUB="$(cat "$PUB")"
ok "public key: $MY_PUB"

# ---------------------------------------------------------------------------
# 3. wg0.conf
# ---------------------------------------------------------------------------
say "3. $CONF"

# PrivateKey goes in the file rather than PostUp-ing it in from elsewhere,
# because that is what wg-quick expects and hiding it does not make it safer.
# What makes it safer is 0600 and a directory nobody else can traverse.
{
	printf '# Day 16 - written by setup.sh. Mode 0600: it holds a private key.\n'
	printf '#\n'
	printf '# [Interface] is this host. [Peer] is the other one. There is no\n'
	printf '# server and no client in WireGuard - only peers, one of which\n'
	printf '# happens to know the other one'\''s address.\n'
	printf '\n[Interface]\n'
	printf '# The tunnel address. wg-quick assigns this; wg(8) never sees it.\n'
	printf 'Address    = %s/24\n' "$MY_TUN"
	printf 'PrivateKey = %s\n' "$(cat "$PRIV")"
	printf '# Both ends listen. Both ends can initiate. Symmetry is the design.\n'
	printf 'ListenPort = %s\n' "$PORT"
} > "$CONF.new"

if [[ -n "$PEER_KEY" ]]; then
	[[ "$PEER_KEY" =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]] ||
		die "that does not look like a WireGuard public key:
  $PEER_KEY
  It is 44 characters of base64 ending in '='. Get it from the other host:
  sudo cat /etc/wireguard/wg0.pub"
	[[ "$PEER_KEY" != "$MY_PUB" ]] ||
		die "that is THIS host's public key. You have copied the wrong one -
  run 'sudo cat /etc/wireguard/wg0.pub' on $PEER_NAME, not here.
  A tunnel to your own key never completes a handshake and never says why."

	[[ -n "$PEER_ENDPOINT" ]] || die "give the peer's real address too:
  sudo $0 $PEER_KEY <$PEER_NAME-address>
  Find it on the laptop with:  ./lab/lab.sh status"

	{
		printf '\n[Peer]\n'
		printf '# %s. This key is public - it is in git-safe territory.\n' "$PEER_NAME"
		printf 'PublicKey  = %s\n' "$PEER_KEY"
		printf '# Where to send the first packet. Only one end needs an Endpoint;\n'
		printf '# after a handshake each end remembers where the other one was.\n'
		printf 'Endpoint   = %s:%s\n' "$PEER_ENDPOINT" "$PORT"
		printf '# Two jobs in one line, and this is the day'\''s lesson:\n'
		printf '#   outbound - a route. Traffic for these addresses goes in here.\n'
		printf '#   inbound  - an ACL. A packet arriving from this peer with a\n'
		printf '#              source outside this list is dropped, silently.\n'
		printf '# Narrow it on one side only and traffic leaves but never returns.\n'
		printf 'AllowedIPs = %s/32\n' "$PEER_TUN"
		printf '# Send something every 25s so NAT and stateful firewalls keep the\n'
		printf '# mapping. Harmless here; essential behind NAT.\n'
		printf 'PersistentKeepalive = 25\n'
	} >> "$CONF.new"
	ok "peer $PEER_NAME configured, endpoint $PEER_ENDPOINT:$PORT"
else
	ok "no peer yet - this is pass 1"
fi

if [[ -f "$CONF" ]] && cmp -s "$CONF" "$CONF.new"; then
	rm -f "$CONF.new"
	ok "$CONF already correct - unchanged"
else
	mv "$CONF.new" "$CONF"
	chmod 0600 "$CONF"
	ok "wrote $CONF (0600)"
fi

# ---------------------------------------------------------------------------
# 4. the port
# ---------------------------------------------------------------------------
say "4. firewalld"

# firewalld has two interfaces and people meet the wrong one first.
# 'firewall-cmd --permanent' talks to the running daemon, which then writes
# the XML. With the daemon stopped it does not fall back to editing files -
# it prints 'FirewallD is not running' and fails. The offline tool,
# firewall-offline-cmd, edits the same XML directly and is the only thing
# that works before the daemon is up.
#
# A freshly built VM here has firewalld installed and stopped, so both cases
# are real.
if systemctl is-active --quiet firewalld; then
	if firewall-cmd --permanent --query-port="$PORT/udp" >/dev/null 2>&1; then
		ok "$PORT/udp already in the permanent policy"
	else
		firewall-cmd --permanent --add-port="$PORT/udp" >/dev/null
		firewall-cmd --reload >/dev/null
		ok "opened $PORT/udp permanently and reloaded"
	fi
else
	note "firewalld is installed but not running - using firewall-offline-cmd,"
	note "which writes the same XML without a daemon to ask"
	if firewall-offline-cmd --query-port="$PORT/udp" >/dev/null 2>&1; then
		ok "$PORT/udp already in the permanent policy"
	else
		firewall-offline-cmd --add-port="$PORT/udp" >/dev/null ||
			die "could not add $PORT/udp offline. Is firewalld installed?
  sudo dnf install -y firewalld"
		ok "opened $PORT/udp in the permanent policy (offline)"
	fi
	# Starting it is the honest end of this step: a port "open" in a policy
	# no daemon has loaded is a comment, and the day's claim is that the
	# tunnel port is reachable while everything else is not.
	if systemctl enable --now firewalld >/dev/null 2>&1; then
		ok "started and enabled firewalld - the policy is now loaded"
	else
		note "could not start firewalld. The tunnel still works: nothing here"
		note "is blocking it. Come back to this if 'systemctl status firewalld'"
		note "says masked"
	fi
fi
note "UDP, and there is no TCP fallback. A firewall that allows 'VPN' by"
note "allowing 443/tcp does not allow this"
note "WireGuard answers nothing unless the packet authenticates - port scans"
note "see a closed port, which is a real property and not security theatre"

# ---------------------------------------------------------------------------
# 5. up, and enabled
# ---------------------------------------------------------------------------
say "5. bringing $IFACE up"

# wg-quick up reads the file. It does not watch it. Every "I changed the
# config and nothing happened" is this: the kernel holds what was loaded, the
# file holds what you typed, and only a reload reconciles them.
if ip link show "$IFACE" >/dev/null 2>&1; then
	note "$IFACE exists already - re-reading the file with wg syncconf"
	# syncconf keeps the interface and its handshakes; 'wg-quick down/up'
	# would drop them, which on a real management tunnel drops your session.
	wg syncconf "$IFACE" <(wg-quick strip "$IFACE") ||
		die "wg syncconf failed - check the file with: wg-quick strip $IFACE"
	ok "configuration re-read without dropping the interface"
else
	wg-quick up "$IFACE" || die "wg-quick up failed. Read the error above; it
  usually names the line it could not parse."
	ok "$IFACE is up"
fi

ip -brief addr show "$IFACE" | sed 's/^/        /'

if systemctl is-enabled --quiet "wg-quick@$IFACE"; then
	ok "wg-quick@$IFACE already enabled"
else
	systemctl enable "wg-quick@$IFACE" >/dev/null 2>&1 ||
		die "could not enable wg-quick@$IFACE"
	ok "enabled wg-quick@$IFACE - the tunnel returns after a reboot"
fi
note "up and enabled are different states. A tunnel that works until the next"
note "reboot is the most common WireGuard bug there is"

# ---------------------------------------------------------------------------
# 6. the payload
# ---------------------------------------------------------------------------
say "6. installing $PAYLOAD"
[[ -f "$PAYLOAD_SRC" ]] || die "missing $PAYLOAD_SRC"
install -m 0755 "$PAYLOAD_SRC" "$PAYLOAD"
ok "$PAYLOAD installed"

# ---------------------------------------------------------------------------
# 7. did it actually work
# ---------------------------------------------------------------------------
if [[ -z "$PEER_KEY" ]]; then
	cat <<EOF

=== pass 1 done on $ROLE ===

This host has keys, an interface and an address, and no peer. That is a
complete and useless WireGuard configuration.

This host's public key:

  $MY_PUB

Now do the same on $PEER_NAME:

  sudo ./days/day16/scripts/setup.sh

Then give each host the other one's key and address. On $PEER_NAME:

  sudo ./days/day16/scripts/setup.sh $MY_PUB <this-host's-address>

and back here, with what $PEER_NAME printed:

  sudo $0 <${PEER_NAME}-public-key> <${PEER_NAME}-address>

The addresses are the ordinary lab ones from ./lab/lab.sh status on your
laptop - not the 10.20.0.x tunnel addresses. The tunnel cannot carry the
packets that build the tunnel.
EOF
	exit 0
fi

say "7. proving it"

# A handshake is the only evidence that matters. An interface with a peer and
# no handshake looks identical to a working one in 'ip addr'.
note "sending a packet to $PEER_TUN to trigger a handshake"
ping -c 2 -W 3 "$PEER_TUN" >/dev/null 2>&1 || true
sleep 1

HS="$(wg show "$IFACE" latest-handshakes | awk '{print $2}' | head -1)"
if [[ -n "$HS" && "$HS" != "0" ]]; then
	ok "handshake completed $(( $(date +%s) - HS ))s ago"
else
	printf '\n'
	note "no handshake yet. In order of likelihood:"
	note "  1. the other host has not had its pass 2 run yet - do that, then"
	note "     re-run this. A tunnel needs both ends to know both keys."
	note "  2. the keys are crossed: each end must hold the OTHER's public key."
	note "     Compare 'sudo wg show $IFACE' here with 'sudo cat $PUB' there."
	note "  3. $PORT/udp is not open on the far end, or the endpoint address is"
	note "     a stale DHCP lease."
	note "WireGuard will not tell you which. It is silent by design: an"
	note "unauthenticated packet gets no reply, including no error."
	note "Watch the attempt with:  sudo wg show $IFACE ; sudo lab-wg"
	exit 0
fi

if ping -c 2 -W 3 "$PEER_TUN" >/dev/null 2>&1; then
	ok "$PEER_TUN answers inside the tunnel"
else
	note "handshake but no ping - that is AllowedIPs on one side, or a"
	note "firewall rule on the far end. Check both with: sudo lab-wg"
fi

cat <<EOF

=== Day 16 is set up on $ROLE ===

  $IFACE      $MY_TUN/24, peer $PEER_NAME at $PEER_TUN
  port      $PORT/udp, open permanently
  unit      wg-quick@$IFACE enabled - survives a reboot

Look at it:

  sudo lab-wg                 the tunnel, end to end
  sudo lab-wg keys            what is public and what is not
  sudo lab-wg routes          AllowedIPs as the routing table it becomes

Then the tour:  sudo ./days/day16/scripts/explore-wg.sh
And break it:   sudo ./days/day16/scripts/break-and-fix.sh
                sudo ./days/day16/scripts/break-and-fix.sh --hard

Check yourself: sudo ./days/day16/verify.sh

One thing worth doing before verify: reboot this VM and watch the tunnel come
back by itself. Enabled and working are not the same claim.
EOF
