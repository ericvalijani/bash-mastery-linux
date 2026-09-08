#!/usr/bin/env bash
#
# Day 04 teardown - remove everything setup.sh created.
#
#   sudo ./scripts/teardown.sh
#
# You do not have to run this. Day 20's backup work is the only later day that
# touches /srv/data, and it is happy to find it already there.
#
# It exists because storage is the one area where leftovers are expensive:
#
#   - a mount unit left enabled will try to mount a device that no longer
#     exists, and a failed mount unit at boot can block anything ordered
#     after it
#   - a volume group left on a loop device that no longer exists leaves LVM
#     printing warnings about missing PVs on every single lvs call
#   - the order matters. unmount, then remove the LV, then the VG, then the
#     PV, then detach the loop device. Doing it backwards leaves LVM holding
#     a device the kernel already took away.
#
# Guarded, because it destroys a filesystem.

set -euo pipefail

# shellcheck source=../../../lab/on-lab-vm.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

VG="labvg"
LV="labdata"
MNT="/srv/data"
UNIT="/etc/systemd/system/srv-data.mount"
IMG="/var/lib/lab-day04-disk.img"
BIN="/usr/local/bin/lab-writer"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
	echo "needs root:  sudo $0" >&2
	exit 1
fi

say() { printf '\n==> %s\n' "$*"; }

say "unmounting $MNT"

# Order: the unit first, so systemd does not immediately remount it.
systemctl disable --now srv-data.mount 2>/dev/null || echo "(unit was not enabled)"
systemctl reset-failed srv-data.mount 2>/dev/null || true

if mountpoint -q "$MNT"; then
	# A busy mount is the normal case, not an error - anything with a shell
	# open in that directory holds it. fuser names the culprit.
	if ! umount "$MNT" 2>/dev/null; then
		echo "$MNT is busy. what is holding it:" >&2
		command -v fuser >/dev/null 2>&1 && fuser -vm "$MNT" 2>&1 | sed 's/^/  /' || true
		echo "close those, or run:  fuser -km $MNT" >&2
		exit 1
	fi
fi
echo "$MNT is not mounted"

say "removing the unit and the payload"
rm -fv "$UNIT" "$BIN" 2>/dev/null || true
systemctl daemon-reload

say "removing the logical volume and volume group"
if lvs "$VG/$LV" >/dev/null 2>&1; then
	lvremove -f "$VG/$LV"
else
	echo "(no $VG/$LV)"
fi

# Remember which PVs the group was using before removing it, because after
# vgremove there is nothing left to ask.
pvlist=""
if vgs "$VG" >/dev/null 2>&1; then
	pvlist="$(pvs --noheadings -o pv_name -S "vg_name=$VG" 2>/dev/null | tr -d ' ' | tr '\n' ' ')"
	vgremove -f "$VG"
else
	echo "(no volume group $VG)"
fi

if [[ -n "$pvlist" ]]; then
	say "releasing the physical volume(s): $pvlist"
	for p in $pvlist; do
		pvremove -f "$p" 2>/dev/null || echo "(could not pvremove $p)"
	done
fi

say "detaching the loop device, if this day used one"
if [[ -f "$IMG" ]]; then
	for l in $(losetup -j "$IMG" 2>/dev/null | cut -d: -f1); do
		losetup -d "$l" && echo "detached $l"
	done
	rm -fv "$IMG"
else
	echo "(no $IMG - this day ran on a real disk, which is left alone)"
	echo "the disk itself is still attached and now has no signature. to remove"
	echo "it properly, from your laptop:  ./lab/lab.sh down node1"
fi

say "removing the mount point"
# Only if empty. A non-empty /srv/data after unmounting means files were
# written to the directory while nothing was mounted on it - which is worth
# noticing rather than deleting.
if [[ -d "$MNT" ]]; then
	if rmdir "$MNT" 2>/dev/null; then
		echo "removed $MNT"
	else
		echo "$MNT is not empty, so it was left in place:" >&2
		ls -la "$MNT" | head | sed 's/^/  /' >&2
		echo "those files were written while nothing was mounted there. that is" >&2
		echo "a finding worth understanding before you delete them." >&2
	fi
fi

say "confirming"
left=0
if mountpoint -q "$MNT" 2>/dev/null; then
	echo "still present: something mounted at $MNT" >&2
	left=$((left + 1))
fi
if [[ -e "$UNIT" ]]; then
	echo "still present: $UNIT" >&2
	left=$((left + 1))
fi
if vgs "$VG" >/dev/null 2>&1; then
	echo "still present: volume group $VG" >&2
	left=$((left + 1))
fi
if [[ -e "$IMG" ]]; then
	echo "still present: $IMG" >&2
	left=$((left + 1))
fi
if [[ -e "$BIN" ]]; then
	echo "still present: $BIN" >&2
	left=$((left + 1))
fi

if [[ $left -gt 0 ]]; then
	echo
	echo "$left item(s) survived. That is a finding, not a bug - go and read why." >&2
	exit 1
fi

echo "mount, unit, logical volume, volume group and payload are all gone. clean."
echo
echo "what deliberately survives:"
echo "  - the journal, including every mount and unmount:"
echo "      journalctl -u srv-data.mount --no-pager"
echo "  - the attached disk itself, if you used a real one. it is blank now,"
echo "    not gone, which is why a second run of setup.sh will find it and"
echo "    claim it again:"
echo "      lsblk -o NAME,SIZE,TYPE,FSTYPE"
