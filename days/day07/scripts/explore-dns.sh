#!/usr/bin/env bash
#
# Day 07 explore - a read-only tour of the resolution path.
#
# Nothing here changes anything. Every command is one you should be able to
# type from memory by the end of the week, because each one answers a
# different question about WHICH LAYER ANSWERED.

set -uo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "needs root:  sudo $0" >&2; exit 1; }
command -v ip >/dev/null 2>&1 || { echo "missing ip" >&2; exit 1; }

heading() { printf '\n=== %s ===\n\n' "$*"; }
note()    { printf '  (%s)\n\n' "$1"; }
run()     { printf '$ %s\n' "$*"; "$@" 2>&1 | sed 's/^/  /' || true; printf '\n'; }
run_sh()  { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/  /' || true; printf '\n'; }

heading "1. the files the client actually reads"

run_sh "ip netns exec client cat /etc/resolv.conf"
note "this is NOT the host's /etc/resolv.conf - compare the next one"
run_sh "cat /etc/resolv.conf | head -5"
note "iproute2 bind-mounts /etc/netns/client/resolv.conf over /etc/resolv.conf on the way in"

heading "2. where those per-namespace files live on disk"

run_sh "ls -l /etc/netns/client/"
note "any file you put here shadows /etc/<same name> inside that namespace, and nowhere else"

heading "3. the order glibc searches"

run_sh "ip netns exec client grep '^hosts:' /etc/nsswitch.conf"
note "files, then dns - so a hosts entry wins, and DNS is never even asked"

heading "4. the same name, asked two different ways"

run_sh "ip netns exec client getent hosts www.lab.test"
run_sh "ip netns exec client dig +short www.lab.test"
note "two answers for one name: getent obeyed nsswitch, dig went straight to the socket"

heading "5. a name that is only in DNS"

run_sh "ip netns exec client getent hosts auth.lab.test"
run_sh "ip netns exec client dig +short auth.lab.test"
note "no hosts entry, so glibc fell through to dns and both agree"

heading "6. a name that is in neither"

run_sh "ip netns exec client getent hosts nope.lab.test; echo 'getent exit status:' \$?"
run_sh "ip netns exec client dig nope.lab.test | grep -E 'status:'"
note "getent says nothing and exits 2; dig says NXDOMAIN out loud - dig is the better debugging tool because it never hides the answer"

heading "7. what dig will not do for you"

run_sh "ip netns exec client dig +short localhost"
note "empty: localhost is a hosts-file name, and dig does not read hosts files. This surprises people at 3am"

heading "8. reading the full answer, not the short one"

run_sh "ip netns exec client dig www.lab.test"
note "note the flags: aa means the server claimed authority. ra is absent - this server cannot recurse, and says so"

heading "9. asking a specific server, ignoring resolv.conf entirely"

run_sh "ip netns exec client dig +short @10.10.1.2 lab.test"
note "@server bypasses resolv.conf - the first thing to try when you suspect the client's configuration rather than the server"

heading "10. who is answering, seen from the server side"

run_sh_tail() { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | tail -5 | sed 's/^/  /' || true; printf '\n'; }
run_sh_tail "tail -5 /var/log/lab-nameserver.log"
note "every query you just made is logged here, with the asker's address - proof of which packets arrived"

heading "11. the resolver's own view"

run_sh_tail "ip netns exec resolver ss -ulnp 2>/dev/null || ip netns exec resolver netstat -ulnp 2>/dev/null || echo 'no ss or netstat here'"
note "the nameserver is bound inside the resolver namespace only - the host's port 53 is untouched"

heading "12. worth doing by hand next"

cat <<'EOF'
  Sit with these three. They are the day.

    sudo ip netns exec client getent hosts www.lab.test
    sudo ip netns exec client dig +short www.lab.test
    sudo ip netns exec client dig +norecurse +short lab.test

  Then answer, without looking:
    - which of those three read /etc/hosts?
    - which one would keep working if the nameserver were switched off?
    - if an application reported the wrong address, which tool would you
      have believed, and which one told the truth?
EOF
