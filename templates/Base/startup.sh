#!/usr/bin/env sh
# Apply the dotfiles at workspace start.
#
# The image already runs `chezmoi init --apply` at build time, but that output
# never reaches a workspace: main.tf mounts the home PVC over /home/coder, and
# Kubernetes PVCs do not copy image content in on first mount the way Docker
# named volumes do. Everything baked under $HOME is masked. Tools under
# /usr/local/bin survive; configuration has to be applied here, at runtime.
#
# First start  -> `chezmoi init --apply`, answering the dotfiles' prompts
#                 non-interactively from the template parameters.
# Later starts -> `chezmoi update`, which pulls and applies, so a dotfiles
#                 change reaches an existing workspace on restart without an
#                 image rebuild.
set -eu

DOTFILES_REPO="https://github.com/nickvigilante/dotfiles.git"
CONFIG="${HOME}/.config/chezmoi/chezmoi.toml"

log() { printf '[dotfiles] %s\n' "$*"; }

if ! command -v chezmoi >/dev/null 2>&1; then
  log "chezmoi not on PATH; the base image should provide it. Skipping."
  exit 0
fi

if [ -f "$CONFIG" ]; then
  log "Existing chezmoi config found; pulling and applying."
  set -- update
else
  log "First start; initialising dotfiles from ${DOTFILES_REPO}."

  # Each flag's key is the prompt's DISPLAY text, not its data key, exactly
  # as the Dockerfile's build-time invocation does. machine=ephemeral is the
  # dotfiles' role for containers; secrets=none because a workspace has no
  # unlocked vault, and the kubeconfig gate would skip it regardless unless
  # this template sets WORKSPACE_CLUSTER_ADMIN, which Base does not.
  set -- init --apply \
    --promptChoice "Profile=personal" \
    --promptString "Full name=${DOTFILES_GIT_NAME:-}" \
    --promptString "Email address=${DOTFILES_GIT_EMAIL:-}" \
    --promptChoice "Machine role=ephemeral" \
    --promptBool "Has graphical display=false" \
    --promptChoice "Secret managers=none" \
    "$DOTFILES_REPO"
fi

# A failed apply must not take the workspace down with it. Report it loudly
# and exit non-zero so Coder flags the startup script, but do not abort before
# the agent is usable: startup_script_behavior is non-blocking by default, so
# the user can still log in and run `chezmoi apply` by hand to see why.
if chezmoi "$@"; then
  log "Dotfiles applied."
else
  status=$?
  log "chezmoi $1 FAILED (exit ${status}). The workspace is still usable;"
  log "run 'chezmoi apply' in a terminal to see the error."
  exit "$status"
fi
