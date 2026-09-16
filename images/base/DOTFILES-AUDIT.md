# Dotfiles bake audit

Before Task 9 bakes dotfiles into a **public** GHCR image, this records what was checked and what's excluded.

Audit profile: `profile: personal, os: linux, display: false`.
This matches the real, currently-applied config on the home-lab server `gandalf` (`~/.config/chezmoi/chezmoi.toml`: `profile = "personal"`, `machine = "server"`, `display = false`, `secrets = "bitwarden"`), which is why it was chosen as the reference config — it's a known-working configuration, not a hypothetical.
`.machine` and `.secrets` are separate chezmoi data prompts not pinned by the profile combination above; see "Required for Task 9" below for why that matters.

Source audited: `nickvigilante/dotfiles`, `home/` (the chezmoi source root — `.chezmoiroot = home`), at `origin/main` commit `bc3007b` (after the fix below merged; the audit itself started at `a78a549`).

## Methodology

1. Re-verified the Brewfile-level secrets-CLI gating against current source.
2. Ran the plan's grep (`bw get|bw unlock|op read|op item|BW_SESSION|op://|1password`) across `home/**.tmpl` and `home/**.sh`, and read every matched file in full.
3. **Supplemented that grep** with a second pass for `(bitwarden |onepasswordRead|(onepassword |keyring|pass show|vault read|gopass`, because the plan's literal pattern list does not match chezmoi's own `bitwarden`/`onepasswordRead` template functions (e.g. `{{ (bitwarden "item" "...").notes }}`) — no literal `bw`/`op`/`BW_SESSION`/`1password` substring appears in that syntax.
   This second pass is what actually surfaced the one real finding below; it found no files beyond what step 2 (and the `find` in step 3) already turned up, but it closes a real gap in the plan's grep as written.
   Recommend any future re-audit include this second pattern.
