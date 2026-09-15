#!/usr/bin/env bash
#
# Day 19 break-and-fix - four detection failures, each fixed in front of you.
#
#   sudo ./scripts/break-and-fix.sh          break, show, fix, move on
#   sudo ./scripts/break-and-fix.sh --hard   leave them live, plus a fifth
#
# Every failure here has the same shape: the daemon is running, the config is
# valid, systemctl is green, and nothing is being detected.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

YAML="/etc/suricata/suricata.yaml"
LAB_RULES="/etc/suricata/rules/lab.rules"
AUDIT_RULES="/etc/audit/rules.d/99-lab.rules"
EVE="/var/log/suricata/eve.json"
BACKUP_DIR="/tmp/day19-broken"

say()  { printf '\n===== %s\n\n' "$*"; }
run()  { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/  /' || true; }
note() { printf '  %s\n' "$*"; }
ok()   { printf '  ok    %s\n' "$*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || { printf 'needs root: sudo %s %s\n' "$0" "$*" >&2; exit 1; }

HARD=no
[[ "${1:-}" == "--hard" ]] && HARD=yes

for f in "$YAML" "$LAB_RULES" "$AUDIT_RULES"; do
	[[ -f "$f" ]] || { printf 'failed: %s missing. Run scripts/setup.sh first.\n' "$f" >&2; exit 1; }
done

mkdir -p "$BACKUP_DIR"
cp -a "$YAML" "$BACKUP_DIR/suricata.yaml.good"
cp -a "$LAB_RULES" "$BACKUP_DIR/lab.rules.good"
cp -a "$AUDIT_RULES" "$BACKUP_DIR/99-lab.rules.good"
note "backups in $BACKUP_DIR"

# ---------------------------------------------------------------------------
say "failure 1 of 4 - a rule with a typo takes down the whole engine"

printf 'alert icmp any any -> any any (msg:"broken rule"; itype:8; sid:9000003)\n' >>"$LAB_RULES"
note "appended a rule missing its trailing semicolon"

run "suricata -T -c $YAML 2>&1 | tail -4"
note "One bad line, and the test fails for everything. If you had reloaded"
note "without testing, suricata would refuse to start with no detection at"
note "all - not 'all rules but that one'. This is why -T exists."

if [[ "$HARD" == "no" ]]; then
	cp -a "$BACKUP_DIR/lab.rules.good" "$LAB_RULES"
	suricata -T -c "$YAML" >/dev/null 2>&1 && ok "rules restored, -T passes again"
fi

# ---------------------------------------------------------------------------
say "failure 2 of 4 - the rule is on disk and not in the engine"

# Count what is already in eve.json first. This script may have been run
# before, and an old alert would make the count look like a success.
BEFORE="$(grep -c '"signature_id":9000004' "$EVE" 2>/dev/null || true)"
BEFORE="${BEFORE:-0}"

cat >>"$LAB_RULES" <<'EOF'

alert icmp any any -> any any ( \
    msg:"LAB-UNLOADED this rule is valid and was never loaded"; \
    itype:0; sid:9000004; rev:1;)
EOF
note "added a valid rule for ICMP replies, sid 9000004, and did not reload"

FILE_RULES="$(grep -c 'sid:' "$LAB_RULES" 2>/dev/null || true)"
LOADED="$(grep -o '[0-9]* rules successfully loaded' /var/log/suricata/suricata.log 2>/dev/null | tail -1 | awk '{print $1}')"
run "grep -c 'sid:' $LAB_RULES"
GW="$(ip route show default | awk '/default/ {print $3; exit}')"
ping -c 2 -W 2 "$GW" >/dev/null 2>&1 || true
sleep 3
AFTER="$(grep -c '"signature_id":9000004' "$EVE" 2>/dev/null || true)"
AFTER="${AFTER:-0}"
note "alerts for sid 9000004 before writing the rule: $BEFORE"
note "alerts for sid 9000004 after the ping:          $AFTER"
note "new alerts: $(( AFTER - BEFORE ))"
note "Zero new ones. The file now holds $FILE_RULES rules; the engine loaded"
note "${LOADED:-fewer} when it last started. Editing a rule file changes"
note "nothing until the engine is told - exactly like Day 11's sysctl files"
note "and Day 16's wg config. Note the before-count: on a second run of this"
note "script a stale alert from last time is sitting in the log, which is why"
note "the comparison matters and a bare grep does not."

if [[ "$HARD" == "no" ]]; then
	systemctl reload suricata >/dev/null 2>&1 || systemctl restart suricata >/dev/null 2>&1
	sleep 3
	ping -c 2 -W 2 "$GW" >/dev/null 2>&1 || true
	sleep 4
	RELOADED="$(grep -c '"signature_id":9000004' "$EVE" 2>/dev/null || true)"
	RELOADED="${RELOADED:-0}"
	if (( RELOADED > AFTER )); then
		ok "after a reload the same ping produces the alert ($AFTER -> $RELOADED)"
	else
		note "still nothing - give it a few more seconds, or check lab-ids status"
	fi
	cp -a "$BACKUP_DIR/lab.rules.good" "$LAB_RULES"
	systemctl reload suricata >/dev/null 2>&1 || systemctl restart suricata >/dev/null 2>&1
	ok "rules restored and reloaded"
fi

# ---------------------------------------------------------------------------
say "failure 3 of 4 - an audit rule written but never loaded"

printf -- '-w /etc/crontab -p wa -k cron_watch\n' >>"$AUDIT_RULES"
note "added a watch on /etc/crontab to $AUDIT_RULES, and did not load it"

run "grep -c crontab $AUDIT_RULES"
run "auditctl -l | grep -c crontab || true"
run "augenrules --check"
note "The file says one thing, the kernel says another, and 'augenrules"
note "--check' is the only command that will tell you. An audit report built"
note "by grepping rules.d would have passed this machine."

if [[ "$HARD" == "no" ]]; then
	cp -a "$BACKUP_DIR/99-lab.rules.good" "$AUDIT_RULES"
	augenrules --load >/dev/null 2>&1
	ok "file restored and reloaded - augenrules --check agrees again"
fi

# ---------------------------------------------------------------------------
say "failure 4 of 4 - auditctl -D, and the daemon systemd will not restart"

run "auditctl -D"
run "auditctl -l"
note "No rules. The files in /etc/audit/rules.d are untouched and perfect."
note "Nothing is being recorded, and no configuration file shows it."

printf '\n'
run "systemctl restart auditd 2>&1 | tail -2 || true"
note "That is the other half of the lesson: auditd is not restarted with"
note "systemctl. Use 'augenrules --load' to reload rules, or"
note "'service auditd restart' when you really must bounce the daemon."

if [[ "$HARD" == "no" ]]; then
	augenrules --load >/dev/null 2>&1
	if auditctl -l | grep -q shadow; then
		ok "augenrules --load brought every rule back"
	else
		note "rules still missing - is auditd running? systemctl status auditd"
	fi
fi

# ---------------------------------------------------------------------------
if [[ "$HARD" == "yes" ]]; then
	say "--hard - the fifth failure: watching the wrong interface"

	sed -i '/^af-packet:/,/^[^[:space:]]/ s/interface: .*/interface: lo/' "$YAML"
	suricata -T -c "$YAML" >/dev/null 2>&1 && note "-T still passes: 'lo' is a real interface"
	systemctl restart suricata >/dev/null 2>&1 || true
	sleep 2
	run "systemctl is-active suricata"
	note "Running. Enabled. Config valid. Rules loaded. Watching the loopback"
	note "interface, where none of the traffic you care about goes."
	printf '\n'
	note "Left live, along with failures 1-4:"
	note "  - a syntactically broken rule in $LAB_RULES"
	note "  - a valid rule that was never loaded"
	note "  - an audit rule in the file and not in the kernel"
	note "  - an empty kernel audit rule set"
	note "  - suricata capturing on lo"
	printf '\n'
	note "'sudo ./verify.sh' should fail. Find each one, then put it all back:"
	note "  sudo ./scripts/setup.sh"
else
	say "all four failures fixed"
	run "suricata -T -c $YAML >/dev/null 2>&1 && echo 'suricata -T: ok'"
	run "augenrules --check"
	note "Run 'sudo ./verify.sh' - it should pass."
	note "Then try '--hard' and diagnose five at once with nothing but"
	note "lab-ids, auditctl and suricata -T."
fi
printf '\n'
