#!/usr/bin/env sh
# Prints the name of each template a change between two commits affects, one
# per line, for CI to validate or push.
#
# A change to the shared module or to this vendoring machinery affects every
# template. So does a base commit git cannot resolve: a push that creates a
# branch reports an all-zero `before` SHA, and after a force push `before` may
# no longer exist. Validating everything is the safe answer to "unknown".
#
# Usage: scripts/changed-templates.sh <base-sha> <head-sha>
set -eu

if [ $# -ne 2 ]; then
  echo "usage: $0 <base-sha> <head-sha>" >&2
  exit 2
fi
base=$1
head=$2

all_templates() {
  for dir in templates/*/; do
    if [ -f "${dir}main.tf" ]; then basename "$dir"; fi
  done
}

if ! git cat-file -e "${base}^{commit}" 2>/dev/null; then
  all_templates
  exit 0
fi

changed=$(git diff --name-only "$base" "$head")

if printf '%s\n' "$changed" | grep -qE '^(modules/workspace/|scripts/vendor-module\.sh$)'; then
  all_templates
  exit 0
fi

# A deleted template shows up in the diff but has nothing left to push.
printf '%s\n' "$changed" \
  | sed -n 's#^templates/\([^/]*\)/.*#\1#p' \
  | sort -u \
  | while read -r name; do
    if [ -f "templates/${name}/main.tf" ]; then echo "$name"; fi
  done
