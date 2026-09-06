#!/usr/bin/env bash
#
# Day 10 — TLS on the wire and a private CA
# Run this on: Host: network namespaces
#
# Exits 0 only when every automatic check passes. Items printed as
# YOU are judgement calls and never affect the exit status.

set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=../../lab/verify-lib.sh
source "../../lab/verify-lib.sh"

vl_init "Day 10 — TLS on the wire and a private CA"
vl_need openssl
vl_need_root

vl_check "a CA certificate exists and is marked as a CA" 'openssl x509 -in ca/ca.crt -noout -text | grep -q "CA:TRUE"'
vl_check "a server certificate carries a subjectAltName" 'openssl x509 -in ca/server.crt -noout -text | grep -q "Subject Alternative Name"'
vl_check "the server certificate verifies against the CA" 'openssl verify -CAfile ca/ca.crt ca/server.crt'
vl_check "the private key matches the certificate" '[ "$(openssl x509 -noout -modulus -in ca/server.crt 2>/dev/null | openssl md5)" = "$(openssl rsa -noout -modulus -in ca/server.key 2>/dev/null | openssl md5)" ]'
vl_manual "you can read an s_client chain and say why it was trusted or refused"
vl_manual "you made verification fail on purpose, by hostname and by expiry"

vl_summary
