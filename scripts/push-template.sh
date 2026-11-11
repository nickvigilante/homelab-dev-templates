#!/usr/bin/env sh
# Pushes one template by hand: vendors the shared module fresh, then runs
# `coder templates push`. Use it instead of pushing the directory directly: a
# vendored copy from an earlier run is git-ignored and survives a pull, so a
# direct push can upload an old module without any error.
#
# Usage: scripts/push-template.sh <template-name> [coder templates push flags...]
set -eu

if [ $# -lt 1 ]; then
  echo "usage: $0 <template-name> [coder templates push flags...]" >&2
  exit 2
fi
name=$1
shift

repo_root=$(cd "$(dirname "$0")/.." && pwd)
dir="$repo_root/templates/$name"
if [ ! -f "$dir/main.tf" ]; then
  echo "error: no template at templates/$name" >&2
  exit 2
fi

"$repo_root/scripts/vendor-module.sh" "$dir"
exec coder templates push "$name" --directory "$dir" "$@"
