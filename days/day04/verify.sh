#!/usr/bin/env bash
#
# Day 04 — Storage: LVM, filesystems and mount units
# Run this on: VM: node1 + extra disk
#
# Exits 0 only when every automatic check passes. Items printed as
# YOU are judgement calls and never affect the exit status.

set -uo pipefail
cd "$(dirname "$0")"
# shellcheck source=../../lab/verify-lib.sh
source "../../lab/verify-lib.sh"

vl_init "Day 04 — Storage: LVM, filesystems and mount units"
vl_need vgs lvs

vl_check "the volume group labvg exists" 'vgs labvg'
vl_check "a logical volume labdata exists in it" 'lvs labvg/labdata'
vl_check "it is mounted at /srv/data" 'mountpoint -q /srv/data'
vl_check "the mount is persistent" 'grep -q "/srv/data" /etc/fstab || systemctl is-enabled srv-data.mount'
vl_check "the filesystem fills the logical volume after extending" 'df --output=avail /srv/data | tail -1 | grep -qE "[0-9]"'
vl_manual "you extended it live, with no unmount, and watched df change"
vl_manual "you found a deleted-but-still-open file with lsof +L1"

vl_summary
