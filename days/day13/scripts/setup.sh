#!/usr/bin/env bash
#
# Day 13 setup - serve content from a non-default path with SELinux enforcing.
#
# Leaves behind:
#   /srv/www/index.html                     content outside /usr/share/nginx
#   an fcontext rule for /srv/www(/.*)?     the PERMANENT label, not a chcon
#   /etc/nginx/conf.d/lab-selinux.conf      nginx on 8080, root /srv/www
#   port label for 8080/tcp confirmed       the third thing SELinux labels
#   boolean httpd_can_network_connect on    set with -P, so it survives reboot
#   the lab_selinux policy module loaded    built from source you can read
#   /usr/local/bin/lab-se                   the payload
#
# Everything here is idempotent. Run it twice; the second run should change
# nothing and say so.
#
# The rule this day exists to teach: nothing in this script ever runs
# 'setenforce 0'. Every problem is solved by giving the right label or the
# right boolean, because that is the fix that survives the next reboot and
# the next audit.

set -euo pipefail

# shellcheck source=../../../lab/on-lab-vm.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

say()  { printf '\n==> %s\n' "$*"; }
die()  { echo "$*" >&2; exit 1; }
ok()   { printf 'ok    %s\n' "$*"; }
note() { printf '  (%s)\n\n' "$1"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "needs root:  sudo $0"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_SRC="$HERE/lab-se.sh"
PAYLOAD="/usr/local/bin/lab-se"
TE_SRC="$HERE/lab_selinux.te"

WEBROOT="/srv/www"
FCONTEXT="${WEBROOT}(/.*)?"
LABEL="httpd_sys_content_t"
NGINX_CONF="/etc/nginx/conf.d/lab-selinux.conf"
PORT="8080"
BOOLEAN="httpd_can_network_connect"
MODULE="lab_selinux"
BUILD="/var/tmp/lab-selinux-build"

# ---------------------------------------------------------------------------
# 0. the tools
# ---------------------------------------------------------------------------
# semanage, restorecon and semodule come from three different packages, which
# is the usual reason a denial-triage session stalls before it starts.
say "0. checking the tools are here"

missing=""
for c in getenforce sestatus semanage restorecon semodule checkmodule semodule_package curl nginx; do
	command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
done
if [[ -n "$missing" ]]; then
	die "missing:$missing
  sudo dnf install -y nginx policycoreutils policycoreutils-python-utils \\
                      checkpolicy setools-console audit curl"
fi
ok "selinux tooling, nginx and curl all present"

# ---------------------------------------------------------------------------
# 1. enforcing, before anything else
# ---------------------------------------------------------------------------
# A day about SELinux on a permissive machine is a day about nothing: policy
# is still evaluated, denials are still logged, and everything is allowed
# anyway. So this is a hard requirement, not a warning.
say "1. SELinux must be enforcing"

mode="$(getenforce)"
case "$mode" in
Enforcing)
	ok "getenforce: Enforcing"
	;;
Permissive)
	setenforce 1
	ok "was Permissive, now Enforcing (runtime)"
	note "check /etc/selinux/config too - runtime and boot-time are separate, exactly like firewalld"
	;;
*)
	die "SELinux is Disabled. That cannot be fixed at runtime:
  edit /etc/selinux/config, set SELINUX=enforcing, then reboot.
  A disabled system also needs a full relabel on the next boot, so expect
  'touch /.autorelabel' and one slow boot."
	;;
esac

if grep -qE '^SELINUX=enforcing' /etc/selinux/config 2>/dev/null; then
	ok "/etc/selinux/config will still be enforcing after a reboot"
else
	echo "      note: /etc/selinux/config does not say enforcing - this VM would"
	echo "      come back permissive. Left alone: changing it is a reboot decision."
fi

# ---------------------------------------------------------------------------
# 2. content in the wrong place on purpose
# ---------------------------------------------------------------------------
# /usr/share/nginx/html is already labelled for the web server. Putting the
# content in /srv/www is what creates the problem this day is about, and it
# is also what real deployments do.
say "2. content in $WEBROOT"

