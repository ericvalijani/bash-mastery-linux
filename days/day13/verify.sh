#!/usr/bin/env bash
#
# Day 13 — SELinux: contexts, booleans and denial triage
# Run this on: VM: node1
#
# Exits 0 only when every automatic check passes. Items printed as
# YOU are judgement calls and never affect the exit status.

set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=../../lab/verify-lib.sh
source "../../lab/verify-lib.sh"

vl_init "Day 13 — SELinux: contexts, booleans and denial triage"
vl_need getenforce semanage

vl_check "SELinux is enforcing" '[ "$(getenforce)" = "Enforcing" ]'
vl_check "the web root carries a web content label" 'ls -Zd /srv/www | grep -q "httpd_sys_content_t"'
vl_check "the label rule is permanent, not just a chcon" 'semanage fcontext -l | grep -q "/srv/www"'
vl_check "restorecon is a no-op, so labels match policy" '[ -z "$(restorecon -nvR /srv/www)" ]'
vl_check "nginx actually serves the content" 'curl -sf http://localhost/ >/dev/null'
vl_check "a boolean you set survives, recorded as permanent" 'semanage boolean -l -C | grep -q .'
vl_check "a custom policy module is loaded" 'semodule -l | grep -qE "lab"'
vl_manual "you fixed a denial by relabelling, not by disabling SELinux"
vl_manual "you built that module from a real AVC with audit2allow and read it before loading"

vl_summary
