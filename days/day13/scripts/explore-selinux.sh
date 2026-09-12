#!/usr/bin/env bash
#
# Day 13 - a read-only tour of SELinux on a machine that is already working.
#
#   sudo ./scripts/explore-selinux.sh
#
# Changes nothing. Every command here is a query. Run it as root: semanage,
# ausearch and sesearch all show less, or nothing, to anyone else.
#
# Read this before break-and-fix.sh. The tour is what a healthy machine looks
# like, and you cannot recognise a denial until you know that.

set -uo pipefail

say()    { printf '\n=== %s ===\n\n' "$*"; }
run_sh() { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/  /' || true; printf '\n'; }
note()   { printf '  (%s)\n\n' "$1"; }

WEBROOT="/srv/www"
PORT="8080"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
	echo "Running without root. semanage and ausearch will refuse."
	echo "Re-run with sudo to see the whole picture:  sudo $0"
	echo
fi

say "1. the mode, and the mode after a reboot"
run_sh "getenforce"
run_sh "grep -vE '^\\s*(#|$)' /etc/selinux/config"
note "two different questions, exactly like firewalld runtime vs permanent in Day 11"

say "2. everything has a context - files, processes, and you"
run_sh "id -Z"
run_sh "ps -eZ | head -5"
run_sh "ls -Zd / /etc /srv $WEBROOT"
note "user:role:type:level. For almost all troubleshooting, only the TYPE matters"

say "3. the type is the whole game"
run_sh "ps -eZ | grep -E 'nginx|sshd' | head -5"
note "nginx runs as httpd_t. A rule allowing httpd_t is a rule about nginx, apache and any other web server"

say "4. what policy wants vs what is on disk"
run_sh "ls -Zd $WEBROOT"
run_sh "matchpathcon $WEBROOT"
run_sh "restorecon -nvR $WEBROOT"
note "silence from restorecon -n is the good answer: disk and policy already agree"

say "5. the rule behind the label"
run_sh "semanage fcontext -l | grep -F '$WEBROOT'"
run_sh "semanage fcontext -l -C"
note "-C lists only local changes. On someone else's machine, read this first"

say "6. ports are labelled too"
run_sh "semanage port -l | grep -E '^http_port_t|^http_cache_port_t'"
note "$PORT/tcp works because it is already in http_cache_port_t. An unlabelled port is a failed bind with a valid config"

say "7. booleans: the supported way to change policy"
run_sh "getsebool -a | grep '^httpd_' | head -15"
run_sh "semanage boolean -l -C"
note "a boolean is a switch the policy author left for you. Always prefer one over a custom module"

say "8. what a boolean actually does"
run_sh "semanage boolean -l | grep httpd_can_network_connect"
note "the description is the documentation. Read it before turning anything on"

say "9. the rules themselves, if you want them"
if command -v sesearch >/dev/null 2>&1; then
	run_sh "sesearch --allow -s httpd_t -t httpd_sys_content_t -c file"
	note "this is the rule that makes step 4 work. sesearch answers 'is this allowed' without testing it in production"
else
	echo "  sesearch is missing:  sudo dnf install -y setools-console"
	echo
fi

say "10. the denials, which is where triage starts"
run_sh "ausearch -m avc -ts recent 2>/dev/null | tail -20"
note "empty is an answer: nothing was denied, so the fault is not SELinux"

say "11. the loaded modules"
run_sh "semodule -l | wc -l"
run_sh "semodule -l | grep -F lab_selinux"
note "hundreds of stock modules, and the one this day added. Only the second one is your responsibility"

say "12. the service, end to end"
run_sh "systemctl is-active nginx"
run_sh "ss -tlpn | grep -E ':$PORT([[:space:]]|\$)'"
run_sh "curl -s -o /dev/null -w 'HTTP %{http_code}\\n' http://localhost:$PORT/"
note "403 with correct ownership and mode is the signature of a label problem, not a permission problem"

cat <<EOF

The procedure, which is the only thing worth memorising:

  1. Is it enforcing?            getenforce
  2. Was anything denied?        ausearch -m avc -ts recent
  3. Who and what?               scontext, tcontext, tclass in that AVC
  4. Is there a boolean?         semanage boolean -l | grep <service>
  5. Is it a label?              ls -Z the file, matchpathcon it, compare
  6. Fix the cause:              semanage fcontext + restorecon, or setsebool -P,
                                 or a module you read before loading

Never step 0: setenforce 0. That is how a label problem becomes a permanent
exception, and how the next person inherits a machine nobody can audit.

Next:  sudo ./scripts/break-and-fix.sh
EOF
