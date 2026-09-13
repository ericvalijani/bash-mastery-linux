#!/usr/bin/env bash
#
# teardown.sh - remove Day 16's tunnel from THIS host.
#
#   sudo ./teardown.sh          interface down, unit disabled, port closed
#   sudo ./teardown.sh --all    also delete the keys and the payload
#
# Run it on both hosts if you want the pair clean. Deleting the keys means
# the far end's [Peer] block is now pointing at a key that no longer exists,
# so if you rebuild, rebuild both ends.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

IFACE="${WG_IFACE:-wg0}"
WG_DIR="/etc/wireguard"
CONF="$WG_DIR/$IFACE.conf"
PORT="${WG_PORT:-51820}"
PAYLOAD="/usr/local/bin/lab-wg"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { printf 'needs root:  sudo %s %s\n' "$0" "${1:-}" >&2; exit 1; }

say()  { printf '\n==> %s\n' "$*"; }
ok()   { printf '  ok    %s\n' "$*"; }
skip() { printf '  --    %s\n' "$*"; }
note() { printf '        %s\n' "$*"; }

ALL=no
[[ "${1:-}" == "--all" ]] && ALL=yes

say "the interface"
if ip link show "$IFACE" >/dev/null 2>&1; then
	wg-quick down "$IFACE" >/dev/null 2>&1 && ok "$IFACE down" || {
		ip link delete "$IFACE" 2>/dev/null && ok "$IFACE deleted by hand"
	}
else
	skip "$IFACE was not up"
fi

say "the unit"
if systemctl is-enabled --quiet "wg-quick@$IFACE" 2>/dev/null; then
	systemctl disable "wg-quick@$IFACE" >/dev/null 2>&1
	ok "wg-quick@$IFACE disabled - it will not return after a reboot"
else
	skip "wg-quick@$IFACE was not enabled"
fi

say "the port"
# Same daemon/offline split as setup.sh: --permanent needs firewalld running,
# firewall-offline-cmd does not.
if systemctl is-active --quiet firewalld &&
   firewall-cmd --permanent --query-port="$PORT/udp" >/dev/null 2>&1; then
	firewall-cmd --permanent --remove-port="$PORT/udp" >/dev/null
	firewall-cmd --reload >/dev/null
	ok "closed $PORT/udp"
elif command -v firewall-offline-cmd >/dev/null 2>&1 &&
     firewall-offline-cmd --query-port="$PORT/udp" >/dev/null 2>&1; then
	firewall-offline-cmd --remove-port="$PORT/udp" >/dev/null
	ok "closed $PORT/udp (offline - firewalld is not running)"
else
	skip "$PORT/udp was not open"
fi

say "the scratch files"
rm -rf /tmp/day16-broken
ok "removed /tmp/day16-broken"

if [[ "$ALL" == yes ]]; then
	say "keys, config and payload"
	rm -f "$CONF" "$WG_DIR/$IFACE.key" "$WG_DIR/$IFACE.pub" "$CONF.new"
	ok "removed the config and this host's keypair"
	note "the far end still lists the key you just deleted. Re-run setup.sh on"
	note "BOTH hosts if you rebuild - a new keypair means a new public key"
	rm -f "$PAYLOAD"
	ok "removed $PAYLOAD"
else
	say "kept"
	note "$CONF and the keypair in $WG_DIR"
	note "$PAYLOAD"
	note "so 'sudo wg-quick up $IFACE' puts the tunnel straight back."
	note "Use --all to remove them too"
fi

say "what is left"
ip link show "$IFACE" >/dev/null 2>&1 && printf '  %s still exists\n' "$IFACE" || printf '  no %s\n' "$IFACE"
ls -l "$WG_DIR" 2>/dev/null | sed 's/^/  /' || printf '  %s is gone\n' "$WG_DIR"

printf '\nwireguard-tools is left installed. dnf remove it if you want the\nhost back to where Day 14 left it.\n'