4. Ran `find home/ -name 'run_*' -o -name '*private_*' -o -name '*.age'` and read every matched file in full.
5. Read every `run_once_*`/`run_after_*` script's *rendered* logic (not just skimmed), tracing which branches are live under `profile=personal, os=linux, display=false`.
6. Verified renders with `chezmoi execute-template` against synthetic configs (not just manual template reading) — both for the Brewfile secrets-CLI section and for the `.chezmoiignore` fix below, including a deliberately adversarial `machine=ephemeral` case to prove the gap was real before the fix and closed after.
7. Skimmed `bootstrap/install.sh` (outside `home/`, so outside chezmoi's applied tree and outside the literal audit scope) for context on how a non-interactive build might invoke this repo — see "Context: bootstrap/install.sh" below.
   It doesn't change any conclusion here; the `.chezmoiignore`-level fix holds regardless of whether Task 9 uses it.

## Checked

### Step 1 — Brewfile-level secrets-CLI installs

`home/dot_config/dotfiles/Brewfile.tmpl`:

- `bitwarden-cli`: still gated `{{ if eq .chezmoi.os "darwin" }}` inside the `.secrets` block.
  True no-op on Linux under every `.secrets` value — Linux gets `bw` from snap via `bootstrap/install.sh`, never from this Brewfile.
  Confirmed by reading the source and by rendering the Brewfile with `.secrets=both` (only `1password-cli` appeared; `bitwarden-cli` never did).
  **Confirmed 2026-09-16.**
- `1password-cli`: darwin gets `cask "1password-cli"`; Linux gets `brew "1password-cli"` (a real Homebrew formula install, not cask) — but only when `.secrets` is `"1password"` or `"both"`.
  This is **not** purely darwin-gated the way the plan's Step 1 assumed.
  It predates this plan (`git log -S'1password-cli'` shows it landed 2026-04-29, commit `f3694b3`, months before this plan), so it isn't drift introduced during this work — it's a standing, intentional design choice (Linux non-Pi machines can use a 1Password Homebrew formula).
  It is **not** a secrets-fetch risk by itself: installing the `op` binary doesn't invoke it, and nothing in the tree auto-runs `op signin`/`op read`/`op item` anywhere.
  Under gandalf's real config (`secrets = "bitwarden"`), this branch doesn't fire at all.
  **Action for Task 9:** whatever `.secrets` value the image build passes, if it's `"1password"` or `"both"`, expect `brew bundle install` (see below) to actually install the `1password-cli` formula during the build — a build-time network/time cost, not a secrets leak.
  Recommend the image build pass `--secrets none` (or `DOTFILES_SECRETS=none`) unless there's a reason to need a secrets CLI baked in, which there shouldn't be for a base image.
- `home/run_after_install-packages.sh.tmpl` is a `run_after_` hook — it **does** execute automatically at the end of `chezmoi apply` on non-Pi, non-32-bit-ARM machines, and runs `brew bundle install` against the rendered Brewfile.
  This doesn't fetch any secret itself (it only installs packages), but it means the Brewfile's `.secrets` gating above has real teeth during an image build, not just theoretical relevance.

### Step 2 — grep for live secret fetches

`grep -rn 'bw get\|bw unlock\|op read\|op item\|BW_SESSION\|op://\|1password' home/ --include='*.tmpl' --include='*.sh' -l` matched 7 files.
Every one read in full:

| File                                                 | What it does                                                                                                                                                                                                       | Runs during `chezmoi apply` under this profile?                                                                                                                | Verdict                                                                                |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `home/.chezmoi.toml.tmpl`                            | Defines the `.secrets` prompt variable + documents the bootstrap re-run command                                                                                                                                    | Yes (it's the data-init template) but fetches nothing — just plumbing                                                                                          | Safe                                                                                   |
| `home/dot_config/dotfiles/Brewfile.tmpl`             | Renders the Brewfile; secrets-CLI lines as above                                                                                                                                                                   | Yes, renders; see Step 1                                                                                                                                       | Safe (no-op on Linux for bitwarden-cli; installs but doesn't fetch, for 1password-cli) |
| `home/dot_zshenv.tmpl`                               | Reads `OP_SERVICE_ACCOUNT_TOKEN` from `~/.config/op/token` **if that file exists**; sets `SSH_AUTH_SOCK` to the Bitwarden SSH-agent socket **if that socket exists**                                               | Renders at apply time, but only *reads local files that won't exist in a fresh image build* — no fetch                                                         | Safe                                                                                   |
| `home/private_dot_env.tmpl`                          | Writes `~/.env`; the 1Password/Bitwarden example lines are deliberately double-escaped (`{{ "{{" }} ... {{ "}}" }}`) so they print as **literal, inert comment text**, not executed template calls                 | Renders, but the secret-fetch syntax shown is commented-out example text, never evaluated                                                                      | Safe                                                                                   |
| `home/dot_config/shell/functions.zsh.tmpl`           | Defines `bw-apply`/`bw-lock` shell functions                                                                                                                                                                       | Written to disk at apply time, but the functions themselves are **interactive, user-invoked only** — never auto-run during `chezmoi apply` or at shell startup | Safe                                                                                   |
| `home/dot_local/bin/executable_dotfiles-doctor.tmpl` | Health-check script; runs `op whoami`/`bw status` **only when a human runs `dotfiles-doctor` manually**                                                                                                            | Written to disk at apply time; never auto-executed                                                                                                             | Safe                                                                                   |
| `home/private_dot_kube/private_homelab.yaml.tmpl`    | **Directly calls `{{ (bitwarden "item" "Homelab Kubeconfig").notes }}`** — a live Bitwarden fetch of the full k3s cluster-admin kubeconfig, evaluated at template-render time (i.e. during `chezmoi apply` itself) | **Yes, if not excluded**                                                                                                                                       | **Finding — see below. Fixed.**                                                        |

### Step 3 — run_once/run_onchange/private/.age scripts

`find home/ -name 'run_*' -o -name '*private_*' -o -name '*.age'` matched 9 paths (no `.age` files exist anywhere in the tree).
Every one read in full:

- `run_after_install-packages.sh.tmpl` — `brew bundle install` driver; covered under Step 1.
  No secrets touched directly.
- `run_once_01-install-bootstrap-prereqs.sh.tmpl` — `apt`/`dnf` prereqs (git, zsh, build tools).
  No secrets.
- `run_once_02-install-uv.sh.tmpl` — installs `uv` via the official installer script.
  No secrets.
- `run_once_03-setup-python-venv.sh.tmpl` — creates `~/venv`.
  No secrets.
- `run_once_04-install-fonts.sh.tmpl` — downloads a Nerd Font from a public GitHub release; gated on `.display` being true, so it's a no-op under `display: false` anyway.
  No secrets.
- `run_once_05-macos-defaults.sh.tmpl` — `defaults write` calls; exits immediately (`{{ if ne .chezmoi.os "darwin" }}exit 0{{ end }}`) on Linux.
  No secrets.
- `run_once_07-vscode-symlink.sh.tmpl` — macOS-only symlink dance, no-op on Linux.
  No secrets.
  (There is no `run_once_06`; not a gap — just a number never assigned/since removed.)
- `run_once_08-set-default-shell.sh.tmpl` — `chsh` to zsh.
  No secrets.
- `home/private_dot_env.tmpl` — covered above (Step 2).
  Inert example text, safe.
- `home/private_dot_kube/private_homelab.yaml.tmpl` — the finding.
  See below.

None of the `run_once_*`/`run_after_*` scripts touch SSH keys, `.netrc`, git credential helpers, or API tokens under this profile.

### Additional checks beyond the plan's literal steps

- Broadened the Step 2 grep to `(bitwarden \|onepasswordRead\|(onepassword \|keyring\|pass show\|vault read\|gopass` across all of `home/` (not just `.tmpl`/`.sh`) — no files beyond the 7 above.
- Checked `home/.chezmoiexternal.toml` (git-repo externals: oh-my-zsh + 2 plugins, all public GitHub clones) — no secrets.
- Checked `home/dot_ssh/create_config`, `home/dot_config/shell/aliases.zsh`, `home/dot_config/shell/exports.zsh.tmpl`, `home/dot_local/bin/executable_dotfiles` (the shell scripts not caught by either grep, since they only *reference* secrets tooling by name) — all benign.
  `exports.zsh.tmpl` sets `KUBECONFIG=$HOME/.kube/homelab.yaml:...` under the same `.machine != "server"` gate as the kubeconfig template itself, but doesn't fetch anything — it just points at a path that may or may not exist.
- Confirmed my local `main` ref was **stale** before trusting it (`git show main:...` reported the kubeconfig template didn't exist; `git fetch origin main` showed local `main` was 47 commits behind `origin/main`, which already had it, merged via PR #24 on 2026-05-29).
  Re-ran every check against `origin/main` after fetching.
  This is the same "stale local main shows phantom state" gotcha this user has hit before in the infrastructure repo — worth calling out since it nearly produced a false "safe" conclusion here.

## Finding: home-lab admin kubeconfig template

`home/private_dot_kube/private_homelab.yaml.tmpl` renders to `~/.kube/homelab.yaml` and its entire content is `{{ (bitwarden "item" "Homelab Kubeconfig").notes }}` — the full k3s cluster-admin kubeconfig for gandalf, stored as a Bitwarden Secure Note.
This executes during `chezmoi apply` itself (this is exactly "fetching a live secret during apply," the scenario this audit exists to catch).

It was excluded only by `home/.chezmoiignore`:

```
{{ if or (ne .profile "personal") (eq .machine "server") -}}
.kube/homelab.yaml
{{ end -}}
```

Under the audited profile (`profile: personal, os: linux, display: false`), `.profile == "personal"` is a given — that's the profile being tested.
The **only** thing that excluded this file was `.machine == "server"`.
But `.machine` is a separate prompt (choices: `laptop`, `desktop`, `server`, `pi`, `ephemeral`) not pinned by the audited profile combination, and `"ephemeral"` — a value that exists specifically for exactly this kind of headless/automated/container use case — is not `"server"`.
A container-image build using `profile=personal` and any `.machine` other than `"server"` (very plausibly `"ephemeral"`, or simply omitted/defaulted to something else) would have rendered this file and fetched gandalf's live cluster-admin kubeconfig straight into a public GHCR image.

This is exactly the class of risk this audit exists to catch, and it was real, not hypothetical — verified with `chezmoi execute-template` against a synthetic `profile=personal, machine=ephemeral` config (see "Excluded from the image build" below for the before/after render proof).

### Context: `bootstrap/install.sh`

`bootstrap/install.sh` (outside `home/`, not chezmoi-managed, so outside the literal scope of this audit) is the documented non-interactive entry point for this repo and has its own safety guard: `--secrets bitwarden`/`--secrets both` combined with a detected-ephemeral environment **and** `--non-interactive` makes it `exit 1` before ever reaching `chezmoi init --apply` (needs an interactive Bitwarden master-password prompt it can't do headless).
In non-interactive mode generally, it also never runs `bw login`/`bw unlock`, so `BW_SESSION` is never set.

That's a reasonable belt for the *bootstrap orchestration layer*, but it's not a substitute for the fix below: it only helps if Task 9 actually invokes `bootstrap/install.sh` (undecided — Task 9 doesn't exist yet), it depends on ephemeral-environment auto-detection correctly firing for whatever build environment Task 9 uses, and it does nothing at all if Task 9 instead does a bare `chezmoi init --apply` or `chezmoi apply` directly against an explicit `chezmoi.toml`.
The `.chezmoiignore`-level fix below is the one guarantee that holds regardless of which path Task 9 takes.

## Excluded from the image build

**`dotfiles` PR merged:** [nickvigilante/dotfiles#64](https://github.com/nickvigilante/dotfiles/pull/64) — "Exclude admin kubeconfig from container-image chezmoi applies."
Merged 2026-09-16 (`bc3007b`).

Added a third OR condition to the existing `.chezmoiignore` gate, keyed on an env var an image build sets, so the exclusion holds regardless of which `.profile`/`.machine` values the build passes:

```
{{ if or (ne .profile "personal") (eq .machine "server") (env "DOTFILES_IMAGE_BUILD") -}}
.kube/homelab.yaml
{{ end -}}
```

Verified with `chezmoi execute-template` against a synthetic `profile=personal, machine=ephemeral` config:

- **Without** `DOTFILES_IMAGE_BUILD` set: `.kube/homelab.yaml` does **not** appear in the rendered ignore list — confirms the file would have applied and fetched the secret (the gap was real).
- **With** `DOTFILES_IMAGE_BUILD=1` set: `.kube/homelab.yaml` **does** appear — confirms the exclusion now fires.
- The pre-existing `machine == "server"` and `profile != "personal"` gates are unaffected (still `or`-combined) — gandalf's real, currently-applied config is untouched by this change.

No other `.chezmoiignore` changes were needed.
Everything else found in Steps 2–3 is already a structural no-op under this profile (darwin gates, `.display` gates, files that only read local state that won't exist in a fresh image, or functions/scripts that require manual invocation and never auto-run during `chezmoi apply`).

## Required for Task 9

Task 9's Dockerfile **must** set `DOTFILES_IMAGE_BUILD=1` (or any non-empty value) in the environment before running `chezmoi apply` (whether directly, or via `bootstrap/install.sh`, which passes through the process environment to the `chezmoi init --apply` it shells out to).
Without this, the fix above does not activate, and the kubeconfig risk is live again for any `.machine` value other than `"server"`.

Recommended, not strictly required given the above, but worth doing as defense in depth: pass `--secrets none` / `DOTFILES_SECRETS=none` for the image build.
There's no reason a base dev-workspace image needs a secrets CLI baked in, and it avoids the Brewfile installing `1password-cli` unnecessarily (Step 1) and avoids ever depending on `bw`/`op` CLI behavior during the build.

## Conclusion

**Safe to proceed to Task 9**, with the `dotfiles` change above merged (it is — PR #64, `origin/main` at `bc3007b`) **and** provided Task 9's Dockerfile sets `DOTFILES_IMAGE_BUILD=1` before running `chezmoi apply`, per "Required for Task 9" above.
That second part is a requirement on Task 9's implementation, not something this audit can verify itself since Task 9's Dockerfile doesn't exist yet — whoever implements Task 9 should treat "does the build set `DOTFILES_IMAGE_BUILD`" as a checklist item and confirm it before that image is ever published.

Confidence: high on the findings themselves (every file the greps and `find` returned was read in full, all reasoning was verified against actual `chezmoi execute-template` renders rather than manual template reading alone, and the one real gap found was closed and merged before this conclusion was written).
The one thing this audit cannot guarantee on its own is that Task 9 actually wires up `DOTFILES_IMAGE_BUILD` — that has to be checked again when Task 9 lands.
