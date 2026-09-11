#!/usr/bin/env bash
#
# Day 11 - a read-only tour of the firewall and the kernel underneath it.
#
#   ./scripts/explore-firewall.sh
#
# Changes nothing. Every command here is a query. Run it as root the first
# time: ss cannot show you which process owns a socket otherwise, and nft
# refuses to list the ruleset at all.

set -uo pipefail

say()    { printf '\n=== %s ===\n\n' "$*"; }
run_sh() { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/  /' || true; printf '\n'; }
note()   { printf '  (%s)\n\n' "$1"; }

ZONE="$(firewall-cmd --get-default-zone 2>/dev/null || echo public)"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
	echo "Running without root. nft will refuse and ss will hide process names."
	echo "Re-run with sudo to see the whole picture:  sudo $0"
	echo
fi

say "1. is the firewall running, and will it come back?"
run_sh "systemctl is-active firewalld; systemctl is-enabled firewalld"
note "two different questions. Active now, enabled after a reboot"

say "2. what zones exist, and which one is in charge"
run_sh "firewall-cmd --get-zones"
run_sh "firewall-cmd --get-default-zone"
run_sh "firewall-cmd --get-active-zones"
note "a zone with no interfaces is a policy nobody is subject to"

say "3. the whole policy for $ZONE, in one screen"
run_sh "firewall-cmd --zone=$ZONE --list-all"
note "target: default means 'reject what is not listed'. This is the summary to read first"

say "4. services are named port lists, nothing more"
run_sh "firewall-cmd --info-service=ssh"
run_sh "firewall-cmd --info-service=http"
note "--add-service=http is exactly --add-port=80/tcp with a name you can read"

say "5. runtime and permanent are two separate configurations"
run_sh "firewall-cmd --zone=$ZONE --list-ports"
run_sh "firewall-cmd --permanent --zone=$ZONE --list-ports"
note "if these ever differ, somebody forgot --permanent or forgot --reload"

say "6. the rich rule"
run_sh "firewall-cmd --zone=$ZONE --list-rich-rules"
note "source + port + action. This is how you open a port to one subnet only"

say "7. who is actually listening"
run_sh "ss -tulpn"
note "0.0.0.0 means every interface. 127.0.0.1 means the firewall is irrelevant"

say "8. the front end is not the firewall - this is"
run_sh "nft list tables"
note "firewalld writes 'table inet firewalld'. Everything it told you lives here"

say "9. chains, hooks and priorities"
run_sh "nft list table inet firewalld | grep -E 'chain |type .* hook ' | head -20"
note "hook = where in the packet path. priority = order, lowest number first"

say "10. following one port down to the kernel"
run_sh "nft list table inet firewalld | grep -n 8080"
note "if firewall-cmd says open and this prints nothing, the reload never happened"

say "11. the counters, which is how you prove a rule is being hit"
run_sh "nft list table inet firewalld | grep -c ."
run_sh "firewall-cmd --zone=$ZONE --query-port=8080/tcp"
note "--query-* exits 0 or 1 and prints yes/no - the form to use in scripts"

say "12. the two answers for the same port"
run_sh "/usr/local/bin/lab-fw 8080 2>/dev/null | head -20"

cat <<'EOF'
Three tools, three different questions, and only all three together answer
"can that machine reach this service":

  ss            is anything listening, and on which address
  firewall-cmd  what the policy intends, runtime and permanent
  nft           what the kernel will actually do with the packet

When a service is unreachable, work in that order. Most of the time you
never get to nft, because ss already showed the process bound to 127.0.0.1.

Next:  sudo ./days/day11/scripts/break-and-fix.sh
EOF
