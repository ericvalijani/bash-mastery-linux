#!/usr/bin/env bash
#
# lab-fw - installed by Day 11 setup.sh as /usr/local/bin/lab-fw
#
#   sudo /usr/local/bin/lab-fw       what is open, what is listening, and where they disagree
#   sudo /usr/local/bin/lab-fw 8080  everything this machine can tell you about one port
#
# The idea: "is the port open?" is never one question. It is three, and
# they are answered by three different programs:
#
#   ss            is a process listening on it?
#   firewall-cmd  does the policy intend to allow it?
#   nft           did that intent reach the kernel?
#
# Any one of those can be yes while the others are no, and every one of
# those combinations produces "connection refused" or a hang from another
# machine. This prints all three side by side so you stop guessing.

set -uo pipefail

ZONE_DEFAULT="$(firewall-cmd --get-default-zone 2>/dev/null || echo public)"
PORT="${1:-}"

hr()   { printf -- '--- %s ---\n\n' "$*"; }
note() { printf '  (%s)\n\n' "$1"; }

if ! command -v firewall-cmd >/dev/null 2>&1; then
	echo "firewall-cmd not found - is firewalld installed?" >&2
	exit 1
fi

if ! systemctl is-active --quiet firewalld; then
	echo "firewalld is not running. Nothing below would be enforced." >&2
	echo "  sudo systemctl start firewalld" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# one port, in detail
# ---------------------------------------------------------------------------
if [ -n "$PORT" ]; then
	hr "port $PORT on zone $ZONE_DEFAULT"

	listening="$(ss -tlpn 2>/dev/null | grep ":$PORT " || true)"
	if [ -n "$listening" ]; then
		echo "listening:"
		echo "$listening" | sed 's/^/  /'
		if echo "$listening" | grep -qE '127\.0\.0\.1:|\[::1\]:'; then
			echo
			echo "  NOTE: bound to loopback only. No firewall rule can make this"
			echo "  reachable from another machine - the process itself refuses."
		fi
	else
		echo "listening:  nothing"
		echo
		echo "  Opening the port in the firewall will not help. There is no"
		echo "  server to reach. Start the service first, then re-check."
	fi
	echo

	runtime="closed"
	firewall-cmd --zone="$ZONE_DEFAULT" --list-ports 2>/dev/null | grep -qw "$PORT/tcp" && runtime="open"
	perm="closed"
	firewall-cmd --permanent --zone="$ZONE_DEFAULT" --list-ports 2>/dev/null | grep -qw "$PORT/tcp" && perm="open"

	printf 'firewalld runtime:    %s\n' "$runtime"
	printf 'firewalld permanent:  %s\n' "$perm"
	echo

	if [ "$runtime" != "$perm" ]; then
		echo "  THE TWO DISAGREE. This is the classic firewalld trap:"
		if [ "$runtime" = "open" ]; then
			echo "  it works right now and will close itself at the next --reload"
			echo "  or reboot. Make it permanent:"
			echo "    sudo firewall-cmd --permanent --add-port=$PORT/tcp && sudo firewall-cmd --reload"
		else
			echo "  it is written on disk and NOT in effect. Somebody added"
			echo "  --permanent and never reloaded:"
			echo "    sudo firewall-cmd --reload"
		fi
		echo
	fi

	echo "in the kernel:"
	# Two probes, not one. Some nft builds fail part way through a whole-table
	# dump and print the chain headers without the rules inside them - which
	# looks exactly like an empty firewall. Asking for the single zone chain
	# is a smaller question and usually survives.
	krules="$(nft list table inet firewalld 2>/dev/null | grep -n "$PORT" || true)"
	if [ -z "$krules" ]; then
		krules="$(nft list chain inet firewalld "filter_IN_${ZONE_DEFAULT}_allow" 2>/dev/null | grep -n "$PORT" || true)"
	fi
	if [ -n "$krules" ]; then
		echo "$krules" | head -5 | sed 's/^/  /'
	else
		echo "  nft printed no rule mentioning $PORT."
		echo "  If firewalld says the port is open, trust firewalld and check by hand:"
		echo "    sudo nft list chain inet firewalld filter_IN_${ZONE_DEFAULT}_allow"
	fi
	echo

	echo "rich rules mentioning it:"
	firewall-cmd --zone="$ZONE_DEFAULT" --list-rich-rules 2>/dev/null | grep "$PORT" | sed 's/^/  /' || true
	echo
	exit 0
fi

# ---------------------------------------------------------------------------
# the whole machine
# ---------------------------------------------------------------------------
hr "zone $ZONE_DEFAULT (the default)"
firewall-cmd --list-all 2>/dev/null | sed 's/^/  /'
echo
note "'interfaces:' empty means this zone governs nothing - check it first"

hr "listening sockets"
ss -tlpn 2>/dev/null | sed 's/^/  /'
echo

hr "where the two disagree"

open_ports="$(firewall-cmd --zone="$ZONE_DEFAULT" --list-ports 2>/dev/null | tr ' ' '\n' | sed 's|/tcp||;s|/udp||' | grep -E '^[0-9]+$' || true)"
# grep -E '^[0-9]+$' guards against anything that is not a port number:
# an ss that ignores -H and prints a header, a socket path, an odd address.
# Without it 'Port' from the header row becomes a port and this section
# reports a disagreement that does not exist.
listen_ports="$(ss -tlnH 2>/dev/null | awk '{print $4}' | sed 's/.*://' | grep -E '^[0-9]+$' | sort -un || true)"

found="no"
for p in $open_ports; do
	if ! echo "$listen_ports" | grep -qx "$p"; then
		echo "  $p  open in the firewall, nothing listening   (a hole to nowhere)"
		found="yes"
	fi
done
for p in $listen_ports; do
	if ! echo "$open_ports" | grep -qx "$p"; then
		bind="$(ss -tlnH 2>/dev/null | awk -v pp=":$p\$" '$4 ~ pp {print $4}' | head -1)"
		case "$bind" in
		127.0.0.1:*|\[::1\]:*) : ;;
		*) echo "  $p  listening on the network, firewall closed  (blocked)" ; found="yes" ;;
		esac
	fi
done
[ "$found" = "no" ] && echo "  none - every open port has a listener and vice versa"
echo

hr "the kernel underneath"
if nft list tables 2>/dev/null | grep -q 'table inet firewalld'; then
	echo "  table inet firewalld:"
	nft list table inet firewalld 2>/dev/null | grep -E 'chain |type .* hook ' | sed 's/^/    /'
	echo
	note "hook and priority decide the ORDER. Lower priority number runs first"
else
	echo "  no firewalld table in the kernel - the front end is enforcing nothing"
	echo
fi

echo "One port in detail:  sudo /usr/local/bin/lab-fw 8080"
