#!/usr/bin/env bash
#
# lab-tls - what a client actually checked, and why it said yes or no.
#
#   lab-tls                        # the lab server on 127.0.0.1:4433
#   lab-tls HOST:PORT              # any TLS server, expecting HOST's name
#   lab-tls HOST:PORT NAME         # ask that server for NAME instead
#
# Three questions get answered separately here, because they fail separately:
#
#   1. does the chain lead to something I trust
#   2. is the certificate valid right now
#   3. does the name I asked for appear in it
#
# Almost every certificate incident is one of those three, and the error
# messages in the wild rarely say which.

set -uo pipefail

CA_DIR="/etc/lab-tls"
CAFILE="$CA_DIR/ca.crt"

target="${1:-127.0.0.1:4433}"
host="${target%%:*}"
name="${2:-}"
if [[ -z "$name" ]]; then
  if [[ "$host" == "127.0.0.1" || "$host" == "localhost" ]]; then
    name="www.lab.test"
  else
    name="$host"
  fi
fi

command -v openssl >/dev/null 2>&1 || { echo "openssl is missing" >&2; exit 1; }

printf '\n--- %s, asking for the name %s ---\n\n' "$target" "$name"

ca_args=()
if [[ -s "$CAFILE" ]]; then
  ca_args=(-CAfile "$CAFILE")
  printf 'trusting: %s\n\n' "$CAFILE"
else
  printf 'trusting: the system store only (%s is not there)\n\n' "$CAFILE"
fi

# One handshake, kept for every question below. Re-connecting per question
# would let the answers disagree with each other.
out="$(echo | openssl s_client -connect "$target" -servername "$name" \
  -verify_hostname "$name" "${ca_args[@]}" -showcerts 2>&1)"

if ! printf '%s' "$out" | grep -q "Certificate chain\|SSL-Session"; then
  echo "no TLS handshake at all. What came back:"
  printf '%s\n' "$out" | head -5 | sed 's/^/  /'
  echo
  echo "That is a connection problem, not a certificate problem - nothing was"
  echo "presented to check. Day 09's tools are the ones for this."
  exit 1
fi

# --- what the server presented ------------------------------------------
leaf="$(printf '%s' "$out" | sed -n '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' | head -30)"

if [[ -n "$leaf" ]]; then
  printf 'presented certificate\n'
  printf '%s' "$leaf" | openssl x509 -noout -subject -issuer 2>/dev/null | sed 's/^/  /'
  printf '%s' "$leaf" | openssl x509 -noout -dates 2>/dev/null | sed 's/^/  /'
  san="$(printf '%s' "$leaf" | openssl x509 -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' ')"
  printf '  names:   %s\n' "${san:-none - and a certificate with no SAN matches nothing}"
  printf '\n'
fi

depth="$(printf '%s' "$out" | grep -c '^ *[0-9] s:' || true)"
printf 'chain depth: %s certificate(s) sent by the server\n' "${depth:-0}"
if [[ "${depth:-0}" -le 1 ]]; then
  printf '  (a leaf on its own. Fine here, because our CA is trusted directly.\n'
  printf '   In production a missing intermediate looks exactly like this, and\n'
  printf '   it works on your laptop because your laptop cached the missing one.)\n'
fi
printf '\n'

# --- the verdict, split into its three parts -----------------------------
code="$(printf '%s' "$out" | sed -n 's/.*Verify return code: \(.*\)/\1/p' | tail -1)"
printf 'verdict: %s\n\n' "${code:-unknown}"

case "${code:-}" in
  "0 (ok)")
    echo "  chain     ok - it leads to a certificate this client was told to trust"
    echo "  dates     ok - valid right now"
    echo "  hostname  ok - $name appears in the certificate"
    ;;
  *"unable to get local issuer"*|*"self signed"*|*"self-signed"*)
    echo "  chain     FAILED - the client does not trust whoever signed this"
    echo
    echo "  Nothing is wrong with the certificate. This is the client's own"
    echo "  trust configuration, and the fix is on the client side:"
    echo "      openssl s_client -connect $target -CAfile $CAFILE"
    ;;
  *"expired"*)
    echo "  dates     FAILED - the certificate is out of date"
    printf '%s' "$leaf" | openssl x509 -noout -dates 2>/dev/null | sed 's/^/            /'
    echo
    echo "  Check the clock before you re-issue anything. A machine whose time"
    echo "  is wrong reports every certificate as expired or not-yet-valid, and"
    echo "  re-issuing will not fix that."
    ;;
  *"Hostname mismatch"*|*"hostname mismatch"*)
    echo "  hostname  FAILED - the chain and the dates are fine"
    echo
    echo "  The certificate is genuine and trusted. It is simply for a different"
    echo "  name than the one you asked for, and no amount of re-issuing the CA"
    echo "  will help. Compare the names above with '$name'."
    ;;
  *)
    echo "  something else. The relevant lines:"
    printf '%s\n' "$out" | grep -E "verify error|Verify return code" | sed 's/^/    /'
    ;;
esac

printf '\n'
