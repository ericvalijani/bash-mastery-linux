#!/usr/bin/env bash
#
# Day 13 - remove what setup.sh built.
#
#   sudo ./scripts/teardown.sh
#
# Order matters here in the same way it did in Day 11: stop the service
# before removing the policy that let it run, and remove the fcontext rule
# before deleting the directory, so the rule is not left describing a path
# that no longer exists.

set -uo pipefail

# shellcheck source=../../../lab/on-lab-vm.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

say() { printf '\n==> %s\n' "$*"; }
die() { echo "$*" >&2; exit 1; }
ok()  { printf '  ok  %s\n' "$*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "needs root:  sudo $0"

WEBROOT="/srv/www"
FCONTEXT="${WEBROOT}(/.*)?"
NGINX_CONF="/etc/nginx/conf.d/lab-selinux.conf"
PORT="8080"
BADPORT="8099"
BOOLEAN="httpd_can_network_connect"
MODULE="lab_selinux"
BUILD="/var/tmp/lab-selinux-build"

say "1. stopping nginx before removing its policy"
rm -f "$NGINX_CONF"
if nginx -t >/dev/null 2>&1; then
	systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true
	ok "lab server config removed, nginx reloaded and still valid"
else
	systemctl stop nginx >/dev/null 2>&1 || true
	ok "lab server config removed, nginx stopped (its remaining config does not parse)"
fi

if ss -tlpn 2>/dev/null | grep -E ":$PORT([[:space:]]|$)" >/dev/null; then
	echo "  something is STILL listening on $PORT:"
	ss -tlpn 2>/dev/null | grep -E ":$PORT([[:space:]]|$)" | sed 's/^/      /'
else
	ok "nothing listening on $PORT"
fi

say "2. removing the policy module"
if semodule -l | grep -Fx "$MODULE" >/dev/null; then
	semodule -r "$MODULE" >/dev/null 2>&1 || true
	ok "semodule -r $MODULE"
else
	ok "$MODULE was not loaded"
fi
rm -rf "$BUILD"
ok "build directory $BUILD removed"

say "3. removing the local port rule, if break-and-fix left one"
if semanage port -l -C 2>/dev/null | grep -E "(^|[[:space:]])$BADPORT(,|$|[[:space:]])" >/dev/null; then
	semanage port -d -t http_port_t -p tcp "$BADPORT" >/dev/null 2>&1 || true
	ok "$BADPORT/tcp label removed"
else
	ok "no local rule for $BADPORT/tcp"
fi

say "4. the boolean, back to the policy default"
setsebool -P "$BOOLEAN" off >/dev/null 2>&1 || true
if semanage boolean -l -C 2>/dev/null | grep -F "$BOOLEAN" >/dev/null; then
	echo "  $BOOLEAN is still listed as a local change:"
	semanage boolean -l -C | grep -F "$BOOLEAN" | sed 's/^/      /'
else
	ok "$BOOLEAN is back to the shipped default"
fi

say "5. the label rule, then the files"
# Rule first: removing the directory first would leave a local fcontext
# entry pointing at nothing, which is exactly the kind of leftover that
# makes 'semanage fcontext -l -C' useless on an inherited machine.
if semanage fcontext -l -C 2>/dev/null | grep -F "$WEBROOT" >/dev/null; then
	semanage fcontext -d "$FCONTEXT" >/dev/null 2>&1 || true
	ok "fcontext rule for $FCONTEXT removed"
else
	ok "no local fcontext rule for $WEBROOT"
fi

rm -rf "$WEBROOT" /usr/local/bin/lab-se
ok "$WEBROOT and /usr/local/bin/lab-se are gone"

say "6. what is deliberately left"
cat <<EOF
SELinux stays Enforcing. Turning it off as cleanup would undo the entire
point of the day, and Days 14-20 all assume a machine that still labels.

nginx itself stays installed and enabled with its distribution config, so
/usr/share/nginx/html on port 80 still works - that path was already
labelled correctly and was never ours.

The audit log stays. Denials you caused today are history worth keeping:
  ausearch -m avc -ts today

Day 13 removed. Current mode: $(getenforce)
EOF
