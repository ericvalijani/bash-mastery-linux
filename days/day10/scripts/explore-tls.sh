#!/usr/bin/env bash
#
# Day 10 tour - twelve looks at three certificates that came from the same
# authority, one minute apart, and behave completely differently.
#
# Read-only. Nothing here issues, installs or changes anything.

set -uo pipefail

CA_DIR="/etc/lab-tls"
PORT="4433"

say()  { printf '\n=== %s ===\n\n' "$*"; }
note() { printf '  (%s)\n\n' "$1"; }
run_sh() { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/  /' || true; printf '\n'; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "needs root:  sudo $0" >&2; exit 1; }
[[ -s "$CA_DIR/ca.crt" ]] ||
  { echo "no CA yet - run: sudo ./days/day10/scripts/setup.sh" >&2; exit 1; }

say "1. a certificate is a text file anyone can read"
run_sh "openssl x509 -in $CA_DIR/server.crt -noout -subject -issuer -dates"
note "Public by design - it is the key beside it that is secret"

say "2. the CA vouches for itself"
run_sh "openssl x509 -in $CA_DIR/ca.crt -noout -subject -issuer"
note "Subject equals issuer: that is what self-signed means, and every chain ends this way"

say "3. what makes it allowed to sign at all"
run_sh "openssl x509 -in $CA_DIR/ca.crt -noout -ext basicConstraints,keyUsage"
note "CA:TRUE. Without it a client refuses to accept its signature on anything"

say "4. the leaf is forbidden from signing"
run_sh "openssl x509 -in $CA_DIR/server.crt -noout -ext basicConstraints,extendedKeyUsage"
note "CA:FALSE plus serverAuth - it can prove a name and nothing else"

say "5. the field that decides hostname matching"
run_sh "openssl x509 -in $CA_DIR/server.crt -noout -ext subjectAltName"
run_sh "openssl x509 -in $CA_DIR/wrongname.crt -noout -ext subjectAltName"
note "Two certificates, same CA, same dates - only these lines differ"

say "6. verify checks the chain, and only the chain"
run_sh "openssl verify -CAfile $CA_DIR/ca.crt $CA_DIR/server.crt $CA_DIR/wrongname.crt"
note "wrongname passes here. verify was never asked about a hostname"

say "7. dates are checked, though"
run_sh "openssl verify -CAfile $CA_DIR/ca.crt $CA_DIR/expired.crt"
run_sh "openssl x509 -in $CA_DIR/expired.crt -noout -dates"
note "Correctly signed by a trusted CA, and refused anyway"

say "8. the key and the certificate must be one pair"
run_sh "openssl x509 -noout -modulus -in $CA_DIR/server.crt | openssl md5"
run_sh "openssl rsa -noout -modulus -in $CA_DIR/server.key | openssl md5"
note "Same hash, same pair. This is the check to run before a confusing restart"

say "9. a real handshake, verified"
run_sh "echo | openssl s_client -connect 127.0.0.1:$PORT -servername www.lab.test -verify_hostname www.lab.test -CAfile $CA_DIR/ca.crt 2>&1 | grep -E 'Verify return code|Cipher is|Protocol'"
note "Verify return code 0 is the only line that means trusted"

say "10. the same server, with no CA supplied"
run_sh "echo | openssl s_client -connect 127.0.0.1:$PORT -servername www.lab.test 2>&1 | grep -E 'verify error|Verify return code'"
note "The certificate did not change. The client's trust did"

say "11. the same server, asked for a name it does not have"
run_sh "echo | openssl s_client -connect 127.0.0.1:$PORT -servername other.lab.test -verify_hostname other.lab.test -CAfile $CA_DIR/ca.crt 2>&1 | grep -E 'verify error|Verify return code'"
note "Trusted chain, valid dates, wrong name - a third kind of failure"

say "12. the payload separates those three for you"
run_sh "lab-tls 127.0.0.1:$PORT other.lab.test | tail -12"
note "Chain, dates, hostname - named individually, because they fail individually"

cat <<'EOF'
Three certificates, one authority, one minute of work apart.

  server.crt      trusted, in date, right name    works
  expired.crt     trusted, right name, out of date  refused by every client
  wrongname.crt   trusted, in date, other name    refused by every client

The last two are not broken files. They are properly signed certificates
that answer a question nobody asked, and they are what real certificate
incidents look like. "Invalid certificate" almost never means invalid.

Next:  sudo ./days/day10/scripts/break-and-fix.sh
EOF
