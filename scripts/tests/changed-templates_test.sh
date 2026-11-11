#!/usr/bin/env sh
# Tests scripts/changed-templates.sh against a throwaway git repository.
#
# Usage: scripts/tests/changed-templates_test.sh
set -eu

script="$(cd "$(dirname "$0")/.." && pwd)/changed-templates.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

git init -q
git config user.email test@example.com
git config user.name test
mkdir -p templates/Base templates/Other modules/workspace scripts
echo base >templates/Base/main.tf
echo other >templates/Other/main.tf
echo module >modules/workspace/main.tf
echo vendor >scripts/vendor-module.sh
echo readme >README.md
git add -A
git commit -qm init
root=$(git rev-parse HEAD)

failures=0
# expect <description> <expected, newline-separated> <base> <head>
expect() {
  actual=$("$script" "$3" "$4")
  if [ "$actual" = "$2" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    printf '  expected: %s\n  actual:   %s\n' "$(echo "$2" | tr '\n' ' ')" "$(echo "$actual" | tr '\n' ' ')"
    failures=$((failures + 1))
  fi
}

commit() {
  git add -A
  git commit -qm "$1"
  git rev-parse HEAD
}

echo x >>templates/Base/main.tf
c1=$(commit "touch Base")
expect "a template change selects only that template" "Base" "$root" "$c1"

echo x >>README.md
c2=$(commit "touch README")
expect "a change outside templates selects nothing" "" "$c1" "$c2"

echo x >>modules/workspace/main.tf
c3=$(commit "touch module")
expect "a module change selects every template" "Base
Other" "$c2" "$c3"

echo x >>scripts/vendor-module.sh
c4=$(commit "touch vendor script")
expect "a vendor script change selects every template" "Base
Other" "$c3" "$c4"

git rm -rq templates/Other
c5=$(commit "delete Other")
expect "a deleted template is not selected" "" "$c4" "$c5"

expect "an all-zero base selects every template" "Base" \
  0000000000000000000000000000000000000000 "$c5"

expect "an unknown base selects every template" "Base" \
  1111111111111111111111111111111111111111 "$c5"

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed" >&2
  exit 1
fi
echo "all tests passed"
