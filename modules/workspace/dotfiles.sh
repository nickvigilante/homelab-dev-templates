#!/usr/bin/env sh
# Apply the dotfiles at workspace start. Runs as coder_script.dotfiles.
#
# The image already runs `chezmoi init --apply` at build time, but that output
# never reaches a workspace: main.tf mounts the home PVC over /home/coder, and
# Kubernetes PVCs do not copy image content in on first mount the way Docker
# named volumes do. Everything baked under $HOME is masked. Tools under
# /usr/local/bin survive; configuration has to be applied here, at runtime.
#
# First start  -> `chezmoi init --apply`, answering the dotfiles' prompts
#                 non-interactively from the template parameters.
# Later starts -> pull, then apply every target that has not drifted. See
#                 apply_undrifted below.
set -eu

DOTFILES_REPO="https://github.com/nickvigilante/dotfiles.git"
CONFIG="${HOME}/.config/chezmoi/chezmoi.toml"

# Unit name for `coder exp sync`. Nothing depends on it today, but naming it
# lets a later script order itself after the dotfiles.
UNIT="dotfiles"

log() { printf '[dotfiles] %s\n' "$*"; }

if ! command -v chezmoi >/dev/null 2>&1; then
  log "chezmoi not on PATH; the base image should provide it. Skipping."
  exit 0
fi

# Wait for the Claude Code install before applying. The dotfiles register MCP
# servers and install Claude Code plugins with the `claude` CLI, and skip both
# when it is missing, so an apply that wins the race leaves Claude Code
# unconfigured until the next restart.
#
# main.tf substitutes the claude-code module's own list of sync names,
# space-separated, for the placeholder. Run by hand, the placeholder is left
# as is, and the wait is skipped.
DOTFILES_AFTER_UNITS="@DOTFILES_AFTER_UNITS@"
case "$DOTFILES_AFTER_UNITS" in @*@) DOTFILES_AFTER_UNITS="" ;; esac

# Best effort: if the agent socket is unavailable or the wait times out, apply
# anyway rather than leave the workspace with no dotfiles at all.
if [ -n "$DOTFILES_AFTER_UNITS" ]; then
  # shellcheck disable=SC2086 # word-splitting the unit list is the point
  if coder exp sync want "$UNIT" $DOTFILES_AFTER_UNITS \
    && coder exp sync start "$UNIT" --timeout 10m; then
    synced=1
  else
    log "Could not wait for ${DOTFILES_AFTER_UNITS}; applying anyway."
  fi
fi

# Mark the unit complete however this script exits.
if [ "${synced:-0}" = 1 ]; then
  trap 'coder exp sync complete "$UNIT" || true' EXIT
fi

# Apply every target except the ones changed outside chezmoi.
#
# A plain `chezmoi apply` stops to ask "X has changed since chezmoi last wrote
# it?" for each such target, and a coder_script has no TTY to answer on, so the
# whole apply fails. That happens on almost every start: Claude Code rewrites
# ~/.claude/settings.json whenever /model, /config or a plugin install touches
# it. Skipping those targets keeps the rest of the dotfiles current. The
# dotfiles' SessionStart hook reports the drift, and /chezmoi-sync reconciles
# it by hand.
#
# `chezmoi status` prints two columns before the path: the first compares the
# last state chezmoi wrote with the actual file, so non-blank means drift; the
# second compares the actual file with the target, so non-blank means pending.
apply_undrifted() {
  st=$(chezmoi status)

  drifted=$(printf '%s\n' "$st" | awk 'substr($0, 1, 1) != " " && NF { print substr($0, 4) }')
  if [ -n "$drifted" ]; then
    log "Skipping targets changed outside chezmoi (run /chezmoi-sync to reconcile):"
    printf '%s\n' "$drifted" | sed 's/^/[dotfiles]   ~\//'
  fi

  # Paths are relative to $HOME, and xargs -r runs nothing when every pending
  # target has drifted. Without -r an empty list would mean "apply everything",
  # prompts included.
  printf '%s\n' "$st" \
    | awk 'substr($0, 1, 1) == " " && NF { print substr($0, 4) }' \
    | (cd "$HOME" && xargs -r -d '\n' chezmoi apply --)
}

# A failed apply must not take the workspace down with it. Report it loudly
# and exit non-zero so Coder flags the script, but main.tf leaves
# start_blocks_login false, so the user can still log in and run
# `chezmoi apply` by hand to see why.
fail() {
  status=$1
  log "chezmoi ${2} FAILED (exit ${status}). The workspace is still usable;"
  log "run 'chezmoi apply' in a terminal to see the error."
  exit "$status"
}

if [ -f "$CONFIG" ]; then
  log "Existing chezmoi config found; pulling and applying."
  chezmoi update --apply=false || fail $? update
  apply_undrifted || fail $? apply
else
  log "First start; initialising dotfiles from ${DOTFILES_REPO}."

  # Each flag's key is the prompt's DISPLAY text, not its data key, exactly
  # as the Dockerfile's build-time invocation does. machine=ephemeral is the
  # dotfiles' role for containers; secrets=none because a workspace has no
  # unlocked vault, and the kubeconfig gate would skip it regardless unless
  # this template sets WORKSPACE_CLUSTER_ADMIN, which Base does not.
  #
  # Nothing has drifted on a first start, so a plain apply cannot prompt.
  chezmoi init --apply \
    --promptChoice "Profile=personal" \
    --promptString "Full name=${GIT_AUTHOR_NAME:-}" \
    --promptString "Email address=${GIT_AUTHOR_EMAIL:-}" \
    --promptChoice "Machine role=ephemeral" \
    --promptBool "Has graphical display=false" \
    --promptChoice "Secret managers=none" \
    "$DOTFILES_REPO" || fail $? init
fi

log "Dotfiles applied."
