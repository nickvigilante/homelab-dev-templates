# Base

The foundational Coder Kubernetes workspace template.
Runs workspace pods in the `coder` namespace on gandalf's k3s cluster,
pinned to the amd64 node via `node_selector`
(this cluster also has arm64 Pi worker nodes;
see the repo-level design doc for why that pin exists).

## Parameters

- `cpu` — 2/4/6/8 cores (default 2)
- `memory` — 2/4/6/8 GB (default 2)
- `home_disk_size` — GB, immutable after creation (default 10)

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
