#!/usr/bin/env bash
#
# Day 10 teardown - stop the TLS server and remove the lab CA.
#
# Nothing today was added to any system trust store, so there is nothing to
# untrust. That was deliberate: a CA you forgot you installed is a CA that
# can still sign for any name on this machine.

set -uo pipefail

say() { printf '\n==> %s\n' "$*"; }

CA_DIR="/etc/lab-tls"
RUN_DIR="/run/lab-tls"
PIDFILE="$RUN_DIR/s_server.pid"
PORT="4433"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "needs root:  sudo $0" >&2; exit 1; }

say "1. stopping the TLS server"

stopped="no"
if [[ -f "$PIDFILE" ]]; then
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    stopped="yes"
    echo "  stopped pid $pid"
  fi
  rm -f "$PIDFILE"
fi

# A pidfile only knows about servers a script started. One started by hand on
# the same port is just as real, so check the port rather than trusting the
# file - the same lesson as Day 08's stray daemons.
sleep 1
for pid in $(pgrep -f "s_server -accept $PORT" 2>/dev/null || true); do
  echo "  stopping a stray s_server (pid $pid) on port $PORT"
  kill "$pid" 2>/dev/null || true
  stopped="yes"
done
[[ "$stopped" == "yes" ]] || echo "  ok  nothing was listening"

say "2. proving the port is free"

sleep 1
if command -v ss >/dev/null 2>&1 && ss -tlpn 2>/dev/null | grep -q ":$PORT"; then
  echo "  something is STILL on $PORT:"
  ss -tlpn 2>/dev/null | grep ":$PORT" | sed 's/^/    /'
  echo "  Find it with:  sudo ss -tlpn | grep :$PORT"
else
  echo "  ok  port $PORT is free"
fi

say "3. removing the CA and its certificates"

if [[ -d "$CA_DIR" ]]; then
  certs="$(find "$CA_DIR" -maxdepth 1 -name '*.crt' 2>/dev/null | wc -l | tr -d ' ')"
  keys="$(find "$CA_DIR" -maxdepth 1 -name '*.key' 2>/dev/null | wc -l | tr -d ' ')"
  rm -rf "$CA_DIR"
  echo "  removed $CA_DIR - $certs certificates and $keys private keys"
  echo
  echo "  Deleting the CA key is final. Every certificate it signed is now"
  echo "  unrenewable, which in a real environment is an outage with a date on"
  echo "  it rather than an immediate one: things keep working until they"
  echo "  expire, and then nothing can re-issue them."
else
  echo "  ok  nothing to remove"
fi

rm -f /usr/local/bin/lab-tls
rm -rf "$RUN_DIR"
echo "  removed /usr/local/bin/lab-tls and $RUN_DIR"

say "4. what was never touched"
cat <<'EOF'
The system trust store. Today's CA was only ever passed explicitly with
-CAfile, so no client on this machine trusts it now and none did before.

Day 17 is the day that installs a CA for real, and it has to remove it again
for the same reason.
EOF

printf '\nDay 10 removed.\n\n'
