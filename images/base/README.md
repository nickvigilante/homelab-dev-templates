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

Starts as an unmodified republish of `codercom/example-base:ubuntu`.
Dotfiles get baked in a follow-up change — see the repo-level design
doc for the plan and the required secrets audit that gates it.
