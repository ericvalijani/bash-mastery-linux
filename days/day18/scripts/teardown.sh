#!/usr/bin/env bash
#
# Day 18 teardown.
#
#   sudo ./scripts/teardown.sh          remove today's namespaces
#   sudo ./scripts/teardown.sh --all    also remove /usr/local/bin/lab-vlan
#                                       and the break-and-fix backups
#
# Only Day 18's own namespaces are touched. Day 06's client/router/resolver/
# auth topology, which Days 07-09 need, is left alone.

set -uo pipefail

NAMESPACES=(sw18 h18a h18b h18c h18t h18d)
PAYLOAD="/usr/local/bin/lab-vlan"
BACKUP_DIR="/tmp/day18-broken"
STATE="/run/day18"

say()  { printf '\n%s\n' "$1"; printf '%s\n' "$(printf '%*s' "${#1}" '' | tr ' ' '-')"; }
ok()   { printf '  ok    %s\n' "$*"; }
skip() { printf '  --    %s\n' "$*"; }
note() { printf '        %s\n' "$*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || { printf 'needs root:  sudo %s %s\n' "$0" "${1:-}" >&2; exit 1; }

ALL=no
[[ "${1:-}" == "--all" ]] && ALL=yes

say "namespaces"
for ns in "${NAMESPACES[@]}"; do
	if ip netns list 2>/dev/null | grep -qw "$ns"; then
		# Deleting a namespace deletes everything inside it, including one
		# end of each veth pair - and a veth pair with one end gone is
		# removed entirely. So the bridge, the ports, the VLAN interfaces
		# and the bond all go with it. There is nothing else to clean up.
		ip netns del "$ns"
		ok "removed $ns"
	else
		skip "$ns was not there"
	fi
done
rm -rf "$STATE"

say "what is left"
if ip netns list 2>/dev/null | grep -q .; then
	ip netns list | sed 's/^/  /'
	note "those belong to Day 06 and are still in use by Days 07-09"
else
	note "no namespaces at all on this host now"
fi

if [[ "$ALL" == "yes" ]]; then
	say "the payload and the backups"
	if [[ -e "$PAYLOAD" ]]; then
		rm -f "$PAYLOAD"
		ok "removed $PAYLOAD"
	else
		skip "$PAYLOAD was not installed"
	fi
	if [[ -d "$BACKUP_DIR" ]]; then
		rm -rf "$BACKUP_DIR"
		ok "removed $BACKUP_DIR"
	else
		skip "no $BACKUP_DIR"
	fi
else
	say "kept"
	note "$PAYLOAD and $BACKUP_DIR - remove them with --all"
fi

say "done"
note "Rebuild any time: sudo ./scripts/setup.sh"
note "Nothing today survived a reboot anyway - namespaces never do"
