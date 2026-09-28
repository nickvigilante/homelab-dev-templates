#!/usr/bin/env sh
# Tests scripts/template-matrix.sh against a throwaway git repository.
#
# Usage: scripts/tests/template-matrix_test.sh
set -eu

scripts="$(cd "$(dirname "$0")/.." && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

git init -q
git config user.email test@example.com
git config user.name test
mkdir -p templates/Agent templates/Base
echo agent >templates/Agent/main.tf
echo base >templates/Base/main.tf
printf '{"icon": "/emojis/1f9f1.png"}\n' >templates/Base/template.json
git add -A
git commit -qm init
root=$(git rev-parse HEAD)

failures=0
pass() { echo "ok   - $1"; }
fail() {
  echo "FAIL - $1"
  failures=$((failures + 1))
}

echo x >>templates/Base/main.tf
git commit -qam "touch Base"
out=$("$scripts/template-matrix.sh" "$root" HEAD)
if [ "$out" = '[{"template":"Base","icon":"/emojis/1f9f1.png"}]' ]; then
  pass "an affected template yields its metadata and name"
else
  fail "an affected template yields its metadata and name (got: $out)"
fi

base=$(git rev-parse HEAD)
out=$("$scripts/template-matrix.sh" "$base" HEAD)
if [ "$out" = '[]' ]; then
  pass "no affected template yields an empty list"
else
  fail "no affected template yields an empty list (got: $out)"
fi

# Agent sorts before Base, so its missing template.json is not the last one
# processed: the case a pipeline's exit status silently drops.
echo x >>templates/Agent/main.tf
echo x >>templates/Base/main.tf
git commit -qam "touch both"
if "$scripts/template-matrix.sh" "$base" HEAD >/dev/null 2>"$work/err"; then
  fail "a missing template.json before another template fails"
else
  if grep -q 'templates/Agent/template.json' "$work/err"; then
    pass "a missing template.json before another template fails"
  else
    fail "a missing template.json fails without naming the file"
  fi
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed" >&2
  exit 1
fi
echo "all tests passed"
