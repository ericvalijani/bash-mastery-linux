#!/usr/bin/env bash
#
# lab-nameserver.sh - the payload for Day 07: about sixty lines of DNS server.
#
# It answers A queries for a tiny fixed zone and NXDOMAIN for everything else.
# That is all today needs, because today is about the RESOLUTION PATH - which
# layer answered - and not about running DNS properly. Day 08 replaces this
# with a real authoritative server and a real recursive resolver, and the
# contrast between the two is the point of that day.
#
#   sudo ./lab-nameserver.sh serve            # foreground, on 0.0.0.0:53
#   sudo ./lab-nameserver.sh serve 10.10.1.2  # bind one address
#
# Run it inside a namespace, which is where it belongs:
#   sudo ip netns exec resolver /usr/local/bin/lab-nameserver serve
#
# The zone it serves:
#   www.lab.test.   -> 10.10.2.2
#   auth.lab.test.  -> 10.10.2.2
#   lab.test.       -> 10.10.2.2
#   client.lab.test -> 10.10.0.2
#
# Written in Python because every machine that can run this repo has python3,
# and because a DNS answer is a byte layout rather than a text protocol - you
# cannot fake one with printf and netcat the way you can fake HTTP.

set -uo pipefail

usage() {
  echo "usage: $0 serve [bind-address]" >&2
  exit 2
}

command -v python3 >/dev/null 2>&1 || { echo "missing python3" >&2; exit 1; }

case "${1:-}" in
  serve) : ;;
  *) usage ;;
esac

BIND="${2:-0.0.0.0}"

# Port 53 is privileged.
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "needs root (port 53):  sudo $0 $*" >&2
  exit 1
fi

export LAB_BIND="$BIND"

exec python3 - <<'PY'
import os, socket, struct, sys

ZONE = {
    "lab.test.":        "10.10.2.2",
    "www.lab.test.":    "10.10.2.2",
    "auth.lab.test.":   "10.10.2.2",
    "client.lab.test.": "10.10.0.2",
}

bind = os.environ.get("LAB_BIND", "0.0.0.0")


def read_name(data, offset):
    """A DNS name on the wire is length-prefixed labels, not a dotted string."""
    labels = []
    while True:
        length = data[offset]
        offset += 1
        if length == 0:
            break
        labels.append(data[offset:offset + length].decode("ascii", "replace"))
        offset += length
    return ".".join(labels) + ".", offset


sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind((bind, 53))
print(f"lab-nameserver listening on {bind}:53 for {len(ZONE)} names", flush=True)

while True:
    try:
        query, peer = sock.recvfrom(2048)
    except KeyboardInterrupt:
        print("stopping", flush=True)
        sys.exit(0)

    if len(query) < 13:
        continue

    txid = query[:2]
    name, end = read_name(query, 12)
    qtype, qclass = struct.unpack("!HH", query[end:end + 4])
    question = query[12:end + 4]

    answer = ZONE.get(name.lower()) if qtype == 1 else None

    # Flags: response, authoritative. rcode 0 with an answer, 3 (NXDOMAIN)
    # without one. AA is honest here: this really is the only source.
    if answer:
        flags, ancount = 0x8400, 1
        rdata = socket.inet_aton(answer)
        body = (b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 60, 4) + rdata)
    else:
        flags, ancount = 0x8403, 0
        body = b""

    header = txid + struct.pack("!HHHHH", flags, 1, ancount, 0, 0)
    sock.sendto(header + question + body, peer)
    print(f"{peer[0]} asked for {name} type {qtype} -> {answer or 'NXDOMAIN'}", flush=True)
PY
