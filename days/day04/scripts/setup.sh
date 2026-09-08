#!/usr/bin/env bash
#
# Day 04 - build a logical volume, put a filesystem on it, and mount it the
# systemd way.
#
#   sudo ./scripts/setup.sh
#
# It creates:
#   pv     one block device claimed by LVM        /dev/vdb, or a loop device
#   vg     labvg                                  the pool
#   lv     labvg/labdata                          512 MB to start, on purpose
#   fs     ext4 on that lv
#   dir    /srv/data                              the mount point
#   unit   srv-data.mount                         persistent, enabled
#
# The logical volume starts DELIBERATELY SMALL. The day is about growing it
# while it is mounted, and you cannot practise that on something already the
# size of the disk.
#
# Safe to run again at any time: every step checks for its own end state
# first, so a second run reports what already exists rather than failing.
#
# Two things worth knowing before you read on:
#
#   - LVM has three layers and people blur them. A PHYSICAL VOLUME is a disk
#     handed to LVM. A VOLUME GROUP is one or more PVs pooled together. A
#     LOGICAL VOLUME is a slice of that pool, and it is the thing you put a
#     filesystem on. Growing storage means growing the LV and then growing
#     the filesystem inside it - two separate steps, and forgetting the
#     second one is the most common LVM mistake there is.
#
#   - A .mount unit's FILENAME is not a free choice. systemd derives it from
#     the mount path, so /srv/data must be srv-data.mount and nothing else.
#     Get it wrong and systemd ignores the file completely.

set -euo pipefail

# This script claims a block device and writes a filesystem, which is the most
# destructive thing in this repository. It refuses to run anywhere but a
# disposable lab VM. See lab/on-lab-vm.sh for what counts as one.
#
# CI is the one exception: the day-04 job on GitHub Actions sets
# LAB_ALLOW_THIS_MACHINE=1, because a runner is destroyed after every job.
# shellcheck source=../../../lab/on-lab-vm.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

VG="labvg"
LV="labdata"
MNT="/srv/data"
UNIT="/etc/systemd/system/srv-data.mount"
LV_PATH="/dev/$VG/$LV"
LV_SIZE="512M"
FSTYPE="ext4"
IMG="/var/lib/lab-day04-disk.img"
IMG_SIZE="2G"

HERE="$(cd "$(dirname "$0")" && pwd)"

