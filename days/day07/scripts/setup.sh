#!/usr/bin/env bash
#
# Day 07 setup - build the resolution path on top of Day 06's topology.
#
# There is no require_lab_vm call here, for the same reason as Day 06: every
# file this script writes lives under /etc/netns/<namespace>/, and those files
# are visible ONLY inside a namespace entered with `ip netns exec`. The host's
# own /etc/resolv.conf, /etc/hosts and /etc/nsswitch.conf are never touched.
# That is the single most useful fact in this whole day, so it is worth saying
# twice: iproute2 bind-mounts /etc/netns/NAME/foo over /etc/foo when it enters
# the namespace NAME. Per-namespace DNS configuration is a mount trick.
#
# What this builds:
#   - a nameserver (the payload) running in the resolver namespace on 10.10.1.2
#   - /etc/netns/client/resolv.conf   pointing at it
#   - /etc/netns/client/hosts         with ONE name that DNS also knows about
#   - /etc/netns/client/nsswitch.conf spelling out files-before-dns
#
# The overlap is deliberate. www.lab.test is 10.10.0.99 in the hosts file and
# 10.10.2.2 in DNS, so getent and dig disagree about it, on purpose, and you
# have to know why.

set -euo pipefail

say() { printf '\n==> %s\n' "$*"; }
die() { echo "$*" >&2; exit 1; }

HERE_DIR="$(cd "$(dirname "$0")" && pwd)"

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "needs root:  sudo $0"

NS_CLIENT="client"
NS_RESOLVER="resolver"
RESOLVER_IP="10.10.1.2"
PIDFILE="/run/lab-nameserver.pid"
LOGFILE="/var/log/lab-nameserver.log"

# ---------------------------------------------------------------------------
say "0. checking what this day needs"

missing=""
for tool in ip getent dig python3; do
  command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done

if [[ -n "$missing" ]]; then
  echo "missing:$missing"
  echo
  echo "  Rocky / RHEL:  sudo dnf install -y iproute bind-utils python3 glibc-common"
  echo "  Debian/Ubuntu: sudo apt-get install -y iproute2 dnsutils python3"
  echo
  die "install those first - dig and getent are the two halves of today"
fi
echo "ok    ip, getent, dig and python3 are all present"

# ---------------------------------------------------------------------------
say "1. making sure Day 06's topology is up"

# Day 07 does not invent a network - it resolves across Day 06's. But it does
# not assume one either, because namespaces live in the running kernel and
# never survive a reboot. A missing topology is the NORMAL case, not an error:
# it happens after every reboot, and on a fresh CI runner every single time.
#
# So build it if it is absent. Day 06's setup.sh is idempotent by design, so
# calling it here is safe whether the topology is missing, complete, or half
# built by an interrupted run.
DAY06_SETUP="$HERE_DIR/../../day06/scripts/setup.sh"

need_topology="no"
for ns in "$NS_CLIENT" "$NS_RESOLVER"; do
  ip netns list | grep -qw "$ns" || need_topology="yes"
done

if [[ "$need_topology" == "yes" ]]; then
  echo "the '$NS_CLIENT' or '$NS_RESOLVER' namespace is missing - building the"
  echo "topology first. This is Day 06's work, and it is what a reboot removes."
  echo
  if [[ -x "$DAY06_SETUP" ]]; then
    bash "$DAY06_SETUP" || die "Day 06's setup.sh failed - fix that first:
  sudo ./days/day06/scripts/setup.sh"
  elif [[ -x "$HERE_DIR/../../../lab/lab.sh" ]]; then
    bash "$HERE_DIR/../../../lab/lab.sh" netns-up ||
      die "could not build the topology with lab.sh netns-up"
  else
    die "no '$NS_CLIENT' namespace, and Day 06's setup.sh is not where it
  should be. Build the topology first:
  sudo ./days/day06/scripts/setup.sh"
  fi
  say "1b. back in Day 07 - the topology is up"
fi

# Whether it was already there or just built, prove it works before relying
# on it. A namespace existing is not the same as a packet crossing.
for ns in "$NS_CLIENT" "$NS_RESOLVER"; do
  ip netns list | grep -qw "$ns" || die "still no '$ns' namespace after building"
done

ip netns exec "$NS_CLIENT" ping -c1 -W2 "$RESOLVER_IP" >/dev/null 2>&1 ||
  die "the client cannot reach $RESOLVER_IP - Day 06's routing is broken.
  Check it with:  sudo ./days/day06/scripts/lab-netcheck.sh"

echo "ok    client and resolver exist, and the client can reach $RESOLVER_IP"

# ---------------------------------------------------------------------------
say "2. installing the nameserver"

