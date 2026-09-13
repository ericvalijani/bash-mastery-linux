#!/usr/bin/env bash
#
# Day 17 — Reverse proxy and TLS termination
# Run this on: node1, WITH sudo
#
# Exits 0 only when every automatic check passes. Items printed as
# YOU are judgement calls and never affect the exit status.

set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=../../lab/verify-lib.sh
source "../../lab/verify-lib.sh"

NAME="${LAB_SITE:-www.lab.test}"
BACKEND_PORT="${LAB_BACKEND_PORT:-8080}"
CA="/etc/lab-tls/ca.crt"
CRT="/etc/pki/tls/certs/$NAME.crt"
KEY="/etc/pki/tls/private/$NAME.key"

vl_init "Day 17 — Reverse proxy and TLS termination"
vl_need nginx openssl curl ss systemctl
vl_need_root

# --- the two halves are running ------------------------------------------
vl_check "nginx is enabled, so the site survives a reboot" "systemctl is-enabled --quiet nginx"
vl_check "nginx is running right now" "systemctl is-active --quiet nginx"
vl_check "the backend unit is active" "systemctl is-active --quiet lab-app.service"
# The whole privacy model of the backend: loopback only, nothing else.
# Collect the listening addresses here rather than inside the quoted command,
# so the check itself stays a plain string comparison.
BACKEND_LISTEN="$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep ":$BACKEND_PORT\$" | sort | tr '\n' ' ')"
vl_check "the backend listens on 127.0.0.1:$BACKEND_PORT and nowhere else" "[ \"$BACKEND_LISTEN\" = \"127.0.0.1:$BACKEND_PORT \" ]"
vl_check "something is listening on 443" "ss -tlnH 'sport = :443' | grep -q ':443'"

# --- the configuration ----------------------------------------------------
vl_check "the running configuration parses" "nginx -t"
vl_check "nginx proxies to the backend instead of serving files" "nginx -T 2>/dev/null | grep -q 'proxy_pass http://127.0.0.1:$BACKEND_PORT'"
vl_check "the backend is told who the client was" "nginx -T 2>/dev/null | grep -q 'X-Forwarded-For'"

# --- the certificate ------------------------------------------------------
# subjectAltName is the field clients match. CN is decoration.
vl_check "the certificate carries DNS:$NAME in subjectAltName" "openssl x509 -in $CRT -noout -ext subjectAltName 2>/dev/null | grep -q 'DNS:$NAME'"
vl_check "it is signed by our CA and still in date" "openssl verify -CAfile $CA $CRT && openssl x509 -in $CRT -noout -checkend 86400"
# openssl verify never checks this, and a mismatched pair stops nginx dead.
vl_check "the certificate and the key are a pair" "[ \"\$(openssl x509 -noout -modulus -in $CRT | openssl md5)\" = \"\$(openssl rsa -noout -modulus -in $KEY 2>/dev/null | openssl md5)\" ]"
vl_check "the private key is 0600" "[ \"\$(stat -c %a $KEY)\" = 600 ]"

# --- end to end, as a client ----------------------------------------------
# No --cacert: this passes only because the CA is in the system trust store.
vl_check "https://$NAME/ verifies against the system trust store" "curl -sf -o /dev/null https://$NAME/"
vl_check "the body came from the backend, so the proxy hop works" "curl -sf https://$NAME/ | grep -q LAB-BACKEND-OK"
vl_check "plain http answers 301, not content" "[ \"\$(curl -sS -o /dev/null -w '%{http_code}' http://$NAME/)\" = 301 ]"
vl_check "a full handshake verifies the hostname too" "echo | openssl s_client -connect 127.0.0.1:443 -servername $NAME -verify_hostname $NAME -CAfile $CA 2>&1 | grep -q 'Verify return code: 0 (ok)'"

# --- the two that only bite later ----------------------------------------
# nginx runs as httpd_t; without this boolean every upstream connect() is
# denied and the only symptom is a 502.
vl_check "httpd_can_network_connect is on, or SELinux is not enforcing" "[ \"\$(getenforce 2>/dev/null)\" != Enforcing ] || getsebool httpd_can_network_connect | grep -q ' on\$'"
vl_check "80/tcp and 443/tcp are open permanently, not just until reload" "{ firewall-cmd --permanent --query-port=80/tcp || firewall-offline-cmd --query-port=80/tcp; } && { firewall-cmd --permanent --query-port=443/tcp || firewall-offline-cmd --query-port=443/tcp; }"
vl_check "$BACKEND_PORT/tcp is NOT open - the proxy reaches it over loopback" "! { firewall-cmd --permanent --query-port=$BACKEND_PORT/tcp || firewall-offline-cmd --query-port=$BACKEND_PORT/tcp; } >/dev/null 2>&1"

vl_manual "you can say exactly where TLS stops and what protects the hop after it"
vl_manual "you saw a 502 caused by SELinux and recognised it without being told"

if [[ ${#VL_MISSING[@]} -gt 0 ]]; then
	printf '\n  missing: %s\n' "${VL_MISSING[*]}"
	printf '  run this on node1, with sudo, after:\n'
	printf '    sudo ./days/day17/scripts/setup.sh\n'
fi

vl_summary
