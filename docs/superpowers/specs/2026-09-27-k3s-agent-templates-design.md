# k3s agent templates — design

**Goal:** Two Coder workspace templates that give Coder Agents access to the k3s cluster: `K3s-Readonly`, from which an agent diagnoses and troubleshoots without being able to change anything, and `K3s-Operator`, usable only by the owner, from which an agent implements changes through GitOps pull requests plus a small set of imperative `kubectl` actions.

**Status:** Partly superseded (2026-10-02); see "Status update" below.
The shared module and multi-template CI shipped in #45.
`K3s-Readonly` is replaced by the `Analyzer` template, and the cluster tools move to `images/analyzer/`.
`K3s-Operator` is still open.

**Date:** 2026-09-27.

**Related issues:** #6 (agent-forwarded SSH signing, whose reasoning about in-cluster credentials this design builds on), #26 (image SHA bumps), #27 (legacy template retirement), and #41, #42 and #43 (Rust, Python and Node.js templates, which follow this work and reuse its shared module).

## Status update (2026-10-02)

A parallel thread designed the same read-only agent as an alert-triggered `Analyzer`, merged in `nickvigilante/homelab` as the spec in #239 and the plans in #240 and #241.
It is more complete than `K3s-Readonly`: an egress NetworkPolicy, a Coder user limited to that one template, a structured report contract and an alert-driven orchestrator.
So this design is reconciled with it as follows:

