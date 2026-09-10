#!/usr/bin/env bash
#
# lab-dnsq.sh - the payload for Day 08: ask both servers the same question and
# print what makes their answers different.
#
# There is no daemon to write today - unbound is the daemon. What is worth
# having is a question you can ask repeatedly, because today's whole subject is
# the DIFFERENCE between two answers to the same query:
#
#   the authoritative server  answers from its own zone      -> aa flag, fixed TTL
#   the recursive resolver    answers from its own cache     -> ra flag, TTL counting DOWN
#
# Usage:
#   sudo ./lab-dnsq.sh                    # www.lab.test, both servers
#   sudo ./lab-dnsq.sh auth.lab.test      # another name
#   sudo ./lab-dnsq.sh www.lab.test SOA   # another type
#
# Run it twice in a row. The authoritative TTL will not move; the resolver's
# will fall. That is the cache, visible, with no tooling.

# Deliberately no `set -e`: this script's job is to report failures, including
# SERVFAIL and timeouts, so it must not exit on the first one.
set -uo pipefail

NAME="${1:-www.lab.test}"
TYPE="${2:-A}"

AUTH_IP="10.10.2.2"
RESOLVER_IP="10.10.1.2"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "needs root:  sudo $0 $*" >&2; exit 1; }
command -v ip  >/dev/null 2>&1 || { echo "missing ip" >&2; exit 1; }
command -v dig >/dev/null 2>&1 || { echo "missing dig" >&2; exit 1; }
ip netns list | grep -qw client || { echo "no client namespace - run setup.sh" >&2; exit 1; }

fails=0

# One query, fully dissected. dig's own output is the source of truth here -
# this only pulls the four fields that answer "who told me, and how do they
# know".
ask() {
  local label="$1" server="$2" out status flags ttl answer

  out="$(ip netns exec client dig +time=2 +tries=1 "$TYPE" "$NAME" "@$server" 2>&1)"

  if ! printf '%s' "$out" | grep -q 'HEADER'; then
    printf '  %-12s %-14s no reply at all (timeout)\n' "$label" "$server"
    fails=$((fails + 1))
    return
  fi

  status="$(printf '%s' "$out" | sed -n 's/.*status: \([A-Z]*\).*/\1/p' | head -1)"
  flags="$(printf '%s' "$out" | sed -n 's/^;; flags: \([a-z ]*\);.*/\1/p' | head -1)"
  # Read the ANSWER section only, and take the first record whatever its type.
  # Keying on the type you asked for would print nothing for a CNAME, which is
  # exactly the case worth seeing: you asked for an A and got back a name.
  answer="$(printf '%s' "$out" | awk '/^;; ANSWER SECTION:/{a=1;next} /^;; /{a=0} a && NF>=5 {print $4" "$5; exit}')"
  ttl="$(printf '%s' "$out" | awk '/^;; ANSWER SECTION:/{a=1;next} /^;; /{a=0} a && NF>=5 {print $2; exit}')"

  printf '  %-12s %-14s %-9s flags:%-14s ttl:%-7s %s\n' \
    "$label" "$server" "$status" "${flags:- -}" "${ttl:- -}" "${answer:- -}"

  [[ "$status" == "NOERROR" || "$status" == "NXDOMAIN" ]] || fails=$((fails + 1))
}

printf '\nasking for %s %s\n\n' "$TYPE" "$NAME"
ask "authoritative" "$AUTH_IP"
ask "recursive" "$RESOLVER_IP"

cat <<'EOF'

  If the RECURSIVE line ever shows aa, stop and read it again: a caching
  resolver has no business claiming authority for this zone. It means some
  other data answered - a built-in local-zone, or a second unbound still
  running on that address with an older config.

  aa = this server is authoritative for the zone: the answer came from its
       own data, not from anyone else's.
  ra = this server is willing to recurse: it will go and find answers it does
       not have. Its TTL counts down because it is serving you a copy.

  Run this again. Only one of the two TTLs will have moved.
EOF

# Exit status reflects DNS, so this can be used in a loop or a pipeline.
[[ $fails -eq 0 ]]
