#!/usr/bin/env bash
#
# Day 19 tour - twelve read-only stops through the two sensors.
#
#   sudo ./scripts/explore-detection.sh
#
# Changes nothing. Every command here is one you would run on a machine you
# had just been handed and been told "something happened last night".

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

EVE="/var/log/suricata/eve.json"
YAML="/etc/suricata/suricata.yaml"
LAB_RULES="/etc/suricata/rules/lab.rules"
CANARY="/etc/lab-canary"

stop() { printf '\n----- %s\n\n' "$*"; }
run()  { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | sed 's/^/  /' || true; }
note() { printf '  %s\n' "$*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || { printf 'needs root: sudo %s\n' "$0" >&2; exit 1; }

printf '\nDay 19 - reading a detection stack\n'

stop "1. are both sensors actually running"
run "systemctl is-active suricata auditd"
note "Two daemons, two blind spots. Suricata sees packets and nothing else;"
note "auditd sees syscalls and nothing else. Neither knows about the other."

stop "2. which interface is suricata listening on"
run "awk '/^af-packet:/{f=1} f && /interface:/{print; exit}' $YAML"
run "ip route show default"
note "These two must name the same interface. When they do not, everything"
note "below is green and no alert will ever fire. That is failure 5."

stop "3. which rule files are loaded"
run "grep -A6 '^rule-files:' $YAML"
note "Absolute path for your own rules, relative names for downloaded ones."
note "Never keep local rules in a file suricata-update can overwrite."

stop "4. the rules you wrote"
run "grep -v '^#' $LAB_RULES | sed '/^$/d'"
note "action proto src -> dst (options). msg is what you will read at 3am,"
note "so write it for that reader. sid must be unique and local-range."

stop "5. what suricata thinks it loaded"
run "suricata -T -c $YAML -v 2>&1 | tail -8"
note "-T is the rules-and-config test. Run it before every reload; a bad"
note "rule takes the whole engine down, not just that rule."

stop "6. eve.json is one JSON object per line"
run "tail -1 $EVE | jq -c 'keys'"
note "Flows, DNS, TLS, HTTP, stats and alerts all share this file. grep works,"
note "but event_type is the field that makes it readable."

stop "7. only the alerts"
run "jq -r 'select(.event_type==\"alert\") | \"\\(.timestamp[0:19]) sid \\(.alert.signature_id) \\(.alert.signature)\"' $EVE | tail -8"
note "An IDS is a log generator. If nothing reads the log on a schedule,"
note "you have bought yourself storage costs and a feeling."

stop "8. alert volume per signature"
run "jq -r 'select(.event_type==\"alert\") | .alert.signature' $EVE | sort | uniq -c | sort -rn | head"
note "This list is how tuning starts. The rule at the top is either your"
note "most important detection or the one nobody will ever read again."

stop "9. the audit rules in the kernel"
run "auditctl -l"
note "-w path -p wa -k key is a file watch. -a always,exit ... -S execve is a"
note "syscall rule. The key is the only practical way to find events later."

stop "10. the kernel's rules versus your files"
run "augenrules --check"
note "'No change' means the two agree. Anything else means someone edited a"
note "file and never loaded it, or ran auditctl by hand and never saved it."

stop "11. finding events by key, and by who"
run "ausearch -k shadow_watch -ts today 2>/dev/null | tail -12"
note "auid is the login uid. It survives su and sudo, so it answers 'who',"
note "where uid only answers 'as whom'. -i translates the numbers."

stop "12. the canary, and why a read is worth recording"
run "auditctl -l | grep -F $CANARY"
run "ausearch -k lab_canary -ts today -i 2>/dev/null | tail -8"
note "-p rwa includes reads. Nobody has a reason to read this file, so every"
note "event is interesting - which is the only kind of rule worth alerting on."

printf '\n----- end of tour\n\n'
note "Nothing here was modified. Next: sudo ./scripts/break-and-fix.sh"
