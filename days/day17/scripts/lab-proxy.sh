#!/usr/bin/env bash
#
# lab-proxy - look at the reverse proxy Day 17 built.
#
#   lab-proxy [status]   listeners, units, and the one SELinux boolean
#   lab-proxy certs       what the certificate claims, and who signed it
#   lab-proxy test        a verified handshake, then a real request
#   lab-proxy logs        the proxy log and the backend's journal
#
# Installed to /usr/local/bin/lab-proxy by setup.sh. Read-only: it inspects,
# it never changes anything.

set -uo pipefail

NAME="${LAB_SITE:-www.lab.test}"
BACKEND_PORT="${LAB_BACKEND_PORT:-8080}"
CA="/etc/lab-tls/ca.crt"
CRT="/etc/pki/tls/certs/$NAME.crt"
KEY="/etc/pki/tls/private/$NAME.key"

head_() { printf '\n%s\n' "$1"; printf '%s\n' "$(printf '%*s' "${#1}" '' | tr ' ' '-')"; }
row()   { printf '  %-22s %s\n' "$1" "$2"; }
run()   { printf '\n$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/  /'; }

status() {
	head_ "units"
	row "nginx" "$(systemctl is-active nginx 2>/dev/null), $(systemctl is-enabled nginx 2>/dev/null)"
	row "lab-app" "$(systemctl is-active lab-app.service 2>/dev/null), $(systemctl is-enabled lab-app.service 2>/dev/null)"

	head_ "who is listening where"
	ss -tlnp 2>/dev/null | awk 'NR==1 || /:(80|443|'"$BACKEND_PORT"')\>/' | sed 's/^/  /'
	printf '\n  443 and 80 are on every address. %s is on 127.0.0.1 only,\n' "$BACKEND_PORT"
	printf '  and that is the only thing keeping it private.\n'

	head_ "the ports firewalld allows"
	if systemctl is-active --quiet firewalld; then
		row "permanent" "$(firewall-cmd --permanent --list-ports 2>/dev/null)"
		row "runtime" "$(firewall-cmd --list-ports 2>/dev/null)"
	elif command -v firewall-offline-cmd >/dev/null 2>&1; then
		row "permanent" "$(firewall-offline-cmd --list-ports 2>/dev/null) (firewalld stopped)"
	else
		row "firewalld" "absent"
	fi

	head_ "SELinux"
	if command -v getenforce >/dev/null 2>&1; then
		row "mode" "$(getenforce)"
		command -v getsebool >/dev/null 2>&1 &&
			row "boolean" "$(getsebool httpd_can_network_connect 2>/dev/null)"
		row "cert label" "$(ls -Z "$CRT" 2>/dev/null | awk '{print $1}')"
	else
		row "mode" "no SELinux tooling"
	fi
}

certs() {
	head_ "the certificate nginx serves"
	run "openssl x509 -in $CRT -noout -subject -issuer -dates -serial"
	run "openssl x509 -in $CRT -noout -ext subjectAltName"
	printf '\n  subjectAltName decides hostname matching. CN is decoration.\n'

	head_ "is it signed by our CA, and is the key its own"
	run "openssl verify -CAfile $CA $CRT"
	printf '  cert modulus  %s\n' "$(openssl x509 -noout -modulus -in "$CRT" 2>/dev/null | openssl md5)"
	printf '  key  modulus  %s\n' "$(openssl rsa -noout -modulus -in "$KEY" 2>/dev/null | openssl md5)"
	printf '\n  Those two lines must match. openssl verify never checks it.\n'

	head_ "modes"
	ls -l "$CRT" "$KEY" "$CA" 2>/dev/null | sed 's/^/  /'
}

test_() {
	head_ "a handshake, checked properly"
	run "echo | openssl s_client -connect 127.0.0.1:443 -servername $NAME -verify_hostname $NAME -CAfile $CA 2>&1 | grep -E 'Verify return code|subject=|issuer=|Protocol|Cipher'"
	printf '\n  Verify return code: 0 (ok) is the only line that means trusted.\n'

	head_ "the same request as a client"
	run "curl -sS -o /dev/null -w 'http_code=%{http_code} tls=%{ssl_verify_result} proto=%{http_version}\\n' https://$NAME/"
	printf '  ssl_verify_result=0 means curl verified it against the system store.\n'

	head_ "and the backend, directly"
	run "curl -sS -o /dev/null -w 'http_code=%{http_code}\\n' http://127.0.0.1:$BACKEND_PORT/"
	printf '  No TLS on that hop, and none needed - it never leaves the host.\n'
}

logs() {
	head_ "proxy access log, last 10"
	tail -n 10 /var/log/nginx/lab-proxy.access.log 2>/dev/null | sed 's/^/  /' ||
		printf '  no access log yet\n'

	head_ "proxy error log, last 10"
	tail -n 10 /var/log/nginx/lab-proxy.error.log 2>/dev/null | sed 's/^/  /' ||
		printf '  no error log yet - which is the point of reading it\n'

	head_ "the backend, last 10"
	journalctl -u lab-app.service -n 10 --no-pager 2>/dev/null | sed 's/^/  /'

	head_ "SELinux denials, if any"
	if command -v ausearch >/dev/null 2>&1; then
		ausearch -m avc -ts recent 2>/dev/null | tail -n 10 | sed 's/^/  /' ||
			printf '  none recently\n'
	else
		printf '  no ausearch here\n'
	fi
}

case "${1:-status}" in
status | "") status ;;
certs) certs ;;
test) test_ ;;
logs) logs ;;
-h | --help | help)
	sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
	;;
*)
	printf 'unknown: %s\n\n' "$1" >&2
	sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 1
	;;
esac
