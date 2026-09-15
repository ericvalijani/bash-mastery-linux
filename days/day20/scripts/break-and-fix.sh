#!/usr/bin/env bash
#
# Day 20 break-and-fix - four ways a backup stops being a backup, plus a
# fifth with --hard that produces snapshots containing nothing.
#
# Run on node1, after setup.sh:
#
#   sudo ./scripts/break-and-fix.sh          four failures, each repaired
#   sudo ./scripts/break-and-fix.sh --hard   the silent one, left for you
#
# Everything it touches is put back, except under --hard.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

say()  { printf '\n==> %s\n\n' "$*"; }
note() { printf '        %s\n' "$*"; }
run()  { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/  /' || true; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || { printf 'needs root:  sudo %s\n' "$0" >&2; exit 1; }

DATA="/srv/data"
CONF_DIR="/etc/restic"
ENV_FILE="$CONF_DIR/env"
PASS_FILE="$CONF_DIR/password"
UNIT="/etc/systemd/system/restic-backup.service"
EXCLUDE="$CONF_DIR/exclude"
BACKUP_DIR="/tmp/day20-broken"
HARD="${1:-}"

[[ -r "$ENV_FILE" ]] || { printf 'no %s - run scripts/setup.sh first\n' "$ENV_FILE" >&2; exit 1; }
install -d -m 0755 "$BACKUP_DIR"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# ---------------------------------------------------------------------------
say "failure 1: the password file is gone"

cp -a "$PASS_FILE" "$BACKUP_DIR/password.orig"
mv "$PASS_FILE" "$BACKUP_DIR/password.moved"
note "moved $PASS_FILE out of the way"
printf '\n'
run "restic snapshots"
note "restic cannot open the repository without it. Nothing is damaged - the"
note "repository is intact and unreadable, which is the same thing as lost."
note "There is no recovery path here: no password, no data. This is the one"
note "failure in this file you cannot fix from this host."
printf '\n'
note "fix: put it back (and in real life, keep a copy somewhere else)"
run "install -m 0600 -o root -g root $BACKUP_DIR/password.moved $PASS_FILE"
run "restic snapshots --compact | tail -3"

# ---------------------------------------------------------------------------
say "failure 2: the repository host is unreachable"

REPO_HOST="$(printf '%s' "${RESTIC_REPOSITORY:-}" | sed 's/^sftp://; s/:.*$//; s/^.*@//')"
note "the repository lives on $REPO_HOST"
note "simulating the outage by pointing at a host that is not there"
printf '\n'
run "RESTIC_REPOSITORY=sftp:restic@192.0.2.9:/srv/restic/repo timeout 20 restic snapshots"
note "That error is a network error wearing a backup error's clothes. Before"
note "you suspect restic, prove the transport:"
run "ssh -o BatchMode=yes -o ConnectTimeout=5 restic@$REPO_HOST true && echo 'ssh works'"
note "ssh works, so the repository is fine and the address was the problem."
note "This is also what a real outage looks like - which is why the timer"
note "failing for three weeks is something you have to notice deliberately."

# ---------------------------------------------------------------------------
say "failure 3: it works by hand and fails on the timer"

cp -a "$UNIT" "$BACKUP_DIR/restic-backup.service.orig"
sed -i '/^EnvironmentFile=/d' "$UNIT"
systemctl daemon-reload
note "removed EnvironmentFile= from $UNIT"
printf '\n'
note "by hand, in a shell that has the environment loaded:"
run "lab-backup run >/dev/null 2>&1 && echo 'works by hand'"
note "and now the same command under systemd, which has no such shell:"
run "systemctl start restic-backup.service; systemctl show restic-backup.service -p ExecMainStatus --value"
run "journalctl -u restic-backup.service -n 8 --no-pager"
note "Non-zero, and the log says it has no repository. The service did not"
note "inherit your environment because services never do. Every 'but it works"
note "when I run it' ticket is some version of this."
printf '\n'
note "fix: give the unit its own environment"
run "install -m 0644 $BACKUP_DIR/restic-backup.service.orig $UNIT && systemctl daemon-reload"
run "systemctl start restic-backup.service; systemctl show restic-backup.service -p ExecMainStatus --value"

# ---------------------------------------------------------------------------
say "failure 4: a stale lock from a run that was killed"

note "restic locks the repository while it writes. Kill a backup mid-flight -"
note "a reboot, an OOM kill, a node fenced - and the lock outlives it."
printf '\n'
# Kill it by PID, not by %1. Job control is off in a non-interactive shell,
# so a jobspec can quietly fail to match - and then the backup keeps running
# as an orphan, refreshing its lock every few minutes. A lock with a live
# owner is not stale, cannot be unlocked, and comes straight back after
# --remove-all. That is a much worse day than the one this is teaching.
# Note the quoting: the pid variables are inside SINGLE quotes so that the
# inner `bash -c` expands them. In double quotes this script would expand
# `$!` itself - and with `set -u` and no background job of its own, that is
# an unbound variable and an instant exit.
run 'restic backup '"$DATA"' --tag day20 & BPID=$!; sleep 2; kill -9 $BPID 2>/dev/null; wait $BPID 2>/dev/null'
sleep 1
if pgrep -f "restic backup" >/dev/null 2>&1; then
	note "A restic backup is still running after the kill. Ending it, because a"
	note "live process would keep re-taking the lock this failure is about:"
	run "pkill -9 -f 'restic backup'; sleep 1; pgrep -af restic || echo 'no restic process left'"
fi
run "restic list locks"
run "timeout 25 restic backup $DATA --tag day20"
note "If that refused with a locked repository, you have just met the failure"
note "that stops tonight's backup and every one after it, silently, until"
note "someone reads the log."
printf '\n'
note "fix: remove locks that no live process owns"
run "restic unlock"
run "restic list locks"

# `restic unlock` on its own removes only locks it can PROVE are stale: same
# host, and a pid that is not running. The lock a kill -9 leaves here is
# often not provably stale, so it survives the unlock and every backup after
# it keeps refusing - which is exactly the trap, so say so instead of
# pretending one unlock is always enough.
if restic list locks 2>/dev/null | grep -q .; then
	printf '\n'
	note "The lock is still there. unlock removes only locks it can prove are"
	note "stale, and it cannot prove that about this one. When you know no"
	note "backup is running anywhere - check first, on every host that writes"
	note "to this repository - you can remove all of them:"
	run "systemctl is-active restic-backup.service || true"
	run "pgrep -af restic || echo 'no restic process is running here'"
	note "That line matters more than the unlock. A lock that comes back after"
	note "--remove-all is not stale at all - it belongs to a process that is"
	note "still alive and refreshing it. Find that process before you unlock."
	run "restic unlock --remove-all"
	run "restic list locks"
	note "--remove-all on a busy shared repository will delete a LIVE lock and"
	note "let two backups write at once. That is why it is not the default."
fi
run "lab-backup run >/dev/null 2>&1 && echo 'backing up again'"
note "Never delete lock files by hand over sftp. restic unlock knows which"
note "locks are stale; rm does not."

# ---------------------------------------------------------------------------
if [[ "$HARD" != "--hard" ]]; then
	say "all four repaired"
	run "lab-backup status | tail -20"
	note "Confirm with:  sudo ./verify.sh"
	printf '\n'
	note "There is a fifth failure, and it is the dangerous one, because"
	note "nothing goes red. Run it when you want it:"
	note "  sudo ./scripts/break-and-fix.sh --hard"
	exit 0
fi

# ---------------------------------------------------------------------------
say "--hard: the backup that succeeds and contains nothing"

printf '%s\n' "/srv/*" >"$EXCLUDE"
cp -a "$UNIT" "$BACKUP_DIR/restic-backup.service.prehard"
sed -i "s|^ExecStart=.*|ExecStart=/usr/bin/restic backup $DATA --exclude-file=$EXCLUDE --tag day20|" "$UNIT"
systemctl daemon-reload
note "added an exclude file and pointed the unit at it"
printf '\n'
run "cat $EXCLUDE"
run "systemctl start restic-backup.service; systemctl show restic-backup.service -p ExecMainStatus --value"
run "journalctl -u restic-backup.service -n 12 --no-pager"
run "restic snapshots --compact | tail -4"

printf '\n'
note "Read that carefully. Exit 0. A new snapshot. A green timer. Every"
note "dashboard you could build from systemd says the backup is healthy."
printf '\n'
note "Now ask the only question that matters:"
run "restic ls latest | head"
printf '\n'
note "Your job: find out why, fix it, and prove it with a restore rather than"
note "with a green unit. Nothing here is hidden from you:"
note "  systemctl cat restic-backup.service"
note "  cat $EXCLUDE"
note "  restic ls latest"
note "  sudo lab-backup drill"
printf '\n'
note "Two ways out. By hand, all four lines, in this order:"
note "  sudo rm -f $EXCLUDE"
note "  sudo install -m 0644 $BACKUP_DIR/restic-backup.service.prehard $UNIT"
note "  sudo systemctl daemon-reload"
note "  sudo lab-backup unlock && sudo lab-backup run && sudo lab-backup drill"
printf '\n'
note "The unlock matters: failure 4 above left a lock behind on purpose, and"
note "verify.sh will keep saying 'no stale lock is holding the repository'"
note "until you clear it. Until you take a fresh run, 'latest' is still the"
note "empty snapshot, so the drill and verify's restore checks stay red."
printf '\n'
note "Or start the day over. BOTH of these run here on node1 - you do not log"
note "into control, and the IP is only an argument telling node1 where the"
note "repository is. One pass, not four, because the password and the"
note "authorised key both survive:"
note "  sudo ./scripts/setup.sh $(cat /etc/restic/control-ip 2>/dev/null || echo '<control-ip>')"
note "That one pass removes the exclude file, clears the lock, rewrites the"
note "unit, takes a snapshot with content, and re-runs the drill. No teardown"
note "is needed - add one only if you want the data and password gone too."
printf '\n'
note "This is the failure that ends companies. Not a backup that errors -"
note "those get noticed. A backup that reports success for eleven months and"
note "restores an empty directory. The drill is the only thing that catches it,"
note "which is why today's drill compares and does not just restore."
