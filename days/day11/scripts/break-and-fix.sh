#!/usr/bin/env bash
#
# Day 11 - break the firewall five ways and repair each one.
#
#   sudo ./scripts/break-and-fix.sh          three that people meet weekly
#   sudo ./scripts/break-and-fix.sh --hard   two that get blamed on the wrong thing
#
# Everything is undone on exit, including on Ctrl-C, by restore().
# The permanent configuration is written back and reloaded, so the machine
# ends exactly as setup.sh left it.

set -uo pipefail

# shellcheck source=../../../lab/on-lab-vm.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

say()  { printf '\n=== %s ===\n\n' "$*"; }
die()  { echo "$*" >&2; exit 1; }
run_sh() { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/  /' || true; printf '\n'; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "needs root:  sudo $0"

PORT="8080"
ZONE="$(firewall-cmd --get-default-zone)"
SERVICE="lab-web.service"
HARD="no"; [[ "${1:-}" == "--hard" ]] && HARD="yes"

probe() {
	# The only honest test: try the connection. Everything else is intent.
	if curl -s -m 3 -o /dev/null "http://127.0.0.1:$PORT/"; then
		echo "  probe: reachable on 127.0.0.1:$PORT"
	else
		echo "  probe: NOT reachable on 127.0.0.1:$PORT"
	fi
}

restore() {
	printf '\n--- putting it back ---\n'
	firewall-cmd --permanent --zone="$ZONE" --add-port="$PORT/tcp" >/dev/null 2>&1 || true
	firewall-cmd --permanent --zone="$ZONE" --remove-service=ssh >/dev/null 2>&1 || true
	firewall-cmd --permanent --zone="$ZONE" --add-service=ssh >/dev/null 2>&1 || true
	firewall-cmd --set-default-zone=public >/dev/null 2>&1 || true
	nft delete table inet lab_block >/dev/null 2>&1 || true
	firewall-cmd --reload >/dev/null 2>&1 || true
	systemctl start "$SERVICE" >/dev/null 2>&1 || true
	sleep 1
	# A teardown that does not verify its own result is an assumption with a
	# nice name. Check, and say so either way.
	if firewall-cmd --zone="$ZONE" --query-port="$PORT/tcp" >/dev/null 2>&1; then
		echo "  $PORT/tcp open again, default zone public, no stray nft tables"
	else
		echo "  WARNING: $PORT/tcp is still closed. Run: sudo ./scripts/setup.sh"
	fi
	probe
}
trap restore EXIT INT TERM

command -v curl >/dev/null 2>&1 || die "needs curl:  sudo dnf install -y curl"

# ---------------------------------------------------------------------------
say "1. the change that works until the next reload"

firewall-cmd --zone="$ZONE" --remove-port="$PORT/tcp" >/dev/null 2>&1 || true
firewall-cmd --zone="$ZONE" --add-port="9099/tcp" >/dev/null

run_sh "firewall-cmd --zone=$ZONE --list-ports"
run_sh "firewall-cmd --permanent --zone=$ZONE --list-ports"

cat <<'EOF'
  Read those two lines together. The runtime has 9099 and the permanent
  configuration does not. Somebody opened a port for a colleague, it
  worked, they moved on - and it will vanish at the next reload or reboot
  with nobody able to say what changed.

  The reverse mistake is worse: --permanent with no --reload writes a rule
  that never takes effect, so the person who "fixed it" is confident and
  wrong.

  fixed by making it permanent and reloading, in that order.
EOF
firewall-cmd --reload >/dev/null

# ---------------------------------------------------------------------------
say "2. the port is open and it still refuses"

systemctl stop "$SERVICE"
sleep 1
run_sh "firewall-cmd --zone=$ZONE --query-port=$PORT/tcp"
probe
run_sh "ss -tlpn | grep :$PORT || echo 'nothing listening'"

cat <<'EOF'
  The firewall says yes. The connection is refused anyway, because the
  firewall's job is to allow packets, not to answer them. There is no
  process behind the rule.

  From another machine these two look identical, which is why remote
  debugging goes in circles: a blocked port usually hangs, a closed port
  refuses immediately. Locally, ss settles it in one line.

  fixed by starting the service, not by touching the firewall.
EOF
systemctl start "$SERVICE"
sleep 1
probe

# ---------------------------------------------------------------------------
say "3. the zone that governs nothing"

run_sh "firewall-cmd --get-active-zones"
firewall-cmd --set-default-zone=trusted >/dev/null
run_sh "firewall-cmd --get-default-zone; firewall-cmd --list-all | head -8"

cat <<'EOF'
  The zone 'trusted' accepts everything. firewalld is running, enabled,
  and reporting healthy - and the machine has no firewall at all. Nothing
  in systemctl status would tell you.

  This is why verify.sh checks that the default zone is NOT trusted. A
  green service is not a policy.

  fixed by putting the default zone back to public.
EOF
firewall-cmd --set-default-zone=public >/dev/null

if [ "$HARD" = "no" ]; then
	cat <<'EOF'

Three failures, three fixes. Two more are waiting behind --hard: the one
where the front end and the kernel disagree, and the one where you lock
yourself out of the machine you are typing on.

  sudo ./days/day11/scripts/break-and-fix.sh --hard
EOF
	exit 0
fi

# ---------------------------------------------------------------------------
say "4. --hard: the front end says open, the kernel says no"

nft add table inet lab_block 2>/dev/null || true
nft add chain inet lab_block input '{ type filter hook input priority -300 ; policy accept ; }' 2>/dev/null || true
nft add rule inet lab_block input tcp dport "$PORT" drop 2>/dev/null || true

run_sh "firewall-cmd --zone=$ZONE --query-port=$PORT/tcp"
probe
run_sh "nft list table inet lab_block"

cat <<'EOF'
  firewall-cmd still answers 'yes'. It is telling the truth about its own
  configuration and knows nothing about the rest of the kernel.

  Another table, hooked at priority -300, runs BEFORE firewalld's chains
  (priority 0) and drops the packet first. Lower priority number wins.
  Docker, kubernetes, a colleague's script and any tool that writes
  nftables directly can all do this to you, and firewalld will keep
  reporting a policy it is no longer able to enforce.

  The tell: firewall-cmd says open, ss says listening, and the connection
  still fails. That combination means look outside firewalld.

  fixed with: nft delete table inet lab_block
EOF
nft delete table inet lab_block >/dev/null 2>&1 || true
sleep 1
probe

# ---------------------------------------------------------------------------
say "5. --hard: the rule that locks you out"

cat <<'EOF'
  Not run here, because it would end your SSH session and there is no
  console on this VM to rescue you with. Read it instead:

    sudo firewall-cmd --permanent --remove-service=ssh
    sudo firewall-cmd --reload

  The reload is the moment the door shuts. Your existing connection may
  survive - firewalld keeps established connections - so it can look like
  nothing happened, and the machine is already unreachable for the next
  login. People discover this the following morning.

  Two habits that cost nothing:

    firewall-cmd --add-port=9099/tcp --timeout=120
        runtime only, reverts itself after two minutes. Test with this
        first, and make it permanent once you are still logged in.

    firewall-cmd --permanent --list-services | grep ssh
        before every reload on a remote machine.

  A firewall change you cannot undo remotely is a change you make on the
  console, or with a timeout, or not at all.
EOF

run_sh "firewall-cmd --permanent --zone=$ZONE --list-services"

cat <<'EOF'
Five failures.

  runtime vs permanent  two configurations, and --reload is the bridge
  no listener           the firewall allows packets, it does not answer them
  trusted zone          a healthy service enforcing nothing
  another nft table     lower priority runs first, firewalld never notices
  removing ssh          the change whose damage starts after you log out

Only the first was fixed by a firewall command that firewall-cmd could see.

Check yourself:  ./days/day11/verify.sh
EOF
