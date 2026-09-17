# syntax=docker/dockerfile:1
FROM codercom/example-base:ubuntu

# Branch, tag, or commit SHA in nickvigilante/dotfiles to bake in. Left as a
# floating branch by default so the Dockerfile doesn't need editing on every
# dotfiles change; pin to a commit SHA per-build via
# `--build-arg DOTFILES_REF=<sha>` when a specific reproducible pin matters
# (e.g. from CI).
ARG DOTFILES_REF=main

# hadolint ignore=DL3066
USER root
# Matches nickvigilante/dotfiles' own os/linux/bootstrap.apt prereq list, so
# the chezmoi run_once_01-install-bootstrap-prereqs.sh.tmpl hook below is a
# fast no-op instead of a second apt-get pass. codercom/example-base:ubuntu
# already ships curl/git/build-essential but not zsh/gnupg/lsb-release.
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git zsh build-essential file procps gnupg lsb-release \
    && rm -rf /var/lib/apt/lists/*

# hadolint ignore=DL3066
USER coder
WORKDIR /home/coder

# Install Homebrew (linuxbrew) non-interactively, matching how gandalf
# itself is provisioned.
ENV NONINTERACTIVE=1
RUN /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
ENV PATH="/home/linuxbrew/.linuxbrew/bin:${PATH}"

RUN brew install chezmoi

# ── Mandatory secrets-audit gate — see DOTFILES-AUDIT.md ────────────────────
# home/.chezmoiignore in nickvigilante/dotfiles excludes the cluster-admin
# kubeconfig template (home/private_dot_kube/private_homelab.yaml.tmpl, a
# live `{{ (bitwarden "item" "Homelab Kubeconfig").notes }}` fetch) only when
# `.machine == "server"` OR this env var is set (dotfiles PR #64). This image
# is published *publicly* on GHCR, so DOTFILES_IMAGE_BUILD must be set
# before chezmoi ever touches the source tree, regardless of the `.machine`
# value passed below. Verified locally (without Docker) against both states:
# unset reproduces the live `bw get item 'Homelab Kubeconfig'` fetch attempt;
# set makes chezmoi report `.kube/homelab.yaml` as ignored and the dry-run
# apply clean. See DOTFILES-AUDIT.md and the Task 9 report for the full
# before/after evidence.
ENV DOTFILES_IMAGE_BUILD=1

# Non-interactive chezmoi init+apply. home/.chezmoi.toml.tmpl gates all of
# its data on promptChoiceOnce/promptStringOnce/promptBoolOnce, which
# `chezmoi init`'s --promptChoice/--promptString/--promptBool flags satisfy
# non-interactively — confirmed against dotfiles' own
# bootstrap/install.sh, which invokes chezmoi exactly this way for its
# documented non-interactive path. Each flag's key is the prompt's
# *display text* (e.g. "Profile"), not the underlying data key ("profile").
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
