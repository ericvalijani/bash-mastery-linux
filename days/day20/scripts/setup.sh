#!/usr/bin/env bash
#
# Day 20 setup - a backup that lives on another machine, on a timer, with a
# restore that has actually been run.
#
# Run this on BOTH VMs, with sudo, and on node1 twice - because the key that
# lets node1 write to control has to get to control somehow, and that is not
# something one command on one host can do:
#
#   control, pass 1:  sudo ./scripts/setup.sh
#                       creates the restic user and the repository directory
#
#   node1,   pass 1:  sudo ./scripts/setup.sh
#                       installs restic, makes the data, generates root's ssh
#                       key, and prints the exact command to run on control
#
#   control, pass 2:  sudo ./scripts/setup.sh 'ssh-ed25519 AAAA... root@node1'
#                       authorises that key
#
#   node1,   pass 2:  sudo ./scripts/setup.sh <control-ip>
#                       initialises the repository, backs up, restores, and
#                       puts the whole thing on a timer
#
# Leaves behind, on control:
#   user restic, home /srv/restic, shell /bin/bash (sftp needs a real shell)
#   /srv/restic/repo                 the repository, 0700, owned by restic
#   /srv/restic/.ssh/authorized_keys node1's root key
#
# Leaves behind, on node1:
#   /srv/data                        the data being protected
#   /etc/restic/password             0600, root only
#   /etc/restic/env                  RESTIC_REPOSITORY + RESTIC_PASSWORD_FILE
#   /usr/local/bin/lab-backup        the payload
#   restic-backup.service/.timer     enabled, and fired at least once
#   /var/tmp/restore                 the last restore drill
#
# Idempotent. Run it as often as you like.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

