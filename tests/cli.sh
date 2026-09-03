#!/usr/bin/env bash
#
# Repository self-test. Runs on any Linux box, needs no VM, no root, and no
# network - so it is safe in a pre-commit hook and in CI.
#
#   ./tests/cli.sh
#
# It checks the things that are cheap to get wrong and expensive to notice:
# syntax, the CLI contract of lab.sh, executable bits, and whether the
# generated files still match their generator.
#
# It deliberately does NOT try to test the day scripts. Those install systemd
# units and need root on a Rocky VM; days/dayNN/verify.sh is their test.

set -uo pipefail
cd "$(dirname "$0")/.."

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

head2 "python generators parse"
for f in gen/*.py; do
	check "ast.parse $f" python3 -c "import ast,sys;ast.parse(open(sys.argv[1]).read())" "$f"
done

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
done < <(sed -n 's/^    \([a-z][a-z-]*\)).*/\1/p' lab/lab.sh | grep -v destroy | sort -u)

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

# The day pages and verify scripts are generated. If someone hand-edits one,
# their change is one regenerate away from vanishing - so catch it now.
head2 "generated files match their generator"
if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
	python3 gen/render.py >/dev/null && python3 gen/readme.py >/dev/null
	if git diff --quiet -- README.md docs/curriculum.md days; then
		ok "regenerating changes nothing"
	else
		bad "generated files are out of date - commit the regenerated output:"
		git diff --stat -- README.md docs/curriculum.md days | sed 's/^/        /'
	fi
else
	printf '  skip  generator freshness (no git repository yet)\n'
fi

printf '\n---------------------------------------------------------------\n'
printf '  %d passed, %d failed\n' "$pass" "$fail"
if [[ $fail -gt 0 ]]; then
	printf '\n  still broken:\n'
	for f in "${failed[@]}"; do printf '    - %s\n' "$f"; done
	exit 1
fi
exit 0
