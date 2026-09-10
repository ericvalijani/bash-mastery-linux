#!/usr/bin/env bash
#
# Day 10 break-and-fix - five certificate failures, and the one line in each
# that tells you which of them you are looking at.
#
# Every case here is a real handshake against a real server. None of the
# certificates involved is corrupt; four of the five are validly signed by an
# authority the client trusts, and they still fail.
#
#   ./break-and-fix.sh          three that name themselves clearly
#   ./break-and-fix.sh --hard   two that get blamed on the wrong thing
#
# The good server is restored before this script exits, including on Ctrl-C.

set -uo pipefail

CA_DIR="/etc/lab-tls"
RUN_DIR="/run/lab-tls"
PIDFILE="$RUN_DIR/s_server.pid"
PORT="4433"
NAME="www.lab.test"
OTHER="other.lab.test"

say()  { printf '\n=== %s ===\n\n' "$*"; }
die()  { echo "$*" >&2; exit 1; }
note() { printf '  (%s)\n\n' "$1"; }
run_sh() { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/  /' || true; printf '\n'; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "needs root:  sudo $0"
[[ -s "$CA_DIR/ca.crt" ]] || die "no CA yet - run: sudo ./days/day10/scripts/setup.sh"

HARD="no"
[[ "${1:-}" == "--hard" ]] && HARD="yes"

# serve CERT KEY - restart the listener with a chosen certificate.
# Each case swaps the certificate rather than editing one, so nothing here can
# leave a half-written file behind.
serve() {
  local crt="$1" key="$2" pid
  if [[ -f "$PIDFILE" ]]; then
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      sleep 1
    fi
  fi
  nohup openssl s_server -accept "$PORT" -naccept 200 -cert "$crt" -key "$key" -www \
    >"$RUN_DIR/s_server.log" 2>&1 &
  echo $! > "$PIDFILE"
  sleep 1
}

restore() {
  serve "$CA_DIR/server.crt" "$CA_DIR/server.key" 2>/dev/null || true
}
trap restore EXIT INT TERM

# The verdict line, and nothing else. Every case below is read through this
# one function so the cases are comparable.
verdict() {
  local host_name="$1"
  shift
  echo | openssl s_client -connect "127.0.0.1:$PORT" -servername "$host_name" \
    -verify_hostname "$host_name" "$@" 2>&1 |
    grep -E "verify error|Verify return code" | sed 's/^/  /' | sort -u
  printf '\n'
}

# ---------------------------------------------------------------------------
say "1. the client has never heard of your CA"

serve "$CA_DIR/server.crt" "$CA_DIR/server.key"
echo "$ openssl s_client ... (no -CAfile)"
verdict "$NAME"
note "unable to get local issuer certificate - nothing is wrong with the server"

echo "  This is the most common certificate error in existence and it is not a"
echo "  certificate error. The server is perfect. The client was never told"
echo "  who to trust, and the fix belongs entirely on the client side."
echo
echo "$ openssl s_client ... -CAfile $CA_DIR/ca.crt"
verdict "$NAME" -CAfile "$CA_DIR/ca.crt"
echo "  fixed - and the server was never touched."

# ---------------------------------------------------------------------------
say "2. the certificate is for a different name"

serve "$CA_DIR/wrongname.crt" "$CA_DIR/wrongname.key"
verdict "$NAME" -CAfile "$CA_DIR/ca.crt"
run_sh "openssl x509 -in $CA_DIR/wrongname.crt -noout -ext subjectAltName"
note "Hostname mismatch: trusted chain, valid dates, wrong name"

echo "  Re-issuing the CA will not help, restarting will not help, and the"
echo "  certificate is genuine. The only fix is a certificate whose SAN"
echo "  contains $NAME - or asking for the name it actually has:"
echo
verdict "$OTHER" -CAfile "$CA_DIR/ca.crt"
serve "$CA_DIR/server.crt" "$CA_DIR/server.key"
echo "  fixed by serving the right certificate."

# ---------------------------------------------------------------------------
say "3. the certificate expired yesterday"

serve "$CA_DIR/expired.crt" "$CA_DIR/expired.key"
verdict "$NAME" -CAfile "$CA_DIR/ca.crt"
run_sh "openssl x509 -in $CA_DIR/expired.crt -noout -dates"
note "certificate has expired - and it was signed by a CA you trust"

echo "  Two things to check before re-issuing, in this order. First the"
echo "  clock: 'date -u'. A machine an hour off is unusual, a machine a year"
echo "  off happens after a dead battery, and it reports every certificate in"
echo "  the world as invalid. Second the dates above. Re-issuing on a machine"
echo "  with a wrong clock produces a certificate that is broken everywhere"
echo "  else instead."
run_sh "date -u"
serve "$CA_DIR/server.crt" "$CA_DIR/server.key"
echo "  fixed by serving the in-date certificate."

if [[ "$HARD" != "yes" ]]; then
  cat <<'EOF'

Three failures, each of which says what it is if you read the verify line.

The two that lie about themselves are behind --hard:

  sudo ./days/day10/scripts/break-and-fix.sh --hard
EOF
  exit 0
fi

# ---------------------------------------------------------------------------
say "4. --hard: the key does not match the certificate"

# A perfectly valid certificate and a perfectly valid key that were never a
# pair. This happens when one of the two is copied and the other is not.
serve "$CA_DIR/server.crt" "$CA_DIR/wrongname.key"

if kill -0 "$(cat "$PIDFILE" 2>/dev/null || echo 0)" 2>/dev/null; then
  verdict "$NAME" -CAfile "$CA_DIR/ca.crt"
else
  echo "  the server refused to start at all. Its own words:"
  grep -iE "key values mismatch|error|unable" "$RUN_DIR/s_server.log" 2>/dev/null |
    head -3 | sed 's/^/    /'
  printf '\n'
fi

note "key values mismatch - and notice this failure is on the SERVER"

echo "  Every failure so far was a client refusing something. This one is"
echo "  different: the service does not come up, and the log line names the"
echo "  cause in words nobody recognises. The check that would have caught it"
echo "  takes two seconds and is the first thing to run when a web server dies"
echo "  after a certificate renewal:"
echo
run_sh "openssl x509 -noout -modulus -in $CA_DIR/server.crt | openssl md5"
run_sh "openssl rsa -noout -modulus -in $CA_DIR/wrongname.key | openssl md5"
echo "  Different hashes, so those two files are not a pair. The matching key"
echo "  gives the same hash as the certificate:"
run_sh "openssl rsa -noout -modulus -in $CA_DIR/server.key | openssl md5"
serve "$CA_DIR/server.crt" "$CA_DIR/server.key"
echo "  fixed by pairing the files that belong together."

# ---------------------------------------------------------------------------
say "5. --hard: it works in the browser and fails in the script"

# The system trust store, which the CA was never added to. A browser or a
# colleague's laptop may already hold this CA; a fresh container does not.
serve "$CA_DIR/server.crt" "$CA_DIR/server.key"

echo "$ ... -CAfile $CA_DIR/ca.crt      (told who to trust)"
verdict "$NAME" -CAfile "$CA_DIR/ca.crt"
echo "$ ... system trust store only        (told nothing)"
verdict "$NAME"

echo "  The same server, the same certificate, the same second, two different"
echo "  verdicts. Nothing about the certificate decided this - trust is a"
echo "  property of the client, and every client has its own store:"
echo
echo "    openssl / curl    /etc/ssl/certs or /etc/pki/tls/certs"
echo "    Java              its own cacerts keystore"
echo "    Python requests   certifi, bundled with the package"
echo "    Firefox           its own store, ignoring the system entirely"
echo
echo "  Which is why 'it works on my machine' is a real answer here and not an"
echo "  excuse. To make it work for everything on this host, the CA has to go"
echo "  into the system store - Day 17 does exactly that:"
echo
echo "    RHEL family:     cp ca.crt /etc/pki/ca-trust/source/anchors/ && update-ca-trust"
echo "    Debian/Ubuntu:   cp ca.crt /usr/local/share/ca-certificates/lab-ca.crt && update-ca-certificates"
echo
echo "  Nothing was installed just now. Today stays inside $CA_DIR."

cat <<'EOF'

Five failures, and the good server is back.

  no CAfile          the client's trust, not the server's certificate
  hostname mismatch  a genuine certificate for a name you did not ask for
  expired            check the clock before you re-issue
  key mismatch       the only one that stops the server starting
  system store       two clients, same certificate, different answers

Only one of those five was fixed by touching a certificate.

Check yourself:  sudo ./days/day10/verify.sh
EOF
