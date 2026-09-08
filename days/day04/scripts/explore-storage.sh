#!/usr/bin/env bash
#
# Day 04 - read-only guided tour of the storage stack.
#
#   ./scripts/explore-storage.sh
#
# Changes nothing. No guard, because it only reads - and reading a storage
# stack you did not build is a useful thing to do on any machine, including
# your own laptop.
#
# Two blocks show more under sudo and say so where they appear.

set -uo pipefail

VG="labvg"
LV="labdata"
MNT="/srv/data"
LV_PATH="/dev/$VG/$LV"

heading() { printf '\n\n===== %s =====\n\n' "$*"; }
note() { printf '  (%s)\n\n' "$1"; }
run() {
	printf '$ %s\n' "$*"
	"$@" 2>&1 | sed 's/^/  /' || true
	printf '\n'
}
run_sh() {
	printf '$ %s\n' "$1"
	bash -c "$1" 2>&1 | sed 's/^/  /' || true
	printf '\n'
}

heading "1. every block device on this machine"

run_sh "lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS"
note "TYPE tells you what each line is: disk, part, lvm. an lvm line is a
   logical volume, and it sits under the disk it was carved from"

run_sh "lsblk -o NAME,SIZE,TYPE | grep -c . || true"
note "loop devices appear here too. if today's volume group sits on one, it
   is because setup.sh found no spare disk"

heading "2. what has a filesystem signature"

run_sh "blkid || echo '(blkid shows nothing useful without root)'"
note "blkid reads the signature at the start of a device. no signature means
   no filesystem - which is what a fresh disk looks like. needs root for the
   full list"

heading "3. the three LVM layers, one command each"

run_sh "pvs 2>/dev/null || echo '(needs root)'"
note "physical volumes: the disks LVM was given"

run_sh "vgs 2>/dev/null || echo '(needs root)'"
note "volume groups: the pool. VFree is the headroom you have to grow into,
   and the number to look at before promising anybody more space"

run_sh "lvs -o lv_name,vg_name,lv_size,devices 2>/dev/null || echo '(needs root)'"
note "logical volumes: the slices. the last column names the PV each one
   actually lives on"

heading "4. df versus du - they answer different questions"

run_sh "df -h $MNT 2>/dev/null || df -h /"
note "df asks the FILESYSTEM how many blocks are free. it counts every block
   in use, including blocks belonging to files nobody can see any more"

run_sh "du -sh $MNT 2>/dev/null || echo '(no $MNT yet - run setup.sh)'"
note "du walks the DIRECTORY TREE and adds up what it finds. it can only
   count files that still have a name"

echo "  when those two disagree by a lot, the difference is usually held by"
echo "  deleted-but-still-open files. section 7 finds them."

heading "5. how the mount is described, three different ways"

run_sh "findmnt $MNT 2>/dev/null || echo '(not mounted)'"
note "findmnt is the readable one, and it resolves the source to the real
   device-mapper name"

run_sh "grep ' $MNT ' /proc/mounts 2>/dev/null || echo '(not in /proc/mounts)'"
note "/proc/mounts is the kernel's own list. this is the authority - if a
   mount is here it exists, whatever any config file says"

run_sh "systemctl cat srv-data.mount 2>/dev/null || echo '(no unit)'"
note "and the unit is the INTENTION. the filename srv-data.mount is derived
   from the path /srv/data and is not a free choice"

run_sh "systemctl list-units --type=mount --no-pager --no-legend 2>/dev/null | head"
note "every mount on the machine is a unit, including the ones generated from
   /etc/fstab behind your back. systemd-fstab-generator writes those"

heading "6. the room left to grow"

run_sh "vgs $VG -o vg_name,vg_size,vg_free --units m 2>/dev/null || echo '(needs root)'"
run_sh "lvs $VG/$LV -o lv_name,lv_size --units m 2>/dev/null || echo '(needs root)'"
note "VFree is what lvextend can hand out. when it reaches zero the answer is
   another disk into the group with vgextend, not a bigger lvextend"

heading "7. deleted, but still costing you space"

run_sh "command -v lsof >/dev/null && (lsof +L1 2>/dev/null | head -15 || true) || echo '(lsof not installed: dnf install lsof)'"
note "+L1 means 'link count less than 1', which is exactly the set of files
   that have been deleted while something still has them open. needs root to
   see other users' processes. an empty list here is good news"

echo "  to make one on purpose and watch it happen, in two shells:"
echo "    shell 1:  lab-writer ghost $MNT 100"
echo "    shell 2:  df -h $MNT; du -sh $MNT; sudo lsof +L1"

heading "8. worth doing by hand next"

cat <<EOF
  sudo lvextend -L +256M $VG/$LV     grow the volume
  df -h $MNT                         unchanged - the fs did not move
  sudo resize2fs $LV_PATH            now grow the filesystem
  df -h $MNT                         and now it did

  sudo dumpe2fs -h $LV_PATH          the fs superblock: block count, size
  sudo tune2fs -l $LV_PATH | head    the same in a different dialect
  cat /proc/self/mountinfo | head    what the kernel tells each process
  systemctl show srv-data.mount -p After -p Requires
  man 5 systemd.mount
  man 8 lvextend
EOF

echo
echo "nothing above changed anything. the two scripts that do are setup.sh and"
echo "break-and-fix.sh, and both refuse to run outside a lab VM."
