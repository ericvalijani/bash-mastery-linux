#!/usr/bin/env bash
#
# Repository self-test. Runs on any Linux box, needs no VM, no root, and no
# network - so it is safe in a pre-commit hook and in CI.
#
#   ./tests/cli.sh
#
# It checks the things that are cheap to get wrong and expensive to notice:
# syntax, the CLI contract of lab.sh, executable bits, and whether the
#
# It deliberately does NOT try to test the day scripts. Those install systemd
# units and need root on a Rocky VM; days/dayNN/verify.sh is their test.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

pass=0
fail=0
failed=()

ok()   { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); failed+=("$1"); }
head2() { printf '\n== %s\n' "$1"; }

# check <description> <command...>   passes when the command exits 0
check() {
	local desc="$1"; shift
	if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

# exits_with <code> <description> <command...>
exits_with() {
	local want="$1" desc="$2"; shift 2
	local got=0
	"$@" >/dev/null 2>&1 || got=$?
	if [[ "$got" == "$want" ]]; then ok "$desc"; else bad "$desc (wanted exit $want, got $got)"; fi
}

head2 "shell syntax"
while IFS= read -r f; do
	check "bash -n $f" bash -n "$f"
done < <(find . -name '*.sh' -not -path './.git/*' | sort)

head2 "lab.sh CLI contract"
exits_with 0 "--help succeeds"              bash lab/lab.sh --help
exits_with 0 "no argument prints usage"     bash lab/lab.sh
exits_with 1 "unknown subcommand exits 1"   bash lab/lab.sh definitely-not-a-subcommand
exits_with 1 "ssh with no vm exits 1"       bash lab/lab.sh ssh
exits_with 1 "push with no vm exits 1"      bash lab/lab.sh push
exits_with 1 "push to unknown vm exits 1"   bash lab/lab.sh push not-a-vm
exits_with 1 "add-disk with no vm exits 1"  bash lab/lab.sh add-disk

# Every subcommand in the dispatcher must appear in the help text, or people
# will never find it. This is the check that would have caught 'push' shipping
# undocumented.
head2 "every subcommand is documented"
while IFS= read -r sub; do
	if bash lab/lab.sh --help | grep -q -- " $sub "; then
		ok "help mentions $sub"
	else
		bad "help does not mention $sub"
	fi
# Read the dispatcher only. Any other case statement in the script - such as
# the network state check - is not a subcommand and must not be demanded of
# the help text.
done < <(awk '/^main\(\) \{/, /^\}/' lab/lab.sh \
  | sed -n 's/^    \([a-z][a-z-]*\)).*/\1/p' | grep -v destroy | sort -u)

head2 "ci-day.sh contract"
exits_with 2 "no argument exits 2"          bash lab/ci-day.sh
exits_with 2 "day 99 exits 2"               bash lab/ci-day.sh 99

head2 "executable bits"
for f in lab/lab.sh lab/ci-day.sh tests/cli.sh days/day*/verify.sh; do
	if [[ -x "$f" ]]; then ok "executable: $f"; else bad "not executable: $f"; fi
done
while IFS= read -r f; do
	if [[ -x "$f" ]]; then ok "executable: $f"; else bad "not executable: $f"; fi
done < <(find days -path '*/scripts/*.sh' | sort)

head2 "every script has a shebang"
while IFS= read -r f; do
	if head -1 "$f" | grep -q '^#!'; then ok "shebang: $f"; else bad "no shebang: $f"; fi
done < <(find . -name '*.sh' -not -path './.git/*' | sort)

# We cannot run the real shellcheck binary from this script, so grep for the
# two rules that have already broken CI once: an unguarded cd, and a
# post-increment under set -e. Do not start these comment lines with the
# word shellcheck - that turns the comment into a directive and SC1072 fails.
head2 "shellcheck rules worth catching early"
if grep -rn 'cd "$(dirname' --include='*.sh' . | grep -v '|| exit' | grep -v '&& pwd' | grep -q .; then
	bad "unguarded cd (SC2164) - use: cd ... || exit 1"
	grep -rn 'cd "$(dirname' --include='*.sh' . | grep -v '|| exit' | grep -v '&& pwd' | sed 's/^/        /'
else
	ok "every cd is guarded (SC2164)"
fi
if grep -rnE '[(][(][A-Za-z_][A-Za-z0-9_]*[+][+][)][)]' --include='*.sh' . | grep -v '^[.]/tests/cli[.]sh:' | grep -q .; then
	bad 'post-increment under set -e - use: n=\$((n + 1))'
else
	ok "no post-increment arithmetic"
fi

printf '\n---------------------------------------------------------------\n'
printf '  %d passed, %d failed\n' "$pass" "$fail"
if [[ $fail -gt 0 ]]; then
	printf '\n  still broken:\n'
	for f in "${failed[@]}"; do printf '    - %s\n' "$f"; done
	exit 1
fi
exit 0
