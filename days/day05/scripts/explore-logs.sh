#!/usr/bin/env bash
#
# Day 05 - a read-only tour of the two logging systems and the clock.
#
#   ./scripts/explore-logs.sh
#
# Changes nothing. Runs without root, but the journal is access-controlled:
# without root you see only your own user's entries plus whatever the
# systemd-journal group can read, so several sections below are thinner than
# they should be. Run it once with sudo and read every line.

set -uo pipefail

heading() { printf '\n\033[1m%s\033[0m\n%s\n' "$1" "$(printf '%.0s-' $(seq 1 ${#1}))"; }
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

APP_LOG="/var/log/lab-app/app.log"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
	echo
	echo "  running without root. journalctl will show you less than it could."
	echo "  re-run as: sudo $0"
fi

heading "1. where the journal actually lives"
run_sh 'ls -ld /var/log/journal /run/log/journal 2>&1'
note "if only /run/log/journal exists, the journal is on tmpfs and dies at reboot"
run journalctl --disk-usage
run_sh 'grep -vE "^\s*#|^\s*$" /etc/systemd/journald.conf'
note "only the lines that are actually in force - the rest of that file is commented defaults"

heading "2. the journal is a database, not a file"
run_sh 'journalctl -n 3 --no-pager'
note "you cannot grep /var/log/journal - it is binary and indexed. journalctl is the reader"
run_sh 'journalctl -t lab-noisy -n 3 --no-pager'
run_sh 'journalctl -u lab-noisy.service -n 3 --no-pager'
note "-t matches the syslog tag, -u matches the unit. today they are the same messages by two routes"

heading "3. the four selectors worth memorising"
run_sh 'journalctl -b -n 3 --no-pager'
note "-b: this boot only. -b -1 is the previous boot, and only works if the journal is persistent"
run_sh 'journalctl -p err -b --no-pager | tail -5'
note "-p err: priority err and worse. the first thing to run on a machine you have just been handed"
run_sh 'journalctl --since "10 min ago" -t lab-noisy --no-pager | tail -3'
note "--since takes plain English: yesterday, 09:00, 2 hours ago"
run_sh 'journalctl -t lab-noisy -n 1 -o json-pretty --no-pager'
note "every entry is structured fields, not a line of text. -o json-pretty shows what is really stored"

heading "4. how many boots does this machine remember"
run_sh 'journalctl --list-boots --no-pager | tail -5'
note "one line here means no history: either this is the first boot or storage is not persistent"

heading "5. the other log - a plain file, and nothing systemd owns"
run_sh "ls -l /var/log/lab-app/ 2>&1"
run_sh "tail -3 $APP_LOG 2>&1"
note "same process, same second, different destination. journald never sees this file"
run_sh 'cat /etc/logrotate.d/lab-app 2>&1'

heading "6. what logrotate would do, without doing it"
run_sh 'logrotate -d /etc/logrotate.d/lab-app 2>&1 | tail -20'
note "-d is a dry run. read the 'log needs rotating' / 'log does not need rotating' line"
run_sh 'cat /var/lib/logrotate/logrotate.status 2>/dev/null | head -5'
note "this is how logrotate remembers when it last rotated each file. delete it and it forgets"

heading "7. who actually runs logrotate"
run_sh 'systemctl list-timers logrotate.timer --no-pager 2>&1'
note "the rule is only a rule. the timer is what makes it happen - a disabled timer is a silent failure"

heading "8. the clock, and the two different questions about it"
run timedatectl
note "'System clock synchronized' and 'NTP service' are different lines and can disagree"
run_sh 'chronyc tracking 2>&1'
note "'Leap status: Normal' means synchronised. 'System time' is how far off you are, in seconds"
run_sh 'chronyc sources -v 2>&1 | head -20'
note "the ^* line is the source currently in use. no ^* means chronyd has not settled on anyone"

heading "9. why servers are set to UTC"
run_sh 'date; date -u; journalctl -t lab-noisy -n 1 --no-pager -o short-full'
note "the journal stores UTC internally always - the timezone only changes how journalctl prints it"
run_sh 'TZ=Asia/Tehran journalctl -t lab-noisy -n 1 --no-pager -o short-full'
note "same stored entry, different display. that is the whole of what a timezone is"

heading "10. worth doing by hand next"
cat <<'EOF'
  journalctl -f -t lab-noisy            follow it live, then leave it running
                                        in a second shell while you work
  journalctl -u lab-noisy -o cat        just the message text, nothing else
  journalctl --vacuum-size=50M          delete oldest entries down to 50M
                                        (this one CHANGES things - read it first)
  journalctl --verify                   check the journal files for corruption
  systemd-analyze timestamp "1 hour ago"
  chronyc sourcestats -v                how much each source is trusted
  logrotate -d -f /etc/logrotate.conf   dry-run the whole system config

  and the one to sit with:

  journalctl -b -1 -p err

  errors from the PREVIOUS boot. If that prints something useful, persistent
  storage has already paid for itself. If it says "Specifying boot ID or
  boot offset has no effect", the journal is still on tmpfs and you did not
  actually make it persistent.
EOF
printf '\n'
