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

Merging to `main` does NOT push the template to Coder today: there is no
`template-push.yml` workflow, and a GitHub-hosted runner could not reach
`coder.vigihome.net` anyway, since it resolves only to a LAN address and a
Tailscale one. After merging, push manually from a machine on the tailnet.

Bumping the image is a second manual step: `image` in `main.tf` pins a full
SHA, so a freshly built image is not used until that string is updated.
