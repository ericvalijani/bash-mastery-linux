#!/usr/bin/env bash
#
# break-and-fix.sh - four ways a WireGuard tunnel fails while looking fine.
#
#   sudo ./break-and-fix.sh          the four that are safe here
#   sudo ./break-and-fix.sh --hard   plus the two that cost you the host
#
# Everything is restored at the end from a copy taken first. Run this on ONE
# host only - the one you are sitting on. It never touches the far end.

set -uo pipefail

IFACE="${WG_IFACE:-wg0}"
WG_DIR="/etc/wireguard"
CONF="$WG_DIR/$IFACE.conf"
BACKUP="/tmp/day16-broken/$IFACE.conf.good"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { printf 'needs root:  sudo %s %s\n' "$0" "${1:-}" >&2; exit 1; }
[[ -f "$CONF" ]] || { printf 'no %s - run scripts/setup.sh first\n' "$CONF" >&2; exit 1; }
wg show "$IFACE" peers | grep -q . || {
	printf 'no peer configured yet - finish pass 2 of setup.sh on both hosts\n' >&2
	exit 1
}

say()  { printf '\n%s\n' "$1"; printf '%s\n' "$(printf '%*s' "${#1}" '' | tr ' ' '-')"; }
step() { printf '\n  -> %s\n' "$*"; }
run()  { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/  /'; printf '\n'; }
note() { printf '  %s\n' "$*"; }

HARD=no
[[ "${1:-}" == "--hard" ]] && HARD=yes

mkdir -p "$(dirname "$BACKUP")"
cp -a "$CONF" "$BACKUP"
chmod 0600 "$BACKUP"

PEER_TUN="$(wg show "$IFACE" allowed-ips | awk '{print $2}' | cut -d/ -f1 | head -1)"
MY_TUN="$(ip -4 -brief addr show "$IFACE" | awk '{print $3}' | cut -d/ -f1)"
note "this host is $MY_TUN, the peer is $PEER_TUN"
note "a good copy of the config is at $BACKUP"

reload()  { wg syncconf "$IFACE" <(wg-quick strip "$IFACE") 2>/dev/null; }
restore() { cp -a "$BACKUP" "$CONF"; reload; }
bounce()  { wg-quick down "$IFACE" >/dev/null 2>&1; wg-quick up "$IFACE" >/dev/null 2>&1; }
hs() {
	local h
	h="$(wg show "$IFACE" latest-handshakes | awk '{print $2}' | head -1)"
	if [[ -n "$h" && "$h" != 0 ]]; then
		printf '%ss ago\n' "$(( $(date +%s) - h ))"
	else
		printf 'never\n'
	fi
}

# ---------------------------------------------------------------------------
say "1. the key that is one character wrong"
# The most common WireGuard failure, and the least informative. A wrong peer
# key is not an error: it is a packet that fails to authenticate, and
# WireGuard's answer to that is silence.
step "before"
run "wg show $IFACE | grep -E 'peer|handshake'"

BAD_PEER="$(head -c 32 /dev/urandom | base64)"
sed -i "s|^PublicKey.*|PublicKey  = $BAD_PEER|" "$CONF"
bounce

step "a valid-looking key that belongs to nobody"
run "wg show $IFACE | grep -E 'peer|handshake|transfer'"
run "ping -c2 -W2 $PEER_TUN; echo exit=\$?"
note "no error from wg. The interface is up, the peer is listed, the route"
note "exists, and the only symptoms are a handshake that never appears and"
note "sent climbing while received stays at zero"
step "nothing in the logs either"
run "journalctl -k --since '2 min ago' | grep -ci wireguard || echo 'no kernel messages'"
step "the fix: compare, do not read"
note "on the far end:  sudo cat /etc/wireguard/$IFACE.pub"
note "here:            sudo wg show $IFACE peers"
note "those two strings must be identical. Diff them, do not eyeball them -"
note "base64 is exactly the kind of string your eye skips over"
restore
bounce
sleep 2
ping -c2 -W2 "$PEER_TUN" >/dev/null 2>&1 || true
run "wg show $IFACE | grep -E 'peer|handshake'"
note "handshake: $(hs)"

# ---------------------------------------------------------------------------
say "2. AllowedIPs narrowed on one side only"
# The asymmetric failure: your side is wrong, the far side is right, and the
# symptom appears at the far side.
step "claim we only talk to an address the peer does not have"
sed -i "s|^AllowedIPs.*|AllowedIPs = 10.20.0.99/32|" "$CONF"
bounce
run "wg show $IFACE allowed-ips"
run "ip route show dev $IFACE"
run "ip route get $PEER_TUN 2>&1 | head -2"
note "the route for the peer is gone, so the packet never enters the tunnel."
note "Note what ip route get says - that is the check worth running first"
run "ping -c2 -W2 $PEER_TUN; echo exit=\$?"
step "the same mistake in the other direction is worse"
note "if the FAR end narrows its AllowedIPs instead, your packets arrive and"
note "its kernel drops them as an unexpected source - so your side shows a"
note "good handshake, sent climbing, received zero, and a perfect config."
note "You would spend the afternoon debugging the healthy host"
step "the fix"
restore
bounce
sleep 2
run "wg show $IFACE allowed-ips; ip route get $PEER_TUN | head -1"
note "whatever you want to reach must be in YOUR AllowedIPs, and your own"
note "addresses must be in THEIRS"

# ---------------------------------------------------------------------------
say "3. MTU: ping works, transfers hang"
# The failure people lose a day to, because every quick test passes.
step "set the tunnel MTU to the underlying link's, ignoring the 80 bytes of overhead"
sed -i "/^.Interface.$/a MTU = 1500" "$CONF"
bounce
run "ip link show $IFACE | grep -o 'mtu [0-9]*'"
step "the small tests all pass"
run "ping -c2 -W2 $PEER_TUN | tail -2"
step "and a full-size packet does not"
run "ping -c2 -W2 -M do -s 1400 $PEER_TUN 2>&1 | tail -3; echo exit=\$?"
note "ping is fine, ssh logs in, and scp stops at 0%. Anything that fills a"
note "packet dies: the encrypted packet exceeds the real link MTU, and the"
note "ICMP that would have said so is usually dropped by somebody"
step "the fix: 1500 - 80 = 1420"
restore
bounce
sleep 2
run "ip link show $IFACE | grep -o 'mtu [0-9]*'"
run "ping -c2 -W2 -M do -s 1300 $PEER_TUN | tail -2"
note "wg-quick picks 1420 by itself. The only reason to set MTU by hand is a"
note "link already below 1500 - and then you subtract from that"

# ---------------------------------------------------------------------------
say "4. the config you edited and never loaded"
step "change the file, and only the file"
sed -i "s|^PersistentKeepalive.*|PersistentKeepalive = 99|" "$CONF"
run "grep -E '^PersistentKeepalive' $CONF"
run "wg show $IFACE persistent-keepalive"
note "the file says 99, the kernel says 25. wg-quick read the file once, when"
note "the interface came up. Nothing watches it afterwards"
step "diff intent against reality"
# Compare settings, not formatting: strip echoes the file's own order and
# spacing, showconf prints the kernel's normalized version. A raw diff is all
# noise, which is why the honest check normalizes both sides first.
NORM="sed -E 's/[[:space:]]+/ /g' | grep -E '^(PublicKey|PresharedKey|AllowedIPs|Endpoint|PersistentKeepalive) = ' | sort"
run "diff <(wg-quick strip $IFACE | $NORM) <(wg showconf $IFACE | $NORM)"
note "wg showconf is live state, wg-quick strip is the file. Diffing the two"
note "catches every unapplied edit, and it belongs in a check script - but"
note "normalize first, or the formatting differences drown the real one"
step "the fix: apply without dropping the tunnel"
run "wg syncconf $IFACE <(wg-quick strip $IFACE) && wg show $IFACE persistent-keepalive"
note "syncconf keeps the interface and the handshake. wg-quick down then up"
note "also applies it, and on a management tunnel it takes your session"
restore

# ---------------------------------------------------------------------------
if [[ "$HARD" == yes ]]; then
	say "the two that cost you the host - described, not run"
	cat <<TXT
  a. AllowedIPs = 0.0.0.0/0 on the wrong side

       [Peer]
       AllowedIPs = 0.0.0.0/0

     Legitimate on a laptop that routes all its traffic through a VPN. On
     this pair it installs a default route into the tunnel, so the SSH
     session you are working in - which arrives on the ordinary lab
     network - tries to reply through the tunnel it is configuring. The
     connection dies mid-command, and because the unit is enabled, a
     reboot brings the same state back.

     If you want to see it: do it from the VM console, not over SSH.

  b. wg-quick down on the far end, over the tunnel

       ssh $PEER_TUN 'sudo wg-quick down $IFACE'

     The command succeeds and the answer never arrives, because the
     interface carrying it is the one you just removed. Enabled means you
     get it back on reboot; merely up means you need the console.

     The habit that avoids both: arm an undo before you break anything -
         sudo sh -c 'sleep 120 && wg-quick up $IFACE' &
     Ugly, and it has saved real machines.
TXT
fi

# ---------------------------------------------------------------------------
say "putting it back"
restore
bounce
sleep 2
ping -c2 -W2 "$PEER_TUN" >/dev/null 2>&1 || true
run "wg show $IFACE | grep -E 'peer|endpoint|allowed|handshake|transfer'"
note "handshake: $(hs)"
note "the good copy is still at $BACKUP if anything above went sideways"

cat <<'TXT'

Four failures.

  wrong peer key      no handshake, no error, nothing in the logs
  AllowedIPs narrow   asymmetric - the symptom shows at the healthy end
  MTU too high        every quick test passes, real transfers hang
  edited, not loaded  the file and the kernel disagree and neither says so

None of them produce an error message. WireGuard's silence is a security
property and a debugging tax, and these four are the bill.

Check yourself:  sudo ./verify.sh
TXT
