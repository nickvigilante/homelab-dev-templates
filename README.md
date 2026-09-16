# homelab-dev-templates

Source-controlled Coder workspace templates and their base image for my
homelab Coder deployment at `coder.vigihome.net`.

## Layout

- `templates/Base/` — the base Kubernetes workspace template, pushed to
  Coder via CI on merge to `main`.
- `images/base/` — the custom multi-arch base image workspaces run on,
  published to `ghcr.io/nickvigilante/homelab-dev-templates` on merge to
  `main`.

See each directory's own README for details.
