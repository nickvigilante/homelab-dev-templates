# base image

Multi-arch (`linux/amd64`, `linux/arm64`) base image for Coder
workspaces on this cluster. Published to
`ghcr.io/nickvigilante/homelab-dev-templates` on merge to `main`,
tagged by full commit SHA and `latest` — the template pins to the SHA
tag, never `:latest`, so its reference is always reproducible.

`linux/arm64` builds run natively on a `ubuntu-24.04-arm`
GitHub-hosted runner, not under QEMU emulation — see
`.github/workflows/image-build.yml`'s `build` job matrix. Each
platform is built and pushed independently by digest, then
`publish` stitches the two into one multi-arch manifest via `docker buildx imagetools create`.

## Building locally

```bash
# Single platform (matches your host — fast, what you want while iterating):
docker buildx build -t base:local --secret id=github_token,env=GITHUB_TOKEN .

# Both platforms (slow on non-native hardware without a native arm64 builder):
docker buildx build --platform linux/amd64,linux/arm64 -t base:local \
  --secret id=github_token,env=GITHUB_TOKEN .
```

`GITHUB_TOKEN` (any token with public read access, e.g. `gh auth token`)
raises the GitHub API rate limit `install-tools.sh` uses to resolve
each tool's latest release — anonymous requests are capped at
60/hour and exhaust quickly from a shared IP (CI runners, in
particular).

## What's baked in

Built on `codercom/example-base:ubuntu`, packages installed two ways:

- **CLI tools with an official multi-arch installer script** —
  `chezmoi`, `starship`, `just`, `zoxide`, `uv` (plus `ruff` via `uv tool install`), and `ollama` — each installed directly via its own
  maintained `curl | sh` installer.
- **Everything else fetched as a prebuilt binary from its latest
  GitHub release** — `ripgrep` (`rg`), `fd`, `eza`, `bat`, `gh`,
  `git-delta` (`delta`), `lazygit`, `fzf`, `gum`, and `neovim`
  (`nvim`). See [`tools.txt`](./tools.txt) for the list and
  [`install-tools.sh`](./install-tools.sh) for the fetch logic —
  every build resolves each tool's actual latest release, there's no
  version pinned in this repo to go stale.
- **`tmux` and `fish`** via `apt` — neither project publishes
  standalone release binaries.

None of the above needs Homebrew, which this image no longer
installs at all. It was the single biggest contributor to slow
builds: its own bootstrap cost, on top of not every formula shipping
a prebuilt `arm64` Linux bottle (some compiled from source even on
native hardware).

A non-interactive `chezmoi init --apply` still runs the real
[`nickvigilante/dotfiles`](https://github.com/nickvigilante/dotfiles)
tree against the image (`profile=personal`, `machine=ephemeral`,
`secrets=none`), pinned via the `DOTFILES_REF` build arg (default
`main`; pass `--build-arg DOTFILES_REF=<sha>` for a reproducible
pin) — for the zsh shell config, `oh-my-zsh` + plugins, and
default-shell/venv setup, not for package installation (dotfiles PR
#71 gates that script off under `DOTFILES_IMAGE_BUILD`, since
packages are handled entirely above, by this Dockerfile).
`secrets=none` means no Bitwarden/1Password CLI is installed or
touched during the build.

**Secrets discipline is load-bearing here — this image is public.**
The dotfiles repo's home-lab cluster-admin kubeconfig template is
excluded from every image build via the `DOTFILES_IMAGE_BUILD`
environment variable, set in the `Dockerfile` before `chezmoi apply`
ever runs. See [`DOTFILES-AUDIT.md`](./DOTFILES-AUDIT.md) for the
full audit that found and closed this gap, and the Task 9 report for
the before/after verification evidence (with vs. without that env
var set).