say()  { printf '\n==> %s\n\n' "$*"; }
die()  { printf '\nfailed: %s\n' "$*" >&2; exit 1; }
ok()   { printf '  ok    %s\n' "$*"; }
note() { printf '        %s\n' "$*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "needs root:  sudo $0 $*"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_SRC="$HERE/lab-backup.sh"
PAYLOAD="/usr/local/bin/lab-backup"

REPO_USER="restic"
REPO_HOME="/srv/restic"
REPO_PATH="$REPO_HOME/repo"

DATA="/srv/data"
CONF_DIR="/etc/restic"
PASS_FILE="$CONF_DIR/password"
ENV_FILE="$CONF_DIR/env"
UNIT="/etc/systemd/system/restic-backup.service"
TIMER="/etc/systemd/system/restic-backup.timer"
BACKUP_DIR="/tmp/day20-broken"

ROLE="${ROLE:-$(hostname -s)}"

# ---------------------------------------------------------------------------
# control: hold the repository, and nothing else
# ---------------------------------------------------------------------------
setup_control() {
	PUBKEY="${1:-}"

	say "1. the account that owns the repository"

	if id "$REPO_USER" >/dev/null 2>&1; then
		ok "user $REPO_USER already exists"
	else
		# A real shell, deliberately. restic over sftp runs the remote
		# sftp-server through the user's login shell, so /sbin/nologin
		# produces "connection lost" with nothing in any log to explain it.
		useradd --system --create-home --home-dir "$REPO_HOME" --shell /bin/bash "$REPO_USER"
		ok "created $REPO_USER with home $REPO_HOME"
	fi
	note "shell: $(getent passwd "$REPO_USER" | cut -d: -f7) - sftp needs one that works"

	install -d -m 0700 -o "$REPO_USER" -g "$REPO_USER" "$REPO_HOME"
	install -d -m 0700 -o "$REPO_USER" -g "$REPO_USER" "$REPO_PATH"
	ok "$REPO_PATH is 0700 and owned by $REPO_USER"

	say "2. authorising node1's key"

	install -d -m 0700 -o "$REPO_USER" -g "$REPO_USER" "$REPO_HOME/.ssh"
	AUTH="$REPO_HOME/.ssh/authorized_keys"
	touch "$AUTH"
	chown "$REPO_USER:$REPO_USER" "$AUTH"
	chmod 0600 "$AUTH"

	# SELinux, and this one is worth knowing about. sshd will only read an
	# authorized_keys file labelled ssh_home_t. This home is under /srv, which
	# the policy does not consider a home directory, so the file comes out as
	# var_t and sshd silently refuses the key: the client sees
	# "Permission denied (publickey)" and nothing on this side looks wrong,
	# because nothing about the owner or the mode IS wrong.
	if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" != "Disabled" ]]; then
		if ! command -v semanage >/dev/null 2>&1; then
			note "installing policycoreutils-python-utils for semanage"
			dnf install -y policycoreutils-python-utils >/dev/null 2>&1 || true
		fi
		if command -v semanage >/dev/null 2>&1; then
			# Tell the policy to treat this path like a home directory.
			semanage fcontext -a -e "/home/$REPO_USER" "$REPO_HOME" >/dev/null 2>&1 ||
				semanage fcontext -m -e "/home/$REPO_USER" "$REPO_HOME" >/dev/null 2>&1 || true
			restorecon -RF "$REPO_HOME" >/dev/null 2>&1 || true
		fi
		# Belt and braces: correct now even if semanage is unavailable.
		chcon -R -t ssh_home_t "$REPO_HOME/.ssh" >/dev/null 2>&1 || true
		CTX="$(ls -Zd "$REPO_HOME/.ssh" 2>/dev/null | awk '{print $1}')"
		if [[ "$CTX" == *ssh_home_t* ]]; then
			ok "SELinux label on $REPO_HOME/.ssh is ssh_home_t"
		else
			note "SELinux label is $CTX - sshd may refuse the key. See:"
			note "  ausearch -m avc -ts recent"
		fi
	fi

	if [[ -z "$PUBKEY" ]]; then
		if [[ -s "$AUTH" ]]; then
			ok "$AUTH already has $(wc -l <"$AUTH") key(s)"
		else
			note "no key yet, and no key given on the command line"
		fi
		printf '\n'
		note "Next, on node1:"
		note "  sudo ./scripts/setup.sh"
		note "It will print its root public key and the command to run back here."
	else
		if grep -qF "$PUBKEY" "$AUTH" 2>/dev/null; then
			ok "that key is already authorised"
		else
			printf '%s\n' "$PUBKEY" >>"$AUTH"
			ok "authorised the key in $AUTH"
		fi
		printf '\n'
		note "Next, on node1:"
		note "  sudo ./scripts/setup.sh $(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {print $7; exit}')"
	fi

	say "3. what control does NOT have"

	note "no restic, no password, no key to node1. A machine that stores your"
	note "backups does not need to be able to read them, and should not be able"
	note "to start the backup either - that direction is the one an attacker on"
	note "control would use."

	say "done"
	note "Nothing else runs here. The rest of today is on node1."
}

# ---------------------------------------------------------------------------
# node1: the data, the schedule, and the drill
# ---------------------------------------------------------------------------
setup_node1() {
	CONTROL_IP="${1:-}"
	SAVED="$CONF_DIR/control-ip"

	install -d -m 0700 "$CONF_DIR"
	install -d -m 0755 "$BACKUP_DIR"

	if [[ -z "$CONTROL_IP" && -r "$SAVED" ]]; then
		CONTROL_IP="$(cat "$SAVED")"
	fi

	# -----------------------------------------------------------------------
	say "1. restic, from EPEL"

	if ! rpm -q epel-release >/dev/null 2>&1; then
		dnf install -y epel-release >/dev/null 2>&1 || die "could not enable EPEL"
		ok "enabled EPEL"
	else
		ok "EPEL is already enabled"
	fi

	for p in restic jq; do
		if rpm -q "$p" >/dev/null 2>&1; then
			ok "$p is installed"
		else
			dnf install -y "$p" >/dev/null 2>&1 || die "could not install $p"
			ok "installed $p"
		fi
	done
	note "restic $(restic version 2>/dev/null | awk '{print $2}')"

	# -----------------------------------------------------------------------
	say "2. the data worth protecting"

	if [[ -d "$DATA" ]] && [[ -n "$(ls -A "$DATA" 2>/dev/null)" ]]; then
		ok "$DATA already exists - leaving it alone"
	else
		install -d -m 0755 "$DATA"
		install -d -m 0755 "$DATA/conf" "$DATA/uploads"
		printf 'site=lab\nowner=%s\n' "$(hostname -s)" >"$DATA/conf/app.conf"
		printf 'secret-ish, and only on this host\n' >"$DATA/conf/token"
		chmod 0600 "$DATA/conf/token"
		# A file big enough that a restore takes measurable time.
		head -c 8000000 /dev/urandom >"$DATA/uploads/blob.bin"
		for i in 1 2 3 4 5; do
			printf 'record %s written by %s\n' "$i" "$(hostname -s)" >"$DATA/uploads/record-$i.txt"
		done
		ok "created $DATA ($(du -sh "$DATA" | cut -f1))"
	fi
	note "files: $(find "$DATA" -type f | wc -l), size: $(du -sh "$DATA" | cut -f1)"

	# -----------------------------------------------------------------------
	say "3. root's ssh key, which is how node1 reaches the repository"

	KEY="/root/.ssh/id_ed25519"
	install -d -m 0700 /root/.ssh
	if [[ -f "$KEY" ]]; then
		ok "$KEY already exists"
	else
		ssh-keygen -t ed25519 -N '' -C "root@$(hostname -s)" -f "$KEY" >/dev/null
		ok "generated $KEY"
	fi
	PUB="$(cat "$KEY.pub")"

	if [[ -z "$CONTROL_IP" ]]; then
		printf '\n'
		say "pass 1 done - now do the out-of-band half"
		note "On control, run exactly this:"
		printf '\n'
		printf "  sudo ./scripts/setup.sh '%s'\n" "$PUB"
		printf '\n'
		note "Then come back here with control's address:"
		note "  sudo ./scripts/setup.sh <control-ip>"
		printf '\n'
		note "Run ./lab/lab.sh status on your laptop for that address."
		note "Nothing is broken. The key has to travel by hand, and a private"
		note "key that travelled is not a private key - so the public half goes"
		note "and this host keeps the other."
		exit 0
	fi

	printf '%s\n' "$CONTROL_IP" >"$SAVED"
	chmod 0600 "$SAVED"
	ok "repository host: $CONTROL_IP (remembered in $SAVED)"

	# -----------------------------------------------------------------------
	say "4. can this host actually write to the repository host"

	if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
		-o ConnectTimeout=5 "$REPO_USER@$CONTROL_IP" true >/dev/null 2>&1; then
		ok "ssh $REPO_USER@$CONTROL_IP works without a password"
	else
		printf '\n'
		note "ssh to $REPO_USER@$CONTROL_IP failed. On control, run:"
		printf '\n'
		printf "  sudo ./scripts/setup.sh '%s'\n" "$PUB"
		printf '\n'
		note "Then run this script again."
		printf '\n'
		note "Diagnose it yourself - as ROOT, with root's key, because that is"
		note "who runs the backup. Your own user has no key on control, so"
		note "'ssh -v $REPO_USER@$CONTROL_IP' as yourself will always be denied:"
		note "  sudo ssh -v -i /root/.ssh/id_ed25519 $REPO_USER@$CONTROL_IP true"
		printf '\n'
		note "If that still says 'Permission denied (publickey)' while control"
		note "says the key is authorised, suspect SELinux on control: sshd only"
		note "reads an authorized_keys labelled ssh_home_t, and $REPO_HOME is"
		note "not a home directory as far as the policy is concerned. On control:"
		note "  ls -Zd $REPO_HOME/.ssh"
		note "  sudo ausearch -m avc -ts recent"
		note "Re-running setup.sh on control relabels it."
		die "the repository host is not reachable as $REPO_USER"
	fi

	# -----------------------------------------------------------------------
	say "5. the password, and where it is not"

	if [[ -s "$PASS_FILE" ]]; then
		ok "$PASS_FILE already exists - not regenerating it"
	else
		# Lose this and the repository is landfill. That is the trade restic
		# makes for a repository the storage host cannot read.
		openssl rand -base64 24 >"$PASS_FILE"
		ok "generated a new repository password"
	fi
	chmod 0600 "$PASS_FILE"
	chown root:root "$PASS_FILE"
	ok "$PASS_FILE is $(stat -c '%a %U:%G' "$PASS_FILE")"

	cat >"$ENV_FILE" <<EOF
# Day 20 - read by /usr/local/bin/lab-backup and by restic-backup.service.
#
# RESTIC_PASSWORD_FILE, never RESTIC_PASSWORD: a password in an environment
# variable is readable in /proc and lands in your shell history. A path is
# not a secret.
RESTIC_REPOSITORY=sftp:$REPO_USER@$CONTROL_IP:$REPO_PATH
RESTIC_PASSWORD_FILE=$PASS_FILE
EOF
	chmod 0600 "$ENV_FILE"
	ok "wrote $ENV_FILE"
	note "repository: sftp:$REPO_USER@$CONTROL_IP:$REPO_PATH"
	note "The password is on node1. The data is on node1. The repository is"
	note "not - and that is the only part of this that makes it a backup."

	set -a
	# shellcheck disable=SC1090
	source "$ENV_FILE"
	set +a

	# -----------------------------------------------------------------------
	say "6. the repository itself"

	if restic snapshots >/dev/null 2>&1; then
		ok "the repository already exists and the password opens it"
	else
		if restic init >"$BACKUP_DIR/init.log" 2>&1; then
			ok "initialised the repository"
		else
			sed 's/^/        /' "$BACKUP_DIR/init.log" >&2
			die "restic init failed - the log above is the whole story"
		fi
	fi

	# -----------------------------------------------------------------------
	say "7. the payload and the schedule"

	[[ -f "$PAYLOAD_SRC" ]] || die "missing $PAYLOAD_SRC"
	install -m 0755 "$PAYLOAD_SRC" "$PAYLOAD"
	ok "installed $PAYLOAD"

	# sudo does not use your PATH. It uses secure_path from /etc/sudoers, and
	# on Rocky that does not include /usr/local/bin - so `sudo lab-backup`
	# says "command not found" for a command that is installed and on your
	# own PATH. A symlink into a directory secure_path does list fixes it.
	ln -sf "$PAYLOAD" /usr/sbin/lab-backup
	ok "linked /usr/sbin/lab-backup so sudo can find it"

	# restic works out its cache directory from $HOME or $XDG_CACHE_HOME. A
	# systemd service has neither, so the scheduled run dies with "unable to
	# locate cache directory" while the same command by hand works perfectly.
	install -d -m 0700 -o root -g root /var/cache/restic
	ok "created /var/cache/restic for the scheduled run"

	# break-and-fix.sh --hard leaves two things behind that this script used
	# to walk straight past: an exclude file that empties every snapshot, and
	# possibly a stale lock from a killed run. The unit gets rewritten below,
	# so the exclude would stop being referenced but the empty snapshots would
	# stay latest - and then the drill at step 9 fails with "the restore did
	# not match" and no explanation. Clear both, out loud.
	if [[ -f "$CONF_DIR/exclude" ]]; then
		rm -f "$CONF_DIR/exclude"
		ok "removed the leftover $CONF_DIR/exclude from break-and-fix.sh --hard"
		note "that file is why the last snapshots were empty. A fresh backup"
		note "is taken below, so the newest snapshot will have content again."
	fi

	if restic list locks 2>/dev/null | grep -q .; then
		restic unlock >/dev/null 2>&1 || true
		# `restic unlock` alone only removes locks it can prove are stale.
		# The lock break-and-fix.sh leaves behind often is not provably
		# stale, so it survives and verify.sh keeps failing. Nothing is
		# backing up during setup, so escalate rather than leave it.
		if restic list locks 2>/dev/null | grep -q .; then
			systemctl stop restic-backup.service >/dev/null 2>&1 || true
			restic unlock --remove-all >/dev/null 2>&1 || true
			ok "removed a lock that restic would not call stale (--remove-all)"
		else
			ok "cleared a stale lock on the repository"
		fi
	fi

	cat >"$UNIT" <<EOF
[Unit]
Description=Day 20 restic backup of $DATA
# Do not start the backup before the network can carry it. This is Wants,
# not Requires: a failed network target should not mark the backup failed.
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
# The unit gets its own environment. A repository that only exists in your
# interactive shell works perfectly by hand and fails under systemd, which
# is the single most common way a scheduled backup turns out not to exist.
EnvironmentFile=$ENV_FILE
# A service has no HOME, and restic derives its cache directory from HOME or
# XDG_CACHE_HOME. Without these the timer's run fails with "unable to locate
# cache directory: neither \$XDG_CACHE_HOME nor \$HOME are defined", while the
# same command by hand succeeds - the whole trap of this day in two lines.
Environment=HOME=/root
Environment=RESTIC_CACHE_DIR=/var/cache/restic
ExecStart=$PAYLOAD run
Nice=10
IOSchedulingClass=idle
EOF
	ok "wrote $UNIT"

	cat >"$TIMER" <<'EOF'
[Unit]
Description=Day 20 restic backup, on a schedule

[Timer]
# Two triggers on purpose. OnCalendar is the real schedule; OnActiveSec makes
# the first run happen 30 seconds after the timer is enabled, so you can see
# a scheduled backup today instead of taking it on faith.
OnCalendar=*:0/10
OnActiveSec=30s
# A machine that was off when the timer was due runs it at the next boot.
Persistent=true
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
	ok "wrote $TIMER"

	systemctl daemon-reload
	systemctl enable --now restic-backup.timer >/dev/null 2>&1 ||
		die "could not enable restic-backup.timer"
	ok "restic-backup.timer is enabled and running"

	# -----------------------------------------------------------------------
	say "8. proving the schedule, rather than trusting it"

	note "the timer is set to fire 30s after being enabled, so this waits."
	note "expect up to 90s of nothing happening - that is the point."
	printf '\n'

	FIRED=no
	for i in $(seq 1 30); do
		LAST="$(systemctl show restic-backup.timer -p LastTriggerUSec --value 2>/dev/null)"
		if [[ -n "$LAST" && "$LAST" != "0" && "$LAST" != "n/a" ]]; then
			FIRED=yes
			ok "the timer fired after about $((i * 3))s: $LAST"
			break
		fi
		if [[ $((i % 5)) -eq 0 ]]; then
			note "still waiting for the first trigger, $((i * 3))s in..."
		fi
		sleep 3
	done

	if [[ "$FIRED" == "no" ]]; then
		note "the timer has not fired yet. Not fatal - look yourself:"
		note "  systemctl list-timers restic-backup.timer"
		note "  journalctl -u restic-backup.service -n 30"
	else
		# Wait for the oneshot to finish before judging it.
		for i in $(seq 1 40); do
			systemctl is-active --quiet restic-backup.service || break
			sleep 3
		done
		# ExecMainStatus is 0 on a unit that has never run, so it is worthless
		# on its own. ExecMainStartTimestamp is empty until the service has
		# actually started at least once - ask that first.
		RAN="$(systemctl show restic-backup.service -p ExecMainStartTimestamp --value 2>/dev/null || true)"
		STATUS="$(systemctl show restic-backup.service -p ExecMainStatus --value 2>/dev/null || true)"
		if [[ -z "$RAN" ]]; then
			note "the timer fired but the service has not run yet - not judging"
			note "its exit status, because a unit that never ran also reports 0."
		elif [[ "$STATUS" == "0" ]]; then
			ok "the scheduled run started $RAN and exited 0"
		else
			note "the scheduled run exited $STATUS. Read it:"
			note "  journalctl -u restic-backup.service -n 40"
		fi
	fi

	# grep -c exits 1 when it counts nothing. Under `set -e` that used to kill
	# this script silently, right here, with the last thing on screen being a
	# cheerful "ok" - which is a far better lesson in `|| true` than anything
	# I could have written on purpose.
	COUNT="$(restic snapshots --json 2>/dev/null | grep -c short_id || true)"
	[[ -n "$COUNT" ]] || COUNT=0
	if [[ "$COUNT" -ge 1 ]]; then
		ok "the repository has $COUNT snapshot(s)"
		# A snapshot existing is not the same as a snapshot containing
		# anything - which is the entire lesson of --hard. If the newest one
		# is empty, take a fresh one now rather than handing the drill a
		# snapshot that cannot possibly match.
		FILES="$(restic ls latest 2>/dev/null | grep -c "^$DATA/" || true)"
		[[ -n "$FILES" ]] || FILES=0
		if [[ "$FILES" -eq 0 ]]; then
			note "the newest snapshot contains nothing under $DATA - taking a"
			note "fresh one now that the exclude file is gone"
			if "$PAYLOAD" run >"$BACKUP_DIR/repair-backup.log" 2>&1; then
				ok "took a snapshot with content in it"
			else
				sed 's/^/        /' "$BACKUP_DIR/repair-backup.log" >&2
				die "the repair backup failed - the log above is the whole story"
			fi
		fi
	else
		note "no snapshot in the repository. What the scheduled run had to say:"
		printf '\n'
		journalctl -u restic-backup.service -n 20 --no-pager 2>/dev/null |
			sed 's/^/        /' || true
		printf '\n'
		note "taking one now, by hand, where you can see it fail"
		if "$PAYLOAD" run >"$BACKUP_DIR/first-backup.log" 2>&1; then
			ok "took a snapshot by hand"
		else
			sed 's/^/        /' "$BACKUP_DIR/first-backup.log" >&2
			die "the first backup failed - the log above is the whole story"
		fi
	fi

	# -----------------------------------------------------------------------
	say "9. the restore drill, which is the only part that matters"

	note "A backup nobody has restored is a rumour. This runs the restore now,"
	note "compares it with the original byte for byte, and times it."
	printf '\n'

	if "$PAYLOAD" drill; then
		ok "the restore reproduced $DATA exactly"
	else
		die "the restore did not match $DATA - that is today's whole subject"
	fi

	say "done"
	note "Next, in this order - the same steps as the README:"
	note "  step 6  sudo lab-backup drill             time a restore"
	note "  step 7  sudo ./scripts/explore-backup.sh  read what you built"
	note "  step 8  sudo ./scripts/break-and-fix.sh   four failures, repaired"
	note "  step 9  sudo ./verify.sh                  check yourself"
	printf '\n'
	note "Any time:  sudo lab-backup status | snapshots | run | check"
	printf '\n'
	note "Write the restore time down. 'We have backups' is not an answer to"
	note "'how long until we are back', and only one of those is a question"
	note "anyone asks during an outage."
}

case "$ROLE" in
control) setup_control "${1:-}" ;;
node1)   setup_node1 "${1:-}" ;;
*)
	die "cannot tell which host this is (hostname -s said '$ROLE').
  Run it as:  sudo ROLE=control $0 $*
          or:  sudo ROLE=node1 $0 $*"
	;;
esac
