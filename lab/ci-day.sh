#!/usr/bin/env bash
#
# ci-day.sh - run one day's verify.sh in an environment CI can actually build.
#
#   ./lab/ci-day.sh 06
#
# The environment comes from one of two places:
#   1. days/dayNN/scripts/setup.sh   if you have written one
#   2. the namespace topology        for the networking days
#
# If neither exists yet this exits 0 with a clear message, rather than
# pretending to have verified something. A day becomes genuinely CI-verified
# the moment it has a setup script.

set -euo pipefail

DAY="${1:-}"
[[ -n "$DAY" ]] || { echo "usage: $0 <NN>" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DAY_DIR="$ROOT/days/day$DAY"
NETNS_DAYS=" 06 07 08 09 18 "

[[ -d "$DAY_DIR" ]] || { echo "no such day: day$DAY" >&2; exit 2; }
[[ -f "$DAY_DIR/verify.sh" ]] || { echo "day$DAY has no verify.sh" >&2; exit 2; }

echo "=== day$DAY ==="

if [[ -f "$DAY_DIR/scripts/setup.sh" ]]; then
  echo "--> running scripts/setup.sh"
  bash "$DAY_DIR/scripts/setup.sh"
elif [[ "$NETNS_DAYS" == *" $DAY "* ]]; then
  echo "--> no setup.sh; building the namespace topology instead"
  bash "$ROOT/lab/lab.sh" netns-up
else
  echo
  echo "day$DAY has no scripts/setup.sh yet, so there is nothing for CI to"
  echo "stand up and nothing to verify. Write the day's scripts first; this"
  echo "job turns real the moment setup.sh exists."
  echo
  echo "SKIPPED (not yet implemented)"
  exit 0
fi

echo "--> running verify.sh"
bash "$DAY_DIR/verify.sh"
