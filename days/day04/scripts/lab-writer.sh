#!/usr/bin/env bash
#
# The payload behind Day 04. It writes files into a directory and, on request,
# holds one of them open after deleting it.
#
#   ./lab-writer.sh fill /srv/data 200      write 200 MB in 10 MB files
#   ./lab-writer.sh ghost /srv/data 100     delete a 100 MB file but keep it open
#   ./lab-writer.sh clean /srv/data         remove what fill made
#
# There is no service today. Days 01 and 03 needed a daemon because the lesson
# was about units; today the lesson is about a filesystem, and a filesystem
# does not care who writes to it. This is a plain command you run by hand.
#
# The 'ghost' mode is the whole reason this file exists. A deleted file whose
# last link is gone but which is still open by a running process keeps its
# blocks allocated - the space is spent, and no amount of ls will show you the
# file. That is the single most common cause of "df says full, du says empty",
# and it is invisible unless you know to ask lsof.

set -euo pipefail

MODE="${1:-}"
DIR="${2:-/srv/data}"
SIZE_MB="${3:-100}"

usage() {
	echo "usage: $0 fill|ghost|clean <dir> [size-in-MB]" >&2
	exit 2
}

[[ -n "$MODE" ]] || usage
[[ -d "$DIR" ]] || {
	echo "no such directory: $DIR" >&2
	exit 1
}

case "$MODE" in
fill)
	# dd rather than truncate on purpose: truncate makes a sparse file, which
	# costs no blocks at all and would teach the wrong lesson. These writes
	# really do consume the filesystem.
	echo "writing ${SIZE_MB} MB into $DIR in 10 MB pieces"
	n=0
	written=0
	while [[ $written -lt $SIZE_MB ]]; do
		n=$((n + 1))
		if ! dd if=/dev/zero of="$DIR/blob.$n" bs=1M count=10 status=none 2>/dev/null; then
			echo
			echo "write failed at piece $n - the filesystem is full."
			echo "that is ENOSPC, and it is what an application sees. it is not"
			echo "a corrupt disk and not a permissions problem:"
			echo "  df -h $DIR"
			exit 0
		fi
		written=$((written + 10))
	done
	echo "wrote $written MB as $DIR/blob.1 .. $DIR/blob.$n"
	;;
ghost)
	GHOST="$DIR/ghost.bin"
	echo "creating ${SIZE_MB} MB at $GHOST"
	dd if=/dev/zero of="$GHOST" bs=1M count="$SIZE_MB" status=none

	# Open the file on fd 3, then unlink it. The directory entry is gone, so
	# ls and du can no longer see it, but this shell still holds a reference
	# and the kernel therefore cannot release the blocks.
	exec 3<"$GHOST"
	rm -f "$GHOST"
	echo "deleted it, and still holding it open on fd 3 as pid $$"
	echo
	echo "from another shell, while this one is still running:"
	echo "  df -h $DIR          # the space is gone"
	echo "  du -sh $DIR         # du cannot see it"
	echo "  sudo lsof +L1       # NLINK 0 - there it is"
	echo
	echo "holding for 120 seconds, then closing the descriptor. press ctrl-c"
	echo "to release it sooner - the space comes back the instant this exits."
	sleep 120
	exec 3<&-
	echo "descriptor closed. the blocks are free again, with no file to delete."
	;;
clean)
	rm -f "$DIR"/blob.* "$DIR/ghost.bin"
	echo "removed the blobs from $DIR"
	;;
*)
	usage
	;;
esac
