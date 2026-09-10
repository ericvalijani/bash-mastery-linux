#!/usr/bin/env bash
#
# Day 10 setup - one certificate authority, four certificates, one TLS server.
#
# No namespaces and no VM today. TLS does not care about topology; it cares
# about names, dates and signatures, and all three can be got wrong on a
# single machine talking to itself.
#
# What gets built, all of it under /etc/lab-tls:
#
#   ca.crt / ca.key        the authority. Self-signed, and the only thing a
#                          client has to be told to trust.
#   server.crt/.key        good: signed by the CA, SAN www.lab.test
#   expired.crt/.key       signed by the same CA, but valid until yesterday
#   wrongname.crt/.key     signed by the same CA, SAN other.lab.test
#
# The last two are the day. A certificate that is wrong is not a certificate
# that is broken - all three below are validly signed by an authority the
# client trusts, and two of them still fail.
#
# Run it on the machine you are reading this on.
#
# Idempotent: existing certificates are reused unless you pass --fresh.

set -euo pipefail

HERE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say()  { printf '\n==> %s\n' "$*"; }
die()  { echo "$*" >&2; exit 1; }

CA_DIR="/etc/lab-tls"
RUN_DIR="/run/lab-tls"
PIDFILE="$RUN_DIR/s_server.pid"
PORT="4433"
SERVER_NAME="www.lab.test"
OTHER_NAME="other.lab.test"

FRESH="no"
[[ "${1:-}" == "--fresh" ]] && FRESH="yes"

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "needs root:  sudo $0"

# ---------------------------------------------------------------------------
say "0. checking what this day needs"

command -v openssl >/dev/null 2>&1 || die "openssl is missing:
  RHEL family:     sudo dnf install -y openssl
  Debian/Ubuntu:   sudo apt-get install -y openssl"

echo "ok    $(openssl version)"

# ---------------------------------------------------------------------------
say "1. making room for the CA"

if [[ "$FRESH" == "yes" && -d "$CA_DIR" ]]; then
  echo "--fresh: removing the old $CA_DIR"
  rm -rf "$CA_DIR"
fi

# 0700 on the directory, and every key written 0600 below. A private key that
# anyone can read is not private, and the CA key is the worst one to lose:
# whoever holds it can issue a certificate for any name you trust it for.
install -d -m 0700 "$CA_DIR"
install -d -m 0755 "$RUN_DIR"
echo "ok    $CA_DIR exists, mode 0700"

# ---------------------------------------------------------------------------
say "2. the certificate authority"

if [[ -s "$CA_DIR/ca.crt" && -s "$CA_DIR/ca.key" ]]; then
  echo "ok    reusing the existing CA (pass --fresh to start over)"
else
  # -newkey with -x509 in one step: a self-signed certificate. Self-signed is
  # not a flaw here - it is what an authority IS. The chain has to stop
  # somewhere, and it stops at something that vouches for itself.
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$CA_DIR/ca.key" -out "$CA_DIR/ca.crt" \
    -subj "/CN=Bash Mastery Lab CA/O=Lab" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
  chmod 0600 "$CA_DIR/ca.key"
  chmod 0644 "$CA_DIR/ca.crt"
  echo "ok    ca.crt, self-signed, CA:TRUE, valid 10 years"
fi

openssl x509 -in "$CA_DIR/ca.crt" -noout -text | grep -q "CA:TRUE" ||
  die "the CA certificate is not marked CA:TRUE - it cannot sign anything"

# ---------------------------------------------------------------------------
say "3. three certificates from the same authority"

# issue NAME SAN DAYS_BACKDATED
# One function, three certificates. The only differences between them are a
# name and a date, which is exactly the point: nothing below is misconfigured
# or corrupt. All three are properly signed.
issue() {
  local base="$1" san="$2" days="$3"
  local key="$CA_DIR/$base.key" crt="$CA_DIR/$base.crt" csr="$CA_DIR/$base.csr"

  if [[ -s "$crt" && -s "$key" ]]; then
    echo "ok    reusing $base.crt"
    return 0
  fi

  openssl req -newkey rsa:2048 -nodes -keyout "$key" -out "$csr" \
    -subj "/CN=$san/O=Lab" 2>/dev/null

  # The SAN is what a modern client actually reads. CN has been ignored for
  # hostname matching for years, which is why a certificate can look right in
  # every human-readable field and still be refused.
  printf 'subjectAltName=DNS:%s,DNS:localhost,IP:127.0.0.1\n' "$san" \
    > "$CA_DIR/$base.ext"
  printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' \
    >> "$CA_DIR/$base.ext"

  if [[ "$days" == "expired" ]]; then
    # -not_after in the past. openssl will happily sign a certificate that was
    # never valid; nothing checks dates at signing time, only at use time.
    local yesterday
    yesterday="$(date -u -d 'yesterday' +%Y%m%d%H%M%SZ 2>/dev/null || date -u -v-1d +%Y%m%d%H%M%SZ)"
    openssl x509 -req -in "$csr" -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" \
      -CAcreateserial -sha256 -extfile "$CA_DIR/$base.ext" \
      -not_before "$(date -u -d '30 days ago' +%Y%m%d%H%M%SZ 2>/dev/null || date -u -v-30d +%Y%m%d%H%M%SZ)" \
      -not_after "$yesterday" -out "$crt" 2>/dev/null ||
      openssl x509 -req -in "$csr" -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" \
        -CAcreateserial -sha256 -extfile "$CA_DIR/$base.ext" \
        -days -1 -out "$crt" 2>/dev/null
  else
    openssl x509 -req -in "$csr" -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" \
      -CAcreateserial -sha256 -extfile "$CA_DIR/$base.ext" \
      -days "$days" -out "$crt" 2>/dev/null
  fi

  [[ -s "$crt" ]] || die "could not issue $base.crt"
  chmod 0600 "$key"
  chmod 0644 "$crt"
  echo "ok    $base.crt  SAN $san"
}

