#!/usr/bin/env bash
#
# Day 17 — Reverse proxy and TLS termination
# Run this on: VM: node1
#
# Exits 0 only when every automatic check passes. Items printed as
# YOU are judgement calls and never affect the exit status.

set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=../../lab/verify-lib.sh
source "../../lab/verify-lib.sh"

vl_init "Day 17 — Reverse proxy and TLS termination"
vl_need nginx curl

vl_check "the nginx config is valid" 'nginx -t'
vl_check "nginx is running and enabled" 'systemctl is-active nginx && systemctl is-enabled nginx'
vl_check "HTTPS works and verifies against your CA" 'curl -sf --cacert /etc/pki/ca-trust/source/anchors/lab-ca.crt https://www.lab.test/ >/dev/null'
vl_check "plain HTTP redirects instead of serving" '[ "$(curl -s -o /dev/null -w %{http_code} http://www.lab.test/)" -ge 301 ]'
vl_check "obsolete TLS versions are refused" '! openssl s_client -connect www.lab.test:443 -tls1_1 </dev/null 2>/dev/null | grep -q BEGIN'
vl_check "the backend is not reachable from outside" '! curl -sf --max-time 3 http://www.lab.test:8080/ >/dev/null'
vl_manual "you hit an SELinux denial on proxy_pass and fixed it with a boolean"

vl_summary
