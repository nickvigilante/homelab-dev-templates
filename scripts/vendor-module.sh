#!/usr/bin/env sh
# Copies modules/workspace into a template directory, so the directory that
# `coder templates push` uploads is self-contained.
#
# A copy, never a symlink: Coder's provisioner drops symlinks when it unpacks
# the upload. The destination has no leading dot because the push skips hidden
# paths. .gitignore keeps the copy out of git; the push does not read
# .gitignore, so the copy still uploads.
#
# Usage: scripts/vendor-module.sh <template-dir>
set -eu

if [ $# -ne 1 ] || [ ! -d "$1" ]; then
  echo "usage: $0 <template-dir>" >&2
  exit 2
fi

repo_root=$(cd "$(dirname "$0")/.." && pwd)
dest="$1/modules/workspace"

# Remove the previous copy first, so a file deleted from the module does not
# linger in the template.
rm -rf "$dest"
mkdir -p "$dest"
tar -C "$repo_root/modules/workspace" \
  --exclude=.terraform --exclude=.terraform.lock.hcl --exclude=tests \
  -cf - . | tar -C "$dest" -xf -
