#!/usr/bin/env bash
#
# Day 04 - break the storage on purpose, three times, and repair each one.
#
#   sudo ./scripts/break-and-fix.sh
#   sudo ./scripts/break-and-fix.sh --hard
#
# Every failure here is one that reads as something else:
#
#   1. the volume grew and the filesystem did not      "lvextend did nothing"
#   2. a mount unit systemd ignores completely         "my unit file is wrong"
#   3. full disk, and du cannot find the files         "df is lying to me"
#
# --hard adds two more:
#
#   4. the volume group runs out of room               lvextend refuses
#   5. an ext4 filesystem cannot be shrunk while mounted
#
# Guarded, because it resizes filesystems and rewrites a unit.

set -euo pipefail

# shellcheck source=../../../lab/on-lab-vm.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

VG="labvg"
LV="labdata"
MNT="/srv/data"
LV_PATH="/dev/$VG/$LV"
UNIT="/etc/systemd/system/srv-data.mount"
WRONG_UNIT="/etc/systemd/system/srv-data-volume.mount"

die() {
	echo "$*" >&2
	exit 1
}
step() {
	printf '\n------------------------------------------------------------\n'
	printf '  %s\n' "$1"
	printf -- '------------------------------------------------------------\n'
}

# Day-specific readings. Each one asks a different layer the same question,
# which is the entire point of the day.
lv_size() { lvs --noheadings -o lv_size --units m "$VG/$LV" 2>/dev/null | tr -d ' '; }
fs_size() { df -BM --output=size "$MNT" 2>/dev/null | tail -1 | tr -d ' '; }
fs_avail() { df -BM --output=avail "$MNT" 2>/dev/null | tail -1 | tr -d ' '; }
vg_free() { vgs --noheadings -o vg_free --units m "$VG" 2>/dev/null | tr -d ' '; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "this resizes filesystems, so it needs root:  sudo $0"

HARD="no"
[[ "${1:-}" == "--hard" ]] && HARD="yes"

lvs "$VG/$LV" >/dev/null 2>&1 || die "no $VG/$LV - run:  sudo ./scripts/setup.sh"
mountpoint -q "$MNT" || die "$MNT is not mounted - run:  sudo ./scripts/setup.sh"

# ============================================================ 1
step "1. the volume grew. the filesystem did not."

echo "before anything, the two numbers that should agree:"
printf '  logical volume : %s\n' "$(lv_size)"
printf '  filesystem     : %s\n' "$(fs_size)"
echo

if [[ "$(vg_free)" == "0m" ]]; then
	echo "the volume group has no free space, so this failure cannot be shown."
	echo "run --hard instead, which is about exactly that."
else
	echo "growing the LOGICAL VOLUME by 256 MB and nothing else:"
	lvextend -L +256M "$VG/$LV"
	echo
	printf '  logical volume : %s   <- grew\n' "$(lv_size)"
	printf '  filesystem     : %s   <- did not\n' "$(fs_size)"
	echo
	echo "this is the most common LVM mistake there is. lvextend worked"
	echo "perfectly. the filesystem inside the volume simply does not know the"
	echo "container got bigger, and it will not find out on its own. df keeps"
	echo "reporting the old size, so it reads as 'lvextend did nothing'."
	echo
	echo "the fix is a second, separate command - and it works MOUNTED, with"
	echo "the filesystem in use, which is the thing worth knowing today:"
	echo "  resize2fs $LV_PATH"
	resize2fs "$LV_PATH"
	echo
	printf '  logical volume : %s\n' "$(lv_size)"
	printf '  filesystem     : %s   <- now it matches\n' "$(fs_size)"
	echo
	echo "for xfs the command is xfs_growfs and it takes the MOUNT POINT, not"
	echo "the device:  xfs_growfs $MNT. and xfs can only ever grow."
fi

# ============================================================ 2
step "2. a mount unit systemd ignores completely"

echo "writing the same working configuration under a different filename:"
echo "  $WRONG_UNIT"
sed 's/Description=.*/Description=Day 04 data volume (misnamed)/' "$UNIT" >"$WRONG_UNIT"
systemctl daemon-reload

echo
echo "systemd's opinion of it:"
systemctl status srv-data-volume.mount --no-pager 2>&1 | head -5 | sed 's/^/  /' || true

echo
echo "the file is valid. the mount options are correct. systemd will not use"
echo "it, and if the real unit were absent this mount would simply never"
echo "happen at boot, with no error that names the cause."
echo
echo "a .mount unit's filename is not a label - systemd derives it from the"
echo "mount path by escaping the slashes. /srv/data is srv-data.mount, and"
echo "nothing else. the tool that tells you the correct name:"
echo "  systemd-escape -p --suffix=mount $MNT"
systemd-escape -p --suffix=mount "$MNT" 2>/dev/null | sed 's/^/  -> /' || true

echo
echo "removing the misnamed file:"
rm -fv "$WRONG_UNIT"
systemctl daemon-reload
systemctl is-enabled srv-data.mount 2>/dev/null | sed 's/^/  real unit: /' || true

# ============================================================ 3
step "3. the disk is full and du cannot find the files"

echo "filling $MNT until writes fail:"
dd if=/dev/zero of="$MNT/filler.bin" bs=1M status=none 2>/dev/null || true
echo
df -h "$MNT" | sed 's/^/  /'
echo
echo "now the interesting version. a file is created, opened, and deleted"
echo "while still open - then we ask both tools where the space went."

rm -f "$MNT/filler.bin"

# Hold a deleted file open in a background subshell. Its blocks stay
# allocated for as long as that shell lives.
dd if=/dev/zero of="$MNT/ghost.bin" bs=1M count=200 status=none 2>/dev/null || true
(
	exec 3<"$MNT/ghost.bin"
	rm -f "$MNT/ghost.bin"
	sleep 25
) &
holder=$!
sleep 3

echo
echo "df - asks the filesystem how many blocks are spent:"
df -h "$MNT" | sed 's/^/  /'
echo
echo "du - walks the directory tree and adds up what it can see:"
du -sh "$MNT" 2>/dev/null | sed 's/^/  /'
echo
echo "ls - there is nothing there at all:"
ls -la "$MNT" | sed 's/^/  /'
echo
echo "the space is spent and the file has no name. it has not leaked and it"
echo "is not corruption: a file's blocks are freed when the last NAME and the"
echo "last OPEN DESCRIPTOR are both gone. one process still holds a"
echo "descriptor, so the kernel is keeping its blocks."
echo
echo "the only tool that finds it - link count below 1:"
if command -v lsof >/dev/null 2>&1; then
	lsof +L1 2>/dev/null | head -5 | sed 's/^/  /' || echo "  (nothing reported)"
else
	echo "  lsof is not installed. install it - this is what it is for:"
	echo "    dnf install -y lsof"
	echo "  the same thing through /proc, which is always available:"
	ls -l /proc/"$holder"/fd 2>/dev/null | sed 's/^/    /' || true
fi

echo
echo "the fix is never rm - there is nothing to remove. you restart or signal"
echo "whatever holds the descriptor. waiting for the holder to exit:"
wait "$holder" 2>/dev/null || true
sleep 1
df -h "$MNT" | sed 's/^/  /'
echo
echo "the space returned the instant that process ended, with no file ever"
echo "deleted. this is why 'truncate the log file instead of deleting it' is"
echo "the advice for a full disk caused by a running daemon:"
echo "  : > /var/log/something.log"

if [[ "$HARD" != "yes" ]]; then
	echo
	echo "------------------------------------------------------------"
	echo "three down. for the two that catch people out later:"
	echo "  sudo $0 --hard"
	exit 0
fi

# ============================================================ 4
step "4. --hard: lvextend refuses, and the number to read first"

echo "free space left in the group:"
printf '  vg_free: %s\n' "$(vg_free)"
echo
echo "asking for far more than exists:"
lvextend -L +50G "$VG/$LV" 2>&1 | head -4 | sed 's/^/  /' || true
echo
echo "read the error carefully - it is not about the logical volume at all."
echo "an LV can only be grown into space the VOLUME GROUP still has. when"
echo "vg_free reaches zero, no lvextend of any size will work."
echo
echo "the fix is not a bigger lvextend. it is more disk in the group:"
echo "  # from your laptop:"
echo "  ./lab/lab.sh add-disk node1 2"
echo "  # then on the VM:"
echo "  pvcreate /dev/vdc && vgextend $VG /dev/vdc"
echo "  vgs $VG                       # vg_free is now larger"
echo
echo "filling the group completely instead, using every extent that is left:"
lvextend -l +100%FREE "$VG/$LV" 2>&1 | tail -2 | sed 's/^/  /' || true
resize2fs "$LV_PATH" 2>&1 | tail -2 | sed 's/^/  /' || true
printf '  vg_free now: %s\n' "$(vg_free)"
echo "  (-l +100%%FREE takes extents rather than megabytes, which is how you"
echo "   avoid arithmetic and rounding errors on a real machine)"

# ============================================================ 5
step "5. --hard: shrinking, which is where data gets destroyed"

echo "the filesystem is ext4, so shrinking is at least possible - but not"
echo "while it is mounted. asking anyway:"
resize2fs "$LV_PATH" 256M 2>&1 | head -4 | sed 's/^/  /' || true

echo
echo "that refusal is a safety feature. an online shrink would have to move"
echo "blocks that are in use underneath a running filesystem, so ext4 will"
echo "only shrink while unmounted, after a full fsck."
echo
echo "and the order is the opposite of growing. this is the sequence that"
echo "destroys a filesystem when done wrong:"
echo
echo "  GROW:    lvextend  ->  resize2fs        volume first, then filesystem"
echo "  SHRINK:  resize2fs ->  lvreduce         filesystem FIRST, then volume"
echo
echo "shrink the volume before the filesystem and you have just cut the end"
echo "off a filesystem that still believes it owns those blocks. there is no"
echo "repair for that beyond a restore."
echo
echo "xfs, which is the Rocky and RHEL default, cannot shrink at all. the"
echo "answer there is a new smaller volume and a copy. that is not a"
echo "limitation to work around, it is the reason to start volumes small and"
echo "grow them - which is why setup.sh gave you 512 MB."

step "back to a known state"
echo "nothing above needs undoing: the volume is larger than it started and"
echo "the filesystem matches it, which is a perfectly good place to be."
echo
echo "to return to a fresh 512 MB volume:"
echo "  sudo ./scripts/teardown.sh && sudo ./scripts/setup.sh"
echo
echo "then confirm the day:"
echo "  ./verify.sh"
