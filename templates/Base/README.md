# Base

The foundational Coder Kubernetes workspace template.
Its pod, home volume, agent, dotfiles and Claude Code setup come from the shared module in `modules/workspace/`; this directory holds only the parameters, the git identity and the module call.
Runs workspace pods in the `coder` namespace on gandalf's k3s cluster,
pinned to the amd64 node via `node_selector`
(this cluster also has arm64 Pi worker nodes;
see the repo-level design doc for why that pin exists).

## Parameters

- `cpu` — 2/4/6/8 cores (default 2)
- `memory` — 2/4/6/8 GB (default 8)
- `home_disk_size` — GB, immutable after creation (default 10)

Raising the `memory` default does not affect existing workspaces. A workspace
keeps the value it was created with; change it in the workspace's own settings,
which is allowed because `memory` is mutable.

## Git identity

Commits made in a workspace are authored as `Nick Vigilante <nickvigilante@users.noreply.github.com>`.
The shared module sets `GIT_AUTHOR_*` and `GIT_COMMITTER_*` on the agent from the `locals` block in `main.tf`, and git ranks those above `user.name` and `user.email` in any config file.
The module's `dotfiles.sh` passes the same values to chezmoi on first start, so the generated `~/.gitconfig` agrees.

They are fixed in `main.tf`, not taken from the Coder account, so commits carry the noreply address and not whatever the account uses.
Change the identity by editing the `locals` block in `main.tf`.
Because the values come from the agent's environment, a change reaches existing workspaces on their next restart.

## Updating

```bash
# From the repo root. The push uploads only this directory, so the module
# must be copied in first. push-template.sh vendors it fresh every time:
# pushing the directory directly can upload a stale, git-ignored copy.
scripts/vendor-module.sh templates/Base
(cd templates/Base && tofu fmt -recursive && tofu init && tofu validate)
scripts/push-template.sh Base -y
```

Merging to `main` with changes under `templates/` pushes and activates the
template via `.github/workflows/template-push.yml`, which runs on the
self-hosted runner inside the cluster. See `docs/runner-setup.md`, including
why that workflow is deliberately push-only.

Pull requests get a structural check from `.github/workflows/template-validate.yml`.
The provisioner-side check, which catches what `tofu validate` cannot (a bad
image tag is syntactically fine), does not run in CI, because that would need a
CI node on the tailnet. Run it yourself from a machine on the tailnet before
merging; `docs/runner-setup.md` has the commands.

Bumping the image is a second manual step: `image` in `main.tf` pins a full
SHA, so a freshly built image is not used until that string is updated.
