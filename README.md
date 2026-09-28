# homelab-dev-templates

Source-controlled Coder workspace templates and their base image for my
homelab Coder deployment at `coder.vigihome.net`.

## Layout

- `templates/Base/` — the base Kubernetes workspace template, pushed to
  Coder via CI on merge to `main`.
- `images/base/` — the custom multi-arch base image workspaces run on,
  published to `ghcr.io/nickvigilante/homelab-dev-templates` on merge to
  `main`.
- `modules/workspace/` — the shared workspace module every template calls.
  `scripts/vendor-module.sh` copies it into a template before validation or push, because `coder templates push` uploads only the template directory.

See each directory's own README for details.

## Docs

- [`docs/design.md`](docs/design.md): why the repo exists and the decisions behind it.
- [`docs/implementation-plan.md`](docs/implementation-plan.md): the original build plan, kept as a record.