mkdir -p "$WEBROOT"
if [[ -f "$WEBROOT/index.html" ]]; then
	ok "$WEBROOT/index.html already exists"
else
	cat > "$WEBROOT/index.html" <<'EOF'
<!doctype html>
<title>day 13</title>
<h1>served from /srv/www with SELinux enforcing</h1>
<p>The label made this work. Not setenforce 0.</p>
EOF
	ok "wrote $WEBROOT/index.html"
fi

echo "      label as it stands now:"
ls -Zd "$WEBROOT" | sed 's/^/        /'
note "probably var_t or default_t. Correct ownership, correct mode, and nginx still cannot read it"

# ---------------------------------------------------------------------------
# 3. the permanent label
# ---------------------------------------------------------------------------
# This is the centre of the day. 'chcon' writes a label onto the inode and
# policy does not know about it; the next 'restorecon -R', package update or
# autorelabel silently undoes it. 'semanage fcontext' records the intent in
# policy, and 'restorecon' then applies that intent. Intent first, then apply.
say "3. the label rule: semanage fcontext, then restorecon"

if semanage fcontext -l 2>/dev/null | grep -F "$WEBROOT" >/dev/null; then
	ok "an fcontext rule for $WEBROOT already exists"
else
	semanage fcontext -a -t "$LABEL" "$FCONTEXT"
	ok "semanage fcontext -a -t $LABEL '$FCONTEXT'"
fi

restorecon -RF "$WEBROOT"
ok "restorecon -RF $WEBROOT applied the rule to the files"

actual="$(ls -Zd "$WEBROOT" | awk '{print $1}')"
case "$actual" in
*":$LABEL:"* | *":$LABEL")
	ok "$WEBROOT now carries $LABEL"
	;;
*)
	die "expected $LABEL on $WEBROOT, got: $actual
  semanage fcontext -l | grep '$WEBROOT'   # is the rule there?
  restorecon -Rnv $WEBROOT                 # what does policy want to change?"
	;;
esac

# A no-op restorecon is the strongest statement available: every label on
# disk already matches what policy says it should be.
if [[ -z "$(restorecon -nvR "$WEBROOT")" ]]; then
	ok "restorecon -nvR is silent: disk and policy agree"
else
	echo "      restorecon still wants to change something:"
	restorecon -nvR "$WEBROOT" | sed 's/^/        /'
fi
note "chcon writes a label; semanage fcontext writes the reason the label is correct"

# ---------------------------------------------------------------------------
# 4. nginx, on a port SELinux already knows
# ---------------------------------------------------------------------------
# 8080/tcp is labelled http_cache_port_t in the stock policy, and httpd_t may
# bind that. Port 8099 is not labelled at all, which is failure 3 in
# break-and-fix.sh - a bind that fails with a valid config and a free port.
say "4. nginx serving $WEBROOT on $PORT"

cat > "$NGINX_CONF" <<EOF
# Day 13 - written by days/day13/scripts/setup.sh
#
# Deliberately not port 80: the distribution ships a default server there,
# and a second default_server on the same port is an nginx error, not an
# SELinux one. Keeping them separate keeps the lesson honest.
server {
    listen $PORT;
    server_name localhost;
    root $WEBROOT;
    index index.html;
}
EOF
ok "wrote $NGINX_CONF"

if nginx -t >/dev/null 2>&1; then
	ok "nginx -t: the configuration parses"
else
	rm -f "$NGINX_CONF"
	nginx -t 2>&1 | sed 's/^/      /' >&2
	die "nginx rejected the config - it has been removed and nothing was loaded"
fi

echo "      what SELinux thinks $PORT/tcp is for:"
semanage port -l | grep -E "(^|[[:space:]])${PORT}(,|$|[[:space:]])" | sed 's/^/        /' || \
	echo "        (no port rule mentions $PORT - httpd_t may refuse to bind it)"

systemctl enable --now nginx >/dev/null 2>&1 || true
systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true

# A service that has just been told to start is not yet a service that
# answers. Same retry lesson as Day 11's listener and Day 12's jail.
serving="no"
for _ in $(seq 1 20); do
	if curl -sf "http://localhost:$PORT/" >/dev/null 2>&1; then serving="yes"; break; fi
	sleep 0.5