install -m 0755 "$HERE_DIR/lab-nameserver.sh" /usr/local/bin/lab-nameserver
echo "ok    /usr/local/bin/lab-nameserver"

# ---------------------------------------------------------------------------
say "3. writing the per-namespace resolver configuration"

# The client is told about exactly one nameserver, by address. Note there is
# no `search` line: a bare `www` will therefore fail, and it should - a search
# domain is a convenience that hides which name was actually looked up.
mkdir -p "/etc/netns/$NS_CLIENT"
cat > "/etc/netns/$NS_CLIENT/resolv.conf" <<EOF
# Day 07 - visible only inside the '$NS_CLIENT' namespace.
nameserver $RESOLVER_IP
options timeout:2 attempts:1
EOF

# files before dns. This is glibc's default, but today you want it written
# down where you can break it without touching the host's copy.
cat > "/etc/netns/$NS_CLIENT/nsswitch.conf" <<'EOF'
# Day 07 - visible only inside the 'client' namespace.
hosts:      files dns
passwd:     files
group:      files
shadow:     files
EOF

# One name that DNS also answers for, with a DIFFERENT address. This is the
# disagreement the whole day hangs on.
cat > "/etc/netns/$NS_CLIENT/hosts" <<'EOF'
# Day 07 - visible only inside the 'client' namespace.
127.0.0.1   localhost
10.10.0.99  www.lab.test
EOF

echo "ok    /etc/netns/$NS_CLIENT/{resolv.conf,nsswitch.conf,hosts}"

# The resolver namespace needs a resolv.conf too, or anything you run in it
# inherits the host's - which points somewhere you do not control.
mkdir -p "/etc/netns/$NS_RESOLVER"
cat > "/etc/netns/$NS_RESOLVER/resolv.conf" <<EOF
nameserver 127.0.0.1
EOF
echo "ok    /etc/netns/$NS_RESOLVER/resolv.conf"

# ---------------------------------------------------------------------------
say "4. starting the nameserver in the resolver namespace"

# Stop an old one first so this script can be run twice.
if [[ -f "$PIDFILE" ]]; then
  oldpid="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [[ -n "$oldpid" ]] && kill -0 "$oldpid" 2>/dev/null; then
    kill "$oldpid" 2>/dev/null || true
    sleep 1
    echo "ok    stopped the previous nameserver (pid $oldpid)"
  fi
  rm -f "$PIDFILE"
fi

touch "$LOGFILE"
ip netns exec "$NS_RESOLVER" /usr/local/bin/lab-nameserver serve "$RESOLVER_IP" \
  >>"$LOGFILE" 2>&1 &
server_pid=$!
echo "$server_pid" > "$PIDFILE"

# Give it a moment to bind, then prove it is alive rather than assume it.
sleep 1
kill -0 "$server_pid" 2>/dev/null ||
  die "the nameserver died immediately - read $LOGFILE"

echo "ok    pid $server_pid, logging to $LOGFILE"

# ---------------------------------------------------------------------------
say "5. proving both paths answer"

# dig speaks to the nameserver socket directly. It knows nothing about
# nsswitch and nothing about /etc/hosts.
dig_answer="$(ip netns exec "$NS_CLIENT" dig +short +time=2 +tries=1 www.lab.test 2>/dev/null | head -1)"
[[ -n "$dig_answer" ]] || die "dig got nothing back - read $LOGFILE"

# getent goes through glibc, which reads nsswitch.conf, which says files first.
getent_answer="$(ip netns exec "$NS_CLIENT" getent hosts www.lab.test | awk '{print $1}' | head -1)"
[[ -n "$getent_answer" ]] || die "getent got nothing back - is the hosts file in place?"

echo "ok    dig    says www.lab.test is $dig_answer"
echo "ok    getent says www.lab.test is $getent_answer"

if [[ "$dig_answer" == "$getent_answer" ]]; then
  die "those two should DISAGREE today - the hosts entry is not being read"
fi

cat <<EOF

==> the resolution path is up

  client (10.10.0.2)                    resolver (10.10.1.2)
    |                                       |
    |-- getent --> nsswitch --> /etc/hosts  |   10.10.0.99
    |                     \\                 |
    |                      '--> dns --------->   10.10.2.2
    |                                       |
    '-- dig ------------------------------->'   10.10.2.2

  Two tools, one name, two answers, and neither is wrong.

Next:
  sudo ./scripts/explore-dns.sh       # the whole path, layer by layer
  sudo ./scripts/break-and-fix.sh     # three failures, then two harder ones
  sudo ./verify.sh                    # the checks for today

The nameserver is a background process, not a service. It dies on reboot and
it is not supervised - Day 08 is where DNS gets run properly.
EOF
