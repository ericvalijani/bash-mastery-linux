#!/usr/bin/env bash
#
# Day 04 — Storage: LVM, filesystems and mount units
# Run this on: VM: node1 + extra disk
#
#   sudo ./verify.sh
#
# Root is required: vgs and lvs refuse to report on volume groups for an
# unprivileged user, so without root the first two checks fail for want of
# permission rather than for want of a volume group - while the mount checks
# pass, because /proc/mounts is world-readable. That combination reads as
# "my LVM is broken" when nothing is broken at all. vl_need_root turns the
# whole run into SKIP instead, which is not a pass - see the summary line.
#
# Exits 0 only when every automatic check passes. Items printed as
# YOU are judgement calls and never affect the exit status.

set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=../../lab/verify-lib.sh
source "../../lab/verify-lib.sh"

vl_init "Day 04 — Storage: LVM, filesystems and mount units"
vl_need vgs lvs
vl_need_root

vl_check "the volume group labvg exists" 'vgs labvg'
vl_check "a logical volume labdata exists in it" 'lvs labvg/labdata'
vl_check "it is mounted at /srv/data" 'mountpoint -q /srv/data'
vl_check "the mount is persistent" 'grep -q "/srv/data" /etc/fstab || systemctl is-enabled srv-data.mount'
vl_check "the filesystem fills the logical volume after extending" 'df --output=avail /srv/data | tail -1 | grep -qE "[0-9]"'
vl_manual "you extended it live, with no unmount, and watched df change"
vl_manual "you found a deleted-but-still-open file with lsof +L1"

vl_summary
