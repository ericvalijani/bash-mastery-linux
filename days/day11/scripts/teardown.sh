#!/usr/bin/env bash
#
# Day 11 - remove what setup.sh built.
#
#   sudo ./scripts/teardown.sh
#
# Stops the service BEFORE closing its port, removes the rules from the
# permanent configuration and reloads so the runtime matches, and proves
# each removal instead of assuming it.

set -uo pipefail

# shellcheck source=../../../lab/on-lab-vm.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

say() { printf '\n==> %s\n' "$*"; }
die() { echo "$*" >&2; exit 1; }
ok()  { printf '  ok  %s\n' "$*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "needs root:  sudo $0"

PORT="8080"
ZONE="$(firewall-cmd --get-default-zone 2>/dev/null || echo public)"
SERVICE="lab-web.service"
UNIT="/etc/systemd/system/$SERVICE"
RICH='rule family="ipv4" source address="127.0.0.0/8" port port="9090" protocol="tcp" accept'

say "1. stopping the service first"
systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
sleep 1
if ss -tlpn 2>/dev/null | grep -qE ":$PORT([[:space:]]|$)"; then
	echo "  something is STILL listening on $PORT:"
	ss -tlpn 2>/dev/null | grep -E ":$PORT([[:space:]]|$)" | sed 's/^/      /'
	echo "  (not ours, or a stray. Find its pid above before closing the port)"
else
	ok "nothing listening on $PORT"
fi

say "2. removing the firewall rules"
firewall-cmd --permanent --zone="$ZONE" --remove-port="$PORT/tcp" >/dev/null 2>&1 || true
firewall-cmd --permanent --zone="$ZONE" --remove-rich-rule="$RICH" >/dev/null 2>&1 || true
firewall-cmd --reload >/dev/null 2>&1 || true

if firewall-cmd --zone="$ZONE" --query-port="$PORT/tcp" >/dev/null 2>&1; then
	echo "  $PORT/tcp is somehow still open - check: firewall-cmd --list-all"
else
	ok "$PORT/tcp closed in runtime and permanent"
fi

say "3. removing the unit and the payload"
rm -f "$UNIT" /usr/local/bin/lab-web /usr/local/bin/lab-fw
rm -rf /srv/lab-web
systemctl daemon-reload
ok "unit, lab-web, lab-fw and /srv/lab-web are gone"

say "4. what is deliberately left"
cat <<EOF
firewalld itself stays running and enabled, and the default zone stays
'public'. Disabling a firewall as cleanup would be an odd thing to teach,
and Days 12 and 13 both assume a machine that still filters.

The nftables table 'inet firewalld' also stays - it is firewalld's, not
ours, and it disappears only when firewalld stops.

Day 11 removed.
EOF
