#!/usr/bin/env bash
#
# Day 16 — WireGuard: a private network between hosts
# Run this on: VM: control + node1
#
# Exits 0 only when every automatic check passes. Items printed as
# YOU are judgement calls and never affect the exit status.

set -uo pipefail
cd "$(dirname "$0")"
# shellcheck source=../../lab/verify-lib.sh
source "../../lab/verify-lib.sh"

vl_init "Day 16 — WireGuard: a private network between hosts"
vl_need wg

vl_check "the wg0 interface exists" 'wg show wg0'
vl_check "a peer is configured" 'wg show wg0 peers | grep -q .'
vl_check "a handshake has happened" '[ "$(wg show wg0 latest-handshakes | awk "{print \$2}")" != "0" ]'
vl_check "the tunnel address is reachable" 'ping -c1 -W2 10.20.0.2 || ping -c1 -W2 10.20.0.1'
vl_check "the tunnel comes up at boot" 'systemctl is-enabled wg-quick@wg0'
vl_check "the private key is not world readable" '[ "$(stat -c %a /etc/wireguard/wg0.conf)" -le 600 ]'
vl_manual "you can explain what AllowedIPs does in both directions"

vl_summary
