#!/usr/bin/env bash
#
# lab-se - what SELinux thinks is going on, in one screen.
#
# Installed as /usr/local/bin/lab-se by setup.sh.
#
#   sudo lab-se              mode, the lab's labels, ports, local changes, denials
#   sudo lab-se /srv/www     everything SELinux knows about one path
#
# Changes nothing. The point of this tool is that "is it SELinux?" is four
# questions, not one: the mode, the label on the file, the context of the
# process, and the label on the port. A denial is always a mismatch between
# two of those, and the last section names the mismatch instead of leaving
# you to compare two screens by eye.

set -uo pipefail

WEBROOT="/srv/www"
PORT="8080"
BOOLEAN="httpd_can_network_connect"
MODULE="lab_selinux"

head()  { printf '\n--- %s ---\n\n' "$*"; }
line()  { printf '  %s\n' "$*"; }
run()   { bash -c "$1" 2>&1 | sed 's/^/  /' || true; }

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
	echo "Run as root: semanage, ausearch and ss all show less to anyone else." >&2
	echo "  sudo $0 $*" >&2
	echo >&2
fi

# ---------------------------------------------------------------------------
# one path, in full
# ---------------------------------------------------------------------------
if [ $# -gt 0 ]; then
	target="$1"

	head "what SELinux knows about $target"

	if [ ! -e "$target" ]; then
		line "$target does not exist"
		exit 1
	fi

	line "label on disk now:"
	run "ls -Zd '$target'"

	line "what policy says it should be:"
	matched="$(matchpathcon "$target" 2>/dev/null || true)"
	if [ -n "$matched" ]; then
		line "  $matched"
	else
		line "  (matchpathcon unavailable - try: restorecon -nv '$target')"
	fi

	line ""
	line "does policy want to change anything here?"
	pending="$(restorecon -nvR "$target" 2>/dev/null || true)"
	if [ -z "$pending" ]; then
		line "  no. Disk and policy agree - this label will survive a relabel."
	else
		printf '%s\n' "$pending" | sed 's/^/    /'
		line "  ^ these are chcon-shaped labels: correct now, gone after the"
		line "    next restorecon, package update or autorelabel."
	fi

	head "the rule that decides it"
	rules="$(semanage fcontext -l 2>/dev/null | grep -F "$target" || true)"
	if [ -n "$rules" ]; then
		printf '%s\n' "$rules" | sed 's/^/  /'
	else
		line "no fcontext rule names this path directly."
		line "It is inheriting a rule for a parent directory, or the default."
		line "Add one with:  semanage fcontext -a -t <type> '${target}(/.*)?'"
	fi
	exit 0
fi

# ---------------------------------------------------------------------------
# 1. the mode
# ---------------------------------------------------------------------------
head "mode"
run "sestatus"
line ""
line "Enforcing = denials are refused and logged."
line "Permissive = denials are logged and allowed. Useful for an hour, not a policy."

# ---------------------------------------------------------------------------
# 2. the three labels that have to agree
# ---------------------------------------------------------------------------
head "file, process, port"

line "file - the content nginx is meant to read:"
if [ -d "$WEBROOT" ]; then
	run "ls -Zd '$WEBROOT'"
	run "ls -Z '$WEBROOT' | head -5"
else
	line "  $WEBROOT does not exist - run setup.sh first"
fi

line "process - the context nginx actually runs in:"
ps_out="$(ps -eZ 2>/dev/null | grep -E 'nginx' || true)"
if [ -n "$ps_out" ]; then
	printf '%s\n' "$ps_out" | sed 's/^/    /'
else
	line "  nginx is not running"
fi

line "port - what SELinux allows a web server to bind:"
run "semanage port -l | grep -E '^http_port_t|^http_cache_port_t'"
line "  ($PORT/tcp must appear in one of those lines, or the bind fails)"

# ---------------------------------------------------------------------------
# 3. what someone changed on this machine
# ---------------------------------------------------------------------------
# This is the section to read first on a machine you did not build. The
# stock policy is the same everywhere; the local changes are the story.
head "local changes - the parts that are not stock policy"

line "booleans changed from their default:"
bools="$(semanage boolean -l -C 2>/dev/null || true)"
if [ -n "$bools" ]; then
	printf '%s\n' "$bools" | sed 's/^/    /'
else
	line "  none. Nothing was set with setsebool -P."
fi

line ""
line "$BOOLEAN right now:"
run "getsebool $BOOLEAN"
line "  (on here but absent above means it was set WITHOUT -P: reboot reverts it)"

line ""
line "file context rules added locally:"
fc="$(semanage fcontext -l -C 2>/dev/null || true)"
if [ -n "$fc" ]; then
	printf '%s\n' "$fc" | sed 's/^/    /'
else
	line "  none"
fi

line ""
line "port rules added locally:"
ports="$(semanage port -l -C 2>/dev/null || true)"
if [ -n "$ports" ]; then
	printf '%s\n' "$ports" | sed 's/^/    /'
else
	line "  none"
fi

line ""
line "policy modules that are not shipped by the distribution:"
if semodule -l 2>/dev/null | grep -F "$MODULE" >/dev/null; then
	line "  $MODULE (this day's - source in /var/tmp/lab-selinux-build)"
else
	line "  $MODULE is not loaded"
fi

# ---------------------------------------------------------------------------
# 4. the denials
# ---------------------------------------------------------------------------
# ausearch is the whole of triage. An empty result is itself an answer: if
# nothing was denied, the problem is not SELinux, and you can stop guessing.
head "recent denials"

if command -v ausearch >/dev/null 2>&1; then
	avc="$(ausearch -m avc -ts recent 2>/dev/null || true)"
	if [ -n "$avc" ]; then
		printf '%s\n' "$avc" | tail -25 | sed 's/^/  /'
		line ""
		line "Read the fields, in this order: scontext (who), tcontext (what),"
		line "tclass and the permission in { } (which operation)."
	else
		line "no AVC denials in the recent window."
		line "If something is broken, it is not SELinux. Check the service."
	fi
else
	line "ausearch is missing:  sudo dnf install -y audit"
fi

# ---------------------------------------------------------------------------
# 5. where the answers disagree
# ---------------------------------------------------------------------------
head "where the answers disagree"

found="no"

if [ -d "$WEBROOT" ]; then
	label="$(ls -Zd "$WEBROOT" | awk '{print $1}')"
	case "$label" in
	*httpd_sys_content_t* | *httpd_sys_rw_content_t*)
		:
		;;
	*)
		line "$WEBROOT is not labelled for web content:"
		line "  $label"
		line "  fix: semanage fcontext -a -t httpd_sys_content_t '${WEBROOT}(/.*)?' && restorecon -RF $WEBROOT"
		found="yes"
		;;
	esac

	if [ -n "$(restorecon -nvR "$WEBROOT" 2>/dev/null || true)" ]; then
		line "labels under $WEBROOT do not match policy - a chcon is holding them in place."
		line "  fix: add the fcontext rule, then restorecon -RF $WEBROOT"
		found="yes"
	fi
fi

if ! ss -tlpn 2>/dev/null | grep -E ":$PORT([[:space:]]|$)" >/dev/null; then
	line "nothing is listening on $PORT."
	line "  a bind refused by policy looks exactly like this: systemctl says failed,"
	line "  the config is valid, and ausearch has the reason."
	found="yes"
elif ! curl -sf "http://localhost:$PORT/" >/dev/null 2>&1; then
	line "something is listening on $PORT but the page does not come back."
	line "  a 403 with correct file modes is the signature of a label problem."
	found="yes"
fi

if [ "$(getenforce)" != "Enforcing" ]; then
	line "SELinux is $(getenforce), so nothing here is actually being enforced."
	line "  everything 'works' and none of it is proven. setenforce 1."
	found="yes"
fi

if [ "$found" = "no" ]; then
	line "nothing. Enforcing, labels match policy, the port is served, and the"
	line "local changes above are all recorded permanently."
fi

printf '\n'
