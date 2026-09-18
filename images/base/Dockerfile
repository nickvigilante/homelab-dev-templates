# syntax=docker/dockerfile:1
FROM codercom/example-base:ubuntu

# Branch, tag, or commit SHA in nickvigilante/dotfiles to bake in — pin to a
# specific commit per-build via `--build-arg DOTFILES_REF=<sha>` when
# reproducibility matters (e.g. from CI). Left at `main` as the default so
# local iteration doesn't need to know a SHA.
ARG DOTFILES_REF=main

# Without this, a failed `curl | sh` in any RUN below would exit 0 (only
# the trailing `sh`'s exit code counts) and silently continue the build on
# a corrupted/empty install.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# hadolint ignore=DL3066
USER root
# Matches nickvigilante/dotfiles' own os/linux/bootstrap.apt prereq list
# (curl/git already ship in codercom/example-base:ubuntu, but zsh/gnupg/
# lsb-release don't), so the chezmoi run_once_01-install-bootstrap-
# prereqs.sh.tmpl hook further down is a fast no-op instead of a second
# apt-get pass. tmux and fish are here (not fetched as static binaries)
# because neither project publishes standalone release binaries. zstd is
# required by ollama's own installer for extraction (hit on the first CI
# run of this Dockerfile — the installer fails loudly if it's missing
# rather than falling back to another extractor).
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git zsh build-essential file procps gnupg lsb-release \
      tmux fish zstd \
    && rm -rf /var/lib/apt/lists/*

# ── CLI tools with their own official multi-arch installer script ──────────
# Preferred over tools.txt's generic GitHub-release fetch wherever the
# project ships one — a maintained installer handles arch detection more
# robustly than hand-written asset-name patterns.
RUN curl -fsSL get.chezmoi.io | sh -s -- -b /usr/local/bin
RUN curl -sS https://starship.rs/install.sh | sh -s -- -y --bin-dir /usr/local/bin
RUN curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh \
      | bash -s -- --to /usr/local/bin
RUN curl -sS https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh \
      | bash -s -- --bin-dir /usr/local/bin
# uv's installer defaults to $HOME/.local/bin; UV_INSTALL_DIR redirects it to
# a location already on PATH for every user, root included. UV_TOOL_BIN_DIR
# does the same for `uv tool install` shims (used for ruff below), so it
# works regardless of which user's $HOME is active when it runs.
ENV UV_INSTALL_DIR=/usr/local/bin
ENV UV_TOOL_BIN_DIR=/usr/local/bin
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
RUN uv tool install ruff
RUN curl -fsSL https://ollama.com/install.sh | sh

# ── CLI tools fetched as prebuilt binaries from their latest GitHub release ─
# See tools.txt for the list + per-tool asset-name pattern, and
# install-tools.sh for the fetch/install logic. Needs GITHUB_TOKEN (mounted
# as a BuildKit secret, never baked into an image layer) — anonymous GitHub
# API requests are capped at 60/hour per IP, which GitHub Actions runners
# routinely share and exhaust; authenticated requests get 5000/hour.
COPY tools.txt install-tools.sh /tmp/
RUN --mount=type=secret,id=github_token \
    sh -c 'export GITHUB_TOKEN="$(cat /run/secrets/github_token 2>/dev/null || true)"; \
           chmod +x /tmp/install-tools.sh && /tmp/install-tools.sh /tmp/tools.txt' \
    && rm -f /tmp/tools.txt /tmp/install-tools.sh

# hadolint ignore=DL3066
USER coder
WORKDIR /home/coder
# Docker's USER directive only changes the effective UID for RUN/CMD; unlike
# a real login shell (PAM/pam_env), it does not export $USER. dotfiles'
# run_once_08-set-default-shell.sh.tmpl reads $USER under `set -u`, so
# without this the build fails with "USER: unbound variable".
ENV USER=coder

# ── Mandatory secrets-audit gate — see DOTFILES-AUDIT.md ────────────────────
# home/.chezmoiignore in nickvigilante/dotfiles excludes the cluster-admin
# kubeconfig template (home/private_dot_kube/private_homelab.yaml.tmpl, a
# live `{{ (bitwarden "item" "Homelab Kubeconfig").notes }}` fetch) only when
# `.machine == "server"` OR this env var is set (dotfiles PR #64). This image
# is published *publicly* on GHCR, so DOTFILES_IMAGE_BUILD must be set
# before chezmoi ever touches the source tree, regardless of the `.machine`
# value passed below. It also gates the always-run package installer
# (dotfiles PR #71) — package installation is handled entirely above, by
# this Dockerfile, so that script must not attempt its own (Homebrew-based)
# install here. See DOTFILES-AUDIT.md and the Task 9 report for the full
# before/after evidence on the kubeconfig gate.
ENV DOTFILES_IMAGE_BUILD=1

# Non-interactive chezmoi init+apply. home/.chezmoi.toml.tmpl gates all of
# its data on promptChoiceOnce/promptStringOnce/promptBoolOnce, which
# `chezmoi init`'s --promptChoice/--promptString/--promptBool flags satisfy
# non-interactively — confirmed against dotfiles' own bootstrap/install.sh,
# which invokes chezmoi exactly this way for its documented non-interactive
# path. Each flag's key is the prompt's *display text* ("Profile"), not the
# underlying data key ("profile").
#
#   - machine=ephemeral: the dotfiles repo's own designated role for
#     headless/automated/container builds.
#   - secrets=none: per DOTFILES-AUDIT.md's recommendation, defense in depth
#     — nothing in a base dev image needs a Bitwarden/1Password CLI, and
#     omitting it means there's no `bw`/`op` binary on PATH at all, so even
#     a broken/missing .chezmoiignore gate would hard-fail this RUN instead
#     of silently baking a secret in.
#   - --revision (not --branch): accepts a branch, tag, or commit SHA alike,
#     matching DOTFILES_REF's dual role as a floating default / pinned SHA.
RUN chezmoi init --apply \
      --revision "${DOTFILES_REF}" \
      --promptChoice "Profile=personal" \
      --promptString "Full name=Coder Workspace" \
      --promptString "Email address=" \
      --promptChoice "Machine role=ephemeral" \
      --promptBool "Has graphical display=false" \
      --promptChoice "Secret managers=none" \
      https://github.com/nickvigilante/dotfiles.git