done

if [[ "$serving" == "yes" ]]; then
	ok "curl http://localhost:$PORT/ returns the page"
else
	echo "      nginx is not serving yet. The three questions, in order:" >&2
	systemctl is-active nginx 2>&1 | sed 's/^/        /' >&2
	ss -tlpn 2>/dev/null | grep -E ":$PORT([[:space:]]|$)" | sed 's/^/        /' >&2 || \
		echo "        nothing is listening on $PORT" >&2
	echo "        ausearch -m avc -ts recent | tail -20   # was it SELinux?" >&2
fi
note "process context matters as much as file context: ps -eZ | grep nginx"

# ---------------------------------------------------------------------------
# 5. a boolean, set permanently
# ---------------------------------------------------------------------------
# Booleans are the supported way to change policy. Without -P the change is
# runtime only and the next reboot quietly reverts it - the same runtime vs
# permanent split as firewalld in Day 11.
say "5. the boolean $BOOLEAN"

if [[ "$(getsebool "$BOOLEAN" | awk '{print $3}')" == "on" ]]; then
	ok "$BOOLEAN is already on"
else
	setsebool -P "$BOOLEAN" on
	ok "setsebool -P $BOOLEAN on"
fi

if semanage boolean -l -C | grep -F "$BOOLEAN" >/dev/null; then
	ok "recorded as a local change, so it survives a reboot"
else
	echo "      $BOOLEAN is on but not in 'semanage boolean -l -C'."
	echo "      That means it was set without -P. Redo it:  setsebool -P $BOOLEAN on"
fi
note "semanage boolean -l -C lists exactly what you changed, which is the first thing to read on someone else's machine"

# ---------------------------------------------------------------------------
# 6. a policy module you can read
# ---------------------------------------------------------------------------
# break-and-fix.sh builds a module the real way, from an AVC through
# audit2allow. This one is compiled from a .te file that ships with the day
# so the source is in front of you before it is loaded - which is the habit
# that matters, because audit2allow will happily hand you a rule that grants
# far more than the denial needed.
say "6. the $MODULE policy module"

[[ -r "$TE_SRC" ]] || die "cannot find $TE_SRC"

if semodule -l | grep -Fx "$MODULE" >/dev/null; then
	ok "$MODULE is already loaded"
else
	mkdir -p "$BUILD"
	install -m 0644 "$TE_SRC" "$BUILD/$MODULE.te"
	echo "      the rules being loaded:"
	grep -vE '^\s*(#|$)' "$BUILD/$MODULE.te" | sed 's/^/        /'
	checkmodule -M -m -o "$BUILD/$MODULE.mod" "$BUILD/$MODULE.te"
	semodule_package -o "$BUILD/$MODULE.pp" -m "$BUILD/$MODULE.mod"
	semodule -i "$BUILD/$MODULE.pp"
	ok "built and loaded $MODULE (source kept in $BUILD)"
fi
note "read the .te before semodule -i. A module is policy, and nobody reviews it later"

# ---------------------------------------------------------------------------
# 7. the payload
# ---------------------------------------------------------------------------
say "7. installing lab-se"

[[ -r "$PAYLOAD_SRC" ]] || die "cannot find $PAYLOAD_SRC"
install -m 0755 "$PAYLOAD_SRC" "$PAYLOAD"
ok "$PAYLOAD"

cat <<EOF

Enforcing, content in $WEBROOT with a permanent label, nginx on $PORT, one
boolean set with -P, and a module whose source you read first.

  sudo $PAYLOAD                 # mode, labels, ports, booleans, recent denials
  sudo $PAYLOAD $WEBROOT        # everything SELinux knows about one path

Then the tour:  sudo ./days/day13/scripts/explore-selinux.sh
And break it:   sudo ./days/day13/scripts/break-and-fix.sh
                sudo ./days/day13/scripts/break-and-fix.sh --hard

Check yourself: sudo ./days/day13/verify.sh
EOF
