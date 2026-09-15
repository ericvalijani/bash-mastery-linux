#!/usr/bin/env bash
#
# Day 20 tour - twelve read-only stops across the backup, the schedule and
# the restore. Changes nothing. Run it on node1 after setup.sh.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

say()  { printf '\n==> %s\n\n' "$*"; }
note() { printf '        %s\n' "$*"; }
run()  { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/  /' || true; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || { printf 'needs root:  sudo %s\n' "$0" >&2; exit 1; }

ENV_FILE="/etc/restic/env"
[[ -r "$ENV_FILE" ]] || { printf 'no %s - run scripts/setup.sh first\n' "$ENV_FILE" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

DATA="/srv/data"
RESTORE="/var/tmp/restore"
PASSF="${RESTIC_PASSWORD_FILE:-/etc/restic/password}"
TIMING="/var/lib/lab-backup/last-restore-seconds"

say "1. where the repository is, and where it is not"
run "cat $ENV_FILE"
note "sftp: means the repository is a directory on another host, reached over"
note "ssh. No agent runs there, nothing is installed there, and control never"
note "learns the password - so it cannot read what it stores."

say "2. the password is a file, not a variable"
run "stat -c '%a %U:%G %n' $PASSF"
note "RESTIC_PASSWORD would work too, and would be visible in the process"
note "environment to anyone who can read /proc, plus your shell history."
note "A path is not a secret; the file it points at is, and it is 0600 root."

say "3. what a snapshot actually is"
run "restic snapshots"
note "Each line is one point in time, with the host and tags it was taken with."
note "The short ID is what you pass to restore, and it is a prefix of the long"
note "one - which is a content hash, not a counter."

say "4. the repository is content-addressed, so the second backup is cheap"
run "restic stats --mode raw-data"
run "restic stats --mode restore-size"
note "restore-size is what you would get back; raw-data is what is stored."
note "The gap is deduplication: identical chunks are stored once no matter how"
note "many snapshots reference them. This is why keeping seven daily snapshots"
note "does not cost seven times the disk."

say "5. reading the inside of a snapshot without restoring it"
run "restic ls latest | head -15"
note "Paths are absolute, as they were on this host. That is why a restore of"
note "$DATA into $RESTORE lands at $RESTORE$DATA and not at $RESTORE."

say "6. what changed between the last two snapshots"
IDS="$(restic snapshots --json 2>/dev/null | grep -o 'short_id":"[a-f0-9]*' | cut -d'"' -f3 | tail -2)"
if [[ "$(printf '%s\n' "$IDS" | grep -c .)" -ge 2 ]]; then
	A="$(printf '%s\n' "$IDS" | head -1)"
	B="$(printf '%s\n' "$IDS" | tail -1)"
	run "restic diff $A $B"
else
	note "only one snapshot so far. Take another:  sudo lab-backup run"
	note "then come back - restic diff <old> <new> is how you answer 'what did"
	note "this deploy change on disk', months later."
fi

say "7. the service, and the environment it does not inherit"
run "systemctl cat restic-backup.service"
note "EnvironmentFile is the whole trick. A timer's service starts with almost"
note "no environment: no RESTIC_REPOSITORY, no PATH you set, no shell profile."
note "A backup that works by hand and not on the timer is nearly always this."

say "8. the timer, and when it will next fire"
run "systemctl cat restic-backup.timer"
run "systemctl list-timers restic-backup.timer --no-pager"
note "LAST and NEXT are the two columns worth trusting. 'enabled' only means"
note "it will start at boot; it says nothing about whether it has ever run."

say "9. what the last scheduled run actually did"
run "journalctl -u restic-backup.service -n 25 --no-pager"
note "restic writes its summary here: files added, bytes added, time taken."
note "This is the log you read when someone asks why last night was slow."

say "10. integrity, which is not the same as the files being there"
run "restic check"
note "This verifies the repository's structure. 'restic check --read-data'"
note "re-reads every byte and is the only version that catches storage that"
note "silently returns the wrong data. It is slow on purpose."

say "11. the restore that has already happened"
if [[ -d "$RESTORE$DATA" ]]; then
	run "diff -r $DATA $RESTORE$DATA && echo identical"
	run "stat -c '%a %U:%G %n' $DATA/conf/token $RESTORE$DATA/conf/token"
	note "Same bytes and same mode. A restore that loses the mode on a 0600 file"
	note "has handed you a different problem from the one you were recovering."
else
	note "no restore tree yet. Run:  sudo lab-backup drill"
fi

say "12. the number nobody can look up for you"
if [[ -r "$TIMING" ]]; then
	run "cat $TIMING"
	note "Seconds, for $(du -sh "$DATA" 2>/dev/null | cut -f1) over a LAN, on an"
	note "idle VM. Scale that honestly: ten times the data over a slower link"
	note "during an incident is not ten times this number, it is worse. The only"
	note "way to know yours is to have run it, which you now have."
else
	note "never timed here. sudo lab-backup drill"
fi

say "end of the tour"
note "Break it on purpose next:  sudo ./scripts/break-and-fix.sh"
