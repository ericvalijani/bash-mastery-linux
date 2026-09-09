#!/usr/bin/env bash
#
# Day 07 break-and-fix - three DNS failures, then two that pass review.
#
# Every failure is repaired before the next one starts, and every symptom is
# named out loud. The skill today is not "fix DNS" - it is looking at one
# symptom and knowing which of the four layers to open first.
#
#   sudo ./break-and-fix.sh          # failures 1-3
#   sudo ./break-and-fix.sh --hard   # and the two subtle ones
#
# Everything it edits lives under /etc/netns/client/, so the host's own
# resolver configuration is never at risk.

set -uo pipefail

die()  { echo "$*" >&2; exit 1; }
step() { printf '\n=== %s ===\n\n' "$*"; }
show() { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/  /' || true; printf '\n'; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "needs root:  sudo $0"
command -v ip >/dev/null 2>&1 || die "missing ip"
command -v dig >/dev/null 2>&1 || die "missing dig - sudo dnf install -y bind-utils"

HARD="no"; [[ "${1:-}" == "--hard" ]] && HARD="yes"

CONF_DIR="/etc/netns/client"
RESOLVER_IP="10.10.1.2"
PIDFILE="/run/lab-nameserver.pid"

[[ -f "$CONF_DIR/resolv.conf" ]] || die "no $CONF_DIR/resolv.conf - run setup.sh first"
ip netns list | grep -qw client || die "no client namespace - run Day 06's setup.sh first"

# Keep pristine copies so each repair is exact rather than approximate.
BACKUP="/root/day07-backup"
mkdir -p "$BACKUP"
cp -a "$CONF_DIR/resolv.conf" "$BACKUP/resolv.conf"
cp -a "$CONF_DIR/nsswitch.conf" "$BACKUP/nsswitch.conf"
cp -a "$CONF_DIR/hosts" "$BACKUP/hosts"

# Two probes, because today the whole point is that they disagree.
dig_try() {
  local out
  out="$(ip netns exec client dig +short +time=2 +tries=1 "$1" 2>&1 | head -2 | tr '\n' ' ')"
  if [[ -z "${out// /}" ]]; then
    printf '  dig    %-16s -> (nothing)\n' "$1"
  else
    printf '  dig    %-16s -> %s\n' "$1" "$out"
  fi
}

getent_try() {
  local out
  out="$(ip netns exec client getent hosts "$1" 2>&1 | head -1)"
  if [[ -z "$out" ]]; then
    printf '  getent %-16s -> (nothing, exit 2)\n' "$1"
  else
    printf '  getent %-16s -> %s\n' "$1" "$out"
  fi
}

both() { dig_try "$1"; getent_try "$1"; printf '\n'; }

# ---------------------------------------------------------------------------
step "baseline - both tools working, and disagreeing on purpose"

both www.lab.test
echo "  The hosts file says 10.10.0.99. DNS says 10.10.2.2. Neither is broken."

# ---------------------------------------------------------------------------
step "failure 1 of 5 - nsswitch no longer consults files"

cat > "$CONF_DIR/nsswitch.conf" <<'EOF'
hosts:      dns
passwd:     files
group:      files
EOF

echo "  changed the client's nsswitch to 'hosts: dns' - no files at all."
echo
both www.lab.test

cat <<'EOF'
  Symptom: getent SUDDENLY AGREES WITH DIG.

  That is the failure mode nobody spots, because nothing errored. An entry
  you deliberately put in /etc/hosts - a pinned address, a temporary
  override during a migration - silently stopped being used, and the
  application quietly started talking to a different machine.

  When a hosts entry "does not work", read the hosts: line before you
  suspect the file.
EOF

cp -a "$BACKUP/nsswitch.conf" "$CONF_DIR/nsswitch.conf"
echo
echo "  repaired: files is back in front of dns."
both www.lab.test

# ---------------------------------------------------------------------------
step "failure 2 of 5 - the nameserver address is wrong"

cat > "$CONF_DIR/resolv.conf" <<EOF
nameserver 10.10.1.99
options timeout:2 attempts:1
EOF

echo "  pointed the client at 10.10.1.99, which nothing answers on."
echo
both www.lab.test
both auth.lab.test

cat <<'EOF'
  Symptom: SOME NAMES STILL WORK.

  www.lab.test resolved instantly - it never needed DNS, it is in the hosts
  file. auth.lab.test hung for the timeout and returned nothing.

  "DNS is down" and "some names resolve" are not contradictory, and a report
  of "it works on my machine" often means "my machine has a hosts entry".
  Which names fail tells you more than which names work.
EOF

cp -a "$BACKUP/resolv.conf" "$CONF_DIR/resolv.conf"
echo
echo "  repaired: nameserver $RESOLVER_IP."
both auth.lab.test

# ---------------------------------------------------------------------------
step "failure 3 of 5 - the nameserver is not running"

server_pid="$(cat "$PIDFILE" 2>/dev/null || true)"
if [[ -z "$server_pid" ]] || ! kill -0 "$server_pid" 2>/dev/null; then
  die "cannot find the running nameserver - re-run setup.sh"
fi

kill -STOP "$server_pid"
echo "  the nameserver process is stopped (SIGSTOP) - the socket is still open,"
echo "  but nothing is reading from it."
echo
both auth.lab.test

cat <<'EOF'
  Symptom: A TIMEOUT, not a refusal.

  This is the distinction worth carrying: the socket exists and the kernel
  accepts the packet, so there is no ICMP port-unreachable and no fast
  "connection refused". The query is simply never answered.

    timeout            -> the packet arrived somewhere and died in silence
    connection refused -> nothing was listening, and the kernel said so
    NXDOMAIN           -> a server answered, authoritatively, "no such name"

  All three are commonly reported as "DNS is broken". They have three
  different causes and three different first commands.

  Prove which one you are in - the requests are arriving:
    sudo ip netns exec router tcpdump -ni any udp port 53
EOF

kill -CONT "$server_pid"
sleep 1
echo
echo "  repaired: the nameserver is reading its socket again (SIGCONT)."
both auth.lab.test

if [[ "$HARD" != "yes" ]]; then
  cat <<'EOF'

=== that is three ===

  Symptom -> first place to look:

    getent and dig agree when they should not   the hosts: line in nsswitch
    some names resolve, others hang             which names, not which tool
    a timeout rather than a refusal             is anything reading the socket

  Two more failures pass a configuration review unchanged:
    sudo ./break-and-fix.sh --hard
EOF
  exit 0
fi

# ---------------------------------------------------------------------------
step "failure 4 of 5 - a trailing dot in the hosts file"

cat > "$CONF_DIR/hosts" <<'EOF'
127.0.0.1   localhost
10.10.0.99  www.lab.test.
EOF

echo "  the hosts entry now reads 'www.lab.test.' - with a trailing dot,"
echo "  which is how the name is spelled everywhere else in DNS."
echo
show "cat $CONF_DIR/hosts"
both www.lab.test

cat <<'EOF'
  Symptom: THE FILE LOOKS RIGHT AND IS IGNORED.

  In DNS a trailing dot means "fully qualified, do not append anything".
  /etc/hosts has no such convention: it matches the string, literally, and
  "www.lab.test." is not the string "www.lab.test". The override silently
  stops applying, and getent falls through to DNS.

  Note which tool exposed it: getent changed its answer. dig never had an
  opinion about this file at all.
EOF

cp -a "$BACKUP/hosts" "$CONF_DIR/hosts"
echo
echo "  repaired: no trailing dot."
both www.lab.test

# ---------------------------------------------------------------------------
step "failure 5 of 5 - the right file in the wrong namespace"

mkdir -p /etc/netns/resolver
cp -a "$CONF_DIR/hosts" /etc/netns/resolver/hosts
cat > "$CONF_DIR/hosts" <<'EOF'
127.0.0.1   localhost
EOF

echo "  the hosts entry was moved to /etc/netns/resolver/hosts - a real"
echo "  directory, a correct file, and the wrong namespace."
echo
show "ls /etc/netns/client /etc/netns/resolver"
both www.lab.test

cat <<'EOF'
  Symptom: THE ENTRY EXISTS AND THE CLIENT CANNOT SEE IT.

  grep -r www.lab.test /etc/netns finds it immediately, so the file is
  "there". It is simply mounted into a namespace that never asks.

  Two habits protect you here:
    - read the path, not the filename: which directory under /etc/netns?
    - check from inside, never from outside:
        sudo ip netns exec client cat /etc/hosts
      That is the only view that counts, because that is the view glibc has.
EOF

cp -a "$BACKUP/hosts" "$CONF_DIR/hosts"
rm -f /etc/netns/resolver/hosts
echo
echo "  repaired: the entry is back in the client's own directory."
both www.lab.test

cat <<'EOF'

=== all five ===

  Symptom -> first place to look:

    getent and dig agree when they should not   the hosts: line in nsswitch
    some names resolve, others hang             which names, not which tool
    a timeout rather than a refusal             is anything reading the socket
    a hosts entry that reads correctly          the exact string, dots and all
    a file that exists but is not seen          which /etc/netns directory

  Four of those five never produced an error message. DNS failures are
  mostly not errors - they are correct answers from the wrong layer.
EOF
