#!/usr/bin/env bash
#
# break-and-fix.sh - four ways a reverse proxy fails, none of which says why.
#
#   sudo ./break-and-fix.sh          the four that are safe here
#   sudo ./break-and-fix.sh --hard   plus the two that quietly undo the TLS
#
# Everything is restored at the end from copies taken first.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

NAME="${LAB_SITE:-www.lab.test}"
BACKEND_PORT="${LAB_BACKEND_PORT:-8080}"
CA_DIR="/etc/lab-tls"
CRT="/etc/pki/tls/certs/$NAME.crt"
KEY="/etc/pki/tls/private/$NAME.key"
CONF="/etc/nginx/conf.d/lab-proxy.conf"
BACKUP_DIR="/tmp/day17-broken"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { printf 'needs root:  sudo %s %s\n' "$0" "${1:-}" >&2; exit 1; }
[[ -f "$CONF" ]] || { printf 'no %s - run scripts/setup.sh first\n' "$CONF" >&2; exit 1; }

say()  { printf '\n%s\n' "$1"; printf '%s\n' "$(printf '%*s' "${#1}" '' | tr ' ' '-')"; }
step() { printf '\n  -> %s\n' "$*"; }
run()  { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/  /'; printf '\n'; }
note() { printf '  %s\n' "$*"; }

HARD=no
[[ "${1:-}" == "--hard" ]] && HARD=yes

mkdir -p "$BACKUP_DIR"
chmod 0700 "$BACKUP_DIR"
cp -a "$CONF" "$BACKUP_DIR/lab-proxy.conf.good"
cp -a "$CRT" "$BACKUP_DIR/server.crt.good"
cp -a "$KEY" "$BACKUP_DIR/server.key.good"
note "good copies are in $BACKUP_DIR"

restore_conf() { cp -a "$BACKUP_DIR/lab-proxy.conf.good" "$CONF"; nginx -t >/dev/null 2>&1 && systemctl reload nginx; }
restore_cert() {
	cp -a "$BACKUP_DIR/server.crt.good" "$CRT"
	cp -a "$BACKUP_DIR/server.key.good" "$KEY"
	command -v restorecon >/dev/null 2>&1 && restorecon -F "$CRT" "$KEY" >/dev/null 2>&1
	systemctl reload nginx >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
say "1. SELinux says no, and nginx says 502"
# The failure this day exists to teach. Nothing in the message mentions
# SELinux, and the configuration is perfect.
step "before"
run "curl -sS -o /dev/null -w 'http_code=%{http_code}\\n' https://$NAME/"

if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == Enforcing ]]; then
	setsebool httpd_can_network_connect off
	step "the boolean is off - the config, the cert and the backend are untouched"
	run "getsebool httpd_can_network_connect"
	run "curl -sS -o /dev/null -w 'http_code=%{http_code}\\n' https://$NAME/"
	run "tail -n 2 /var/log/nginx/lab-proxy.error.log"
	note "502 Bad Gateway, and the error log says Permission denied. Not"
	note "'connection refused' - the backend is running and reachable. Permission"
	note "denied on a connect() to 127.0.0.1 is SELinux, essentially always"
	step "the audit log is the only place that names it"
	run "ausearch -m avc -ts recent 2>/dev/null | tail -n 6 || echo '(no ausearch, or auditd is not running)'"
	step "the fix"
	run "setsebool -P httpd_can_network_connect on"
	run "curl -sS -o /dev/null -w 'http_code=%{http_code}\\n' https://$NAME/"
	note "-P or it comes back at the next reboot, working until then"
else
	note "SELinux is not enforcing here, so this failure cannot be shown."
	note "On a real RHEL-family host it is the first thing to suspect behind"
	note "a 502 whose configuration is obviously correct"
fi

# ---------------------------------------------------------------------------
say "2. the right certificate for the wrong name"
# Ties Day 10 to something running. The chain is trusted, the dates are fine,
# and every client refuses it anyway.
step "issue a certificate for other.lab.test and serve that instead"
TMP_EXT="$(mktemp)"
cat > "$TMP_EXT" <<'EXT'
basicConstraints=CA:FALSE
extendedKeyUsage=serverAuth
subjectAltName=DNS:other.lab.test
EXT
(umask 077 && openssl genrsa -out "$BACKUP_DIR/wrong.key" 2048 >/dev/null 2>&1)
openssl req -new -key "$BACKUP_DIR/wrong.key" -subj "/CN=other.lab.test" -out "$BACKUP_DIR/wrong.csr" >/dev/null 2>&1
openssl x509 -req -in "$BACKUP_DIR/wrong.csr" -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" \
	-CAcreateserial -days 30 -sha256 -extfile "$TMP_EXT" -out "$BACKUP_DIR/wrong.crt" >/dev/null 2>&1
rm -f "$TMP_EXT"
cp -a "$BACKUP_DIR/wrong.crt" "$CRT"
cp -a "$BACKUP_DIR/wrong.key" "$KEY"
command -v restorecon >/dev/null 2>&1 && restorecon -F "$CRT" "$KEY" >/dev/null 2>&1
systemctl reload nginx >/dev/null 2>&1

run "openssl verify -CAfile $CA_DIR/ca.crt $CRT"
note "openssl verify says OK - it checks the chain and the dates, and it has"
note "never once checked a hostname"
run "curl -sS -o /dev/null -w 'http_code=%{http_code} verify=%{ssl_verify_result}\\n' https://$NAME/ || true"
run "echo | openssl s_client -connect 127.0.0.1:443 -servername $NAME -verify_hostname $NAME -CAfile $CA_DIR/ca.crt 2>&1 | grep -E 'subject=|Verify return code'"
note "the certificate is valid and signed by a CA this host trusts. It is for"
note "another name, which is a different question and a different failure"
step "the fix"
restore_cert
run "curl -sS -o /dev/null -w 'http_code=%{http_code} verify=%{ssl_verify_result}\\n' https://$NAME/"

# ---------------------------------------------------------------------------
say "3. 502 versus 504, which are not the same news"
step "stop the backend entirely"
systemctl stop lab-app.service
run "curl -sS -o /dev/null -w 'http_code=%{http_code}\\n' https://$NAME/"
run "tail -n 1 /var/log/nginx/lab-proxy.error.log"
note "502 with 'Connection refused': something answered the connect attempt"
note "with a refusal, immediately. The backend is down, and you know within"
note "one millisecond"
step "the other shape of the same outage"
note "if the packets were dropped instead of refused - a firewall rule, a dead"
note "host, a hung application - nginx would wait proxy_connect_timeout and"
note "then return 504. 502 means refused or broken; 504 means silence."
note "Reading which one you got tells you where to look before you look"
step "the fix"
systemctl start lab-app.service
sleep 1
run "curl -sS -o /dev/null -w 'http_code=%{http_code}\\n' https://$NAME/"

# ---------------------------------------------------------------------------
say "4. the certificate you replaced and never reloaded"
# The same lesson as Day 16's unapplied config, in the place it costs most:
# certificate renewal.
step "the serial nginx is serving right now"
SERIAL_BEFORE="$(echo | openssl s_client -connect 127.0.0.1:443 -servername "$NAME" 2>/dev/null | openssl x509 -noout -serial 2>/dev/null)"
note "on the wire: ${SERIAL_BEFORE:-unknown}"

step "issue a fresh certificate, exactly as a renewal would"
TMP_EXT="$(mktemp)"
cat > "$TMP_EXT" <<EXT
basicConstraints=CA:FALSE
extendedKeyUsage=serverAuth
subjectAltName=DNS:$NAME
EXT
(umask 077 && openssl genrsa -out "$KEY" 2048 >/dev/null 2>&1)
openssl req -new -key "$KEY" -subj "/CN=$NAME" -out "$BACKUP_DIR/renew.csr" >/dev/null 2>&1
openssl x509 -req -in "$BACKUP_DIR/renew.csr" -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" \
	-CAcreateserial -days 825 -sha256 -extfile "$TMP_EXT" -out "$CRT" >/dev/null 2>&1
rm -f "$TMP_EXT"
command -v restorecon >/dev/null 2>&1 && restorecon -F "$CRT" "$KEY" >/dev/null 2>&1

run "openssl x509 -in $CRT -noout -serial"
SERIAL_WIRE="$(echo | openssl s_client -connect 127.0.0.1:443 -servername "$NAME" 2>/dev/null | openssl x509 -noout -serial 2>/dev/null)"
note "on disk:    $(openssl x509 -in "$CRT" -noout -serial)"
note "on the wire: ${SERIAL_WIRE:-unknown}"
note "nginx read the certificate once, when the workers started. Nothing"
note "watches the file. Every renewal needs a reload, and a renewal that"
note "forgets one expires in production while the new certificate sits on disk"
run "nginx -t 2>&1 | tail -1"
note "and nginx -t passes, because the file on disk is perfectly valid"
step "the fix: reload, not restart"
run "systemctl reload nginx && sleep 1 && echo | openssl s_client -connect 127.0.0.1:443 -servername $NAME 2>/dev/null | openssl x509 -noout -serial"
note "reload starts new workers and lets the old ones finish their requests."
note "restart drops every connection in flight, including long uploads"
step "put the original certificate back"
restore_cert
run "curl -sS -o /dev/null -w 'http_code=%{http_code} verify=%{ssl_verify_result}\\n' https://$NAME/"

# ---------------------------------------------------------------------------
if [[ "$HARD" == yes ]]; then
	say "the two that quietly undo the whole day - described, not run"
	cat <<TXT
  a. the backend bound to 0.0.0.0

       ExecStart=... --bind 0.0.0.0

     Everything keeps working. https://$NAME/ still serves, the
     certificate still verifies, the proxy log still fills up. And the
     same content is now available unencrypted on port $BACKEND_PORT to
     anything that can reach this host - no TLS, no redirect, no log line
     in the proxy's access log, because those requests never touch nginx.

     Nothing fails. That is what makes it worth knowing: the only symptom
     is an open port, and the only tool that shows it is ss(8).

  b. opening $BACKEND_PORT in firewalld "to test something"

       firewall-cmd --permanent --add-port=$BACKEND_PORT/tcp

     Same outcome as (a) the moment the backend is bound anywhere but
     loopback, and it survives reboots. Temporary firewall holes opened
     during an incident are how most permanent ones start.

  Both are safe to try on this VM, and both are worth doing once in your
  life, from the console, with ss -tlnp open in another window. Neither is
  automated here because a script that opens a service to the network and
  then closes it teaches the closing, not the exposure.
TXT
fi

# ---------------------------------------------------------------------------
restore_conf
restore_cert
systemctl is-active --quiet lab-app.service || systemctl start lab-app.service
rm -f "$BACKUP_DIR"/wrong.* "$BACKUP_DIR"/renew.csr

say "restored"
run "curl -sS -o /dev/null -w 'http_code=%{http_code} verify=%{ssl_verify_result}\\n' https://$NAME/"
note "good copies are still in $BACKUP_DIR if anything above went sideways"

cat <<'TXT'

Four failures.

  SELinux boolean   502, Permission denied, and the word SELinux nowhere
  wrong name        a valid certificate that every client refuses
  backend stopped   502 refused now, versus 504 silence later
  never reloaded    disk and wire disagree, and nginx -t says fine

Three of the four are the proxy reporting a failure it did not cause, which
is the job of a proxy and the reason they are annoying to debug.

Check yourself:  sudo ./verify.sh
TXT
