#!/usr/bin/env bash
#
# Day 19 — Intrusion detection and audit alerting
# Run this on: node1, WITH sudo
#
# Exits 0 only when every automatic check passes. Items printed as
# YOU are judgement calls and never affect the exit status.

set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=../../lab/verify-lib.sh
source "../../lab/verify-lib.sh"

YAML="/etc/suricata/suricata.yaml"
LAB_RULES="/etc/suricata/rules/lab.rules"
EVE="/var/log/suricata/eve.json"
AUDIT_RULES_DIR="/etc/audit/rules.d"
CANARY="/etc/lab-canary"

vl_init "Day 19 — Intrusion detection and audit alerting"
vl_need suricata auditctl ausearch jq systemctl
vl_need_root

# Values that are awkward to quote inside a check are computed here and
# compared inside the check, so every check stays one readable expression.
IFACE_CONF="$(awk '/^af-packet:/{f=1} f && /interface:/{print $NF; exit}' "$YAML" 2>/dev/null)"
IFACE_REAL="$(ip -o route show default 2>/dev/null | awk '{print $5; exit}')"
AUDIT_STATE="$(auditctl -s 2>/dev/null | awk '/^enabled/{print $2; exit}')"
# augenrules prefixes its own name: "/sbin/augenrules: No change". Match the
# phrase, not the whole line.
AUGEN_OK=no
augenrules --check 2>&1 | grep -q 'No change' && AUGEN_OK=yes
# auditctl -l prints watches as "-w /etc/lab-canary -p rwa -k lab_canary",
# so pull the permission letters out and look for r in them.
CANARY_PERMS="$(auditctl -l 2>/dev/null | grep -F "$CANARY" | grep -oE '(-p +|perm=)[rwxa]+' | tr -d ' ' | head -1)"
CANARY_READS=no
case "$CANARY_PERMS" in *r*) CANARY_READS=yes ;; esac
LOW_SIDS="$(grep -oE 'sid:[0-9]+' "$LAB_RULES" 2>/dev/null | cut -d: -f2 | awk '$1 < 1000000' | wc -l)"

# --- suricata is running, and running on the right wire -------------------
vl_check "suricata is enabled, so detection survives a reboot" "systemctl is-enabled --quiet suricata"
vl_check "suricata is running right now" "systemctl is-active --quiet suricata"
vl_check "the config and every loaded rule parse (suricata -T)" "suricata -T -c $YAML >/dev/null 2>&1"
vl_check "af-packet captures on the interface that carries traffic" "[ -n '$IFACE_CONF' ] && [ '$IFACE_CONF' = '$IFACE_REAL' ]"

# --- the rules are yours, loaded, and numbered legally --------------------
vl_check "the lab rule file exists" "[ -s $LAB_RULES ]"
vl_check "suricata.yaml references the lab rule file" "grep -qF $LAB_RULES $YAML"
vl_check "both lab signatures are present" "grep -q 'sid:9000001' $LAB_RULES && grep -q 'sid:9000002' $LAB_RULES"
vl_check "no lab sid collides with the public ruleset ranges" "[ '$LOW_SIDS' = 0 ]"

# --- something was actually detected --------------------------------------
vl_check "eve.json exists and has events in it" "[ -s $EVE ]"
vl_check "eve.json is one valid JSON object per line" "tail -1 $EVE | jq -e . >/dev/null"
vl_check "at least one alert has been written" "grep -q '\"event_type\":\"alert\"' $EVE"
vl_check "your own rule fired, not just somebody else's" "grep -q '\"signature_id\":9000001' $EVE"
vl_check "the alert carries the message you wrote" "grep -q 'LAB-ICMP' $EVE"

# --- auditd: the disk half -------------------------------------------------
vl_check "auditd is running" "systemctl is-active --quiet auditd"
vl_check "auditing is enabled in the kernel" "[ '${AUDIT_STATE:-0}' != 0 ]"
vl_check "the kernel watches /etc/shadow" "auditctl -l | grep -q '/etc/shadow'"
vl_check "the watch is keyed, so ausearch can find it" "auditctl -l | grep -q 'shadow_watch'"
vl_check "the rule is persistent, not just loaded by hand" "grep -rq '/etc/shadow' $AUDIT_RULES_DIR/"
vl_check "the kernel's rules match the files (augenrules --check)" "[ '$AUGEN_OK' = yes ]"
vl_check "the canary watch includes reads, not only writes" "[ '$CANARY_READS' = yes ]"
vl_check "root commands run from a login session are recorded" "auditctl -l | grep -q 'root_cmd'"
vl_check "an audit event was actually recorded" "ausearch -k lab_canary 2>/dev/null | grep -q 'type=SYSCALL'"

vl_manual "you triggered your own rule on purpose and found the alert in eve.json"
vl_manual "you tuned out one false positive, or can name the rule here that would be one in production"

vl_summary