die() {
	echo "$*" >&2
	exit 1
}
say() { printf '\n==> %s\n' "$*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "this claims a disk and mounts a filesystem, so it needs root:  sudo $0"

# The Rocky 9 cloud image is minimal and ships none of these. Checking up
# front, rather than dying halfway through with a volume group created and no
# way to put a filesystem on it.
for c in pvs vgs lvs pvcreate vgcreate lvcreate "mkfs.$FSTYPE" resize2fs; do
	command -v "$c" >/dev/null 2>&1 || die "missing $c. install what this day needs:

  sudo dnf install -y lvm2 e2fsprogs lsof

lvm2 gives you pvs/vgs/lvs and lvextend, e2fsprogs gives mkfs.ext4 and
resize2fs, and lsof is needed later for the deleted-but-open file."
done

# ----------------------------------------------------------- find a device
# Preference order, and the reasoning:
#
#   1. an unused whole disk such as /dev/vdb. This is the real thing, it is
#      what ./lab/lab.sh add-disk node1 2 gives you, and it survives a reboot.
#   2. a loop device backed by a sparse file. Also a real block device as far
#      as LVM is concerned - real pvcreate, real vgcreate, real resize - but
#      it does NOT survive a reboot unless something re-attaches it.
#
# Nothing here will touch a device that already has a partition table, a
# filesystem signature, or anything mounted on it.
say "looking for a block device LVM may have"

device=""
if vgs "$VG" >/dev/null 2>&1; then
	device="(already claimed)"
	echo "volume group $VG already exists - skipping device selection"
	pvs -o pv_name,vg_name --noheadings | sed 's/^/  /'
else
	for cand in /dev/vdb /dev/vdc /dev/sdb /dev/sdc; do
		[[ -b "$cand" ]] || continue

		# Refuse anything that looks like it holds data. blkid prints a
		# signature for a filesystem or a partition table; lsblk lists
		# children, which means it is partitioned.
		if blkid "$cand" >/dev/null 2>&1; then
			echo "skipping $cand - it already carries a signature:"
			blkid "$cand" | sed 's/^/    /'
			continue
		fi
		if [[ -n "$(lsblk -nro NAME "$cand" | tail -n +2)" ]]; then
			echo "skipping $cand - it has partitions"
			continue
		fi
		if lsblk -nro MOUNTPOINT "$cand" | grep -q .; then
			echo "skipping $cand - something is mounted from it"
			continue
		fi
		device="$cand"
		break
	done

	if [[ -z "$device" ]]; then
		echo "no spare disk found, so falling back to a loop device."
		echo
		echo "this is real LVM on a real block device - the kernel presents the"
		echo "file below as one - but it will NOT come back after a reboot, so"
		echo "step 5 of the README cannot be done this way. on node1, run this"
		echo "from your laptop and then re-run me:"
		echo "  ./lab/lab.sh add-disk node1 2"
		echo

		command -v losetup >/dev/null 2>&1 || die "missing losetup and no spare disk"
		if [[ ! -f "$IMG" ]]; then
			truncate -s "$IMG_SIZE" "$IMG"
			echo "created $IMG ($IMG_SIZE, sparse)"
		fi

		# Reuse the existing association if this script already ran.
		device="$(losetup -j "$IMG" | cut -d: -f1 | head -1)"
		if [[ -z "$device" ]]; then
			device="$(losetup --find --show "$IMG")"
		fi
		echo "$IMG is attached as $device"
	fi
	echo "using $device"
fi

# ------------------------------------------------------------- pv, vg, lv
say "physical volume, volume group, logical volume"

if [[ "$device" != "(already claimed)" ]]; then
	if pvs "$device" >/dev/null 2>&1; then
		echo "$device is already a PV"
	else
		pvcreate "$device"
	fi
	if vgs "$VG" >/dev/null 2>&1; then
		echo "$VG already exists"
	else
		vgcreate "$VG" "$device"
	fi
fi

if lvs "$VG/$LV" >/dev/null 2>&1; then
	echo "$VG/$LV already exists - leaving its size alone"
else
	# -n name, -L size. Deliberately small: the day is about growing it.
	lvcreate -n "$LV" -L "$LV_SIZE" "$VG"
fi

echo
echo "the three layers, each with its own command:"
pvs
vgs
lvs

# --------------------------------------------------------------- the fs
say "filesystem on $LV_PATH"

# Never reformat: a second run of this script must not destroy the data the
# reader put there. blkid is the test - if it reports a type, leave it.
if blkid "$LV_PATH" >/dev/null 2>&1; then
	echo "$LV_PATH already has a filesystem - not touching it:"
	blkid "$LV_PATH" | sed 's/^/  /'
else
	# ext4 rather than xfs on purpose. Both grow online; only ext4 can also
	# be shrunk, and break-and-fix.sh --hard uses that difference.
	"mkfs.$FSTYPE" "$LV_PATH"
fi

# -------------------------------------------------------------- the mount
say "mounting it with a unit, not fstab"

mkdir -p "$MNT"

# Two ways exist to make a mount persistent, and they are not equivalent:
#
#   /etc/fstab       the old contract. systemd reads it at boot and generates
#                    units from it behind your back.
#   a .mount unit    the same thing written directly, with unit dependencies
#                    available to you: After=, Requires=, WantedBy=.
#
# The unit is used here because you can then reason about ordering with the
# same tools as every other unit. The filename must match the path.
cat >"$UNIT" <<EOF
[Unit]
Description=Day 04 data volume
Documentation=file://$HERE/setup.sh

[Mount]
What=$LV_PATH
Where=$MNT
Type=$FSTYPE

# noatime is not required, it is here so that reading a file does not cause a
# write. Worth knowing about when you are chasing unexpected disk activity.
Options=defaults,noatime

[Install]
WantedBy=multi-user.target
EOF

echo "wrote $UNIT"
systemctl daemon-reload

# --now mounts it immediately; enable alone would only take effect at boot.
systemctl enable --now srv-data.mount

mountpoint -q "$MNT" || die "$MNT did not mount. read why:  systemctl status srv-data.mount"
echo "$MNT is mounted"

# ------------------------------------------------------------- the payload
say "installing the writer"

[[ -f "$HERE/lab-writer.sh" ]] || die "cannot find $HERE/lab-writer.sh - run this from days/day04"
install -m 0755 "$HERE/lab-writer.sh" /usr/local/bin/lab-writer
[[ -x /usr/local/bin/lab-writer ]] || die "install reported success but /usr/local/bin/lab-writer is not there"
ls -l /usr/local/bin/lab-writer

# Do not promise the reader a bare command name. /usr/local/bin is on an
# interactive PATH, but sudo on RHEL-family systems replaces PATH with its own
# secure_path, which frequently does not include /usr/local/bin - so
# "sudo lab-writer" can fail with command not found on a machine where the
# file is plainly present and executable.
if sudo -n true 2>/dev/null && ! sudo -n command -v lab-writer >/dev/null 2>&1; then
	echo "note: sudo's secure_path does not include /usr/local/bin on this"
	echo "      machine, so call it by path instead:"
	echo "      sudo $HERE/lab-writer.sh ghost $MNT 100"
else
	echo "call it as:  sudo lab-writer ghost $MNT 100"
	echo "or by path:  sudo $HERE/lab-writer.sh ghost $MNT 100"
fi

# ------------------------------------------------------------------ proof
say "where things stand"

df -h "$MNT"
echo
lvs "$VG/$LV" -o lv_name,lv_size,vg_free --units m
echo
echo "read those two blocks together. the logical volume is $LV_SIZE and the"
echo "filesystem fills it, but the volume group still has free space - which"
echo "is exactly the position you are in at 3am when a disk fills up."
echo
echo "the day is to grow it without unmounting:"
echo "  sudo lvextend -L +512M $VG/$LV"
echo "  df -h $MNT                      # unchanged. the LV grew, the fs did not"
echo "  sudo resize2fs $LV_PATH"
echo "  df -h $MNT                      # now it grew"
echo
echo "then run:  sudo ./scripts/break-and-fix.sh"
