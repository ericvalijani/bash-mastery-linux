#!/usr/bin/env bash
#
# Day 02 — Users, sudo, permissions and ACLs
# Run this on: VM: node1
#
# Exits 0 only when every automatic check passes. Items printed as
# YOU are judgement calls and never affect the exit status.

set -uo pipefail
cd "$(dirname "$0")"
# shellcheck source=../../lab/verify-lib.sh
source "../../lab/verify-lib.sh"

vl_init "Day 02 — Users, sudo, permissions and ACLs"
vl_need setfacl

vl_check "a system account appsvc exists with no login shell" 'id appsvc && getent passwd appsvc | grep -qE "(nologin|false)$"'
vl_check "appsvc may restart one service and nothing else" 'sudo -l -U appsvc | grep -q "systemctl restart"'
vl_check "appsvc cannot become root" '! sudo -l -U appsvc | grep -qE "\(ALL\).*ALL"'
vl_check "the shared directory is setgid" '[ -g /srv/shared ]'
vl_check "an ACL grants appsvc access without changing the owner" 'getfacl -p /srv/shared 2>/dev/null | grep -q "^user:appsvc:"'
vl_manual "you can explain every line of sudo -l -U appsvc"

vl_summary
