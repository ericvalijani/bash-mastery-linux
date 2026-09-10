#!/usr/bin/env bash
#
# Day 10 - run your own CA, and know what a client actually verifies.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../../lab/verify-lib.sh"

vl_init "Day 10 - TLS on the wire and a private CA"
vl_need openssl
vl_need_root

vl_check "a CA certificate exists and is marked as a CA" \
  'openssl x509 -in /etc/lab-tls/ca.crt -noout -text | grep -q "CA:TRUE"'

vl_check "a server certificate carries a subjectAltName for www.lab.test" \
  'openssl x509 -in /etc/lab-tls/server.crt -noout -ext subjectAltName 2>/dev/null | grep -q "www.lab.test"'

vl_check "the server certificate verifies against the CA" \
  'openssl verify -CAfile /etc/lab-tls/ca.crt /etc/lab-tls/server.crt >/dev/null 2>&1'

vl_check "the private key matches the certificate" \
  '[ "$(openssl x509 -noout -modulus -in /etc/lab-tls/server.crt 2>/dev/null | openssl md5)" = "$(openssl rsa -noout -modulus -in /etc/lab-tls/server.key 2>/dev/null | openssl md5)" ]'

vl_check "the CA key is readable only by root" \
  '[ "$(stat -c %a /etc/lab-tls/ca.key 2>/dev/null)" = "600" ]'

vl_check "a handshake on 127.0.0.1:4433 verifies with the CA and the hostname" \
  'echo | openssl s_client -connect 127.0.0.1:4433 -servername www.lab.test -verify_hostname www.lab.test -CAfile /etc/lab-tls/ca.crt 2>&1 | grep -q "Verify return code: 0 (ok)"'

vl_check "the same handshake is refused when no CA is supplied" \
  '! echo | openssl s_client -connect 127.0.0.1:4433 -servername www.lab.test 2>&1 | grep -q "Verify return code: 0 (ok)"'

vl_manual "you can read an s_client chain and say why it was trusted or refused"
vl_manual "you made verification fail on purpose, by hostname and by expiry"

vl_summary
