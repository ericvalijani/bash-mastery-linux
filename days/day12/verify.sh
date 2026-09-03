#!/usr/bin/env bash
#
# Day 12 — SSH hardening, bastions and fail2ban
# Run this on: VM: control + node1
#
# Exits 0 only when every automatic check passes. Items printed as
# YOU are judgement calls and never affect the exit status.

set -uo pipefail
cd "$(dirname "$0")"
# shellcheck source=../../lab/verify-lib.sh
source "../../lab/verify-lib.sh"

vl_init "Day 12 — SSH hardening, bastions and fail2ban"
vl_need fail2ban-client

vl_check "password authentication is off" 'sshd -T | grep -qx "passwordauthentication no"'
vl_check "root cannot log in with a password" 'sshd -T | grep -qE "^permitrootlogin (no|prohibit-password)$"'
vl_check "login is restricted to a named user or group" 'sshd -T | grep -qE "^(allowusers|allowgroups) "'
vl_check "the config is valid" 'sshd -t'
vl_check "fail2ban is watching sshd" 'fail2ban-client status sshd'
vl_manual "you reached node1 with ProxyJump through control, and direct access is refused"
vl_manual "you triggered a ban on purpose and then unbanned yourself"

vl_summary
