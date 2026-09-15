#!/usr/bin/env bash
#
# Day 19 teardown.
#
#   sudo ./scripts/teardown.sh          lab rules, the canary, the payload
#   sudo ./scripts/teardown.sh --all    also stops suricata and restores the
#                                       original suricata.yaml
#
# auditd is never stopped. It is a machine's record of who did what, and
# turning it off to tidy up a lab is a bad habit to build.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
require_lab_vm

YAML="/etc/suricata/suricata.yaml"
LAB_RULES="/etc/suricata/rules/lab.rules"
AUDIT_RULES="/etc/audit/rules.d/99-lab.rules"
AUDITD_CONF="/etc/audit/auditd.conf"
CANARY="/etc/lab-canary"
PAYLOAD="/usr/local/bin/lab-ids"
BACKUP_DIR="/tmp/day19-broken"

say()  { printf '\n==> %s\n\n' "$*"; }
ok()   { printf '  ok    %s\n' "$*"; }
note() { printf '        %s\n' "$*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || { printf 'needs root: sudo %s %s\n' "$0" "$*" >&2; exit 1; }

ALL=no
[[ "${1:-}" == "--all" ]] && ALL=yes

say "1. audit rules"

if [[ -f "$AUDIT_RULES" ]]; then
	rm -f "$AUDIT_RULES"
	ok "removed $AUDIT_RULES"
else
	note "no $AUDIT_RULES"
fi

# Deleting the file is not enough: the rules are in the kernel until something
# reloads them. augenrules --load rebuilds the kernel's set from what is left
# in rules.d, which is the whole point of the directory.
if augenrules --load >/dev/null 2>&1; then
	ok "reloaded the remaining rules into the kernel"
else
	note "augenrules --load failed - check 'auditctl -l' by hand"
fi
if auditctl -l 2>/dev/null | grep -q 'lab-canary'; then
	note "the canary watch is still loaded - is the audit config immutable (-e 2)?"
	note "that state only clears on reboot, by design"
else
	ok "the lab watches are gone from the kernel"
fi

# setup.sh lowered auditd.conf's freq to 1 so events reach audit.log
# immediately. Put the packaged value back - the lab's preference is not the
# machine's.
if [[ -f "$BACKUP_DIR/auditd.conf.orig" ]]; then
	cp -a "$BACKUP_DIR/auditd.conf.orig" "$AUDITD_CONF"
	systemctl reload auditd >/dev/null 2>&1 ||
		service auditd reload >/dev/null 2>&1 ||
		pkill -HUP auditd >/dev/null 2>&1 || true
	ok "restored the original $AUDITD_CONF"
fi

say "2. the canary and the payload"

rm -f "$CANARY" && ok "removed $CANARY"
if [[ -f "$PAYLOAD" ]]; then
	rm -f "$PAYLOAD"
	ok "removed $PAYLOAD"
fi

say "3. suricata rules"

if [[ -f "$LAB_RULES" ]]; then
	rm -f "$LAB_RULES"
	ok "removed $LAB_RULES"
fi

if [[ "$ALL" == "yes" ]]; then
	say "4. --all: suricata back to how the package left it"

	systemctl disable --now suricata >/dev/null 2>&1 &&
		ok "suricata stopped and disabled" ||
		note "suricata was not running"

	if [[ -f "$BACKUP_DIR/suricata.yaml.orig" ]]; then
		cp -a "$BACKUP_DIR/suricata.yaml.orig" "$YAML"
		ok "restored the original $YAML"
	else
		note "no backup of $YAML - the af-packet interface and rule-files"
		note "entry from setup.sh are still in place"
	fi
	rm -rf "$BACKUP_DIR" && ok "removed $BACKUP_DIR"
	note "/var/log/suricata/eve.json is left alone - it is evidence, and"
	note "deleting logs during cleanup is how incidents become unexplainable"
else
	# Removing the rule file while suricata still references it would make the
	# next reload fail, so tell it now rather than at the next restart.
	if systemctl is-active --quiet suricata; then
		sed -i "\\|^  - $LAB_RULES\$|d" "$YAML"
		if suricata -T -c "$YAML" >/dev/null 2>&1; then
			systemctl reload suricata >/dev/null 2>&1 || systemctl restart suricata >/dev/null 2>&1
			ok "suricata reloaded without the lab rules, still running"
		else
			note "suricata -T now fails - not reloading a broken config"
		fi
	fi
	note "suricata and auditd are both left running."
	note "Use --all to stop suricata and restore its original config."
fi

say "done"
note "Re-run it all with: sudo ./scripts/setup.sh"
