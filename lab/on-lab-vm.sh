#!/usr/bin/env bash
#
# Refuse to modify a machine that is not a throwaway lab VM.
#
# Sourced by every day script that changes system state. The days install
# units, rewrite firewall rules, relabel filesystems and break things on
# purpose - all of which is fine on a VM you can delete in a minute, and none
# of which belongs on the laptop you are reading this on.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/../../../lab/on-lab-vm.sh"
#   require_lab_vm

# A machine counts as a lab VM if cloud-init dropped our marker there, or if it
# carries one of the lab hostnames. Both are set by lab.sh, so a VM created any
# other way needs the override.
_lab_host() {
	local h=""
	if command -v hostname >/dev/null 2>&1; then
		h=$(hostname -s 2>/dev/null || true)
	fi
	if [[ -z "$h" && -r /etc/hostname ]]; then
		h=$(cut -d. -f1 /etc/hostname 2>/dev/null || true)
	fi
	echo "${h:-unknown}"
}

lab_vm_reason() {
	if [[ -f /etc/bash-mastery-linux-lab ]]; then
		echo "marker file /etc/bash-mastery-linux-lab"
		return 0
	fi
	case "$(_lab_host)" in
	control | node1 | node2)
		echo "hostname $(_lab_host)"
		return 0
		;;
	esac
	return 1
}

require_lab_vm() {
	if lab_vm_reason >/dev/null; then
		return 0
	fi

	# LAB_ALLOW_THIS_MACHINE is deliberately long-winded. If you want it, you
	# already know what you are doing and why.
	if [[ -n "${LAB_ALLOW_THIS_MACHINE:-}" ]]; then
		echo "WARNING: LAB_ALLOW_THIS_MACHINE is set - modifying this machine anyway" >&2
		return 0
	fi

	echo >&2
	echo "refusing to run: $(_lab_host) does not look like a lab VM." >&2
	echo >&2
	echo "The day scripts change system state. They belong on a disposable VM," >&2
	echo "not on your own machine. Nothing has been changed." >&2
	echo >&2
	echo "From the repository on your laptop:" >&2
	echo "  ./lab/lab.sh up control      # create the VM if it is not running" >&2
	echo "  ./lab/lab.sh push control    # copy days/ and lab/ into ~/lab on it" >&2
	echo "  ./lab/lab.sh ssh control     # log in, then cd ~/lab/days/<day>" >&2
	echo >&2
	exit 1
}
