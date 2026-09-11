#!/usr/bin/env bash
#
# Day 11 - build the firewall environment from nothing.
#
#   sudo ./scripts/setup.sh
#
# Creates:
#   /usr/local/bin/lab-web                  a service worth protecting (port 8080)
#   /etc/systemd/system/lab-web.service     it runs forever, on all interfaces
#   /usr/local/bin/lab-fw                   the payload: what is open, and why
#   firewalld running, enabled, default zone public
#   8080/tcp open - permanently, and reloaded so the runtime matches
#
# Why a service at all: a firewall with nothing behind it teaches nothing.
# The interesting question today is never "is the port open" on its own, it
# is the pair - is something listening, AND is the packet allowed to reach
# it. Those two failures look identical from another machine and have
# nothing to do with each other, so the day builds both halves.
#
# Idempotent. Run it twice; the second run reports what already exists.

set -euo pipefail

# shellcheck source=../../../lab/on-lab-vm.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

say()  { printf '\n==> %s\n' "$*"; }
die()  { echo "$*" >&2; exit 1; }
ok()   { printf 'ok    %s\n' "$*"; }
note() { printf '  (%s)\n\n' "$1"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "needs root:  sudo $0"

HERE="$(cd "$(dirname "$0")" && pwd)"

PAYLOAD_SRC="$HERE/lab-fw.sh"
PAYLOAD="/usr/local/bin/lab-fw"
WEB_BIN="/usr/local/bin/lab-web"
SERVICE="lab-web.service"
UNIT="/etc/systemd/system/$SERVICE"
WEB_ROOT="/srv/lab-web"
PORT="8080"
ZONE="public"

# ---------------------------------------------------------------------------
# 0. dependencies
#
# The Rocky 9 cloud image ships firewalld but does not always start it, and
# nft comes from a separate package. Check for everything the whole day
# uses, including the tools only the tour calls - a day that dies halfway
# through because ss is missing is worse than one that refuses at the top.
# ---------------------------------------------------------------------------
missing=""
for tool in firewall-cmd nft ss python3 systemctl; do
	command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
if [ -n "$missing" ]; then
	echo "missing:$missing" >&2
	echo >&2
	echo "  RHEL family:    sudo dnf install -y firewalld nftables iproute python3" >&2
	echo "  Debian/Ubuntu:  sudo apt-get install -y firewalld nftables iproute2 python3" >&2
	die "install those first, then run this again"
fi
ok "firewall-cmd, nft, ss, python3 all present"

# ---------------------------------------------------------------------------
# 1. firewalld itself
#
# is-active and is-enabled are different questions and people conflate them
# constantly. Active means it is running now. Enabled means it comes back
# after a reboot. A firewall that is active but not enabled is a machine
# that protects itself until the next power cut.
# ---------------------------------------------------------------------------
say "1. firewalld running and enabled"

if systemctl is-active --quiet firewalld; then
	ok "firewalld already running"
else
	systemctl start firewalld
	ok "firewalld started"
fi

if systemctl is-enabled --quiet firewalld; then
	ok "firewalld already enabled at boot"
else
	systemctl enable firewalld >/dev/null 2>&1
	ok "firewalld enabled at boot"
fi

note "active = running now. enabled = survives a reboot. Check both"

# ---------------------------------------------------------------------------
# 2. the default zone
#
# firewalld assigns every interface to a zone, and the zone decides the
# policy. 'trusted' accepts everything, which is a firewall in name only.
# We force 'public' so the day starts from deny-by-default.
# ---------------------------------------------------------------------------
say "2. the default zone"

current_zone="$(firewall-cmd --get-default-zone)"
if [ "$current_zone" = "$ZONE" ]; then
	ok "default zone is already $ZONE"
else
	firewall-cmd --set-default-zone="$ZONE" >/dev/null
	ok "default zone changed from $current_zone to $ZONE"
fi

printf '  interfaces in %s: %s\n' "$ZONE" "$(firewall-cmd --zone="$ZONE" --list-interfaces || true)"
note "a zone with no interfaces enforces nothing - always check this line"

# ---------------------------------------------------------------------------
# 3. something worth protecting
#
# A tiny HTTP server on 8080, bound to every interface on purpose. Binding
# to 0.0.0.0 is what makes the firewall the only thing standing between
# this process and the network - which is the point of the day.
# ---------------------------------------------------------------------------
say "3. a service on port $PORT"

install -d -m 0755 "$WEB_ROOT"
printf 'Day 11: you reached lab-web on port %s.\n' "$PORT" > "$WEB_ROOT/index.html"

cat > "$WEB_BIN" <<'WEBEOF'
#!/usr/bin/env bash
# Installed by Day 11 setup.sh. A one-line web server, so the day has
# something real behind the firewall rule.
exec /usr/bin/python3 -m http.server 8080 --bind 0.0.0.0 --directory /srv/lab-web
WEBEOF
chmod 0755 "$WEB_BIN"
ok "$WEB_BIN"

cat > "$UNIT" <<UNITEOF
[Unit]
Description=Day 11 lab web service (port $PORT)
After=network-online.target

[Service]
ExecStart=$WEB_BIN
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNITEOF

systemctl daemon-reload
systemctl enable --now "$SERVICE" >/dev/null 2>&1 || true
# A check that races a daemon start must retry. systemd returns as soon as
# it has forked the process; python3 still has to start and bind, and on a
# small VM that is comfortably longer than one second. Poll for ten.
listening=""
for _ in $(seq 1 20); do
	listening="$(ss -tlpn 2>/dev/null | grep -E ":$PORT([[:space:]]|$)" || true)"
	[ -n "$listening" ] && break
	sleep 0.5
done

if [ -n "$listening" ]; then
	ok "something is listening on $PORT:"
	echo "$listening" | sed 's/^/      /'
else
	systemctl status "$SERVICE" --no-pager -l | sed 's/^/      /' || true
	die "lab-web did not start - read the status above before going on"
fi

note "ss answers 'is anything listening'. It says nothing about reachability"

# ---------------------------------------------------------------------------
# 4. opening the port, both halves
#
# This is the single most common firewalld mistake, and it is a mistake in
# BOTH directions:
#
#   firewall-cmd --add-port=8080/tcp               works now, gone after reload
#   firewall-cmd --permanent --add-port=8080/tcp   survives, does nothing now
#
# The runtime configuration and the permanent configuration are two
# separate things. You need both, which is why every real change ends in
# --reload. break-and-fix.sh shows each half failing on its own.
# ---------------------------------------------------------------------------
say "4. opening $PORT/tcp - permanently, then reloading"

if firewall-cmd --permanent --zone="$ZONE" --list-ports | grep -qw "$PORT/tcp"; then
	ok "$PORT/tcp already in the permanent configuration"
else
	firewall-cmd --permanent --zone="$ZONE" --add-port="$PORT/tcp" >/dev/null
	ok "$PORT/tcp added to the permanent configuration"
fi

firewall-cmd --reload >/dev/null
ok "reloaded - the running rules now match the files on disk"

if firewall-cmd --zone="$ZONE" --list-ports | grep -qw "$PORT/tcp"; then
	ok "$PORT/tcp is open in the runtime configuration too"
else
	die "$PORT/tcp is permanent but not runtime - the reload did not take"
fi

# ---------------------------------------------------------------------------
# 5. a rich rule
#
# Ports and services are the blunt instruments. A rich rule carries a
# source, an action and optionally logging, which is how you say 'this one
# subnet may reach SSH and nobody else'. We add one that logs rejected
# traffic, because a firewall you cannot see working is a firewall you
# cannot debug.
# ---------------------------------------------------------------------------
say "5. a rich rule, so there is something to read later"

RICH='rule family="ipv4" source address="127.0.0.0/8" port port="9090" protocol="tcp" accept'

if firewall-cmd --permanent --zone="$ZONE" --query-rich-rule="$RICH" >/dev/null 2>&1; then
	ok "rich rule already present"
else
	firewall-cmd --permanent --zone="$ZONE" --add-rich-rule="$RICH" >/dev/null
	firewall-cmd --reload >/dev/null
	ok "rich rule added: 9090/tcp from 127.0.0.0/8 only"
fi

note "9090 is open to loopback and closed to the world - one rule, two answers"

# ---------------------------------------------------------------------------
# 6. the kernel rules your commands produced
#
# firewalld is a front end. It does not filter anything itself - it writes
# nftables rules and lets the kernel do the work. If 'nft list ruleset' has
# no 'table inet firewalld' in it, then whatever firewall-cmd told you, no
# firewalld rule is being enforced.
# ---------------------------------------------------------------------------
say "6. what firewalld actually built"

# firewalld can drive EITHER backend. With FirewallBackend=iptables it is
# still a working firewall, but it writes iptables rules and there is no
# 'table inet firewalld' to look at - which would make the whole second
# half of this day impossible. So if the table is missing, look at the
# backend before blaming anything else, and switch it.
FW_CONF="/etc/firewalld/firewalld.conf"

if ! nft list tables 2>/dev/null | grep -q 'table inet firewalld'; then
	backend="$(grep -E '^FirewallBackend=' "$FW_CONF" 2>/dev/null | cut -d= -f2)"
	printf '      no inet firewalld table yet. FirewallBackend=%s\n' "${backend:-unset}"

	if [ "$backend" != "nftables" ]; then
		if grep -qE '^FirewallBackend=' "$FW_CONF" 2>/dev/null; then
			sed -i 's/^FirewallBackend=.*/FirewallBackend=nftables/' "$FW_CONF"
		else
			echo 'FirewallBackend=nftables' >> "$FW_CONF"
		fi
		ok "switched FirewallBackend to nftables in $FW_CONF"
	fi

	# A reload is not enough for a backend change - firewalld reads this
	# setting at startup only.
	systemctl restart firewalld
	for _ in $(seq 1 20); do
		nft list tables 2>/dev/null | grep -q 'table inet firewalld' && break
		sleep 0.5
	done
	ok "firewalld restarted"

	# The restart reloads from the permanent configuration, so the port is
	# still open - but prove it rather than assume it.
	if ! firewall-cmd --zone="$ZONE" --query-port="$PORT/tcp" >/dev/null 2>&1; then
		firewall-cmd --reload >/dev/null 2>&1 || true
	fi
fi

if nft list tables 2>/dev/null | grep -q 'table inet firewalld'; then
	ok "table inet firewalld exists in the kernel"
	chains="$(nft list table inet firewalld 2>/dev/null | grep -c 'chain ' || true)"
	printf '      %s chains inside it\n' "$chains"
else
	echo "      tables the kernel does have:" >&2
	nft list tables 2>&1 | sed 's/^/        /' >&2
	echo "      FirewallBackend now: $(grep -E '^FirewallBackend=' "$FW_CONF" 2>/dev/null || echo unset)" >&2
	die "no 'table inet firewalld' - see the tables above before going on"
fi

note "the front end reports intent. nft reports what the kernel will do"

# ---------------------------------------------------------------------------
# 7. the payload
# ---------------------------------------------------------------------------
say "7. installing lab-fw"

[ -f "$PAYLOAD_SRC" ] || die "missing $PAYLOAD_SRC"
install -m 0755 "$PAYLOAD_SRC" "$PAYLOAD"
ok "$PAYLOAD"

cat <<EOF

One service, one zone, one open port, and the nftables table underneath it.

  sudo /usr/local/bin/lab-fw       # what is open, what is listening, and the gaps
  sudo /usr/local/bin/lab-fw $PORT  # everything about one port

Then the tour:  ./days/day11/scripts/explore-firewall.sh
And break it:   sudo ./days/day11/scripts/break-and-fix.sh
                sudo ./days/day11/scripts/break-and-fix.sh --hard

Check yourself: ./days/day11/verify.sh
EOF
