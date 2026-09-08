#!/usr/bin/env bash
#
# Day 05 - build the logging and time environment from nothing.
#
#   sudo ./scripts/setup.sh
#
# Creates:
#   /var/log/journal                        persistent journal storage
#   /etc/systemd/journald.conf              Storage=persistent, SystemMaxUse=200M
#   /usr/local/bin/lab-noisy                the payload
#   /etc/systemd/system/lab-noisy.service   a service that logs forever
#   /var/log/lab-app/app.log                the plain file logrotate owns
#   /etc/logrotate.d/lab-app                the rotation rule
#   chronyd enabled, timezone set explicitly
#
# Why all of that for one day: the reader needs one log that journald owns
# and one log that logrotate owns, at the same time, written by the same
# process. Almost every argument about "where do the logs go" on a modern
# RHEL-family box comes from not noticing that both systems are running.
#
# Idempotent. Run it twice; the second run reports what already exists and
# changes nothing.

set -euo pipefail

# shellcheck source=../../../lab/on-lab-vm.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

say() { printf '\n==> %s\n' "$*"; }
die() { echo "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "needs root:  sudo $0"

HERE="$(cd "$(dirname "$0")" && pwd)"

JOURNAL_DIR="/var/log/journal"
JOURNALD_CONF="/etc/systemd/journald.conf"
MAX_USE="200M"
PAYLOAD_SRC="$HERE/lab-noisy.sh"
PAYLOAD="/usr/local/bin/lab-noisy"
SERVICE="lab-noisy.service"
UNIT="/etc/systemd/system/$SERVICE"
APP_DIR="/var/log/lab-app"
APP_LOG="$APP_DIR/app.log"
ROTATE_RULE="/etc/logrotate.d/lab-app"
TZ_WANTED="UTC"

# ---------------------------------------------------------------------------
# 0. dependencies
#
# Same lesson as Day 04: check for every tool the whole day uses, not just
# the ones this script calls. The Rocky 9 cloud image ships none of chrony,
# and logrotate is not guaranteed either.
# ---------------------------------------------------------------------------
missing=""
for tool in chronyc logrotate logger journalctl timedatectl; do
	command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
if [ -n "$missing" ]; then
	echo "missing:$missing" >&2
	echo >&2
	echo "install them first:" >&2
	echo "  sudo dnf install -y chrony logrotate util-linux systemd" >&2
	echo >&2
	echo "chrony gives chronyc and chronyd; logrotate gives logrotate and its" >&2
	echo "timer; util-linux gives logger. journalctl and timedatectl come with" >&2
	echo "systemd and should already be here." >&2
	exit 1
fi

[ -f "$PAYLOAD_SRC" ] || die "cannot find $PAYLOAD_SRC - run this from days/day05"

# ---------------------------------------------------------------------------
# 1. make the journal persistent
#
# Storage=auto (the default) means: use /var/log/journal if the directory
# exists, otherwise keep everything in /run/log/journal, which is tmpfs and
# is therefore erased at every boot. So on a default machine `journalctl -b -1`
# has nothing to show you, which is precisely the boot you need after a crash.
#
# Creating the directory is enough to change the behaviour. We set Storage
# explicitly anyway, because a configuration that depends on a directory
# existing is a configuration nobody can read off the file.
# ---------------------------------------------------------------------------
say "1. persistent journal"

if [ -d "$JOURNAL_DIR" ]; then
	echo "  $JOURNAL_DIR already exists"
else
	mkdir -p "$JOURNAL_DIR"
	systemd-tmpfiles --create --prefix "$JOURNAL_DIR" 2>/dev/null || true
	echo "  created $JOURNAL_DIR"
fi

# Both settings live in the [Journal] section. sed in place if the key is
# there in any form (commented or not), append if it is missing entirely.
set_journald() {
	key="$1"
	val="$2"
	if grep -qE "^#?${key}=" "$JOURNALD_CONF"; then
		sed -i -E "s|^#?${key}=.*|${key}=${val}|" "$JOURNALD_CONF"
	else
		printf '%s=%s\n' "$key" "$val" >>"$JOURNALD_CONF"
	fi
	echo "  ${key}=${val}"
}

set_journald Storage persistent

# ---------------------------------------------------------------------------
# 2. bound it
#
# An unbounded journal is a disk-full outage with a delay fuse. The default
# is 10% of the filesystem, which sounds safe until the filesystem is the
# root filesystem and 10% is several gigabytes you needed for something else.
#
# 200M is deliberately small so that break-and-fix.sh can fill it in front of
# you and you can watch journald delete its own oldest entries. Note what
# that means: exceeding the limit does not stop logging, it silently discards
# history. The failure is invisible unless you go looking.
# ---------------------------------------------------------------------------
say "2. bound the journal at $MAX_USE"
set_journald SystemMaxUse "$MAX_USE"

systemctl restart systemd-journald
echo "  journald restarted"
journalctl --disk-usage 2>/dev/null | sed 's/^/  /'

# ---------------------------------------------------------------------------
# 3. time
#
# Two separate things that get confused constantly:
#
#   the timezone   - a display setting. Changes what you see, not what is
#                    stored. The journal stores UTC internally regardless.
#   the clock      - the actual number of seconds, kept honest by chronyd.
#
# UTC on servers is not dogma, it is correlation: when you are reading logs
# from four machines during an incident you cannot afford to be doing
# arithmetic in your head about which one is on daylight saving.
# ---------------------------------------------------------------------------
say "3. time"

current_tz="$(timedatectl show -p Timezone --value)"
if [ "$current_tz" = "$TZ_WANTED" ]; then
	echo "  timezone already $TZ_WANTED"
else
	timedatectl set-timezone "$TZ_WANTED"
	echo "  timezone $current_tz -> $TZ_WANTED"
fi

if systemctl is-enabled chronyd >/dev/null 2>&1; then
	echo "  chronyd already enabled"
else
	systemctl enable chronyd >/dev/null 2>&1 || true
	echo "  chronyd enabled"
fi
systemctl start chronyd 2>/dev/null || true
timedatectl set-ntp true 2>/dev/null || true

# chronyd needs a moment before tracking reports anything useful, and on a
# VM with no outbound NTP it may never synchronise. Say so rather than
# letting the reader think the check is broken.
sleep 2
if chronyc tracking 2>/dev/null | grep -q 'Leap status.*Normal'; then
	echo "  clock synchronised"
else
	echo "  clock NOT yet synchronised - chronyd may still be reaching a source"
	echo "  check with:  chronyc sources -v   (and give it a minute)"
fi

# ---------------------------------------------------------------------------
# 4. the payload and its service
# ---------------------------------------------------------------------------
say "4. the noisy service"

install -m 0755 "$PAYLOAD_SRC" "$PAYLOAD"
echo "  installed $PAYLOAD"

mkdir -p "$APP_DIR"
touch "$APP_LOG"
chmod 0644 "$APP_LOG"
echo "  $APP_LOG ready"

cat >"$UNIT" <<EOF
[Unit]
Description=Day 05 noisy logger (writes to a file and to the journal)
After=network.target

[Service]
# The payload writes its own file on fd 3 and calls logger(1) for the
# journal, so nothing here needs StandardOutput= redirection. Anything a
# service prints on stdout goes to the journal anyway - that is the default
# on this distro and it is worth knowing.
ExecStart=$PAYLOAD run $APP_LOG
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
echo "  wrote $UNIT"

systemctl daemon-reload
systemctl enable --now "$SERVICE" >/dev/null 2>&1 || systemctl enable --now "$SERVICE"
sleep 3
systemctl is-active "$SERVICE" >/dev/null 2>&1 &&
	echo "  $SERVICE is running" ||
	die "$SERVICE did not start - journalctl -u $SERVICE -n 20"

# ---------------------------------------------------------------------------
# 5. the logrotate rule
#
# Read this rule properly, because break-and-fix.sh removes one line of it
# and the consequence is not obvious.
#
#   copytruncate - copy the file aside, then truncate the ORIGINAL in place,
#                  rather than renaming it and creating a new one. It exists
#                  for exactly the situation this day builds: a writer that
#                  holds its descriptor open and will never be told to
#                  reopen. Without it the writer keeps filling the renamed
#                  file and the new one stays empty forever.
#
#   missingok    - do not error if the file is absent.
#   notifempty   - do not rotate an empty file.
#   rotate 5     - keep five old copies, then delete.
#   size 100k    - rotate on size, not on a schedule, so you can trigger it
#                  by hand today instead of waiting for tomorrow.
#
# The alternative to copytruncate is a postrotate stanza that signals the
# daemon to reopen its log. That is the better answer when the daemon
# supports it, because copytruncate has a real race: anything written
# between the copy and the truncate is lost.
# ---------------------------------------------------------------------------
say "5. the logrotate rule"

cat >"$ROTATE_RULE" <<EOF
$APP_LOG {
    size 100k
    rotate 5
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF
chmod 0644 "$ROTATE_RULE"
echo "  wrote $ROTATE_RULE"

# -d is a dry run: it says what it WOULD do and touches nothing. This is the
# single most useful logrotate flag and the manual check for today.
if logrotate -d "$ROTATE_RULE" >/dev/null 2>&1; then
	echo "  logrotate -d parses it cleanly"
else
	echo "  logrotate -d reported a problem - run it yourself:"
	echo "    logrotate -d $ROTATE_RULE"
fi

if systemctl is-enabled logrotate.timer >/dev/null 2>&1; then
	echo "  logrotate.timer is enabled (this is what actually runs it daily)"
else
	echo "  logrotate.timer is NOT enabled - the rule would never run on its own"
	systemctl enable --now logrotate.timer >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# done
# ---------------------------------------------------------------------------
say "done"
cat <<EOF

  journal:    persistent in $JOURNAL_DIR, capped at $MAX_USE
  service:    $SERVICE, one line per second
  file log:   $APP_LOG   (logrotate's)
  journal log: journalctl -t lab-noisy   (journald's)
  rule:       $ROTATE_RULE

the same process writes both. that is the point of today.

look at them side by side:

  tail -3 $APP_LOG
  journalctl -t lab-noisy -n 3 --no-pager
  journalctl --disk-usage
  du -sh $APP_DIR

then force a rotation without waiting for the timer:

  sudo logrotate -d $ROTATE_RULE     # dry run - says what it would do
  sudo logrotate -f $ROTATE_RULE     # force it for real
  ls -l $APP_DIR
EOF
