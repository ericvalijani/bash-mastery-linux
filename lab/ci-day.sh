#!/usr/bin/env bash
#
# ci-day.sh - run one day's verify.sh, but only when CI can honestly build
# the thing that day is about.
#
#   ./lab/ci-day.sh 06
#
# A day is verifiable here only if it has days/dayNN/scripts/setup.sh, which
# is what stands the day's work up. Day 06 is the one exception: its work IS
# the namespace topology, and lab.sh builds that.
#
# For the other networking days the topology is only the floor they stand on.
# Building it and then running verify.sh would fail every time, because the
# day's own work - the zone, the resolver, the bridge - does not exist yet.
# That is a missing script, not a broken repo, so this exits 0 and says so.

set -euo pipefail

DAY="${1:-}"
[[ -n "$DAY" ]] || { echo "usage: $0 <NN>" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DAY_DIR="$ROOT/days/day$DAY"
NETNS_DAYS=" 06 07 08 09 18 "

[[ -d "$DAY_DIR" ]] || { echo "no such day: day$DAY" >&2; exit 2; }
[[ -f "$DAY_DIR/verify.sh" ]] || { echo "day$DAY has no verify.sh" >&2; exit 2; }

echo "=== day$DAY ==="

run_verify=no

if [[ -f "$DAY_DIR/scripts/setup.sh" ]]; then
  echo "--> running scripts/setup.sh"
  bash "$DAY_DIR/scripts/setup.sh"
  run_verify=yes
elif [[ "$NETNS_DAYS" == *" $DAY "* ]]; then
  echo "--> no setup.sh; building the namespace topology"
  bash "$ROOT/lab/lab.sh" netns-up
  # Day 06 is done at this point. The rest need their own work on top.
  if [[ "$DAY" == "06" ]]; then
    run_verify=yes
  fi
fi

if [[ "$run_verify" == "no" ]]; then
  echo
  echo "day$DAY has no scripts/setup.sh yet, so the work this day verifies has"
  echo "not been written. Nothing was checked. This job turns real the moment"
  echo "days/day$DAY/scripts/setup.sh exists."
  echo
  echo "SKIPPED (not yet implemented)"
  exit 0
fi

echo "--> running verify.sh"
bash "$DAY_DIR/verify.sh"
