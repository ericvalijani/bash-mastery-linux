#!/usr/bin/env bash
#
# Day 20 teardown - undo setup.sh. Role-aware, like setup.sh.
#
#   node1:    sudo ./scripts/teardown.sh          timer, unit, payload, config,
#                                                 restore tree. Leaves /srv/data
#                                                 and the repository alone.
#             sudo ./scripts/teardown.sh --all    also deletes /srv/data and the
#                                                 repository password
#
#   control:  sudo ./scripts/teardown.sh          nothing destructive
#             sudo ./scripts/teardown.sh --all    removes the repository AND
#                                                 the restic user - every
#                                                 snapshot, permanently

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

say()  { printf '\n==> %s\n\n' "$*"; }
ok()   { printf '  ok    %s\n' "$*"; }
note() { printf '        %s\n' "$*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || { printf 'needs root:  sudo %s %s\n' "$0" "${1:-}" >&2; exit 1; }

ALL="${1:-}"
ROLE="${ROLE:-$(hostname -s)}"

DATA="/srv/data"
CONF_DIR="/etc/restic"
RESTORE="/var/tmp/restore"
UNIT="/etc/systemd/system/restic-backup.service"
TIMER="/etc/systemd/system/restic-backup.timer"
PAYLOAD="/usr/local/bin/lab-backup"
BACKUP_DIR="/tmp/day20-broken"
REPO_USER="restic"
REPO_HOME="/srv/restic"

teardown_node1() {
	say "the schedule"
	systemctl disable --now restic-backup.timer >/dev/null 2>&1 || true
	systemctl stop restic-backup.service >/dev/null 2>&1 || true
	ok "timer disabled and stopped"

	say "units and payload"
	for f in "$TIMER" "$UNIT" "$PAYLOAD" /usr/sbin/lab-backup "$CONF_DIR/exclude"; do
		if [[ -e "$f" ]]; then
			rm -f "$f"
			ok "removed $f"
		fi
	done
	systemctl daemon-reload
	ok "daemon-reload"

	say "the restore tree and the timing record"
	rm -rf "$RESTORE" /var/lib/lab-backup /var/cache/restic
	ok "removed $RESTORE, /var/lib/lab-backup and /var/cache/restic"

	say "break-and-fix leftovers"
	if [[ -d "$BACKUP_DIR" ]]; then
		rm -rf "$BACKUP_DIR"
		ok "removed $BACKUP_DIR"
	else
		ok "nothing in $BACKUP_DIR"
	fi

	if [[ "$ALL" != "--all" ]]; then
		say "kept on purpose"
		note "$CONF_DIR - including the password. Delete that and the snapshots"
		note "on control become unreadable, so it is not going anywhere without"
		note "you asking for it."
		note "$DATA - the data itself."
		printf '\n'
		note "Everything, including both:  sudo ./scripts/teardown.sh --all"
		note "Rebuild:                     sudo ./scripts/setup.sh <control-ip>"
		return 0
	fi

	say "--all: the password and the data"
	rm -rf "$CONF_DIR"
	ok "removed $CONF_DIR"
	note "any snapshots still on control are now unreadable - that is what"
	note "deleting a repository password means"
	rm -rf "$DATA"
	ok "removed $DATA"

	say "done"
	note "To remove the repository too, run on control:"
	note "  sudo ./scripts/teardown.sh --all"
	note "Rebuild from scratch: setup.sh on control, then here, twice."
}

teardown_control() {
	if [[ "$ALL" != "--all" ]]; then
		say "nothing to undo here without --all"
		note "control holds the repository. Removing it deletes every snapshot,"
		note "so it takes an explicit flag:"
		note "  sudo ./scripts/teardown.sh --all"
		printf '\n'
		note "Current state:"
		if id "$REPO_USER" >/dev/null 2>&1; then
			note "  user $REPO_USER: present"
		else
			note "  user $REPO_USER: absent"
		fi
		if [[ -d "$REPO_HOME/repo" ]]; then
			note "  $REPO_HOME/repo: $(du -sh "$REPO_HOME/repo" 2>/dev/null | cut -f1)"
		fi
		return 0
	fi

	say "--all: the repository"
	if [[ -d "$REPO_HOME" ]]; then
		rm -rf "$REPO_HOME"
		ok "removed $REPO_HOME - every snapshot with it"
	else
		ok "no $REPO_HOME"
	fi

	say "--all: the account"
	if id "$REPO_USER" >/dev/null 2>&1; then
		userdel -r "$REPO_USER" >/dev/null 2>&1 || userdel "$REPO_USER" >/dev/null 2>&1 || true
		ok "removed user $REPO_USER"
	else
		ok "no user $REPO_USER"
	fi

	say "done"
	note "node1 still has its config and its key. Rebuild with setup.sh here"
	note "first, then node1 twice - the key exchange has to happen again."
}

case "$ROLE" in
control) teardown_control ;;
node1)   teardown_node1 ;;
*)
	printf 'cannot tell which host this is (hostname -s said %s).\n' "$ROLE" >&2
	printf 'Run it as:  sudo ROLE=control %s %s\n' "$0" "$ALL" >&2
	printf '        or:  sudo ROLE=node1 %s %s\n' "$0" "$ALL" >&2
	exit 1
	;;
esac
