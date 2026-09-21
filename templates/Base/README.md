# Base

The foundational Coder Kubernetes workspace template.
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
`main.tf` sets `GIT_AUTHOR_*` and `GIT_COMMITTER_*` on the agent, and git ranks those above `user.name` and `user.email` in any config file.
`dotfiles.sh` passes the same values to chezmoi on first start, so the generated `~/.gitconfig` agrees.

They are fixed in `main.tf`, not taken from the Coder account, so commits carry the noreply address and not whatever the account uses.
Change the identity by editing the `locals` block in `main.tf`.
Because the values come from the agent's environment, a change reaches existing workspaces on their next restart.

## Updating

```bash
tofu fmt -recursive && tofu validate
coder templates push Base --directory . -y
```

Merging to `main` with changes under `templates/` pushes and activates the
template via `.github/workflows/template-push.yml`, which runs on the
self-hosted runner inside the cluster. See `docs/runner-setup.md`, including
why that workflow is deliberately push-only.

Pull requests are validated first by `.github/workflows/template-validate.yml`,
which pushes a non-activated version so the Coder provisioner checks it
server-side. Fork PRs skip that check: they receive no secrets, so it reports
and skips rather than failing.

Bumping the image is a second manual step: `image` in `main.tf` pins a full
SHA, so a freshly built image is not used until that string is updated.