- **Shipped, as designed here:** the shared module, the vendoring and per-template CI, and the `Base` migration with `moved` blocks (#45, implementation phase 1).
- **Replaced by the Analyzer:** everything in this document about `K3s-Readonly`, including `coder-ws-reader`.
  The Analyzer runs as ServiceAccount `analyzer`, bound to the built-in `view` role, as this design also intended.
  `nickvigilante/homelab#242` adapts the analyzer plan to #45.
- **Replaced by `images/analyzer/`:** putting `kubectl`, `helm` and `flux` in the base image (implementation phase 2).
  #46 implemented it and was closed, because the analyzer plan keeps those tools in a separate image with a checksum-verified `kubectl` pinned to the cluster's minor version.
- **Still open: `K3s-Operator`.**
  The analyzer spec names a different operator template as out of scope, one that holds `Homelab-IaC` credentials for `ansible` and `tofu`.
  This design's operator instead changes the cluster through `homelab` pull requests from a GitHub App plus a few imperative `kubectl` verbs, and holds no IaC credentials.
  Which one to build, or whether both are wanted, is decided before the operator gets its own plan.
  Sections below that describe `K3s-Readonly` are kept as the record of this design and no longer describe what will be built.

## Context

Workspaces from `Base` run as pods in the `coder` namespace of the same k3s cluster that Coder runs in.
The cluster is reconciled by Flux from the `homelab` repo, so a change to cluster state is normally a pull request to `homelab`, not a `kubectl apply`.

`homelab/k8s/claude-mcp` already runs a read-only Kubernetes MCP server (ServiceAccount `claude-mcp`, bound to the built-in `view` ClusterRole, Secrets denied) and a read-only Grafana MCP server, both reachable from any pod in the `coder` namespace and already used by Coder Agents chats.
Its README flags that namespace-wide reach as something to revisit before adding collaborators.

The Coder deployment carries a Premium license, so per-template user and group permissions are available.

Two facts found during brainstorming shape the write path:

- `homelab`'s `main` requires a pull request but zero approving reviews, and `enforce_admins` is off.
  A personal access token acts as the owner, who is an admin, so a token of that kind could push straight to `main` and Flux would apply it.
- Coder Agents run unattended, so the agent-forwarding design in #6, which needs a laptop to approve each signature, is not available to them.

## Decisions

- **Credentials are in-cluster ServiceAccounts**, set on the workspace pod through `service_account_name`, never kubeconfig files stored as secrets.
  The kubelet mounts a short-lived projected token and rotates it; nothing needs storing or rotating by hand.
- **Read-only means the built-in `view` ClusterRole**: no Secrets, no `pods/exec`, no writes, with `pods/log` allowed, matching the existing MCP server.
- **The read-write path is GitOps plus narrow `kubectl`.**
  Changes to declared state land as pull requests to `homelab` that only the owner can merge.
  The ServiceAccount adds only imperative verbs that Flux cannot express: restarting rollouts, deleting pods, and triggering, suspending or resuming Flux reconciliation.
- **The agent reaches GitHub as a GitHub App installed on `homelab` only**, with contents and pull-request write permissions.
  An App installation is its own identity and never an admin, so requiring one approving review on `homelab/main` stops it from merging its own pull requests, while the owner still merges through the admin bypass.
  Its installation tokens expire after an hour.
- **The read-write template gets its own namespace, `coder-ops`.**
  A pod can mount only ServiceAccounts in its own namespace, so the operator ServiceAccount is out of reach of every template that schedules into `coder`.
- **The templates share `Base` through a local module, vendored by CI.**
  `coder templates push` uploads only the template directory, so a `../../modules` source does not resolve server-side; a script copies the module into each template directory before `validate` and `push`.
  A git-sourced module was rejected because every module change would need a second pull request to bump each template's `ref`, the same chore #26 exists to remove.
- **`kubectl`, `flux` and `helm` go into the base image** through `images/base/tools.txt`.
  They are small, and a derived image is deferred to the language-image decision in #41, #42 and #43.

## Components in `homelab`

Everything here is Flux-reconciled and lands before the template that depends on it.

| Piece                    | `K3s-Readonly`     | `K3s-Operator`                                                                     |
| ------------------------ | ------------------ | ---------------------------------------------------------------------------------- |
| Namespace                | `coder` (existing) | `coder-ops` (new)                                                                  |
| ServiceAccount           | `coder-ws-reader`  | `coder-ws-operator`                                                                |
| ClusterRoleBindings      | `view`             | `view` and `coder-ops-imperative`                                                  |
| Coder can schedule there | already does       | Role and RoleBinding for Coder's ServiceAccount in `coder-ops`                     |
| MCP servers reachable    | already admitted   | `coder-ops` added to `k8s/claude-mcp/netpol-allow-coder.yaml`                      |
| GitHub credential        | none               | ExternalSecret syncing the GitHub App ID, installation ID and private key from BWS |

`coder-ops-imperative` grants exactly:

- `patch` on `deployments`, `statefulsets` and `daemonsets` in `apps`, which is what `kubectl rollout restart` sends.
- `delete` on `pods`.
- `patch` on Flux `kustomizations`, `helmreleases`, `gitrepositories`, `helmrepositories` and `ocirepositories`, which is what `flux reconcile`, `flux suspend` and `flux resume` send.

The Role for Coder's own ServiceAccount in `coder-ops` mirrors what the Coder chart's `workspacePerms` grants in `coder`, plus `get` on `serviceaccounts` (see the lookup under failure handling).
If the chart's `workspacePerms` does not already include `get` on `serviceaccounts` in `coder`, add it there too.

On GitHub, outside Flux: create the App, install it on `homelab` only, store its credentials in BWS, and change `homelab/main` protection to require one approving review.

## Components in `homelab-dev-templates`

### Shared module: `modules/workspace/`

It holds what `templates/Base/main.tf` defines today: the home PVC, the deployment, the agent and its metadata, the dotfiles `coder_script` and the `claude-code` module.
Its inputs cover what the templates vary:

- `namespace`, defaulting to `coder`.
- `service_account_name`, defaulting to none, and `automount_service_account_token`, defaulting to `false`.
- `image`.
- `git_name` and `git_email`, which set the `GIT_AUTHOR_*` and `GIT_COMMITTER_*` agent env as `Base` does today.
- `extra_env`, and `mcp` and a workspace `CLAUDE.md` body passed through to Claude Code.

The `coder_parameter` blocks stay in each template, because parameters belong to the template a user picks.

`scripts/vendor-module.sh <template-dir>` copies the module into the template directory.
The copy is git-ignored, so the source stays in one place.

### `templates/Base/`

A thin caller of the module, with the automounted token now off.
Today a `Base` pod silently mounts the `coder` namespace's `default` token; it grants nothing now, but it would grow silently if that account were ever bound to a role.

It carries `moved {}` blocks for every resource and module that changes address, so existing workspaces migrate their state instead of destroying and recreating their home volumes.

### `templates/K3s-Readonly/` (superseded by the Analyzer)

- Namespace `coder`, ServiceAccount `coder-ws-reader`, token automounted.
- A `coder_script` writes `~/.kube/config` whose user reads the mounted token by `tokenFile`, so rotation keeps working, giving `kubectl`, `flux` and `helm` one explicit context.
- `mcp` wires in the Kubernetes and Grafana MCP servers at their in-cluster URLs.
- A `coder_script` clones `homelab` over anonymous HTTPS into `~/homelab` and pulls it on each start; the repo is public, so no Git credential exists in this workspace.
- The workspace `CLAUDE.md` says the workspace is for diagnosis only, and to compare declared state in `~/homelab` with the live cluster, to query Loki through the Grafana MCP for logs older than the current container, and to report findings with proposed fixes.

### `templates/K3s-Operator/`

- Namespace `coder-ops`, ServiceAccount `coder-ws-operator`, token automounted, and the same kubeconfig script.
- The GitHub App Secret is mounted read-only as files.
- A git credential helper mints an installation token from the App key on demand and caches it until shortly before expiry; `git push` and `gh` both use it.
- `git_name` and `git_email` are the App's bot identity, so agent commits are distinguishable from the owner's in history and on pull requests.
- The workspace `CLAUDE.md` sets the workflow: branch, commit, open a pull request and never merge, use only the imperative verbs above against the live cluster, and record each one in the pull request or chat.
- A Terraform `precondition` fails the build unless the workspace owner is the owner's Coder user.

### Images and CI

- `images/base/tools.txt` gains `kubectl`, `flux` and `helm`.
- `lint.yml`, `template-validate.yml` and `template-push.yml` run once per changed template instead of hardcoding `Base`, calling `vendor-module.sh` first, and treat a change under `modules/` as a change to every template.
- `template-push.yml` re-applies per-template metadata that versions do not carry, as it already does for the icon:
  `K3s-Operator`'s permissions (remove `Everyone`, grant the owner) and a two-hour default auto-stop, so a forgotten agent workspace does not keep live credentials running.
  A failure here fails the job, because it is a security control.

## Failure handling

- **Missing ServiceAccount**, for example when the `homelab` change has not merged yet: the module looks the ServiceAccount up with a `data` block whenever one is set, so the build fails at plan time with the missing name instead of creating a deployment whose pod never starts, which `wait_for_rollout = false` would otherwise hide.
- **Kubeconfig script failure:** it does not block login and exits non-zero with an actionable message, the same pattern as `dotfiles.sh`.
- **MCP server unreachable:** the agent loses those tools, and `CLAUDE.md` tells it to fall back to `kubectl` and to say that it did.
- **Token helper failure:** it names the cause on stderr, such as an unreadable key, a wrong installation ID or clock skew, rather than leaving git to report a bare authentication failure.
- **Template permissions drift:** the push job fails if it cannot apply them, and the `precondition` still rejects any other owner if `Everyone` is re-added in the dashboard.

## Testing

- **Module refactor:** update a real `Base` workspace to the new version and confirm the build log shows moves, not replacements, and that the home PVC's UID is unchanged.
- **RBAC:** a script in `homelab` runs `kubectl auth can-i --as=system:serviceaccount:<ns>:<sa>` against a fixed expectation list.
  The reader must be denied every write verb, Secrets and `pods/exec`, and allowed `get`, `list` and `watch` plus `pods/log`.
  The operator must be allowed exactly the imperative verbs above and still be denied Secrets.
  It runs after Flux applies the change, and again from inside each workspace.
- **GitHub:** from a `K3s-Operator` workspace, `git push origin main` is rejected, opening a pull request succeeds, and `gh pr merge` is rejected.
- **Access:** a local test account cannot see `K3s-Operator`, and forcing a build as that account fails the `precondition`.
- **End to end:** deploy a workload with a bad image tag into a scratch namespace.
  A Coder Agents chat on `K3s-Readonly` identifies the cause without changing anything, and one on `K3s-Operator` opens a pull request that fixes it.
- **CI:** every workflow validates all three templates from their vendored copies, and a pull request touching only `modules/` validates all of them.

## Implementation order

Each phase merges and is proven before the next starts.

1. **Module refactor.** Extract `modules/workspace/`, add `vendor-module.sh`, generalize the workflows, and convert `Base` with `moved` blocks; `Base` workspaces behave identically.
2. **Tools in the image.** Add `kubectl`, `flux` and `helm` to `tools.txt` and bump `Base`'s pinned image.
3. **Read-only, cluster side.** In `homelab`: `coder-ws-reader`, its binding, the Coder ServiceAccount `get serviceaccounts` permission if missing, and the RBAC check script.
4. **`K3s-Readonly`.** The template, then the end-to-end diagnosis test.
5. **Read-write, cluster and GitHub side.** In `homelab`: `coder-ops`, `coder-ws-operator`, `coder-ops-imperative`, the Coder Role, the NetworkPolicy change and the ExternalSecret; on GitHub: the App, its installation and the review requirement.
6. **`K3s-Operator`.** The template, its permissions and auto-stop in CI, then the GitHub, access and end-to-end tests.

## To verify during planning

- Whether `homelab` requires signed commits.
  If it does, the helper must create commits through the GitHub API, which signs commits made by an App, instead of pushing unsigned ones.
- Whether Flux's CRDs are readable under `view`; Flux normally ships ClusterRoles aggregated into it, but the reader must see Kustomizations and HelmReleases.
- The `claude-code` module 5.2.0 input for a workspace `CLAUDE.md` or system prompt, and whether Coder Agents chats honor the template's `mcp` setting or configure MCP servers deployment-wide.
- Which Coder user the `precondition` should name, and whether a Coder Agents workspace is owned by the user who started the chat.
- How `template-push.yml` sets template permissions and auto-stop: `coder templates edit` flags where they exist, otherwise the template ACL API.

## Out of scope

- The Rust, Python and Node.js templates (#41, #42, #43), which reuse the module afterwards.
- Narrowing the claude-mcp servers' namespace-wide reach, which matters only once collaborators exist.
- Signing agent commits with the owner's key; #6 covers interactive signing, and agent commits are deliberately not the owner's.