issue "server"    "$SERVER_NAME" 365
issue "wrongname" "$OTHER_NAME"  365
issue "expired"   "$SERVER_NAME" "expired"

# ---------------------------------------------------------------------------
say "4. asking the CA to check its own work"

openssl verify -CAfile "$CA_DIR/ca.crt" "$CA_DIR/server.crt" >/dev/null 2>&1 ||
  die "server.crt does not verify against ca.crt, which should be impossible
  here - the CA just signed it. Re-run with --fresh."
echo "ok    server.crt verifies against ca.crt"

if openssl verify -CAfile "$CA_DIR/ca.crt" "$CA_DIR/expired.crt" >/dev/null 2>&1; then
  echo "      note: expired.crt verified, so this openssl ignored the dates"
else
  echo "ok    expired.crt does NOT verify - correctly signed, and still refused"
fi

# wrongname.crt verifies perfectly. It has to: the signature is real and the
# dates are fine. Nothing about a name mismatch is visible to 'verify', which
# only checks the chain. The hostname is checked by the CLIENT, later.
if openssl verify -CAfile "$CA_DIR/ca.crt" "$CA_DIR/wrongname.crt" >/dev/null 2>&1; then
  echo "ok    wrongname.crt verifies too - the chain is fine, the NAME is not"
fi

mod_crt="$(openssl x509 -noout -modulus -in "$CA_DIR/server.crt" | openssl md5)"
mod_key="$(openssl rsa -noout -modulus -in "$CA_DIR/server.key" 2>/dev/null | openssl md5)"
[[ "$mod_crt" == "$mod_key" ]] ||
  die "server.key does not match server.crt - a server started with these
  two would refuse to come up at all"
echo "ok    server.key matches server.crt (same modulus)"

# ---------------------------------------------------------------------------
say "5. a TLS server, listening on 127.0.0.1:$PORT"

# Stop anything this day started earlier. A pidfile alone is not enough - a
# server started by hand and forgotten owns the port just as firmly - so the
# port itself is the thing we check afterwards.
if [[ -f "$PIDFILE" ]]; then
  old="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then
    kill "$old" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$PIDFILE"
fi

# -www makes s_server answer a plain HTTP request with a status page, which is
# enough to prove a handshake completed rather than merely started.
nohup openssl s_server -accept "$PORT" -naccept 200 \
  -cert "$CA_DIR/server.crt" -key "$CA_DIR/server.key" -www \
  >"$RUN_DIR/s_server.log" 2>&1 &
echo $! > "$PIDFILE"
sleep 1

kill -0 "$(cat "$PIDFILE")" 2>/dev/null ||
  die "the TLS server did not stay up. Its output:
$(sed 's/^/    /' "$RUN_DIR/s_server.log" 2>/dev/null | head -10)"

echo "ok    openssl s_server is up, pid $(cat "$PIDFILE")"

# ---------------------------------------------------------------------------
say "6. one handshake, checked properly"

# -verify_return_error turns a verification failure into a failed command
# instead of a warning buried in output nobody reads.
out="$(echo | openssl s_client -connect "127.0.0.1:$PORT" \
  -servername "$SERVER_NAME" -verify_hostname "$SERVER_NAME" \
  -CAfile "$CA_DIR/ca.crt" -verify_return_error 2>&1 || true)"

if printf '%s' "$out" | grep -q "Verify return code: 0 (ok)"; then
  echo "ok    the handshake verified: chain OK and hostname $SERVER_NAME matched"
else
  echo "$out" | grep -E "Verify return code|verify error" | sed 's/^/    /'
  die "the handshake did not verify, on a certificate this script just
  issued. Re-run with --fresh, and check the clock: TLS is a dated
  protocol and a wrong system time breaks every certificate at once."
fi

# Same server, same certificate, no CA supplied. This is the failure everyone
# has seen and nobody reads: the certificate is perfect, the client simply has
# not been told who to trust.
if echo | openssl s_client -connect "127.0.0.1:$PORT" -servername "$SERVER_NAME" \
  -verify_return_error 2>&1 | grep -q "Verify return code: 0 (ok)"; then
  echo "      note: it verified without -CAfile, so this CA is already trusted"
else
  echo "ok    without -CAfile the same handshake is refused - trust is the client's"
fi

# ---------------------------------------------------------------------------
say "7. installing lab-tls"
install -m 0755 "$HERE_DIR/lab-tls.sh" /usr/local/bin/lab-tls
echo "ok    /usr/local/bin/lab-tls"

cat <<EOF

One authority, three certificates, one server. Two of those certificates are
validly signed and still unusable, which is the day.

  sudo lab-tls                       # the server on 127.0.0.1:$PORT
  sudo lab-tls 127.0.0.1:$PORT $OTHER_NAME   # ask for a name it does not have

Then the tour:  sudo ./days/day10/scripts/explore-tls.sh
And break it:   sudo ./days/day10/scripts/break-and-fix.sh
                sudo ./days/day10/scripts/break-and-fix.sh --hard

Everything lives in $CA_DIR. The server keeps running until you
run the teardown, so you can come back to it.

Check yourself:  sudo ./days/day10/verify.sh
EOF
