#!/usr/bin/env bash
#
# Day 19 setup - detection on node1: Suricata on the wire, auditd on the disk.
#
#   sudo ./scripts/setup.sh
#
# Two different questions, two different tools:
#
#   Suricata  "what crossed the network interface"
#   auditd    "who touched this file, and with which syscall"
#
# Neither prevents anything. That is not a gap in the setup - it is the
# category. Days 11-13 were prevention; today is the part that tells you the
# prevention was not enough.
#
# Idempotent: run it as often as you like.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

say()  { printf '\n==> %s\n\n' "$*"; }
die()  { printf '\nfailed: %s\n' "$*" >&2; exit 1; }
ok()   { printf '  ok    %s\n' "$*"; }
note() { printf '        %s\n' "$*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "needs root:  sudo $0 $*"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_SRC="$HERE/lab-ids.sh"
PAYLOAD="/usr/local/bin/lab-ids"

YAML="/etc/suricata/suricata.yaml"
LAB_RULES="/etc/suricata/rules/lab.rules"
EVE="/var/log/suricata/eve.json"
SURILOG="/var/log/suricata/suricata.log"
AUDIT_RULES="/etc/audit/rules.d/99-lab.rules"
AUDITD_CONF="/etc/audit/auditd.conf"
CANARY="/etc/lab-canary"
BACKUP_DIR="/tmp/day19-broken"

# ---------------------------------------------------------------------------
# 1. packages
# ---------------------------------------------------------------------------
say "1. packages"

NEEDED=()
command -v suricata  >/dev/null 2>&1 || NEEDED+=(suricata)
command -v auditctl  >/dev/null 2>&1 || NEEDED+=(audit)
command -v ausearch  >/dev/null 2>&1 || NEEDED+=(audit)
command -v jq        >/dev/null 2>&1 || NEEDED+=(jq)
command -v dig       >/dev/null 2>&1 || NEEDED+=(bind-utils)

if [[ ${#NEEDED[@]} -gt 0 ]]; then
	# Suricata is not in the base Rocky repositories - it comes from EPEL,
	# the same place Day 12 got fail2ban from.
	if ! rpm -q epel-release >/dev/null 2>&1; then
		dnf install -y epel-release >/dev/null
		ok "installed epel-release"
	fi
	note "installing: ${NEEDED[*]}"
	dnf install -y "${NEEDED[@]}" >/dev/null
fi
for c in suricata auditctl ausearch jq dig; do
	command -v "$c" >/dev/null 2>&1 || die "$c is still missing after install"
done
ok "suricata $(suricata -V 2>/dev/null | awk '{print $5}'), audit, jq, dig"

mkdir -p "$BACKUP_DIR"

# ---------------------------------------------------------------------------
# 2. which interface is the wire
# ---------------------------------------------------------------------------
say "2. the interface Suricata will watch"

# An IDS that is listening on an interface that does not exist is running,
# enabled, green in systemctl, and blind. The default config says eth0;
# this VM's interface is probably not called that.
IFACE="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
[[ -n "$IFACE" ]] || die "no default route - cannot tell which interface carries traffic"
GW="$(ip route show default | awk '/default/ {print $3; exit}')"
ok "default route leaves through $IFACE (gateway $GW)"

# ---------------------------------------------------------------------------
# 3. the Suricata configuration
# ---------------------------------------------------------------------------
say "3. suricata.yaml"

[[ -f "$YAML" ]] || die "no $YAML - the suricata package did not install cleanly"
[[ -f "$BACKUP_DIR/suricata.yaml.orig" ]] || cp -a "$YAML" "$BACKUP_DIR/suricata.yaml.orig"

# The af-packet section names the interface to capture from. Rewrite only the
# first 'interface:' line inside af-packet, and leave the rest of this very
# large file alone.
CURRENT_IF="$(awk '/^af-packet:/{f=1} f && /^[[:space:]]*-?[[:space:]]*interface:/{print $NF; exit}' "$YAML")"
if [[ "$CURRENT_IF" == "$IFACE" ]]; then
	ok "af-packet already captures on $IFACE"
else
	awk -v want="$IFACE" '
		/^af-packet:/ { inaf=1 }
		inaf && !done && /^[[:space:]]*-?[[:space:]]*interface:/ {
			sub(/interface:.*/, "interface: " want); done=1
		}
		{ print }
	' "$YAML" >"$YAML.new" && mv "$YAML.new" "$YAML"
	ok "af-packet now captures on $IFACE (was ${CURRENT_IF:-unset})"
fi

# suricata-update has probably never run here, and downloading the Emerging
# Threats ruleset is not the point of this day - your own rules are. Make
# sure the default ruleset path exists so the config is valid either way.
mkdir -p /var/lib/suricata/rules /etc/suricata/rules /var/log/suricata
[[ -f /var/lib/suricata/rules/suricata.rules ]] || : >/var/lib/suricata/rules/suricata.rules
chown -R suricata:suricata /var/log/suricata /var/lib/suricata 2>/dev/null || true

if grep -q "$LAB_RULES" "$YAML"; then
	ok "$LAB_RULES is already in rule-files"
else
	# rule-files takes relative names under default-rule-path, or absolute
	# paths. Absolute keeps our rules out of anything suricata-update
	# overwrites - a downloaded ruleset must never be able to delete yours.
	awk -v add="  - $LAB_RULES" '
		{ print }
		/^rule-files:/ && !done { print add; done=1 }
	' "$YAML" >"$YAML.new" && mv "$YAML.new" "$YAML"
	grep -q "$LAB_RULES" "$YAML" || die "could not add $LAB_RULES to rule-files in $YAML"
	ok "added $LAB_RULES to rule-files"
fi

# ---------------------------------------------------------------------------
# 4. rules you wrote yourself
# ---------------------------------------------------------------------------
say "4. two rules, with sids in the local range"

# sid numbering is not decoration. 1000000-1999999 is reserved for local
# rules; anything below that belongs to a public ruleset, and a collision
# means your rule or theirs silently loses. The 9000000 block used here is
# also outside the public ranges and makes lab rules obvious in a log.
cat >"$LAB_RULES" <<'EOF'
# Day 19 lab rules. Local sids only - never reuse a public ruleset's number.
alert icmp any any -> any any ( \
    msg:"LAB-ICMP echo request seen on the wire"; \
    itype:8; \
    classtype:not-suspicious; \
    sid:9000001; rev:1;)

alert dns any any -> any any ( \
    msg:"LAB-CANARY someone looked up the canary name"; \
    dns.query; content:"lab-canary"; nocase; \
    classtype:policy-violation; \
    sid:9000002; rev:1;)
EOF
ok "wrote $LAB_RULES (sid 9000001 ICMP, sid 9000002 DNS canary)"
note "an ICMP rule in production would be pure noise - here it is a rule"
note "you can fire on demand, which is what you need to trust the pipeline"

# ---------------------------------------------------------------------------
# 5. test the config, then run it
# ---------------------------------------------------------------------------
say "5. suricata -T, then the service"

if suricata -T -c "$YAML" -v >"$BACKUP_DIR/suricata-test.log" 2>&1; then
	ok "configuration and rules parse"
else
	sed -n '1,20p' "$BACKUP_DIR/suricata-test.log" >&2
	die "suricata rejected the configuration - the output above says why"
fi

systemctl enable suricata >/dev/null 2>&1 || true
systemctl restart suricata
systemctl is-active --quiet suricata || {
	systemctl status suricata --no-pager | sed -n '1,10p' >&2
	die "suricata did not start"
}
ok "suricata is running and enabled"

# This is the part everyone gets wrong. 'systemctl is-active' means the
# process exists, not that the detection engine is ready: Suricata parses the
# config, builds the detection engine from every rule, then creates capture
# threads, and only then does it look at a single packet. On a 2 GB VM that
# takes tens of seconds. Traffic sent before "Engine started" appears in
# suricata.log did not happen as far as the IDS is concerned - and there is
# nothing in eve.json to tell you that is why you have no alerts.
say "5b. waiting for the detection engine to actually start"

READY=no
for i in $(seq 1 120); do
	if grep -q 'Engine started' "$SURILOG" 2>/dev/null; then READY=yes; break; fi
	systemctl is-active --quiet suricata || break
	[[ $((i % 15)) -eq 0 ]] && note "still initialising (${i}s)..."
	sleep 1
done
if [[ "$READY" == "yes" ]]; then
	ok "engine started - Suricata is now looking at packets on $IFACE"
else
	note "no 'Engine started' line in $SURILOG after two minutes:"
	tail -15 "$SURILOG" 2>/dev/null | sed 's/^/        /' >&2
	systemctl is-active --quiet suricata || die "suricata stopped - see the log above"
	note "carrying on anyway - the trigger step below retries for two minutes"
fi

# ---------------------------------------------------------------------------
# 6. auditd
# ---------------------------------------------------------------------------
say "6. audit rules"

touch "$CANARY"
chmod 0600 "$CANARY"

cat >"$AUDIT_RULES" <<EOF
## Day 19 lab audit rules.
## -w path -p permissions -k key
##   r read  w write  x execute  a attribute change
## The key is not a comment: it is how ausearch finds these events later.

-w /etc/shadow -p wa -k shadow_watch
-w /etc/sudoers -p wa -k sudoers_watch
-w $CANARY -p rwa -k lab_canary

## Every execution of a privileged shell by a normal login session.
## auid is the login uid - it survives su and sudo, which is exactly why
## it, and not uid, answers "who did this".
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=unset -k root_cmd
EOF
ok "wrote $AUDIT_RULES"

systemctl is-active --quiet auditd || systemctl start auditd

# auditd is the one daemon systemd will not restart for you:
#   systemctl restart auditd  ->  "Operation refused, unit may be requested
#   by dependency only". Rules are loaded with augenrules, not by restarting.
if augenrules --load >"$BACKUP_DIR/augenrules.log" 2>&1; then
	ok "augenrules --load: rules compiled and loaded into the kernel"
else
	sed -n '1,15p' "$BACKUP_DIR/augenrules.log" >&2
	die "augenrules could not load the rules - the output above says why"
fi

auditctl -l | grep -q 'shadow' || die "the kernel did not accept the shadow rule"
ok "the kernel is watching /etc/shadow"

# The kernel records events immediately; auditd decides when they reach disk.
# The shipped auditd.conf uses flush = INCREMENTAL_ASYNC with freq = 50, so
# audit.log is written every 50 records. On an idle lab VM a handful of
# events can sit unwritten for minutes, and every ausearch in between
# honestly reports nothing. Set freq = 1 here so the log is the truth as
# soon as it happens, which is what you want on a machine you are watching.
cp -a "$AUDITD_CONF" "$BACKUP_DIR/auditd.conf.orig" 2>/dev/null || true
CUR_FREQ="$(awk -F= '/^[[:space:]]*freq[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$AUDITD_CONF" 2>/dev/null)"
if [[ "${CUR_FREQ:-unset}" != "1" ]]; then
	if grep -qE '^[[:space:]]*freq[[:space:]]*=' "$AUDITD_CONF"; then
		sed -i -E 's/^[[:space:]]*freq[[:space:]]*=.*/freq = 1/' "$AUDITD_CONF"
	else
		printf 'freq = 1\n' >>"$AUDITD_CONF"
	fi
	ok "auditd.conf: freq ${CUR_FREQ:-unset} -> 1 (original in $BACKUP_DIR)"
else
	ok "auditd.conf already writes every record (freq = 1)"
fi

# auditd.conf is re-read on reload. systemctl reload works where restart is
# refused, and the legacy action is the fallback on older builds.
if systemctl reload auditd >/dev/null 2>&1 ||
	service auditd reload >/dev/null 2>&1 ||
	pkill -HUP auditd >/dev/null 2>&1; then
	ok "auditd re-read its config"
else
	note "could not reload auditd - events may lag behind by up to freq records"
fi
note "auditctl -l shows the kernel's rules; the file shows your intent."
note "'augenrules --check' is the command that compares the two"

# ---------------------------------------------------------------------------
# 7. the payload
# ---------------------------------------------------------------------------
say "7. installing lab-ids"

if [[ -f "$PAYLOAD_SRC" ]]; then
	install -m 0755 "$PAYLOAD_SRC" "$PAYLOAD"
	ok "installed $PAYLOAD"
	note "lab-ids status | alerts | audit | trigger"
else
	note "lab-ids.sh not found next to this script - skipping"
fi

# ---------------------------------------------------------------------------
# 8. fire both sensors on purpose
# ---------------------------------------------------------------------------
say "8. proving the pipeline, rather than hoping"

# A detection stack nobody has ever seen fire is a detection stack you do not
# know works. Both halves are triggered here, deliberately.
# Send traffic repeatedly rather than once. eve.json is flushed on an
# interval, so a single ping and an immediate grep is a race you will lose
# even on a healthy host.
FOUND=no
for i in $(seq 1 24); do
	ping -c 2 -W 2 "$GW" >/dev/null 2>&1 || true
	dig +time=2 +tries=1 "@$GW" lab-canary.lab.test >/dev/null 2>&1 || true
	sleep 4
	if grep -q '"signature_id":9000001' "$EVE" 2>/dev/null; then FOUND=yes; break; fi
	[[ $((i % 6)) -eq 0 ]] && note "no alert yet after $((i * 5))s - still trying"
done

if [[ "$FOUND" == "yes" ]]; then
	ok "sid 9000001 fired - the ICMP you just sent is in $EVE"
else
	# Print everything needed to tell the three causes apart instead of
	# guessing at one of them.
	printf '\n'
	note "no alert for sid 9000001 after two minutes. The state of things:"
	note "  interface in suricata.yaml : $(awk '/^af-packet:/{f=1} f && /interface:/{print $NF; exit}' "$YAML")"
	note "  interface with the traffic : $IFACE"
	note "  suricata                  : $(systemctl is-active suricata)"
	note "  eve.json                  : $( [[ -s "$EVE" ]] && grep -c . "$EVE" || echo 'missing or empty') lines"
	note "  engine started            : $(grep -c 'Engine started' "$SURILOG" 2>/dev/null || echo 0)"
	note "  rules loaded              : $(grep -o '[0-9]* rules successfully loaded' "$SURILOG" 2>/dev/null | tail -1)"
	printf '\n'
	note "last 20 lines of $SURILOG:"
	tail -20 "$SURILOG" 2>/dev/null | sed 's/^/        /'
	printf '\n'
	note "Most likely, in order: the engine is still building (re-run this"
	note "script), af-packet is on the wrong interface, or capture failed -"
	note "which the log above says in as many words."
	die "no alert for sid 9000001 - see the diagnosis above"
fi

# Which event to trigger matters, and the permission letters decide it.
# /etc/shadow is watched with -p wa: writes and attribute changes only, so
# reading it records nothing. The canary is watched with -p rwa, so both a
# read and a write of it are recorded. Trigger the one the rules can see.
cat /etc/shadow >/dev/null 2>&1 || true

# One access is not enough to see anything, and that is auditd's design, not
# a fault. /etc/audit/auditd.conf ships flush = INCREMENTAL_ASYNC with
# freq = 50: the kernel hands records to auditd immediately, but auditd holds
# them and writes audit.log every 50 records. On an idle VM a single read
# sits in that buffer indefinitely, so ausearch finds nothing while the event
# has in fact been recorded. Generate more than freq events and the buffer
# flushes.
for i in $(seq 1 60); do
	cat "$CANARY" >/dev/null 2>&1 || true
done
printf 'touched by setup.sh\n' >>"$CANARY"

AUD=no
for i in $(seq 1 15); do
	if ausearch -k lab_canary -ts today 2>/dev/null | grep -q 'type=SYSCALL'; then
		AUD=yes
		break
	fi
	sleep 2
	cat "$CANARY" >/dev/null 2>&1 || true
done

if [[ "$AUD" == "yes" ]]; then
	ok "auditd recorded the reads and the write of $CANARY"
	note "The read of /etc/shadow above is not in the log: that watch is"
	note "-p wa. Permission letters decide what you can see later."
	note "It took a burst of accesses, not one: auditd buffers and writes"
	note "audit.log every 'freq' records (see /etc/audit/auditd.conf)."
else
	printf '\n'
	note "no audit event after 20s. The state of things:"
	note "  auditd        : $(systemctl is-active auditd)"
	note "  kernel enabled: $(auditctl -s 2>/dev/null | awk '/^enabled/{print $2; exit}')"
	note "  canary rule   : $(auditctl -l 2>/dev/null | grep -F "$CANARY" || echo 'not in the kernel')"
	note "  backlog       : $(auditctl -s 2>/dev/null | awk '/^backlog /{print $0; exit}')"
	note "  flush/freq    : $(awk '/^(flush|freq)/{printf "%s ", $0}' /etc/audit/auditd.conf 2>/dev/null)"
	note "  log lines     : $(wc -l </var/log/audit/audit.log 2>/dev/null || echo '?')"
	note "auditd buffers records before writing them. If the rule is in the"
	note "kernel and the backlog is moving, the events exist and simply have"
	note "not been flushed to audit.log yet - they usually show up shortly"
	note "after this, which is the whole lesson."
	printf '\n'
	note "Not fatal: the rules are loaded and the network half is proven."
	note "Look again yourself in a minute:"
	note "  sudo ausearch -k lab_canary -ts today | tail"
	note "  sudo lab-ids audit"
fi

say "done"
note "See both sensors:     sudo lab-ids status"
note "Read the alerts:      sudo lab-ids alerts"
note "Read the audit trail: sudo lab-ids audit"
note "Take the tour:        sudo ./scripts/explore-detection.sh"
note "Break it on purpose:  sudo ./scripts/break-and-fix.sh"
note "Check yourself:       sudo ./verify.sh"
echo
note "Worth doing once: sudo lab-ids prove"
note "It fires both sensors, waits up to 90s for the alert to be written,"
note "and tells you how long that took. That wait is the flush interval,"
note "and on this VM it is tens of seconds - longer than it feels like it"
note "should be. One session, no coordination, nothing to paste twice."
