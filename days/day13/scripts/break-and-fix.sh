#!/usr/bin/env bash
#
# Day 13 - break SELinux four ways, then fix each one properly.
#
#   sudo ./scripts/break-and-fix.sh           the four survivable failures
#   sudo ./scripts/break-and-fix.sh --hard    adds the two you must not run
#
# Every fix here is a label, a port rule, a boolean or a reviewed module.
# None of them is setenforce 0, and that is the whole day.
#
# Run setup.sh first. This script assumes /srv/www, nginx on 8080, and the
# fcontext rule are all in place, and it puts them back before it exits.

set -uo pipefail

# shellcheck source=../../../lab/on-lab-vm.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

say()    { printf '\n=== %s ===\n\n' "$*"; }
step()   { printf '\n-- %s\n' "$*"; }
run_sh() { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/  /' || true; }
note()   { printf '  (%s)\n' "$1"; }
die()    { echo "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "needs root:  sudo $0"

WEBROOT="/srv/www"
LABEL="httpd_sys_content_t"
FCONTEXT="${WEBROOT}(/.*)?"
NGINX_CONF="/etc/nginx/conf.d/lab-selinux.conf"
PORT="8080"
BADPORT="8099"
BOOLEAN="httpd_can_network_connect"

HARD="no"
[[ "${1:-}" == "--hard" ]] && HARD="yes"

[[ -d "$WEBROOT" ]] || die "$WEBROOT is missing - run: sudo ./scripts/setup.sh"
[[ -f "$NGINX_CONF" ]] || die "$NGINX_CONF is missing - run: sudo ./scripts/setup.sh"

http_code() { curl -s -o /dev/null -w '%{http_code}' "http://localhost:$1/" 2>/dev/null || echo 000; }

# ---------------------------------------------------------------------------
# 1. chcon: the fix that disappears
# ---------------------------------------------------------------------------
# The most common SELinux mistake is not disabling it. It is fixing a label
# with chcon, seeing the service work, and closing the ticket. The label is
# real until the next relabel, and then the outage returns with no
# corresponding change in any configuration file.
say "1. chcon works, and then it does not"

step "the label now, and the rule that backs it"
run_sh "ls -Zd $WEBROOT"
run_sh "semanage fcontext -l -C | grep -F '$WEBROOT' || echo '(no local rule)'"

step "break it: chcon to a type nginx cannot read"
run_sh "chcon -R -t var_t $WEBROOT"
run_sh "ls -Zd $WEBROOT"
printf '  HTTP %s\n' "$(http_code "$PORT")"
note "403. Ownership and mode never changed - only the label did"

step "the denial, in the words the kernel used"
run_sh "ausearch -m avc -ts recent 2>/dev/null | tail -8"
note "scontext=httpd_t, tcontext=var_t, tclass=file. Who, what, which operation"

step "fix it the temporary way, which is the trap"
run_sh "chcon -R -t $LABEL $WEBROOT"
printf '  HTTP %s\n' "$(http_code "$PORT")"
note "200. Looks finished. It is not"

step "prove the trap: ask policy what it thinks"
run_sh "restorecon -nvR $WEBROOT"
note "silence means the fcontext rule from setup.sh agrees with the label. Without that rule this would list every file, and a relabel would revert your chcon"

step "see it revert, on a file with no rule behind it"
run_sh "install -m 0644 /dev/null /srv/lab-orphan"
run_sh "chcon -t $LABEL /srv/lab-orphan"
run_sh "ls -Z /srv/lab-orphan"
run_sh "restorecon -v /srv/lab-orphan"
run_sh "ls -Z /srv/lab-orphan"
note "that is what happens to every chcon with no semanage rule under it"
run_sh "rm -f /srv/lab-orphan"

# ---------------------------------------------------------------------------
# 2. a label that is right for the wrong job
# ---------------------------------------------------------------------------
# httpd_sys_content_t is not the only web label, and the differences are not
# cosmetic. This is the failure where somebody 'used an httpd type' and the
# service still refuses.
say "2. the right family, the wrong type"

step "break it: a type that exists, is web-related, and is not readable content"
run_sh "chcon -R -t httpd_sys_script_exec_t $WEBROOT"
printf '  HTTP %s\n' "$(http_code "$PORT")"
note "'it has an httpd type' is not the same as 'nginx may read it'"

step "ask policy which types httpd_t may actually read as files"
if command -v sesearch >/dev/null 2>&1; then
	run_sh "sesearch --allow -s httpd_t -c file -p read | grep -E 'httpd_sys(_rw)?_content_t' | head -5"
	note "sesearch answers this without a single test request"
else
	note "sesearch is missing: sudo dnf install -y setools-console"
fi

step "fix it the permanent way: the rule, then apply the rule"
run_sh "semanage fcontext -l | grep -F '$WEBROOT' || semanage fcontext -a -t $LABEL '$FCONTEXT'"
run_sh "restorecon -RF $WEBROOT"
run_sh "ls -Zd $WEBROOT"
printf '  HTTP %s\n' "$(http_code "$PORT")"
note "restorecon did not need to be told the type. The rule already knew it"

# ---------------------------------------------------------------------------
# 3. a port nobody labelled
# ---------------------------------------------------------------------------
# The failure that convinces people SELinux is haunted: a valid config, a
# free port, and a service that will not start. Nothing in nginx -t can see
# it, because nothing about it is an nginx problem.
say "3. a free port, a valid config, and a refused bind"

step "what SELinux allows a web server to bind"
run_sh "semanage port -l | grep -E '^http_port_t|^http_cache_port_t'"
run_sh "semanage port -l | grep -E '(^|[[:space:]])$BADPORT(,|\$|[[:space:]])' || echo '(nothing claims $BADPORT/tcp)'"

step "break it: move nginx to $BADPORT"
run_sh "sed -i 's/listen $PORT;/listen $BADPORT;/' $NGINX_CONF"
run_sh "nginx -t"
note "nginx says the configuration is fine, because it is"
run_sh "systemctl restart nginx"
run_sh "systemctl is-active nginx"
run_sh "ss -tlpn | grep -E ':$BADPORT([[:space:]]|\$)' || echo '(nothing listening on $BADPORT)'"

step "the reason, which is not in the nginx log"
run_sh "ausearch -m avc -ts recent 2>/dev/null | grep -F 'name_bind' | tail -5"
note "tclass=tcp_socket, permission name_bind. A port is a labelled object like any file"

step "fix it: label the port, do not move the service back"
run_sh "semanage port -a -t http_port_t -p tcp $BADPORT"
run_sh "semanage port -l -C"
run_sh "systemctl restart nginx"
printf '  HTTP %s\n' "$(http_code "$BADPORT")"
note "semanage port -a is the supported answer. -m modifies an existing label, -d removes yours"

step "put the day's port back, and take the port rule with it"
run_sh "sed -i 's/listen $BADPORT;/listen $PORT;/' $NGINX_CONF"
run_sh "semanage port -d -t http_port_t -p tcp $BADPORT"
run_sh "systemctl restart nginx"
printf '  HTTP %s\n' "$(http_code "$PORT")"

# ---------------------------------------------------------------------------
# 4. the boolean, and the module people reach for instead
# ---------------------------------------------------------------------------
# A denial does not mean you need a policy module. Most of the interesting
# ones already have a boolean: written by the policy author, described in
# one line, and supported across upgrades.
say "4. the boolean you should have looked for first"

step "break it: turn the boolean off, runtime only"
run_sh "setsebool $BOOLEAN off"
run_sh "getsebool $BOOLEAN"
note "no -P. This is the change that vanishes at the next reboot and takes your explanation with it"

step "what a reverse proxy attempt would hit now"
run_sh "semanage boolean -l | grep $BOOLEAN"
note "the description is the documentation: httpd_t may not open outbound connections while this is off"

step "how to find the right boolean from a denial, without guessing"
run_sh "semanage boolean -l | grep -E 'httpd_(can_network|unified|enable)' | head -6"
if command -v audit2allow >/dev/null 2>&1; then
	run_sh "ausearch -m avc -ts recent 2>/dev/null | audit2allow | head -20"
	note "audit2allow suggests a rule. When its output mentions a boolean, use the boolean and throw the rule away"
else
	note "audit2allow is missing: sudo dnf install -y policycoreutils-devel"
fi

step "fix it properly: same change, recorded permanently"
run_sh "setsebool -P $BOOLEAN on"
run_sh "semanage boolean -l -C"
note "-P writes it into policy. Now the next person can see what you did"

# ---------------------------------------------------------------------------
# the two that are not exercises
# ---------------------------------------------------------------------------
if [[ "$HARD" == "yes" ]]; then
	say "5. setenforce 0 - described, not executed"
	cat <<'EOF'
  This one is not run because there is nothing to see: every failure above
  would have "worked", and none of them would have been understood.

  What actually happens on a production box:

    setenforce 0        the outage ends in one second
    the ticket closes   with no root cause and no label rule
    the reboot comes    and /etc/selinux/config still says enforcing
    the outage returns  weeks later, with nobody on call who remembers

  The variant that is worse: SELINUX=disabled in /etc/selinux/config. A
  disabled system stops labelling new files at all, so turning it back on
  needs a full relabel (touch /.autorelabel, then one very slow boot). That
  is how "we will re-enable it later" becomes "we never re-enabled it".

  Permissive has one legitimate use: a time-boxed diagnostic window to
  collect every denial at once instead of finding them one restart at a
  time. Even then, you write down when you turned it off.

    setenforce 0
    # reproduce the failure once
    ausearch -m avc -ts recent | audit2allow -m lab_candidate   # read it
    setenforce 1
EOF

	say "6. relabelling the whole filesystem - also not executed"
	cat <<'EOF'
  touch /.autorelabel && reboot

  Sometimes necessary, never casual. On this VM it costs minutes. On a real
  fileserver it is hours of downtime, and if the policy driving the relabel
  is wrong, the machine comes back consistently mislabelled - much harder to
  diagnose than one wrong directory.

  The targeted version is nearly always what you want:

    restorecon -Rnv /path     # what would change (n = dry run, v = verbose)
    restorecon -RFv /path     # do it, F = force even if the type looks right

  Read the -n output first. Every time.
EOF
else
	say "the two not shown"
	cat <<'EOF'
  Run with --hard for the two failures that are described rather than
  performed: setenforce 0 as an incident "fix", and a full filesystem
  relabel. One teaches nothing and one costs hours.
EOF
fi

# ---------------------------------------------------------------------------
# put it back, and prove it
# ---------------------------------------------------------------------------
say "putting it back"

semanage fcontext -l | grep -F "$WEBROOT" >/dev/null || semanage fcontext -a -t "$LABEL" "$FCONTEXT"
restorecon -RF "$WEBROOT"
sed -i "s/listen $BADPORT;/listen $PORT;/" "$NGINX_CONF"
semanage port -d -t http_port_t -p tcp "$BADPORT" >/dev/null 2>&1 || true
setsebool -P "$BOOLEAN" on
systemctl restart nginx >/dev/null 2>&1 || true
rm -f /srv/lab-orphan

pending="$(restorecon -nvR "$WEBROOT" 2>/dev/null || true)"
printf '  label:      %s\n' "$(ls -Zd "$WEBROOT" | awk '{print $1}')"
if [[ -z "$pending" ]]; then
	printf '  restorecon: silent - disk matches policy\n'
else
	printf '  restorecon: still wants changes\n'
fi
printf '  boolean:    %s\n' "$(getsebool "$BOOLEAN")"
printf '  mode:       %s\n' "$(getenforce)"
printf '  HTTP %s from http://localhost:%s/\n' "$(http_code "$PORT")" "$PORT"

cat <<EOF

Four failures.

  chcon            the fix that works today and vanishes at the next relabel
  wrong type       an httpd label is not the same as a readable one
  unlabelled port  valid config, free port, refused bind, nothing in the log
  boolean off      a supported switch existed and no module was needed

Only the first is visible in a file listing. The rest need ausearch.

Check yourself:  sudo ./days/day13/verify.sh
EOF
