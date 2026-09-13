#!/usr/bin/env bash
#
# explore-proxy.sh - twelve read-only stops through the proxy you just built.
#
#   sudo ./scripts/explore-proxy.sh
#
# Changes nothing. Every command here is one you would run on a real host at
# three in the morning, in roughly this order.

set -uo pipefail

NAME="${LAB_SITE:-www.lab.test}"
BACKEND_PORT="${LAB_BACKEND_PORT:-8080}"
CA="/etc/lab-tls/ca.crt"
CRT="/etc/pki/tls/certs/$NAME.crt"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { printf 'needs root:  sudo %s\n' "$0" >&2; exit 1; }
[[ -s "$CRT" ]] || { printf 'no %s - run scripts/setup.sh first\n' "$CRT" >&2; exit 1; }

say()  { printf '\n%s\n' "$1"; printf '%s\n' "$(printf '%*s' "${#1}" '' | tr ' ' '-')"; }
run()  { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/  /'; printf '\n'; }
note() { printf '  %s\n' "$*"; }

# ---------------------------------------------------------------------------
say "1. what is listening, and on which addresses"
run "ss -tlnp | awk 'NR==1 || /:(80|443|$BACKEND_PORT)\\>/'"
note "443 and 80 are on 0.0.0.0. $BACKEND_PORT is on 127.0.0.1 only."
note "That single difference is the entire boundary between public and private"
note "here - not the firewall, which never sees loopback traffic at all"

say "2. the configuration nginx is actually running"
run "nginx -T 2>/dev/null | grep -vE '^\\s*#|^\\s*\$' | sed -n '1,40p'"
note "nginx -T dumps the whole assembled config, includes and all. -t only"
note "tests it. Neither tells you when the workers last read it"

say "3. the two server blocks, and why there are two"
run "nginx -T 2>/dev/null | grep -E 'server_name|listen|return 301|proxy_pass'"
note "port 80 exists only to refuse. A service reachable over both http and"
note "https is a service somebody will use over http"

# ---------------------------------------------------------------------------
say "4. the handshake, verified the way a client does it"
run "echo | openssl s_client -connect 127.0.0.1:443 -servername $NAME -verify_hostname $NAME -CAfile $CA 2>&1 | grep -E 'subject=|issuer=|Verify return code|Protocol|Cipher'"
note "three separate questions, and s_client answers all three: is the chain"
note "trusted, is it in date, does the name match. Only 'Verify return"
note "code: 0 (ok)' means yes to all of them"

say "5. the same connection without -servername"
run "echo | openssl s_client -connect 127.0.0.1:443 -CAfile $CA 2>&1 | grep -E 'subject=|Verify return code'"
note "no SNI, so nginx answers with its default server. On a host with one"
note "site you get away with it; on a host with six you get somebody else's"
note "certificate and a very confusing afternoon"

say "6. what the certificate claims"
run "openssl x509 -in $CRT -noout -subject -dates -ext subjectAltName"
note "subjectAltName is the field that matches hostnames. A certificate with"
note "no SAN matches nothing, whatever its CN says"

say "7. why curl needs no flags here"
run "ls -l /etc/pki/ca-trust/source/anchors/ 2>/dev/null; trust list --filter=ca-anchors 2>/dev/null | grep -A2 -i 'lab' | head -6"
run "curl -sS -o /dev/null -w 'http_code=%{http_code} verify=%{ssl_verify_result}\\n' https://$NAME/"
note "the CA is in the system trust store, so verify=0 with no --cacert."
note "Firefox, Java and node keep their own stores and will still refuse it"

# ---------------------------------------------------------------------------
say "8. the hop behind the proxy is plain HTTP"
run "curl -sS -i http://127.0.0.1:$BACKEND_PORT/ | head -8"
note "no TLS, no certificate, no verification. That is normal for a backend"
note "on loopback, and a serious problem the moment it moves to another host"

say "9. what the backend is told about the client"
run "curl -sS https://$NAME/ | grep -i 'backend' "
run "journalctl -u lab-app.service -n 5 --no-pager | tail -5"
note "the backend logs 127.0.0.1 for every request, because every request"
note "genuinely arrives from nginx. X-Forwarded-For is the only record of who"
note "really asked, and it is a header, which means it can be forged unless"
note "the backend is told which proxies to believe"

say "10. the redirect, as a client sees it"
run "curl -sS -i http://$NAME/ | head -5"
note "301 is permanent and gets cached by everything. Correct here, and the"
note "reason a mistaken 301 is so hard to withdraw"

# ---------------------------------------------------------------------------
say "11. SELinux, and the boolean this all depends on"
run "getenforce; getsebool httpd_can_network_connect; ls -Z $CRT"
note "nginx runs as httpd_t. Without that boolean it may not open a socket to"
note "anything, including 127.0.0.1, and the symptom is a 502 with"
note "'Permission denied' in the error log - not the word SELinux anywhere"

say "12. the logs worth knowing by path"
run "tail -n 3 /var/log/nginx/lab-proxy.access.log 2>/dev/null; tail -n 3 /var/log/nginx/lab-proxy.error.log 2>/dev/null || echo '(error log empty - good)'"
note "access log: what clients asked for. error log: what nginx could not do"
note "about it. The upstream failures only ever appear in the second one"

printf '\nThat is the tour. Now break it:  sudo ./scripts/break-and-fix.sh\n'
