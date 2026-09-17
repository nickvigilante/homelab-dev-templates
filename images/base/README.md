# base image

Multi-arch (`linux/amd64`, `linux/arm64`) base image for Coder
workspaces on this cluster. Published to
`ghcr.io/nickvigilante/homelab-dev-templates` on merge to `main`,
tagged by short commit SHA — never `:latest`, so the template's pinned
reference is always reproducible.

## Building locally

```bash
docker buildx build --platform linux/amd64,linux/arm64 -t base:local .
```

## What's baked in

Built on `codercom/example-base:ubuntu`, then a non-interactive
`chezmoi init --apply` runs the real
[`nickvigilante/dotfiles`](https://github.com/nickvigilante/dotfiles)
tree against it (`profile=personal`, `machine=ephemeral`,
`secrets=none`), pinned via the `DOTFILES_REF` build arg (default
`main`; pass `--build-arg DOTFILES_REF=<sha>` for a reproducible
pin). That installs Homebrew (linuxbrew) and, via the dotfiles repo's
`run_after_install-packages.sh.tmpl` hook, everything in
`home/dot_config/dotfiles/Brewfile.tmpl`'s cross-platform CLI and
personal-only sections — including `ripgrep`, `fd`, `fzf`, `eza`,
`bat`, `zoxide`, `neovim`, `tmux`, `gh`, `git-delta`, `lazygit`,
`chezmoi`, `starship`, `uv`, `ruff`, `gum`, `just`, `fish`, and
`ollama` — plus the zsh shell config, `oh-my-zsh` + plugins, and
default-shell/venv setup that come with the rest of the dotfiles
tree. `secrets=none` means no Bitwarden/1Password CLI is installed or
touched during the build.

**Secrets discipline is load-bearing here — this image is public.**
The dotfiles repo's home-lab cluster-admin kubeconfig template is
excluded from every image build via the `DOTFILES_IMAGE_BUILD`
environment variable, set in the `Dockerfile` before `chezmoi apply`
ever runs. See [`DOTFILES-AUDIT.md`](./DOTFILES-AUDIT.md) for the
full audit that found and closed this gap, and the Task 9 report for
the before/after verification evidence (with vs. without that env
var set).
