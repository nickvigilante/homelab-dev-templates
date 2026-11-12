# Shared workspace module Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status (2026-10-02):** Tasks 1–6 shipped in #45, including the real-workspace migration test.
Tasks 7 and 8 were dropped: #46, which implemented Task 7, was closed in favor of the analyzer plan's `images/analyzer/` (`nickvigilante/homelab#241`), so `Base` keeps its current image.

**Goal:** Move everything `templates/Base` defines except its parameters into a shared `modules/workspace/` module that CI vendors into each template, with `Base` behaving identically for existing workspaces, and bake `kubectl`, `flux` and `helm` into the base image.

**Architecture:** `modules/workspace/` holds the agent, dotfiles script, home PVC, deployment and `claude-code` module, driven by inputs.
`scripts/vendor-module.sh` copies it into `templates/<name>/modules/workspace/` (git-ignored) because `coder templates push` uploads only the template directory.
`Base` becomes a thin caller with `moved {}` blocks, and the three workflows run once per affected template, chosen by `scripts/changed-templates.sh`.

**Tech Stack:** Terraform/OpenTofu HCL (Coder's provisioner runs Terraform 1.15.5; CI and local checks use OpenTofu 1.12), `tofu test` with mocked providers, POSIX `sh`, GitHub Actions, Docker.

**Spec:** `docs/superpowers/specs/2026-09-27-k3s-agent-templates-design.md`.
This plan implements its phases 1 and 2 only.
Phases 3 and 4 (read-only) and 5 and 6 (read-write) get their own plans once this one has merged, because they build on the module interface this plan fixes.

## Global Constraints

- `Base` must behave identically for existing workspaces: the same home PVC (same UID), the same image, parameters, hostname, `node_selector`, git identity, dotfiles script and Claude Code install.
  The one intended change is `automount_service_account_token = false` on the pod.
- The vendored copy lives at `templates/<name>/modules/workspace/`: never a symlink (Coder's provisioner drops symlinks when it unpacks the upload) and never under a path segment starting with `.` (the push skips hidden paths).
- `templates/*/modules/` is git-ignored; the push does not read `.gitignore`, so the copy still uploads.
- The upload limit is 1 MiB per template archive.
- The module declares `required_version = ">= 1.9"`, which the `claude-code` module 5.2.0 requires.
- `template-push.yml` stays push-only and `template-validate.yml` stays on a GitHub-hosted runner; neither gains a trigger (see the comments heading each file and `docs/runner-setup.md`).
- Values that reach a `run:` block from a PR (template directory names included) go through `env:`, never through inline `${{ }}`.
- Shell scripts pass `shellcheck -S info` and `shfmt -i 2 -ci -bn`.
- Markdown files use one sentence per line.
- Commit messages are Conventional Commits and end with the trailer `Assisted-by: AI`; PR bodies end with a `---` rule and `🤖 Built with AI assistance.`, and name no AI vendor or product.
- Work happens in a worktree under `.worktrees/`, never on `main`.

## Review Focus

1. **An existing, running `Base` workspace updated to the new version** must keep its home PVC and files; a missing or wrong `moved` block destroys the volume.
   Task 6 pins this with a real workspace before merge.
2. **An existing `Base` workspace that is stopped when the new version activates** has no deployment or `claude-code` instances in state; its first start on the new version must move, not replace, the PVC.
   Task 6 pins this with a second, stopped workspace.
3. **A hand push that skips vendoring** (`coder templates push Base --directory templates/Base` with no `modules/workspace` copy, or a stale one) must fail loudly or be impossible to miss.
   Task 4 puts the vendoring step directly above the push command in `templates/Base/README.md`, and the provisioner fails the import on a missing module.
4. **A push whose `before` SHA git cannot resolve** (a branch's first push, a force push) must push every template rather than none.
   Task 2's tests pin both the all-zero and unknown-SHA cases.
5. **A template directory without `template.json`** must fail the push job instead of pushing a template without its metadata.
   Task 5's `jq` pipeline fails on the missing file; Task 5 Step 5 checks it.

______________________________________________________________________

## File Structure

| Path                                           | Change                | Responsibility                                                                   |
| ---------------------------------------------- | --------------------- | -------------------------------------------------------------------------------- |
| `scripts/vendor-module.sh`                     | create                | Copy `modules/workspace` into one template directory.                            |
| `scripts/tests/vendor-module_test.sh`          | create                | Tests for the above.                                                             |
| `scripts/changed-templates.sh`                 | create                | Print the templates a commit range affects.                                      |
| `scripts/tests/changed-templates_test.sh`      | create                | Tests for the above.                                                             |
| `.gitignore`                                   | modify                | Ignore vendored copies.                                                          |
| `.pre-commit-config.yaml`                      | modify                | Make the `tofu fmt` hook recursive, so it checks `modules/` and `templates/`.    |
| `modules/workspace/versions.tf`                | create                | Terraform and provider requirements.                                             |
| `modules/workspace/variables.tf`               | create                | The module's inputs.                                                             |
| `modules/workspace/main.tf`                    | create                | Agent, dotfiles script, ServiceAccount lookup, home PVC, deployment.             |
| `modules/workspace/claude.tf`                  | create                | The `claude-code` registry module.                                               |
| `modules/workspace/dotfiles.sh`                | create (copy of Base) | The dotfiles `coder_script` body.                                                |
| `modules/workspace/tests/workspace.tftest.hcl` | create                | Plan-only tests with mocked providers.                                           |
| `templates/Base/main.tf`                       | rewrite               | Parameters, git identity, the module call and `moved` blocks.                    |
| `templates/Base/modules.tf`                    | delete                | Its contents move to `modules/workspace/claude.tf` and `templates/Base/main.tf`. |
| `templates/Base/dotfiles.sh`                   | delete                | Moved to the module.                                                             |
| `templates/Base/template.json`                 | create                | Per-template metadata `template-push.yml` applies (the icon, for now).           |
| `templates/Base/README.md`, `README.md`        | modify                | Document the module and the vendoring step.                                      |
| `.github/workflows/lint.yml`                   | modify                | Run script tests, `tofu test`, and `tofu validate` for every vendored template.  |
| `.github/workflows/template-validate.yml`      | rewrite               | Validate each affected template.                                                 |
| `.github/workflows/template-push.yml`          | rewrite               | Push each affected template with its `template.json` metadata.                   |
| `images/base/Dockerfile`                       | modify                | Install `kubectl`, `helm` and `flux`.                                            |
| `.github/workflows/image-build.yml`            | modify                | Check the three new tools landed.                                                |

______________________________________________________________________

### Task 1: Vendoring script

**Files:**

- Create: `scripts/vendor-module.sh`
- Create: `scripts/tests/vendor-module_test.sh`
- Modify: `.gitignore`

**Interfaces:**

- Produces: `scripts/vendor-module.sh <template-dir>` — replaces `<template-dir>/modules/workspace/` with a fresh copy of `modules/workspace/`, excluding `tests/`, `.terraform/` and `.terraform.lock.hcl`; exits 2 on a wrong argument count or a missing directory.

- [ ] **Step 1: Create the worktree**

```bash
git fetch origin
git worktree add -b feat/shared-workspace-module .worktrees/feat-shared-workspace-module origin/main
cd .worktrees/feat-shared-workspace-module
```

- [ ] **Step 2: Write the failing test**

Create `scripts/tests/vendor-module_test.sh`:

```sh
#!/usr/bin/env sh
# Tests scripts/vendor-module.sh against a throwaway copy of the repo layout.
#
# Usage: scripts/tests/vendor-module_test.sh
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/scripts" "$work/modules/workspace/tests" \
  "$work/modules/workspace/.terraform" "$work/templates/T"
cp "$here/vendor-module.sh" "$work/scripts/"
echo main >"$work/modules/workspace/main.tf"
echo script >"$work/modules/workspace/dotfiles.sh"
echo test >"$work/modules/workspace/tests/workspace.tftest.hcl"
echo cache >"$work/modules/workspace/.terraform/cache"
echo lock >"$work/modules/workspace/.terraform.lock.hcl"
echo root >"$work/templates/T/main.tf"

failures=0
# check <description> <command...>
check() {
  description=$1
  shift
  if "$@"; then
    echo "ok   - $description"
  else
    echo "FAIL - $description"
    failures=$((failures + 1))
  fi
}

dest="$work/templates/T/modules/workspace"

"$work/scripts/vendor-module.sh" "$work/templates/T"
check "main.tf is copied" test -f "$dest/main.tf"
check "dotfiles.sh is copied" test -f "$dest/dotfiles.sh"
check "copies are regular files, not symlinks" test ! -L "$dest/main.tf"
check "tests are not copied" test ! -e "$dest/tests"
check "the .terraform cache is not copied" test ! -e "$dest/.terraform"
check "the module lock file is not copied" test ! -e "$dest/.terraform.lock.hcl"

rm "$work/modules/workspace/dotfiles.sh"
"$work/scripts/vendor-module.sh" "$work/templates/T"
check "a file removed from the module is removed from the copy" test ! -e "$dest/dotfiles.sh"

if "$work/scripts/vendor-module.sh" "$work/templates/missing" 2>/dev/null; then
  check "a missing template directory is rejected" false
else
  check "a missing template directory is rejected" true
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed" >&2
  exit 1
fi
echo "all tests passed"
```

Run: `chmod +x scripts/tests/vendor-module_test.sh`

- [ ] **Step 3: Run the test to verify it fails**

Run: `scripts/tests/vendor-module_test.sh`
Expected: FAIL with `cp: cannot stat '.../scripts/vendor-module.sh': No such file or directory`.

- [ ] **Step 4: Write the script**

Create `scripts/vendor-module.sh`:

```sh
#!/usr/bin/env sh
# Copies modules/workspace into a template directory, so the directory that
# `coder templates push` uploads is self-contained.
#
# A copy, never a symlink: Coder's provisioner drops symlinks when it unpacks
# the upload. The destination has no leading dot because the push skips hidden
# paths. .gitignore keeps the copy out of git; the push does not read
# .gitignore, so the copy still uploads.
#
# Usage: scripts/vendor-module.sh <template-dir>
set -eu

if [ $# -ne 1 ] || [ ! -d "$1" ]; then
  echo "usage: $0 <template-dir>" >&2
  exit 2
fi

repo_root=$(cd "$(dirname "$0")/.." && pwd)
dest="$1/modules/workspace"

# Remove the previous copy first, so a file deleted from the module does not
# linger in the template.
rm -rf "$dest"
mkdir -p "$dest"
tar -C "$repo_root/modules/workspace" \
  --exclude=.terraform --exclude=.terraform.lock.hcl --exclude=tests \
  -cf - . | tar -C "$dest" -xf -
```

Run: `chmod +x scripts/vendor-module.sh`

- [ ] **Step 5: Run the test to verify it passes**

Run: `scripts/tests/vendor-module_test.sh`
Expected: eight `ok` lines, then `all tests passed`.

- [ ] **Step 6: Ignore vendored copies**

Append to `.gitignore`:

```gitignore

# Vendored copies of modules/workspace, made by scripts/vendor-module.sh.
# `coder templates push` does not read this file, so they still upload.
templates/*/modules/
```

- [ ] **Step 7: Lint and commit**

Run: `shellcheck -S info scripts/vendor-module.sh scripts/tests/vendor-module_test.sh && shfmt -d -i 2 -ci -bn scripts/`
Expected: no output.

```bash
git add scripts/vendor-module.sh scripts/tests/vendor-module_test.sh .gitignore
git commit -F - <<'EOF'
feat(ci): add a script that vendors the shared module into a template

`coder templates push` uploads only the template directory, so a module
outside it never reaches the provisioner. The script copies it in, and
the copy is git-ignored so the source stays in one place.

Assisted-by: AI
EOF
```

______________________________________________________________________

### Task 2: Affected-templates script

**Files:**

- Create: `scripts/changed-templates.sh`
- Create: `scripts/tests/changed-templates_test.sh`

**Interfaces:**

- Produces: `scripts/changed-templates.sh <base-sha> <head-sha>` — prints one template directory name per line (for example `Base`), run from the repo root.
  It prints every template with a `main.tf` when `modules/workspace/**` or `scripts/vendor-module.sh` changed, or when `<base-sha>` does not resolve to a commit; otherwise only templates with a changed file that still have a `main.tf`.
  It prints nothing when no template is affected.

- [ ] **Step 1: Write the failing test**

Create `scripts/tests/changed-templates_test.sh`:

```sh
#!/usr/bin/env sh
# Tests scripts/changed-templates.sh against a throwaway git repository.
#
# Usage: scripts/tests/changed-templates_test.sh
set -eu

script="$(cd "$(dirname "$0")/.." && pwd)/changed-templates.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

git init -q
git config user.email test@example.com
git config user.name test
mkdir -p templates/Base templates/Other modules/workspace scripts
echo base >templates/Base/main.tf
echo other >templates/Other/main.tf
echo module >modules/workspace/main.tf
echo vendor >scripts/vendor-module.sh
echo readme >README.md
git add -A
git commit -qm init
root=$(git rev-parse HEAD)

failures=0
# expect <description> <expected, newline-separated> <base> <head>
expect() {
  actual=$("$script" "$3" "$4")
  if [ "$actual" = "$2" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    printf '  expected: %s\n  actual:   %s\n' "$(echo "$2" | tr '\n' ' ')" "$(echo "$actual" | tr '\n' ' ')"
    failures=$((failures + 1))
  fi
}

commit() {
  git add -A
  git commit -qm "$1"
  git rev-parse HEAD
}

echo x >>templates/Base/main.tf
c1=$(commit "touch Base")
expect "a template change selects only that template" "Base" "$root" "$c1"

echo x >>README.md
c2=$(commit "touch README")
expect "a change outside templates selects nothing" "" "$c1" "$c2"

echo x >>modules/workspace/main.tf
c3=$(commit "touch module")
expect "a module change selects every template" "Base
Other" "$c2" "$c3"

echo x >>scripts/vendor-module.sh
c4=$(commit "touch vendor script")
expect "a vendor script change selects every template" "Base
Other" "$c3" "$c4"

git rm -rq templates/Other
c5=$(commit "delete Other")
expect "a deleted template is not selected" "" "$c4" "$c5"

expect "an all-zero base selects every template" "Base" \
  0000000000000000000000000000000000000000 "$c5"

expect "an unknown base selects every template" "Base" \
  1111111111111111111111111111111111111111 "$c5"

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed" >&2
  exit 1
fi
echo "all tests passed"
```

Run: `chmod +x scripts/tests/changed-templates_test.sh`

- [ ] **Step 2: Run the test to verify it fails**

Run: `scripts/tests/changed-templates_test.sh`
Expected: FAIL with `.../scripts/changed-templates.sh: No such file or directory` and exit status 127.

- [ ] **Step 3: Write the script**

Create `scripts/changed-templates.sh`:

```sh
#!/usr/bin/env sh
# Prints the name of each template a change between two commits affects, one
# per line, for CI to validate or push.
#
# A change to the shared module or to this vendoring machinery affects every
# template. So does a base commit git cannot resolve: a push that creates a
# branch reports an all-zero `before` SHA, and after a force push `before` may
# no longer exist. Validating everything is the safe answer to "unknown".
#
# Usage: scripts/changed-templates.sh <base-sha> <head-sha>
set -eu

if [ $# -ne 2 ]; then
  echo "usage: $0 <base-sha> <head-sha>" >&2
  exit 2
fi
base=$1
head=$2

all_templates() {
  for dir in templates/*/; do
    if [ -f "${dir}main.tf" ]; then basename "$dir"; fi
  done
}

if ! git cat-file -e "${base}^{commit}" 2>/dev/null; then
  all_templates
  exit 0
fi

changed=$(git diff --name-only "$base" "$head")

if printf '%s\n' "$changed" | grep -qE '^(modules/workspace/|scripts/vendor-module\.sh$)'; then
  all_templates
  exit 0
fi

# A deleted template shows up in the diff but has nothing left to push.
printf '%s\n' "$changed" \
  | sed -n 's#^templates/\([^/]*\)/.*#\1#p' \
  | sort -u \
  | while read -r name; do
    if [ -f "templates/${name}/main.tf" ]; then echo "$name"; fi
  done
```

Run: `chmod +x scripts/changed-templates.sh`

- [ ] **Step 4: Run the test to verify it passes**

Run: `scripts/tests/changed-templates_test.sh`
Expected: seven `ok` lines, then `all tests passed`.

- [ ] **Step 5: Lint and commit**

Run: `shellcheck -S info scripts/changed-templates.sh scripts/tests/changed-templates_test.sh && shfmt -d -i 2 -ci -bn scripts/`
Expected: no output.

```bash
git add scripts/changed-templates.sh scripts/tests/changed-templates_test.sh
git commit -F - <<'EOF'
feat(ci): add a script that lists the templates a change affects

CI will validate and push once per template instead of hardcoding Base.
A module change affects every template, and so does a base commit git
cannot resolve, such as a branch's first push.

Assisted-by: AI
EOF
```

______________________________________________________________________

### Task 3: The shared module

**Files:**

- Create: `modules/workspace/versions.tf`, `modules/workspace/variables.tf`, `modules/workspace/main.tf`, `modules/workspace/claude.tf`
- Create: `modules/workspace/dotfiles.sh` (a copy of `templates/Base/dotfiles.sh`; Task 4 deletes the original)
- Create: `modules/workspace/tests/workspace.tftest.hcl`
- Modify: `.pre-commit-config.yaml` (the `tofu-fmt` hook)

**Interfaces:**

- Consumes: nothing from earlier tasks.
- Produces: module `modules/workspace` with these inputs, which Task 4 and the later plans call:
  - `image` (string, required)
  - `cpu` (string, required; cores)
  - `memory` (string, required; GB)
  - `home_disk_size` (number, required; GB)
  - `git_name`, `git_email` (string, required)
  - `namespace` (string, default `"coder"`)
  - `service_account_name` (string, default `null`; when set, the pod runs as it with its token mounted, and a missing ServiceAccount fails the plan)
  - `claude_code_oauth_token` (string, sensitive, default `""`)
- Produces these resource addresses inside the module, which Task 4's `moved` blocks target: `coder_agent.main`, `coder_script.dotfiles`, `kubernetes_persistent_volume_claim_v1.home`, `kubernetes_deployment_v1.main`, `module.claude-code`.

The spec lists `automount_service_account_token` as a separate input.
This plan derives it from `service_account_name` instead, because the only other combinations are "a token for the namespace's `default` account", which the spec exists to remove, and "a named account with no token", which is useless.
The spec's `extra_env`, `mcp` and `CLAUDE.md` inputs are added by the read-only plan, which is their first caller.

- [ ] **Step 1: Write the failing tests**

Create `modules/workspace/tests/workspace.tftest.hcl`:

```hcl
# Plan-only tests against mocked providers: no cluster and no Coder deployment.
# They pin what each template relies on the module to do with its inputs.

mock_provider "coder" {
  mock_data "coder_workspace" {
    defaults = {
      id          = "0b7d5a1e-0000-4000-8000-000000000001"
      name        = "My-Workspace"
      start_count = 1
    }
  }
  mock_data "coder_workspace_owner" {
    defaults = {
      id    = "0b7d5a1e-0000-4000-8000-000000000002"
      name  = "nick"
      email = "nick@example.com"
    }
  }
}

mock_provider "kubernetes" {}

variables {
  image          = "ghcr.io/nickvigilante/homelab-dev-templates:test"
  cpu            = "4"
  memory         = "8"
  home_disk_size = 10
  git_name       = "Test Author"
  git_email      = "author@example.com"
}

run "defaults_mount_no_token" {
  command = plan

  assert {
    condition     = kubernetes_deployment_v1.main[0].spec[0].template[0].spec[0].automount_service_account_token == false
    error_message = "A workspace with no service_account_name must not mount a ServiceAccount token."
  }
  assert {
    condition     = length(data.kubernetes_service_account_v1.workspace) == 0
    error_message = "No ServiceAccount lookup should happen without service_account_name."
  }
  assert {
    condition     = kubernetes_deployment_v1.main[0].metadata[0].namespace == "coder" && kubernetes_persistent_volume_claim_v1.home.metadata[0].namespace == "coder"
    error_message = "The namespace must default to coder."
  }
}

run "inputs_reach_the_pod" {
  command = plan

  assert {
    condition     = kubernetes_deployment_v1.main[0].spec[0].template[0].spec[0].container[0].image == var.image
    error_message = "The container must run var.image."
  }
  assert {
    condition     = kubernetes_deployment_v1.main[0].spec[0].template[0].spec[0].container[0].resources[0].limits["cpu"] == "4"
    error_message = "The CPU limit must come from var.cpu."
  }
  assert {
    condition     = kubernetes_deployment_v1.main[0].spec[0].template[0].spec[0].container[0].resources[0].limits["memory"] == "8Gi"
    error_message = "The memory limit must be var.memory in Gi."
  }
  assert {
    condition     = kubernetes_persistent_volume_claim_v1.home.spec[0].resources[0].requests["storage"] == "10Gi"
    error_message = "The home PVC must request var.home_disk_size in Gi."
  }
  assert {
    condition     = kubernetes_deployment_v1.main[0].spec[0].template[0].spec[0].hostname == "my-workspace"
    error_message = "The pod hostname must be the lowercased workspace name."
  }
  assert {
    condition     = kubernetes_deployment_v1.main[0].spec[0].template[0].spec[0].node_selector["kubernetes.io/arch"] == "amd64"
    error_message = "The pod must stay pinned to amd64, matching coder_agent.main.arch."
  }
  assert {
    condition = (
      coder_agent.main.env["GIT_AUTHOR_NAME"] == "Test Author" &&
      coder_agent.main.env["GIT_COMMITTER_NAME"] == "Test Author" &&
      coder_agent.main.env["GIT_AUTHOR_EMAIL"] == "author@example.com" &&
      coder_agent.main.env["GIT_COMMITTER_EMAIL"] == "author@example.com"
    )
    error_message = "The agent's GIT_* env must come from git_name and git_email."
  }
}

run "service_account_mounts_its_token" {
  command = plan

  variables {
    namespace            = "coder-ops"
    service_account_name = "coder-ws-operator"
  }

  assert {
    condition     = kubernetes_deployment_v1.main[0].spec[0].template[0].spec[0].service_account_name == "coder-ws-operator"
    error_message = "The pod must run as service_account_name."
  }
  assert {
    condition     = kubernetes_deployment_v1.main[0].spec[0].template[0].spec[0].automount_service_account_token == true
    error_message = "The pod must mount the token of the ServiceAccount it runs as."
  }
  assert {
    condition     = data.kubernetes_service_account_v1.workspace[0].metadata[0].namespace == "coder-ops"
    error_message = "The ServiceAccount must be looked up in the workspace's own namespace."
  }
  assert {
    condition     = kubernetes_deployment_v1.main[0].metadata[0].namespace == "coder-ops" && kubernetes_persistent_volume_claim_v1.home.metadata[0].namespace == "coder-ops"
    error_message = "The pod and home PVC must both land in var.namespace."
  }
}

run "dotfiles_placeholder_is_substituted" {
  command = plan

  assert {
    condition     = !strcontains(coder_script.dotfiles.script, "@DOTFILES_AFTER_UNITS@")
    error_message = "main.tf must replace dotfiles.sh's placeholder."
  }
}

# A stopped workspace keeps its home volume and drops everything else. The
# dotfiles script must still render: try() covers the missing module.
run "stopped_workspace_keeps_home" {
  command = plan

  override_data {
    target = data.coder_workspace.me
    values = {
      id          = "0b7d5a1e-0000-4000-8000-000000000001"
      name        = "My-Workspace"
      start_count = 0
    }
  }

  assert {
    condition     = length(kubernetes_deployment_v1.main) == 0 && length(module.claude-code) == 0
    error_message = "A stopped workspace must have no deployment and no claude-code module."
  }
  assert {
    condition     = kubernetes_persistent_volume_claim_v1.home.spec[0].resources[0].requests["storage"] == "10Gi"
    error_message = "A stopped workspace must keep its home PVC."
  }
  assert {
    condition     = !strcontains(coder_script.dotfiles.script, "@DOTFILES_AFTER_UNITS@")
    error_message = "The placeholder must be substituted even with the claude-code module absent."
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd modules/workspace && tofu init -input=false && tofu test; cd -`
Expected: `tofu init` reports the directory has no configuration files, and `tofu test` ends `Failure! 0 passed, 1 failed, 4 skipped.` with `Error: Missing required provider`, because there is no module yet.

- [ ] **Step 3: Write `versions.tf`**

```hcl
terraform {
  # The claude-code module requires 1.9; Coder's provisioner runs 1.15.
  required_version = ">= 1.9"

  required_providers {
    coder = {
      source = "coder/coder"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}
```

- [ ] **Step 4: Write `variables.tf`**

```hcl
variable "image" {
  description = "Workspace container image, pinned by SHA tag."
  type        = string
}

variable "cpu" {
  description = "CPU limit, in cores."
  type        = string
}

variable "memory" {
  description = "Memory limit, in GB."
  type        = string
}

variable "home_disk_size" {
  description = "Home PVC size, in GB."
  type        = number
}

variable "git_name" {
  description = "Author and committer name for every commit made in the workspace."
  type        = string
}

variable "git_email" {
  description = "Author and committer email for every commit made in the workspace."
  type        = string
}

variable "namespace" {
  description = "Namespace for the workspace pod and its home PVC."
  type        = string
  default     = "coder"
}

# The pod mounts a token only when this is set. Without one it would mount the
# namespace's `default` token, which grants nothing today but would grow
# silently if that account were ever bound to a role.
variable "service_account_name" {
  description = "ServiceAccount the workspace pod runs as. Null runs it with no token mounted."
  type        = string
  default     = null
}

variable "claude_code_oauth_token" {
  description = "OAuth token passed to Claude Code via the CLAUDE_CODE_OAUTH_TOKEN env var."
  type        = string
  default     = ""
  sensitive   = true
}
```

- [ ] **Step 5: Write `main.tf`**

This is `templates/Base/main.tf` from `data "coder_workspace" "me" {}` onward, with parameters, locals and the hardcoded namespace and image replaced by `var.*`, plus the ServiceAccount lookup and the two pod fields.
Every existing comment is kept.

```hcl
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

resource "coder_agent" "main" {
  os   = "linux"
  arch = "amd64"

  # Every shell, IDE and agent session inherits these, and git ranks them
  # above user.name and user.email in any config file. dotfiles.sh also passes
  # them to chezmoi, so the generated ~/.gitconfig agrees.
  env = {
    GIT_AUTHOR_NAME     = var.git_name
    GIT_AUTHOR_EMAIL    = var.git_email
    GIT_COMMITTER_NAME  = var.git_name
    GIT_COMMITTER_EMAIL = var.git_email
  }

  # The following metadata blocks are optional. They are used to display
  # information about your workspace in the dashboard. You can remove them
  # if you don't want to display any information.
  # For basic resources, you can use the `coder stat` command.
  # If you need more control, you can write your own script.
  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Home Disk"
    key          = "3_home_disk"
    script       = "coder stat disk --path $${HOME}"
    interval     = 60
    timeout      = 1
  }

  metadata {
    display_name = "CPU Usage (Host)"
    key          = "4_cpu_usage_host"
    script       = "coder stat cpu --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Memory Usage (Host)"
    key          = "5_mem_usage_host"
    script       = "coder stat mem --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Load Average (Host)"
    key          = "6_load_host"
    # get load avg scaled by number of cores
    script   = <<EOT
      echo "`cat /proc/loadavg | awk '{ print $1 }'` `nproc`" | awk '{ printf "%0.2f", $1/$2 }'
    EOT
    interval = 60
    timeout  = 1
  }
}

# Dotfiles as a coder_script, not the agent's startup_script: coder_script is
# what Coder recommends now, it gets its own row and log in the dashboard, and
# it can order itself after the claude-code module's scripts with
# `coder exp sync`. See dotfiles.sh for why it waits on them.
resource "coder_script" "dotfiles" {
  agent_id     = coder_agent.main.id
  display_name = "Dotfiles"
  icon         = "/icon/git.svg"
  run_on_start = true

  # dotfiles.sh deliberately exits non-zero when chezmoi fails, so Coder flags
  # the run, and its error message tells the user the workspace is still usable
  # and to run `chezmoi apply` by hand. That promise only holds while login
  # does not wait on this script -- otherwise a failed apply would keep them
  # out of the workspace entirely. Stated rather than inherited, so a change of
  # provider default cannot quietly turn a warning into a lockout.
  start_blocks_login = false

  # The script names its dependencies through a placeholder rather than
  # templatefile(), which would also try to interpolate every shell ${...}.
  # try() covers a stopped workspace, where the module has count = 0.
  script = replace(
    file("${path.module}/dotfiles.sh"),
    "@DOTFILES_AFTER_UNITS@",
    join(" ", try(module.claude-code[0].scripts, [])),
  )
}

# Looked up rather than trusted, so a ServiceAccount that does not exist yet
# fails the build at plan time. Otherwise the deployment is created, its pod is
# rejected, and wait_for_rollout = false below hides that the workspace never
# starts.
data "kubernetes_service_account_v1" "workspace" {
  count = var.service_account_name == null ? 0 : 1
  metadata {
    name      = var.service_account_name
    namespace = var.namespace
  }
}

resource "kubernetes_persistent_volume_claim_v1" "home" {
  metadata {
    name      = "coder-${data.coder_workspace.me.id}-home"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"     = "coder-pvc"
      "app.kubernetes.io/instance" = "coder-pvc-${data.coder_workspace.me.id}"
      "app.kubernetes.io/part-of"  = "coder"
      //Coder-specific labels.
      "com.coder.resource"       = "true"
      "com.coder.workspace.id"   = data.coder_workspace.me.id
      "com.coder.workspace.name" = data.coder_workspace.me.name
      "com.coder.user.id"        = data.coder_workspace_owner.me.id
      "com.coder.user.username"  = data.coder_workspace_owner.me.name
    }
    annotations = {
      "com.coder.user.email" = data.coder_workspace_owner.me.email
    }
  }
  wait_until_bound = false
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "${var.home_disk_size}Gi"
      }
    }
  }
}

resource "kubernetes_deployment_v1" "main" {
  count = data.coder_workspace.me.start_count
  depends_on = [
    kubernetes_persistent_volume_claim_v1.home
  ]
  wait_for_rollout = false
  metadata {
    name      = "coder-${data.coder_workspace.me.id}"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"     = "coder-workspace"
      "app.kubernetes.io/instance" = "coder-workspace-${data.coder_workspace.me.id}"
      "app.kubernetes.io/part-of"  = "coder"
      "com.coder.resource"         = "true"
      "com.coder.workspace.id"     = data.coder_workspace.me.id
      "com.coder.workspace.name"   = data.coder_workspace.me.name
      "com.coder.user.id"          = data.coder_workspace_owner.me.id
      "com.coder.user.username"    = data.coder_workspace_owner.me.name
    }
    annotations = {
      "com.coder.user.email" = data.coder_workspace_owner.me.email
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        "app.kubernetes.io/name"     = "coder-workspace"
        "app.kubernetes.io/instance" = "coder-workspace-${data.coder_workspace.me.id}"
        "app.kubernetes.io/part-of"  = "coder"
        "com.coder.resource"         = "true"
        "com.coder.workspace.id"     = data.coder_workspace.me.id
        "com.coder.workspace.name"   = data.coder_workspace.me.name
        "com.coder.user.id"          = data.coder_workspace_owner.me.id
        "com.coder.user.username"    = data.coder_workspace_owner.me.name
      }
    }
    strategy {
      type = "Recreate"
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"     = "coder-workspace"
          "app.kubernetes.io/instance" = "coder-workspace-${data.coder_workspace.me.id}"
          "app.kubernetes.io/part-of"  = "coder"
          "com.coder.resource"         = "true"
          "com.coder.workspace.id"     = data.coder_workspace.me.id
          "com.coder.workspace.name"   = data.coder_workspace.me.name
          "com.coder.user.id"          = data.coder_workspace_owner.me.id
          "com.coder.user.username"    = data.coder_workspace_owner.me.name
        }
      }
      spec {
        # Kubernetes defaults the pod hostname to the pod name
        # (coder-<workspace-uuid>-<replicaset>-<pod>), which changes on every
        # rebuild and cannot be changed from inside the pod: `hostname` needs
        # CAP_SYS_ADMIN, which the workspace securityContext drops. That breaks
        # per-host chezmoi gating on .chezmoi.hostname, and makes anything that
        # derives a name from the host unusable -- bootstrap/lib/bw-ssh-agent.sh
        # in the dotfiles repo names its Bitwarden item "<host> - Home Lab",
        # which would otherwise be a fresh item per rebuild, each named after a
        # pod that no longer exists.
        #
        # lower() keeps this a valid RFC 1123 DNS label, which the field requires.
        hostname = lower(data.coder_workspace.me.name)

        # This cluster mixes an amd64 control-plane node (gandalf) with
        # arm64 worker Pis. coder_agent.main.arch above is hardcoded to
        # "amd64", so the agent binary the startup script downloads is
        # amd64-only. Without this selector, pod_anti_affinity below is
        # free to schedule the pod onto an arm64 Pi, where the agent
        # binary fails immediately with "Exec format error" (the startup
        # script then sleeps 24h to preserve logs, so kubectl shows the
        # pod as 1/1 Running even though the workspace never came up).
        node_selector = {
          "kubernetes.io/arch" = "amd64"
        }

        service_account_name            = try(data.kubernetes_service_account_v1.workspace[0].metadata[0].name, null)
        automount_service_account_token = var.service_account_name != null

        security_context {
          run_as_user     = 1000
          fs_group        = 1000
          run_as_non_root = true
        }

        container {
          name              = "dev"
          image             = var.image
          image_pull_policy = "Always"
          command           = ["sh", "-c", coder_agent.main.init_script]
          security_context {
            run_as_user = "1000"
          }
          env {
            name  = "CODER_AGENT_TOKEN"
            value = coder_agent.main.token
          }
          resources {
            requests = {
              "cpu"    = "250m"
              "memory" = "512Mi"
            }
            limits = {
              "cpu"    = var.cpu
              "memory" = "${var.memory}Gi"
            }
          }
          volume_mount {
            mount_path = "/home/coder"
            name       = "home"
            read_only  = false
          }
        }

        volume {
          name = "home"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.home.metadata.0.name
            read_only  = false
          }
        }

        affinity {
          // This affinity attempts to spread out all workspace pods evenly across
          // nodes.
          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 1
              pod_affinity_term {
                topology_key = "kubernetes.io/hostname"
                label_selector {
                  match_expressions {
                    key      = "app.kubernetes.io/name"
                    operator = "In"
                    values   = ["coder-workspace"]
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
```

- [ ] **Step 6: Write `claude.tf` and copy the dotfiles script**

`claude.tf` is `templates/Base/modules.tf` minus the `claude_code_oauth_token` variable, which becomes a module input:

```hcl
# No vscode-desktop module: Coder renders a built-in VS Code Desktop app for
# every agent, so adding one produced two identical buttons. To open a specific
# folder, add the module back and set display_apps.vscode = false on the agent.

module "claude-code" {
  count                   = data.coder_workspace.me.start_count
  source                  = "registry.coder.com/coder/claude-code/coder"
  version                 = "5.2.0"
  agent_id                = coder_agent.main.id
  anthropic_api_key       = ""
  claude_binary_path      = "$HOME/.local/bin"
  claude_code_oauth_token = var.claude_code_oauth_token
  claude_code_version     = "latest"
  disable_autoupdater     = false
  enable_ai_gateway       = false
  icon                    = "/icon/claude.svg"
  install_claude_code     = true
  mcp                     = ""
  model                   = ""
  post_install_script     = null
  pre_install_script      = null
  workdir                 = null
}
```

Run: `cp templates/Base/dotfiles.sh modules/workspace/dotfiles.sh`

- [ ] **Step 7: Run the tests to verify they pass**

Run: `cd modules/workspace && tofu init -input=false && tofu validate && tofu test; cd -`
Expected: `Success! The configuration is valid.`, then five passing runs and `Success! 5 passed, 0 failed.`

- [ ] **Step 8: Prove the tests can fail**

Temporarily change `automount_service_account_token = var.service_account_name != null` in `modules/workspace/main.tf` to `automount_service_account_token = true` and rerun `tofu test` in `modules/workspace`.
Expected: `run "defaults_mount_no_token"... fail`.
Undo the edit and rerun: `Success! 5 passed, 0 failed.`

- [ ] **Step 9: Make the fmt hook recursive**

Today the `tofu-fmt` hook runs `tofu fmt -check -diff` in the repo root, which holds no `.tf` files, so it checks nothing.
In `.pre-commit-config.yaml`, change the hook's entry:

```yaml
        entry: tofu fmt -check -diff -recursive
```

Run: `pre-commit run tofu-fmt --all-files`
Expected: `tofu fmt -check....Passed`.

- [ ] **Step 10: Commit**

Keep `modules/workspace/.terraform.lock.hcl` out of git: the module's providers are locked by each template's own lock file, and the vendoring script already skips it.

```bash
printf '\n# The module is locked by each template that vendors it.\nmodules/workspace/.terraform.lock.hcl\n' >> .gitignore
git add .gitignore .pre-commit-config.yaml modules/workspace
git status --short   # expect no .terraform/ or lock file staged
git commit -F - <<'EOF'
feat(module): extract the workspace into a shared module

Holds what templates/Base defines except its parameters, driven by
inputs, so the k3s and language templates can reuse it. A pod now
mounts a ServiceAccount token only when the caller names the account.

The fmt hook becomes recursive: it ran in the repo root, which has no
.tf files, so it never checked any.

Assisted-by: AI
EOF
```

______________________________________________________________________

### Task 4: Convert Base to the module

**Files:**

- Rewrite: `templates/Base/main.tf`
- Delete: `templates/Base/modules.tf`, `templates/Base/dotfiles.sh`
- Create: `templates/Base/template.json`
- Modify: `templates/Base/README.md`, `README.md`

**Interfaces:**

- Consumes: Task 1's `scripts/vendor-module.sh`; Task 3's module inputs and resource addresses.

- Produces: `templates/<name>/template.json`, a JSON object whose keys Task 5's push workflow reads; this plan defines `icon` (string, a Coder icon path).
  The later plans add keys to it.

- [ ] **Step 1: Record the addresses the old version creates**

Run:

```bash
git show origin/main:templates/Base/main.tf origin/main:templates/Base/modules.tf \
  | sed -nE 's/^(resource|module) "([^"]+)"( "([^"]+)")? \{.*/\1 \2 \4/p'
```

Expected, exactly these five lines:

```text
resource coder_agent main
resource coder_script dotfiles
resource kubernetes_persistent_volume_claim_v1 home
resource kubernetes_deployment_v1 main
module claude-code
```

Each needs a `moved` block in Step 2.
If the list differs, stop: `main` has changed since this plan was written, and every new address needs its own block.

- [ ] **Step 2: Rewrite `templates/Base/main.tf`**

The parameters and the git identity `locals` are unchanged except for the comment above `locals`, which now says the module applies the identity.

```hcl
terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

provider "coder" {
}

provider "kubernetes" {
  # Authenticate via ~/.kube/config or a Coder-specific ServiceAccount, depending on admin preferences
  config_path = false == true ? "~/.kube/config" : null
}

data "coder_parameter" "cpu" {
  name         = "cpu"
  display_name = "CPU"
  description  = "The number of CPU cores"
  default      = "2"
  icon         = "/icon/memory.svg"
  mutable      = true
  option {
    name  = "2 Cores"
    value = "2"
  }
  option {
    name  = "4 Cores"
    value = "4"
  }
  option {
    name  = "6 Cores"
    value = "6"
  }
  option {
    name  = "8 Cores"
    value = "8"
  }
}

data "coder_parameter" "memory" {
  name         = "memory"
  display_name = "Memory"
  description  = "The amount of memory in GB"
  # 2 GB cannot link a Rust binary: building the `bws` cargo package OOM-killed
  # the workspace at that size. Default to a value that can actually build the
  # toolchain; it stays mutable, so smaller workspaces can still dial it down.
  default = "8"
  icon    = "/icon/memory.svg"
  mutable = true
  option {
    name  = "2 GB"
    value = "2"
  }
  option {
    name  = "4 GB"
    value = "4"
  }
  option {
    name  = "6 GB"
    value = "6"
  }
  option {
    name  = "8 GB"
    value = "8"
  }
}

data "coder_parameter" "home_disk_size" {
  name         = "home_disk_size"
  display_name = "Home disk size"
  description  = "The size of the home disk in GB"
  default      = "10"
  type         = "number"
  icon         = "/emojis/1f4be.png"
  mutable      = false
  validation {
    min = 1
    max = 99999
  }
}

# Git identity for every commit made in a workspace. The module sets it as
# GIT_AUTHOR_* and GIT_COMMITTER_* on the agent.
#
# Fixed here rather than taken from coder_workspace_owner: the owner record
# carries the Coder account email, and substituting it would silently change
# the identity on every commit made from a workspace. Nor are they parameters
# any more: the answer never changes, so asking for it on every workspace was
# only friction.
locals {
  git_name  = "Nick Vigilante"
  git_email = "nickvigilante@users.noreply.github.com"
}

variable "claude_code_oauth_token" {
  description = "OAuth token passed to Claude Code via the CLAUDE_CODE_OAUTH_TOKEN env var. Generate one with `claude setup-token`."
  type        = string
  default     = ""
  sensitive   = true
}

# Everything but the parameters lives in the shared module, which CI copies in
# from modules/workspace. Run scripts/vendor-module.sh templates/Base before
# pushing by hand.
module "workspace" {
  source = "./modules/workspace"

  image                   = "ghcr.io/nickvigilante/homelab-dev-templates:c4c96c8988a5300e875db67cf953bb3e62efcb68"
  cpu                     = data.coder_parameter.cpu.value
  memory                  = data.coder_parameter.memory.value
  home_disk_size          = data.coder_parameter.home_disk_size.value
  git_name                = local.git_name
  git_email               = local.git_email
  claude_code_oauth_token = var.claude_code_oauth_token
}

# These resources lived in this file before the module existed. Without the
# moved blocks, Terraform would read the new addresses as new resources and
# destroy the old ones -- including every workspace's home volume.
moved {
  from = coder_agent.main
  to   = module.workspace.coder_agent.main
}

moved {
  from = coder_script.dotfiles
  to   = module.workspace.coder_script.dotfiles
}

moved {
  from = kubernetes_persistent_volume_claim_v1.home
  to   = module.workspace.kubernetes_persistent_volume_claim_v1.home
}

moved {
  from = kubernetes_deployment_v1.main
  to   = module.workspace.kubernetes_deployment_v1.main
}

moved {
  from = module.claude-code
  to   = module.workspace.module.claude-code
}
```

- [ ] **Step 3: Delete what moved, add the metadata file**

```bash
git rm templates/Base/modules.tf templates/Base/dotfiles.sh
printf '{"icon": "/emojis/1f9f1.png"}\n' > templates/Base/template.json
```

- [ ] **Step 4: Check every old address has a `moved` block**

Run:

```bash
grep -E '^  from = ' templates/Base/main.tf
```

Expected, exactly:

```text
  from = coder_agent.main
  from = coder_script.dotfiles
  from = kubernetes_persistent_volume_claim_v1.home
  from = kubernetes_deployment_v1.main
  from = module.claude-code
```

- [ ] **Step 5: Validate from a vendored copy**

Run:

```bash
scripts/vendor-module.sh templates/Base
cd templates/Base && tofu init -input=false && tofu validate; cd -
git status --short templates/Base
```

Expected: `Success! The configuration is valid.`
`git status` lists `main.tf`, `template.json` and the two deletions, and neither `modules/` (ignored) nor a change to `.terraform.lock.hcl`.
If `tofu init` rewrote the lock file, restore it with `git checkout -- templates/Base/.terraform.lock.hcl`: the providers have not changed, and Coder's provisioner reads that file.

- [ ] **Step 6: Update the docs**

Make three edits to `templates/Base/README.md`.

Replace the first line under `# Base`, `The foundational Coder Kubernetes workspace template.`, with:

```markdown
The foundational Coder Kubernetes workspace template.
Its pod, home volume, agent, dotfiles and Claude Code setup come from the shared module in `modules/workspace/`; this directory holds only the parameters, the git identity and the module call.
```

Replace the `## Git identity` section's line beginning `` main.tf` sets `GIT_AUTHOR_*`  `` with:

```markdown
The shared module sets `GIT_AUTHOR_*` and `GIT_COMMITTER_*` on the agent from the `locals` block in `main.tf`, and git ranks those above `user.name` and `user.email` in any config file.
```

Replace the `bash` code block under `## Updating` with:

````markdown
```bash
# From the repo root. The push uploads only this directory, so the module
# must be copied in first; a missing copy fails the import.
scripts/vendor-module.sh templates/Base
cd templates/Base
tofu fmt -recursive && tofu init && tofu validate
coder templates push Base --directory . -y
```
````

In the top-level `README.md`, add under `## Layout`, after the `templates/Base/` item:

```markdown
- `modules/workspace/` — the shared workspace module every template calls.
  `scripts/vendor-module.sh` copies it into a template before validation or push, because `coder templates push` uploads only the template directory.
```

- [ ] **Step 7: Lint and commit**

Run: `pre-commit run --all-files`
Expected: every hook `Passed` or `Skipped`.

```bash
git add -A templates/Base README.md
git commit -F - <<'EOF'
refactor(base): call the shared workspace module

Base keeps its parameters and git identity and passes them to
modules/workspace. The moved blocks turn the address change into a
state rename; without them Terraform would destroy and recreate every
workspace's home volume.

Assisted-by: AI
EOF
```

______________________________________________________________________

### Task 5: CI runs once per affected template

**Files:**

- Modify: `.github/workflows/lint.yml`
- Rewrite: `.github/workflows/template-validate.yml`, `.github/workflows/template-push.yml`

**Interfaces:**

- Consumes: `scripts/vendor-module.sh`, `scripts/changed-templates.sh`, `scripts/tests/*_test.sh`, `templates/<name>/template.json` with key `icon`.

- Produces: `template-push.yml` passes each `template.json` key to its push job as `matrix.<key>`; the later plans read new keys the same way.

- [ ] **Step 1: Replace the `tofu validate` step in `lint.yml`**

Replace the last step, `tofu validate (templates/Base)`, with:

```yaml
      - name: Script tests
        run: |
          set -euo pipefail
          for t in scripts/tests/*_test.sh; do "$t"; done
      - name: tofu test (modules/workspace)
        working-directory: modules/workspace
        run: |
          tofu init -input=false
          tofu test
      # Every template, from a freshly vendored module copy, exactly as
      # template-push.yml uploads it.
      - name: tofu validate (every template)
        run: |
          set -euo pipefail
          for dir in templates/*/; do
            echo "== ${dir}"
            scripts/vendor-module.sh "$dir"
            (cd "$dir" && tofu init -input=false && tofu validate)
          done
```

- [ ] **Step 2: Rewrite `template-validate.yml`**

```yaml
name: template-validate

# PR-only, and deliberately on a GitHub-hosted runner.
#
# This is the trigger fork pull requests can reach, so it must never run on the
# self-hosted in-cluster runner: this repository is public, and a pull_request
# job executes the PR's own code. Delivery lives in template-push.yml, which is
# push-only for exactly that reason. See docs/runner-setup.md.
on:
  pull_request:
    branches: [main]
    paths:
      - 'templates/**'
      - 'modules/workspace/**'
      - 'scripts/vendor-module.sh'
      - 'scripts/changed-templates.sh'

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  # Which templates this PR affects. A module change affects all of them; see
  # scripts/changed-templates.sh.
  changes:
    runs-on: ubuntu-latest
    outputs:
      templates: ${{ steps.list.outputs.templates }}
    steps:
      # Full history: the diff needs the PR's base commit.
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          persist-credentials: false
      - name: List affected templates
        id: list
        env:
          BASE_SHA: ${{ github.event.pull_request.base.sha }}
        run: |
          set -euo pipefail
          templates="$(scripts/changed-templates.sh "$BASE_SHA" HEAD | jq -R -s -c 'split("\n") | map(select(length > 0))')"
          echo "templates=${templates}" >> "$GITHUB_OUTPUT"
          echo "Affected templates: ${templates}"

  validate:
    name: validate (${{ matrix.template }})
    needs: changes
    if: needs.changes.outputs.templates != '[]'
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        template: ${{ fromJSON(needs.changes.outputs.templates) }}
    steps:
      - uses: actions/checkout@v4
        with:
          persist-credentials: false

      # Fork PRs receive no secrets, and the tailnet/Coder credentials may not
      # be provisioned yet. Report and skip rather than fail: a red check for
      # "not configured" is indistinguishable from a red check for "the
      # template is broken", which is the signal this job exists to give.
      - name: Check whether live validation is configured
        id: cfg
        env:
          TS_ID: ${{ secrets.TS_OAUTH_CLIENT_ID }}
          CODER_URL: ${{ secrets.CODER_URL }}
          CODER_TAILNET_IP: ${{ vars.CODER_TAILNET_IP }}
        run: |
          set -euo pipefail
          if [ -z "${TS_ID}" ] || [ -z "${CODER_URL}" ] || [ -z "${CODER_TAILNET_IP}" ]; then
            echo "configured=false" >> "$GITHUB_OUTPUT"
            echo "::notice::Tailscale/Coder secrets or CODER_TAILNET_IP absent — skipping live validation. Fork PRs always land here."
          else
            echo "configured=true" >> "$GITHUB_OUTPUT"
          fi

      - name: Join the tailnet
        if: steps.cfg.outputs.configured == 'true'
        uses: tailscale/github-action@v3
        with:
          oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
          oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}
          tags: tag:ci

      # Resolution, not routing, is what fails without this. The observed error
      # is `curl: (28) Resolving timed out`, a hang rather than a refusal:
      # coder.vigihome.net has no public record, and after the Tailscale action
      # runs the resolver is MagicDNS, whose split-DNS lookup for vigihome.net
      # would need an internal resolver on port 53 that tag:ci is not granted.
      # The query has nowhere to go.
      #
      # Widening the ACL to reach that resolver is the alternative, and is not
      # taken: keeping tag:ci scoped to one host on one port is most of the value
      # of validating from a throwaway node.
      #
      # Map it in /etc/hosts rather than using curl --resolve, because the coder
      # CLI needs it too and has no equivalent flag; a curl-only fix would just
      # move the failure to the push step.
      #
      # The address is a repository variable rather than a literal so the tailnet
      # topology is not baked into a public workflow, and so a re-addressed host
      # is one setting away rather than a commit.
      - name: Resolve the deployment to its tailnet address
        if: steps.cfg.outputs.configured == 'true'
        env:
          CODER_URL: ${{ secrets.CODER_URL }}
          CODER_TAILNET_IP: ${{ vars.CODER_TAILNET_IP }}
        run: |
          set -euo pipefail
          host="$(printf '%s' "$CODER_URL" | sed -E 's#^[a-z]+://##; s#[:/].*$##')"
          [ -n "$host" ] || { echo "::error::could not parse a hostname out of CODER_URL"; exit 1; }
          printf '%s %s\n' "$CODER_TAILNET_IP" "$host" | sudo tee -a /etc/hosts > /dev/null
          echo "Mapped $host -> $CODER_TAILNET_IP"

      # --prefix, and then $GITHUB_PATH, because the installer's default
      # location depends on who is running it: /usr/local/bin as root, but
      # ~/.local/bin otherwise, and ~/.local/bin is not on a GitHub-hosted
      # runner's PATH. Without this the step succeeds and the next one fails
      # with `coder: command not found`.
      - name: Install the Coder CLI
        if: steps.cfg.outputs.configured == 'true'
        run: |
          set -euo pipefail
          curl -fsSL https://coder.com/install.sh \
            | sh -s -- --method standalone --prefix "$HOME/.coder"
          echo "$HOME/.coder/bin" >> "$GITHUB_PATH"
          "$HOME/.coder/bin/coder" version | head -1

      - name: Confirm the deployment is reachable
        if: steps.cfg.outputs.configured == 'true'
        env:
          CODER_URL: ${{ secrets.CODER_URL }}
        run: curl -fsS --max-time 10 "$CODER_URL/healthz"

      # --activate=false makes the Coder provisioner run the Terraform import
      # server-side and reject anything malformed, without making the version
      # live. That catches what `tofu validate` structurally cannot — a bad
      # image tag is syntactically fine — and means CI never needs cluster
      # credentials of its own, because the provisioner does the plan.
      - name: Vendor the shared module
        if: steps.cfg.outputs.configured == 'true'
        env:
          TEMPLATE: ${{ matrix.template }}
        run: scripts/vendor-module.sh "templates/${TEMPLATE}"

      - name: Push a non-activated version
        if: steps.cfg.outputs.configured == 'true'
        env:
          CODER_URL: ${{ secrets.CODER_URL }}
          CODER_SESSION_TOKEN: ${{ secrets.CODER_SESSION_TOKEN }}
          # Passed via env rather than expanded inline in run:. This value is
          # a GitHub-assigned integer and cannot carry a payload, but inline
          # expansion into a shell command is the shape that gets copied to a
          # field that can -- a PR title, a branch name -- so it is avoided.
          PR_NUMBER: ${{ github.event.number }}
          # A directory name, which a fork PR controls: env, never inline.
          TEMPLATE: ${{ matrix.template }}
        run: |
          set -euo pipefail
          coder templates push "$TEMPLATE" \
            --directory "templates/${TEMPLATE}" \
            --name "pr-${PR_NUMBER}-$(git rev-parse --short HEAD)" \
            --activate=false \
            --yes
```

- [ ] **Step 3: Rewrite `template-push.yml`**

```yaml
name: template-push

# DELIBERATELY push-only. Do not add a pull_request trigger. Ever.
#
# This job runs on a self-hosted runner inside the k3s cluster, and this
# repository is public. A pull_request trigger executes the pull request's own
# code, including from forks, so adding one here would let anyone run arbitrary
# code on the cluster control plane, alongside every workspace PVC.
#
# PR-time validation already exists and is safe: template-validate.yml runs on
# a GitHub-hosted runner and pushes a non-activated version. There is no reason
# to validate here. See docs/runner-setup.md.
on:
  push:
    branches: [main]
    paths:
      - 'templates/**'
      - 'modules/workspace/**'
      - 'scripts/vendor-module.sh'
      - 'scripts/changed-templates.sh'

permissions:
  contents: read

# No cancel-in-progress: two rapid merges should queue, not race to activate
# different template versions.
concurrency:
  group: template-push
  cancel-in-progress: false

jobs:
  # Which templates this merge affects, each with its template.json metadata.
  # Runs on a GitHub-hosted runner, which has jq; the in-cluster runner then
  # only needs the values it is handed.
  changes:
    runs-on: ubuntu-latest
    outputs:
      templates: ${{ steps.list.outputs.templates }}
    steps:
      # Full history: the diff needs the commit before this push.
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          persist-credentials: false
      # Every template must carry a template.json; jq fails the job on a
      # missing one rather than pushing a template without its metadata.
      - name: List affected templates
        id: list
        env:
          BEFORE_SHA: ${{ github.event.before }}
        run: |
          set -euo pipefail
          templates="$(scripts/changed-templates.sh "$BEFORE_SHA" HEAD \
            | while read -r t; do jq -c --arg t "$t" '{template: $t} + .' "templates/${t}/template.json"; done \
            | jq -s -c '.')"
          echo "templates=${templates}" >> "$GITHUB_OUTPUT"
          echo "Affected templates: ${templates}"

  push:
    name: push (${{ matrix.template }})
    needs: changes
    if: needs.changes.outputs.templates != '[]'
    strategy:
      fail-fast: false
      matrix:
        include: ${{ fromJSON(needs.changes.outputs.templates) }}
    runs-on: arc-runner-set
    # A missing or unhealthy runner leaves the job queued indefinitely rather
    # than failing, which looks identical to "nothing was merged". Fail instead.
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v4
        with:
          persist-credentials: false

      # Explicit --prefix and $GITHUB_PATH. This currently works without them
      # only because the ARC runner happens to run as root, so the installer
      # picks /usr/local/bin; a non-root runner image would break it exactly as
      # it broke template-validate. Do not depend on the runner's uid.
      - name: Install the Coder CLI
        run: |
          set -euo pipefail
          curl -fsSL https://coder.com/install.sh \
            | sh -s -- --method standalone --prefix "$HOME/.coder"
          echo "$HOME/.coder/bin" >> "$GITHUB_PATH"
          "$HOME/.coder/bin/coder" version | head -1

      - name: Vendor the shared module
        env:
          TEMPLATE: ${{ matrix.template }}
        run: scripts/vendor-module.sh "templates/${TEMPLATE}"

      - name: Activate the template
        env:
          CODER_URL: ${{ secrets.CODER_URL }}
          CODER_SESSION_TOKEN: ${{ secrets.CODER_SESSION_TOKEN }}
          TEMPLATE: ${{ matrix.template }}
        run: |
          set -euo pipefail
          coder templates push "$TEMPLATE" \
            --directory "templates/${TEMPLATE}" \
            --name "main-$(git rev-parse --short HEAD)" \
            --yes

      # The icon is template metadata, not part of a version, so `templates
      # push` cannot set it. Re-stating it on every push keeps it declared in
      # the template's template.json rather than living only in the
      # dashboard. Any /emojis/*.png or /icon/*.svg path ships with Coder;
      # avoid the /icon/ ones named after a product, which read as that
      # product's template.
      - name: Set the template icon
        env:
          CODER_URL: ${{ secrets.CODER_URL }}
          CODER_SESSION_TOKEN: ${{ secrets.CODER_SESSION_TOKEN }}
          TEMPLATE: ${{ matrix.template }}
          ICON: ${{ matrix.icon }}
        run: coder templates edit "$TEMPLATE" --icon "$ICON"

      - name: Report the active version
        env:
          CODER_URL: ${{ secrets.CODER_URL }}
          CODER_SESSION_TOKEN: ${{ secrets.CODER_SESSION_TOKEN }}
          TEMPLATE: ${{ matrix.template }}
        run: coder templates versions list "$TEMPLATE" | head -5
```

- [ ] **Step 4: Lint the workflows**

Run: `actionlint .github/workflows/*.yml && pre-commit run --all-files`
Expected: actionlint reports only `label "arc-runner-set" is unknown` (a self-hosted label it cannot know), and every pre-commit hook passes.

- [ ] **Step 5: Dry-run the matrix commands locally**

Run from the worktree root:

```bash
base=$(git merge-base origin/main HEAD)
scripts/changed-templates.sh "$base" HEAD | jq -R -s -c 'split("\n") | map(select(length > 0))'
scripts/changed-templates.sh "$base" HEAD \
  | while read -r t; do jq -c --arg t "$t" '{template: $t} + .' "templates/${t}/template.json"; done \
  | jq -s -c '.'
mv templates/Base/template.json /tmp/template.json.bak
scripts/changed-templates.sh "$base" HEAD \
  | while read -r t; do jq -c --arg t "$t" '{template: $t} + .' "templates/${t}/template.json"; done \
  | jq -s -c '.'; echo "exit=$?"
mv /tmp/template.json.bak templates/Base/template.json
```

Expected: `["Base"]`, then `[{"template":"Base","icon":"/emojis/1f9f1.png"}]`, then a `jq` error that `templates/Base/template.json` cannot be opened.
In the workflow, `set -euo pipefail` makes that error fail the job (Review Focus 5); in this interactive shell the final `jq -s` still prints `[]`, which is why the workflow sets `pipefail`.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows
git commit -F - <<'EOF'
ci: validate and push each affected template, not only Base

Each workflow vendors the shared module first. Lint also runs the
script tests and the module's tofu tests. The push job takes the icon
from each template's template.json instead of hardcoding Base's.

Assisted-by: AI
EOF
```

______________________________________________________________________

### Task 6: Prove the migration on real workspaces, then merge

This is the test Review Focus 1 and 2 depend on.
It needs the Coder CLI logged in (`coder login https://coder.vigihome.net`) and the admin kubeconfig.

**Files:** none.

- [ ] **Step 1: Open the PR**

```bash
git push -u origin feat/shared-workspace-module
gh pr create --title "refactor: move Base into a shared workspace module" --body-file - <<'EOF'
## Summary

Moves everything Base defines except its parameters into modules/workspace, which CI vendors into each template, so the k3s and language templates can reuse it. Base keeps its behavior; moved blocks migrate existing workspaces' state instead of recreating their home volumes. Implements phase 1 of docs/superpowers/specs/2026-09-27-k3s-agent-templates-design.md.

## Changes

- modules/workspace, with plan-only tofu tests against mocked providers.
- scripts/vendor-module.sh and scripts/changed-templates.sh, each with tests.
- Base calls the module, with moved blocks for all five old addresses. Its pod no longer mounts the namespace's default ServiceAccount token.
- lint, template-validate and template-push run once per affected template; the icon comes from template.json.
- The tofu fmt pre-commit hook is now recursive; it previously checked nothing.

## Testing

- [ ] tofu test in modules/workspace
- [ ] scripts/tests/*_test.sh
- [ ] A running Base workspace updated to this PR's version keeps its home PVC UID and files
- [ ] A stopped Base workspace updated to this PR's version starts with its home PVC UID and files intact

---

🤖 Built with AI assistance.
EOF
```

Wait for `lint` and `template-validate` to pass.
`template-validate` pushes a non-activated version named `pr-<number>-<short-sha>`.

- [ ] **Step 2: Create two throwaway workspaces on the current version**

```bash
for ws in migrate-running migrate-stopped; do
  coder create "$ws" --template Base --yes \
    --parameter cpu=2 --parameter memory=2 --parameter home_disk_size=1
  coder ssh "$ws" -- sh -c 'echo keep > ~/migration-marker'
done
coder stop migrate-stopped --yes
for ws in migrate-running migrate-stopped; do
  printf '%s ' "$ws"
  kubectl -n coder get pvc -l "com.coder.workspace.name=${ws}" \
    -o jsonpath='{.items[0].metadata.uid}{"\n"}'
done | tee /tmp/pvc-uids-before
```

Expected: two lines, each a workspace name and a UID.

- [ ] **Step 3: Move both to the PR's version**

In the dashboard, for each workspace: open it, choose the menu → **Change version**, and pick `pr-<number>-<short-sha>`.
`migrate-running` rebuilds at once; start `migrate-stopped` afterwards with `coder start migrate-stopped`.
In each build's log, find Terraform's plan output.

Expected in each log: lines saying the old addresses `has moved to module.workspace...`, and a summary with `0 to destroy`.
If any build plans to destroy `kubernetes_persistent_volume_claim_v1.home`, cancel it, do not merge, and fix the `moved` blocks.

- [ ] **Step 4: Check the volumes and files survived**

```bash
for ws in migrate-running migrate-stopped; do
  printf '%s ' "$ws"
  kubectl -n coder get pvc -l "com.coder.workspace.name=${ws}" \
    -o jsonpath='{.items[0].metadata.uid}{"\n"}'
done | diff /tmp/pvc-uids-before - && echo "PVC UIDs unchanged"
for ws in migrate-running migrate-stopped; do
  coder ssh "$ws" -- cat ~/migration-marker
  coder ssh "$ws" -- sh -c 'test ! -e /var/run/secrets/kubernetes.io/serviceaccount/token && echo "no token mounted"'
done
```

Expected: `PVC UIDs unchanged`, then `keep` and `no token mounted` for each workspace.
Tick the two migration boxes in the PR body.

- [ ] **Step 5: Clean up and merge**

```bash
coder delete migrate-running --yes
coder delete migrate-stopped --yes
gh pr merge --squash --delete-branch
```

Then watch `template-push` on `main`: it must run one `push (Base)` job, which activates the version and sets the icon.

______________________________________________________________________

### Task 7: Bake `kubectl`, `helm` and `flux` into the image

**Files:**

- Modify: `images/base/Dockerfile`
- Modify: `.github/workflows/image-build.yml`

**Interfaces:**

- Produces: `/usr/local/bin/kubectl`, `/usr/local/bin/helm` and `/usr/local/bin/flux` in the base image, which the read-only and read-write plans rely on.

None of the three fits `tools.txt`: `kubectl` and `helm` are not GitHub release assets, and `helm` and `flux` ship official installer scripts, which the Dockerfile already prefers.

- [ ] **Step 1: Create the worktree**

```bash
git fetch origin
git worktree add -b feat/image-k8s-tools .worktrees/feat-image-k8s-tools origin/main
cd .worktrees/feat-image-k8s-tools
```

- [ ] **Step 2: Write the failing check**

In `.github/workflows/image-build.yml`, in the step `Verify baked-in CLI tools landed`, change the last line of the command from:

```yaml
             && zoxide --version && uv --version && ruff --version'
```

to:

```yaml
             && zoxide --version && uv --version && ruff --version \
             && kubectl version --client && helm version && flux version --client'
```

- [ ] **Step 3: Run the check to verify it fails**

Run:

```bash
docker build --secret id=github_token,env=GITHUB_TOKEN -t base:validate images/base
docker run --rm base:validate sh -c 'kubectl version --client && helm version && flux version --client'
```

Expected: FAIL with `kubectl: not found`.
(`GITHUB_TOKEN` can be `$(gh auth token)`; without it, `install-tools.sh` may hit GitHub's anonymous rate limit.)

- [ ] **Step 4: Install the tools**

In `images/base/Dockerfile`, after the line `RUN curl -fsSL https://ollama.com/install.sh | sh`, add:

```dockerfile
# Kubernetes CLIs for the k3s templates. helm and flux ship official
# installers, which install into /usr/local/bin when run as root. kubectl has
# none: dl.k8s.io serves one static binary per release and architecture, and
# stable.txt names the current release. kubectl supports one minor version of
# skew against the cluster, so bump k3s or pin this if the two drift apart.
RUN curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
RUN curl -fsSL https://fluxcd.io/install.sh | bash
RUN arch="$(dpkg --print-architecture)" \
    && version="$(curl -fsSL https://dl.k8s.io/release/stable.txt)" \
    && curl -fsSLo /usr/local/bin/kubectl \
         "https://dl.k8s.io/release/${version}/bin/linux/${arch}/kubectl" \
    && chmod 0755 /usr/local/bin/kubectl
```

- [ ] **Step 5: Run the check to verify it passes**

Run the two commands from Step 3 again.
Expected: three version outputs and exit status 0.
Then run `hadolint images/base/Dockerfile` (expected: no output) and `pre-commit run --all-files` (expected: all hooks pass).

- [ ] **Step 6: Commit, open the PR and merge**

```bash
git add images/base/Dockerfile .github/workflows/image-build.yml
git commit -F - <<'EOF'
feat(image): bake kubectl, helm and flux into the base image

The k3s templates need them, and they are small enough that a derived
image is not worth a second pipeline yet; the language templates decide
that question for all images.

Assisted-by: AI
EOF
git push -u origin feat/image-k8s-tools
gh pr create --title "feat(image): bake kubectl, helm and flux into the base image" --body-file - <<'EOF'
## Summary

Installs kubectl, helm and flux in the base image for the k3s templates (phase 2 of docs/superpowers/specs/2026-09-27-k3s-agent-templates-design.md).

## Changes

- helm and flux via their official installers, kubectl from dl.k8s.io at the current stable release.
- image-build's tool check now covers all three.

## Testing

- [ ] image-build validates on both amd64 and arm64

---

🤖 Built with AI assistance.
EOF
```

Wait for both `validate (linux/amd64)` and `validate (linux/arm64)` to pass, then `gh pr merge --squash --delete-branch`.

______________________________________________________________________

### Task 8: Pin Base to the new image

**Files:**

- Modify: `templates/Base/main.tf` (the `image` argument of `module "workspace"`)

- [ ] **Step 1: Find the published tag**

Wait for `image-build` on `main` to finish its `publish` job for Task 7's merge commit, then run:

```bash
sha=$(gh run list --workflow image-build --branch main --status success --limit 1 --json headSha -q '.[0].headSha')
docker manifest inspect "ghcr.io/nickvigilante/homelab-dev-templates:${sha}" >/dev/null && echo "published: ${sha}"
```

Expected: `published: <40-character sha>`.

- [ ] **Step 2: Bump the pin**

```bash
git fetch origin
git worktree add -b chore/bump-base-image .worktrees/chore-bump-base-image origin/main
cd .worktrees/chore-bump-base-image
sed -i -E "s#(homelab-dev-templates:)[0-9a-f]{40}#\1${sha}#" templates/Base/main.tf
grep -n 'homelab-dev-templates:' templates/Base/main.tf
```

Expected: one line, ending in the new SHA.

- [ ] **Step 3: Commit, open the PR, verify and merge**

```bash
git commit -am "chore(base): bump the pinned image to ${sha:0:7}" -m "Picks up kubectl, helm and flux." -m "Assisted-by: AI"
git push -u origin chore/bump-base-image
gh pr create --title "chore(base): bump the pinned image to ${sha:0:7}" --body-file - <<'EOF'
## Summary

Pins Base to the image that carries kubectl, helm and flux.

## Testing

- [ ] A workspace from this PR's version runs all three

---

🤖 Built with AI assistance.
EOF
```

After `template-validate` passes, create a workspace from the PR's version (`coder create k8s-tools-check --template Base --template-version pr-<number>-<short-sha> --yes --parameter cpu=2 --parameter memory=2 --parameter home_disk_size=1`), run `coder ssh k8s-tools-check -- sh -c 'kubectl version --client && helm version && flux version --client'`, expect three version outputs, then `coder delete k8s-tools-check --yes` and `gh pr merge --squash --delete-branch`.
