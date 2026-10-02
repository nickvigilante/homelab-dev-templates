#!/usr/bin/env sh
# Prints a JSON array for template-push.yml's matrix: for each template a
# change affects, its template.json with the directory name added as
# "template". template-validate.yml runs it too, so a missing file fails the
# pull request instead of the push.
#
# Fails when an affected template has no template.json, rather than pushing
# the template without its metadata. The loop runs in this shell, not in a
# pipeline or command substitution, because a failure there only counts when
# it happens to be the last one.
#
# Usage: scripts/template-matrix.sh <base-sha> <head-sha>
set -eu

if [ $# -ne 2 ]; then
  echo "usage: $0 <base-sha> <head-sha>" >&2
  exit 2
fi

names=$("$(dirname "$0")/changed-templates.sh" "$1" "$2")

objects=""
while read -r name; do
  [ -n "$name" ] || continue
  meta="templates/${name}/template.json"
  if [ ! -f "$meta" ]; then
    echo "error: ${meta} is missing; every template needs one" >&2
    exit 1
  fi
  objects="${objects}$(jq -c --arg t "$name" '{template: $t} + .' "$meta")
"
done <<EOF_NAMES
$names
EOF_NAMES

printf '%s' "$objects" | jq -s -c '.'
