#!/usr/bin/env sh
# Tests scripts/vendor-module.sh against a throwaway copy of the repo layout.
#
# Usage: scripts/tests/vendor-module_test.sh
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/scripts" "$work/modules/workspace/tests" \
  "$work/modules/workspace/.terraform" "$work/templates/T"
cp "$here/vendor-module.sh" "$work/scripts/"
echo main >"$work/modules/workspace/main.tf"
echo script >"$work/modules/workspace/dotfiles.sh"
echo test >"$work/modules/workspace/tests/workspace.tftest.hcl"
echo cache >"$work/modules/workspace/.terraform/cache"
echo lock >"$work/modules/workspace/.terraform.lock.hcl"
echo root >"$work/templates/T/main.tf"

failures=0
# check <description> <command...>
check() {
  description=$1
  shift
  if "$@"; then
    echo "ok   - $description"
  else
    echo "FAIL - $description"
    failures=$((failures + 1))
  fi
}

dest="$work/templates/T/modules/workspace"

"$work/scripts/vendor-module.sh" "$work/templates/T"
check "main.tf is copied" test -f "$dest/main.tf"
check "dotfiles.sh is copied" test -f "$dest/dotfiles.sh"
check "copies are regular files, not symlinks" test ! -L "$dest/main.tf"
check "tests are not copied" test ! -e "$dest/tests"
check "the .terraform cache is not copied" test ! -e "$dest/.terraform"
check "the module lock file is not copied" test ! -e "$dest/.terraform.lock.hcl"

rm "$work/modules/workspace/dotfiles.sh"
"$work/scripts/vendor-module.sh" "$work/templates/T"
check "a file removed from the module is removed from the copy" test ! -e "$dest/dotfiles.sh"

if "$work/scripts/vendor-module.sh" "$work/templates/missing" 2>/dev/null; then
  check "a missing template directory is rejected" false
else
  check "a missing template directory is rejected" true
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed" >&2
  exit 1
fi
echo "all tests passed"
