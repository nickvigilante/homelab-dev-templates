#!/usr/bin/env sh
# Tests scripts/push-template.sh with a stub `coder` on PATH.
#
# Usage: scripts/tests/push-template_test.sh
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/scripts" "$work/modules/workspace" "$work/templates/T/modules/workspace" "$work/bin"
cp "$here/push-template.sh" "$here/vendor-module.sh" "$work/scripts/"
echo main >"$work/modules/workspace/main.tf"
echo root >"$work/templates/T/main.tf"
echo stale >"$work/templates/T/modules/workspace/stale.tf"
cat >"$work/bin/coder" <<STUB
#!/usr/bin/env sh
printf '%s\n' "\$@" >"$work/coder-args"
STUB
chmod +x "$work/bin/coder"

failures=0
pass() { echo "ok   - $1"; }
fail() {
  echo "FAIL - $1"
  failures=$((failures + 1))
}

PATH="$work/bin:$PATH" "$work/scripts/push-template.sh" T -y
if [ -f "$work/templates/T/modules/workspace/main.tf" ] && [ ! -e "$work/templates/T/modules/workspace/stale.tf" ]; then
  pass "the module is vendored fresh before the push"
else
  fail "the module is vendored fresh before the push"
fi
expected=$(printf '%s\n' templates push T --directory "$work/templates/T" -y)
if [ "$(cat "$work/coder-args")" = "$expected" ]; then
  pass "coder templates push gets the name, the directory and extra flags"
else
  fail "coder templates push gets the name, the directory and extra flags (got: $(tr '\n' ' ' <"$work/coder-args"))"
fi

rm -f "$work/coder-args"
if PATH="$work/bin:$PATH" "$work/scripts/push-template.sh" Missing 2>/dev/null; then
  fail "an unknown template is rejected"
elif [ -e "$work/coder-args" ]; then
  fail "an unknown template is rejected before coder runs"
else
  pass "an unknown template is rejected before coder runs"
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed" >&2
  exit 1
fi
echo "all tests passed"
