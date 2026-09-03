#!/usr/bin/env bash
#
# verify-lib.sh - assertion helpers for the per-day verify.sh scripts.
#
# Each day sources this file, declares its checks, and ends with vl_summary.
# Exit status is 0 only if nothing FAILED.
#
#   source "$(dirname "$0")/../../lab/verify-lib.sh"
#   vl_init "Day 01 - systemd and the boot path"
#   vl_need systemctl
#   vl_check "no failed units" '[ "$(systemctl list-units --failed --no-legend | wc -l)" -eq 0 ]'
#   vl_manual "you can explain systemd-analyze critical-chain"
#   vl_summary
#
# Outcomes:
#   PASS   the command succeeded
#   FAIL   the command failed - the day is not done
#   SKIP   a prerequisite is missing, so the check could not run
#   YOU    a judgement call; printed as a reminder, never affects exit status

VL_PASS=0
VL_FAIL=0
VL_SKIP=0
VL_MANUAL=0
VL_TITLE=""
VL_FAILED=()
VL_MISSING=()

_vl_colour() { [[ -t 1 ]] && printf '\033[%sm' "$1" || true; }

vl_init() {
  VL_TITLE="$*"
  printf '\n'
  _vl_colour '1'; printf '%s\n' "$VL_TITLE"; _vl_colour '0'
  printf '%s\n' "$(printf '%*s' "${#VL_TITLE}" '' | tr ' ' '-')"
}

vl_need() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || VL_MISSING+=("$c")
  done
}

vl_need_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || VL_MISSING+=("root")
}

_vl_blocked() { [[ ${#VL_MISSING[@]} -gt 0 ]]; }

vl_check() {
  local desc="$1" cmd="$2"
  if _vl_blocked; then
    VL_SKIP=$((VL_SKIP + 1))
    _vl_colour '0;33'; printf '  SKIP  '; _vl_colour '0'
    printf '%s\n' "$desc"
    return 0
  fi
  if bash -c "$cmd" >/dev/null 2>&1; then
    VL_PASS=$((VL_PASS + 1))
    _vl_colour '0;32'; printf '  PASS  '; _vl_colour '0'
    printf '%s\n' "$desc"
  else
    VL_FAIL=$((VL_FAIL + 1))
    VL_FAILED+=("$desc")
    _vl_colour '0;31'; printf '  FAIL  '; _vl_colour '0'
    printf '%s\n' "$desc"
  fi
  return 0
}

vl_manual() {
  VL_MANUAL=$((VL_MANUAL + 1))
  _vl_colour '0;36'; printf '  YOU   '; _vl_colour '0'
  printf '%s\n' "$1"
  return 0
}

vl_summary() {
  printf '\n'
  if _vl_blocked; then
    _vl_colour '0;33'
    printf 'could not run: missing %s\n' "$(printf '%s ' "${VL_MISSING[@]}")"
    _vl_colour '0'
    printf 'This day runs elsewhere - see the "Runs on" line in its README.\n'
    printf '%d checks skipped, %d for you to judge.\n' "$VL_SKIP" "$VL_MANUAL"
    return 0
  fi
  printf '%d passed, %d failed' "$VL_PASS" "$VL_FAIL"
  [[ $VL_MANUAL -gt 0 ]] && printf ', %d for you to judge' "$VL_MANUAL"
  printf '\n'
  if [[ $VL_FAIL -gt 0 ]]; then
    printf '\nstill to do:\n'
    local d
    for d in "${VL_FAILED[@]}"; do printf '  - %s\n' "$d"; done
    return 1
  fi
  _vl_colour '0;32'; printf 'day complete\n'; _vl_colour '0'
  return 0
}
