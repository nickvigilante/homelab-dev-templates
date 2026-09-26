# Alert-triggered Coder Task investigator — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** when a real Alertmanager alert fires, automatically create a Coder
Task from a new `Investigate` template that runs Claude Code, read-only,
against the alert's details, and reports findings back before a human looks.

**Architecture:** Alertmanager gets a new `webhook_configs` receiver → a
small Python relay (new, in `homelab-dev-templates`, deployed via `homelab`)
dedupes by alert fingerprint and runs `coder task create` → a new
`templates/Investigate/` Task-mode template (read-only RBAC, no
`pods/exec`, no `Secret` reads) runs Claude Code non-interactively against
the alert prompt via the upstream `claude-code`/`agentapi` modules → the
agent writes `~/findings.md` and emails it via the existing `smtp-relay`
secret, then the workspace auto-stops.

**Tech Stack:** OpenTofu (Terraform), `coder/coder` provider v2.19.0 (the
version already pinned in `templates/Base/.terraform.lock.hcl`, matching
live server v2.37.0), the upstream `registry.coder.com/coder/claude-code/ coder` module **pinned to v4.9.2** (not the `Base` template's v5.2.0 — v5
"drops support for Coder Tasks" per its own changelog; v4.9.2 is the newest
release that still has the `ai_prompt`/`report_tasks`/AgentAPI wiring this
needs), Python 3 stdlib (`http.server`, `json`, `subprocess`) for the relay,
GitHub Actions + GHCR (matching `images/base`'s existing pipeline), Flux/
Kustomize + `external-secrets` (`ClusterSecretStore: bitwarden`) in
`homelab`.

**Spec:** [`docs/design-investigate.md`](design-investigate.md) — read it
first; this plan does not repeat the reasoning behind each decision, only
the resulting tasks. The module-version finding above (v4.9.2 vs v5.2.0)
was confirmed against the actual upstream source during this plan's
drafting (`gh api repos/coder/registry/...`), not assumed — the design doc
flagged this as an open question; this plan is where it got resolved.

## Global Constraints

- Two repos: `homelab-dev-templates` (template + relay image + CI) and
  `homelab` (Alertmanager config + relay's K8s manifests + secrets) — both
  public GitHub repos with PR-only branch protection (`lint` required
  check in `homelab-dev-templates`; check `homelab`'s own required checks
  before opening a PR there).
- Every task lands via its own branch + PR, per the existing convention in
  both repos. **Do not merge any PR without the user's explicit review** —
  this whole feature touches a live Alertmanager config and a live Coder
  deployment; per the design doc's "Decisions needing your sign-off" #5,
  PRs stay open until the user reviews them.
- Commits: plain imperative-subject messages, no `Co-Authored-By: Claude…`
  trailer — end with `Assisted-by: AI` per the user's global git-attribution
  convention; PR bodies end with `---\n🤖 Built with AI assistance.`.
- `homelab-dev-templates`: `.terraform.lock.hcl` committed, `.terraform/`
  gitignored (existing repo convention, see `templates/Base/`).
- New shell scripts get `shfmt -w -i 2 -ci -bn` + `shellcheck -S info`
  clean (existing pre-commit hooks apply repo-wide, no exemption needed).
- New Dockerfile gets `hadolint` clean (existing hook, `files: Dockerfile$`,
  applies automatically).
- RBAC for the `Investigate` template: **no `pods/exec`, no `get`/`list` on
  `secrets`, no write verbs anywhere** — this is the design's core safety
  property, not a detail a later task may loosen.
- Claude Code's own `disallowed_tools` in the template is a second,
  courtesy layer on top of RBAC (see Task 3) — RBAC is the authoritative
  backstop, since alert `labels`/`annotations` are attacker-adjacent input
  (anyone who can get Alertmanager to fire a crafted alert can put
  arbitrary text in front of the agent) and a prompt-injected agent could
  try to talk its way around a soft tool restriction but cannot talk its
  way around a 403 from the Kubernetes API server.

## Review Focus

- **A crafted/malicious alert label or annotation** (prompt injection via
  the one input this system takes from outside the cluster's own
  components) — the relay must not interpolate alert text into anything
  executed as a shell command (only as data passed through as a single
  argument/env var to `coder task create`), and the template's RBAC must
  hold even if the agent is fully convinced by injected text to try
  something destructive. Covered by Task 2 (relay uses `subprocess.run`
  with an argument list, never `shell=True` or string-built commands) and
  Task 4 (RBAC `Role`/`ClusterRole` review).
- **The same alert firing repeatedly** (Alertmanager's `repeat_interval`
  renotifies a still-firing alert) must not spawn a new investigator
  workspace every cycle. Covered by Task 2's fingerprint-dedupe test.
- **Alertmanager webhook payload with zero alerts, or a resolved alert**
  (Alertmanager sends `"status": "resolved"` webhooks too, and a `group`
  payload can contain multiple `alerts[]`) — the relay must not crash or
  create a workspace for a resolved-only payload. Covered by Task 2's
  parsing tests.
- **The template opened as a plain interactive workspace**, not a Task
  (someone debugging the template itself) — `data.coder_task.me.enabled`
  is `false`, `.prompt` is empty; the template must not crash `tofu`-side
  or hang waiting on an empty prompt. Covered by Task 3's `ai_prompt`
  fallback.
- **The relay's own crash/restart losing in-memory dedupe state** — an
  accepted, documented gap (see design doc), but the relay must still
  return `200` to Alertmanager on every webhook regardless of internal
  dedupe/creation failure, otherwise Alertmanager's own webhook retry
  logic compounds the problem. Covered by Task 2's error-handling test.

______________________________________________________________________

### Task 1: RBAC for the Investigate template (`homelab-dev-templates`)

**Files:**

- Create: `templates/Investigate/rbac.tf`

**Interfaces:**

- Consumes: nothing from earlier tasks.

- Produces: a `kubernetes_service_account`, `kubernetes_cluster_role`, and
  `kubernetes_cluster_role_binding` — all **static** (no `count` tied to
  `data.coder_workspace.me.start_count`), so they persist across
  workspace start/stop instead of being deleted every time a Task
  workspace stops (which would race with any other Task instance still
  running). Later tasks (`main.tf`) reference the ServiceAccount by name.

- [ ] **Step 1: Write `templates/Investigate/rbac.tf`**

```hcl
# Static RBAC for every Investigate-template workspace. NOT tied to
# data.coder_workspace.me.start_count — a workspace stopping must not
# delete the ServiceAccount/ClusterRole a still-running sibling Task
# depends on. Deliberately read-only: no pods/exec, no secrets get/list,
# no write verbs anywhere. See docs/design-investigate.md for why
# pods/exec specifically is excluded even though it feels "read-only".

resource "kubernetes_service_account" "investigate" {
  metadata {
    name      = "coder-investigate"
    namespace = "coder"
  }
}

resource "kubernetes_cluster_role" "investigate_readonly" {
  metadata {
    name = "coder-investigate-readonly"
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log", "events", "nodes", "services", "namespaces"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "replicasets", "daemonsets", "statefulsets"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["batch"]
    resources  = ["jobs", "cronjobs"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding" "investigate_readonly" {
  metadata {
    name = "coder-investigate-readonly"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.investigate_readonly.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.investigate.metadata[0].name
    namespace = "coder"
  }
}
```

- [ ] **Step 2: `tofu fmt` and `tofu init` (this task's directory doesn't
  exist as a template yet — create it now with just this file plus a
  minimal `main.tf` stub so `tofu init` has a provider block to work
  with)**

```bash
cd templates/Investigate
cat > main.tf <<'EOF'
terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "2.19.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
  }
}
EOF
tofu fmt -recursive
tofu init -input=false
```

Expected: `OpenTofu has been successfully initialized!` — generates
`templates/Investigate/.terraform.lock.hcl`.

- [ ] **Step 3: `tofu validate`**

```bash
tofu validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Commit via PR**

```bash
cd ~/git/nickvigilante/homelab-dev-templates
git checkout -b investigate-rbac
git add templates/Investigate/rbac.tf templates/Investigate/main.tf templates/Investigate/.terraform.lock.hcl
git commit -m "$(cat <<'EOF'
Add static read-only RBAC for the Investigate template

ServiceAccount + ClusterRole + ClusterRoleBinding, not tied to
workspace start/stop lifecycle. No pods/exec, no secrets access, no
write verbs anywhere -- this is the template's core safety property.

Assisted-by: AI
EOF
)"
git push -u origin investigate-rbac
gh pr create --title "Add read-only RBAC for the Investigate template" --body "$(cat <<'EOF'
## Summary

First piece of the alert-triggered investigator (see
docs/design-investigate.md): static ServiceAccount + ClusterRole +
ClusterRoleBinding, get/list/watch only, no exec, no secrets.

## Testing

- `tofu validate` passes.

---
🤖 Built with AI assistance.
EOF
)"
```

**Do not merge** — leave open per Global Constraints.

______________________________________________________________________

### Task 2: Alertmanager relay service (`homelab-dev-templates`)

**Files:**

- Create: `services/alert-relay/relay.py`
- Create: `services/alert-relay/test_relay.py`
- Create: `services/alert-relay/Dockerfile`
- Create: `services/alert-relay/README.md`

**Interfaces:**

- Consumes: nothing from earlier tasks (independent of Task 1).

- Produces: a container image, built by Task 5's CI, that `homelab`'s
  Task 7 Deployment runs. Environment contract: `CODER_SESSION_TOKEN`
  (required), `CODER_URL` (default `https://coder.vigihome.net`),
  `CODER_TEMPLATE` (default `Investigate`), listens on `:8080`,
  route `POST /alertmanager-webhook`.

- [ ] **Step 1: Write the failing tests**

```python
# services/alert-relay/test_relay.py
import json
import time
import unittest
from unittest.mock import patch, MagicMock

from relay import build_prompt, dedupe_fingerprint, handle_webhook, Dedupe


RESOLVED_PAYLOAD = {
    "receiver": "coder-investigator",
    "status": "resolved",
    "alerts": [
        {
            "status": "resolved",
            "labels": {"alertname": "KubeJobFailed", "severity": "warning"},
            "annotations": {"summary": "Job failed to complete."},
            "startsAt": "2026-09-25T07:30:20.898Z",
            "endsAt": "2026-09-25T23:43:20.898Z",
            "fingerprint": "10c688058232e656",
            "generatorURL": "https://prometheus.vigihome.net/graph?g0.expr=up",
        }
    ],
}

FIRING_PAYLOAD = {
    "receiver": "coder-investigator",
    "status": "firing",
    "alerts": [
        {
            "status": "firing",
            "labels": {"alertname": "ResticBackupStale", "severity": "warning"},
            "annotations": {
                "summary": "Nightly restic backup has not succeeded in over 25h",
                "description": "No successful restic-backup CronJob run in >25h.",
            },
            "startsAt": "2026-09-25T08:31:30.529Z",
            "endsAt": "0001-01-01T00:00:00Z",
            "fingerprint": "aa0842d6093b0fc4",
            "generatorURL": "https://prometheus.vigihome.net/graph?g0.expr=up",
        }
    ],
}

EMPTY_PAYLOAD = {"receiver": "coder-investigator", "status": "firing", "alerts": []}


class BuildPromptTests(unittest.TestCase):
    def test_includes_alertname_and_summary(self):
        prompt = build_prompt(FIRING_PAYLOAD["alerts"][0])
        self.assertIn("ResticBackupStale", prompt)
        self.assertIn("Nightly restic backup has not succeeded", prompt)

    def test_includes_investigate_only_contract(self):
        prompt = build_prompt(FIRING_PAYLOAD["alerts"][0])
        self.assertIn("do not modify", prompt.lower())


class DedupeTests(unittest.TestCase):
    def test_first_seen_is_not_a_duplicate(self):
        d = Dedupe(ttl_seconds=3600)
        self.assertFalse(d.seen_recently("fp1"))

    def test_second_call_within_ttl_is_a_duplicate(self):
        d = Dedupe(ttl_seconds=3600)
        d.seen_recently("fp1")
        self.assertTrue(d.seen_recently("fp1"))

    def test_call_after_ttl_expiry_is_not_a_duplicate(self):
        d = Dedupe(ttl_seconds=0)
        d.seen_recently("fp1")
        time.sleep(0.01)
        self.assertFalse(d.seen_recently("fp1"))


class HandleWebhookTests(unittest.TestCase):
    def setUp(self):
        self.dedupe = Dedupe(ttl_seconds=3600)

    @patch("relay.create_task")
    def test_resolved_alert_does_not_create_a_task(self, mock_create):
        handle_webhook(RESOLVED_PAYLOAD, self.dedupe)
        mock_create.assert_not_called()

    @patch("relay.create_task")
    def test_empty_alerts_list_does_not_crash(self, mock_create):
        handle_webhook(EMPTY_PAYLOAD, self.dedupe)
        mock_create.assert_not_called()

    @patch("relay.create_task")
    def test_firing_alert_creates_exactly_one_task(self, mock_create):
        handle_webhook(FIRING_PAYLOAD, self.dedupe)
        mock_create.assert_called_once()

    @patch("relay.create_task")
    def test_duplicate_fingerprint_within_ttl_creates_only_once(self, mock_create):
        handle_webhook(FIRING_PAYLOAD, self.dedupe)
        handle_webhook(FIRING_PAYLOAD, self.dedupe)
        mock_create.assert_called_once()

    @patch("relay.create_task", side_effect=RuntimeError("coder CLI failed"))
    def test_create_task_failure_does_not_raise(self, mock_create):
        # handle_webhook must swallow this -- the HTTP handler always
        # answers 200 to Alertmanager regardless, so Alertmanager's own
        # retry logic doesn't compound a downstream failure.
        try:
            handle_webhook(FIRING_PAYLOAD, self.dedupe)
        except RuntimeError:
            self.fail("handle_webhook must not propagate create_task errors")


class CreateTaskArgsTests(unittest.TestCase):
    @patch("relay.subprocess.run")
    def test_create_task_never_uses_shell_true(self, mock_run):
        from relay import create_task

        mock_run.return_value = MagicMock(returncode=0, stdout="", stderr="")
        create_task("some prompt with ; rm -rf / in it")
        _, kwargs = mock_run.call_args
        self.assertNotIn("shell", kwargs)
        args = mock_run.call_args[0][0]
        self.assertIsInstance(args, list)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd services/alert-relay
python3 -m pytest test_relay.py -v
```

Expected: `ModuleNotFoundError: No module named 'relay'` (or import
errors for `build_prompt`/`dedupe_fingerprint`/etc.) — `relay.py`
doesn't exist yet.

- [ ] **Step 3: Write `relay.py`**

```python
#!/usr/bin/env python3
"""Alertmanager webhook -> `coder task create` relay.

Deliberately minimal: stdlib only (http.server, json, subprocess), no
web framework. Holds CODER_SESSION_TOKEN; the only thing it does with
alert-derived text is pass it as a single argument to the `coder` CLI,
never through a shell, so a crafted alert label/annotation can't reach
command injection here (see docs/design-investigate.md).
"""
import json
import os
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CODER_URL = os.environ.get("CODER_URL", "https://coder.vigihome.net")
CODER_TEMPLATE = os.environ.get("CODER_TEMPLATE", "Investigate")
DEDUPE_TTL_SECONDS = int(os.environ.get("DEDUPE_TTL_SECONDS", "21600"))  # 6h

INVESTIGATE_ONLY_CONTRACT = (
    "You are investigating a homelab Kubernetes alert. Gather evidence "
    "(kubectl get/describe/logs, and curl to Prometheus/Alertmanager's "
    "in-cluster Service DNS) and write a root-cause report to "
    "~/findings.md. Do NOT modify any cluster state -- your "
    "ServiceAccount has read-only RBAC (no exec, no secrets, no write "
    "verbs) so mutating commands will fail, and that is intentional: "
    "report a suggested fix, do not attempt to apply one."
)


class Dedupe:
    """Fingerprint -> last-seen timestamp, in-memory, TTL-bounded.

    No persistence: a relay restart at worst re-triggers one
    already-firing alert once. See docs/design-investigate.md.
    """

    def __init__(self, ttl_seconds: int):
        self.ttl_seconds = ttl_seconds
        self._seen: dict[str, float] = {}
        self._lock = threading.Lock()

    def seen_recently(self, fingerprint: str) -> bool:
        now = time.monotonic()
        with self._lock:
            last = self._seen.get(fingerprint)
            self._seen[fingerprint] = now
            if last is None:
                return False
            return (now - last) < self.ttl_seconds


def build_prompt(alert: dict) -> str:
    labels = alert.get("labels", {})
    annotations = alert.get("annotations", {})
    lines = [
        INVESTIGATE_ONLY_CONTRACT,
        "",
        f"Alert: {labels.get('alertname', 'unknown')}",
        f"Severity: {labels.get('severity', 'unknown')}",
        f"Started: {alert.get('startsAt', 'unknown')}",
        f"Summary: {annotations.get('summary', '')}",
        f"Description: {annotations.get('description', '')}",
        f"Labels: {json.dumps(labels)}",
        f"Prometheus query: {alert.get('generatorURL', '')}",
    ]
    return "\n".join(lines)


def create_task(prompt: str) -> None:
    result = subprocess.run(
        [
            "coder",
            "task",
            "create",
            "--template",
            CODER_TEMPLATE,
            "--input",
            prompt,
        ],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"coder task create failed: {result.stderr}")


def handle_webhook(payload: dict, dedupe: Dedupe) -> None:
    for alert in payload.get("alerts", []):
        if alert.get("status") != "firing":
            continue
        fingerprint = alert.get("fingerprint", "")
        if fingerprint and dedupe.seen_recently(fingerprint):
            continue
        prompt = build_prompt(alert)
        try:
            create_task(prompt)
        except Exception as exc:  # noqa: BLE001 -- must never propagate
            print(f"create_task failed, continuing: {exc}", flush=True)


class Handler(BaseHTTPRequestHandler):
    dedupe = Dedupe(ttl_seconds=DEDUPE_TTL_SECONDS)

    def do_POST(self):  # noqa: N802 -- BaseHTTPRequestHandler naming
        if self.path != "/alertmanager-webhook":
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            payload = {"alerts": []}
        handle_webhook(payload, self.dedupe)
        self.send_response(200)
        self.end_headers()

    def log_message(self, fmt, *args):  # quieter default access log
        print(f"{self.address_string()} - {fmt % args}", flush=True)


def main():
    if not os.environ.get("CODER_SESSION_TOKEN"):
        raise SystemExit("CODER_SESSION_TOKEN is required")
    server = ThreadingHTTPServer(("0.0.0.0", 8080), Handler)
    print("alert-relay listening on :8080", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run the tests, verify they pass**

```bash
python3 -m pytest test_relay.py -v
```

Expected: all tests `PASS`.

- [ ] **Step 5: Write `Dockerfile`**

```dockerfile
# syntax=docker/dockerfile:1
FROM python:3.13-slim

# Pin the coder CLI install script's target version alongside the
# server -- update in lockstep with templates/Base's own Coder version
# expectations if the server is ever upgraded.
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && curl -fsSL https://coder.vigihome.net/install.sh | sh \
    && apt-get purge -y curl && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY relay.py .

USER 65534:65534
ENTRYPOINT ["python3", "/app/relay.py"]
```

- [ ] **Step 6: Write `README.md`**

```markdown
# alert-relay

Translates Alertmanager `webhook_configs` POSTs into `coder task create`
calls against the `Investigate` template. Stdlib-only Python (no
framework) -- see `docs/design-investigate.md` in this repo for why.

## Environment

- `CODER_SESSION_TOKEN` (required) -- a Coder API token, scoped to
  creating Tasks from the `Investigate` template only if/when Coder
  supports per-token template scoping; otherwise a plain user token,
  stored via `homelab`'s `k8s/coder/external-secret.yaml`-equivalent
  for this service.
- `CODER_URL` (default `https://coder.vigihome.net`)
- `CODER_TEMPLATE` (default `Investigate`)
- `DEDUPE_TTL_SECONDS` (default `21600`, 6h)

## Local testing

\`\`\`bash
python3 -m pytest test_relay.py -v
\`\`\`
```

- [ ] **Step 7: Commit via PR**

```bash
cd ~/git/nickvigilante/homelab-dev-templates
git checkout -b alert-relay-service
git add services/alert-relay
git commit -m "$(cat <<'EOF'
Add the Alertmanager-to-Coder-Task relay service

Stdlib-only Python: parses Alertmanager webhook payloads, dedupes by
alert fingerprint (in-memory, 6h TTL), and shells out to `coder task
create` with the alert text passed as a single argument (never through
a shell) so a crafted alert label/annotation can't reach command
injection.

Assisted-by: AI
EOF
)"
git push -u origin alert-relay-service
gh pr create --title "Add the Alertmanager-to-Coder-Task relay service" --body "$(cat <<'EOF'
## Summary

New `services/alert-relay/`: the piece that turns a firing Alertmanager
alert into a `coder task create` call against the new `Investigate`
template (docs/design-investigate.md).

## Testing

- `python3 -m pytest test_relay.py -v` -- all passing, covers resolved
  vs. firing alerts, empty alert lists, fingerprint dedupe + TTL
  expiry, and that create_task failures never propagate/crash the
  handler.

---
🤖 Built with AI assistance.
EOF
)"
```

**Do not merge.**

______________________________________________________________________

### Task 3: `templates/Investigate/main.tf` — Task-mode Claude Code wiring

**Files:**

- Modify: `templates/Investigate/main.tf`
- Create: `templates/Investigate/modules.tf`
- Create: `templates/Investigate/scripts/report.sh`
- Create: `templates/Investigate/README.md`

**Interfaces:**

- Consumes: `kubernetes_service_account.investigate` from Task 1
  (`rbac.tf`, same directory/state).

- Produces: a `tofu validate`-clean Task-mode template. `coder_ai_task`
  wired to `module.claude-code[0].task_app_id`, per the confirmed-working
  upstream pattern.

- [ ] **Step 1: Replace the `main.tf` stub from Task 1 with the full
  template**

```hcl
terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "2.19.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
  }
}

provider "coder" {}
provider "kubernetes" {}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}
data "coder_task" "me" {}

resource "coder_agent" "main" {
  os             = "linux"
  arch           = "amd64"
  startup_script_behavior = "blocking"
  startup_script = <<-EOT
    set -e
    echo "Investigate workspace ready."
  EOT
}

# Only the Task-mode prompt matters here -- if someone opens this
# template as a plain interactive workspace to iterate on it,
# data.coder_task.me.enabled is false and this falls back to a
# harmless placeholder rather than an empty prompt.
locals {
  task_prompt = data.coder_task.me.enabled ? data.coder_task.me.prompt : "No task prompt was supplied (this workspace was not created as a Coder Task). Describe what to investigate."
}

resource "kubernetes_deployment_v1" "main" {
  count = data.coder_workspace.me.start_count
  metadata {
    name      = "coder-investigate-${data.coder_workspace.me.id}"
    namespace = "coder"
  }
  spec {
    replicas = 1
    selector {
      match_labels = { "coder.workspace" = data.coder_workspace.me.id }
    }
    template {
      metadata {
        labels = { "coder.workspace" = data.coder_workspace.me.id }
      }
      spec {
        service_account_name = "coder-investigate"
        node_selector = {
          "kubernetes.io/arch" = "amd64"
        }
        container {
          name    = "investigate"
          image   = "ghcr.io/nickvigilante/homelab-dev-templates:base-latest"
          command = ["sh", "-c", coder_agent.main.init_script]
          security_context {
            run_as_user = 1000
          }
          resources {
            requests = { cpu = "500m", memory = "1Gi" }
            limits   = { cpu = "2", memory = "4Gi" }
          }
        }
        restart_policy = "Always"
      }
    }
  }
}
```

Note: `image` above reuses the `Base` template's own published base
image (`ghcr.io/nickvigilante/homelab-dev-templates`) rather than
publishing a second one — it already has the tooling (`kubectl`, `curl`)
this template needs, and there's no dotfiles/secrets concern since this
workspace never runs as the user interactively. Confirm the actual
`:base-latest`-equivalent tag convention against what Task 5/6 of
`implementation-plan.md` settled on (short-SHA, not literally
`:latest`) and pin accordingly rather than copying this placeholder tag
verbatim.

- [ ] **Step 2: Write `templates/Investigate/modules.tf`**

```hcl
module "claude-code" {
  count   = data.coder_workspace.me.start_count
  source  = "registry.coder.com/coder/claude-code/coder"
  version = "4.9.2" # NOT 5.x -- v5 dropped Coder Tasks support, see this
                    # plan's header and docs/design-investigate.md.

  agent_id     = coder_agent.main.id
  workdir      = "/home/coder"
  ai_prompt    = local.task_prompt
  report_tasks = data.coder_task.me.enabled

  system_prompt = "You investigate homelab Kubernetes alerts. Never modify cluster state -- your RBAC is read-only by design."

  # Defense in depth on top of read-only RBAC, not a substitute for it --
  # RBAC is what actually stops a mutating call; this just stops Claude
  # Code from trying one that would otherwise merely 403.
  disallowed_tools = join(",", [
    "Write", "Edit",
    "Bash(kubectl apply:*)", "Bash(kubectl delete:*)",
    "Bash(kubectl create:*)", "Bash(kubectl patch:*)",
    "Bash(kubectl edit:*)", "Bash(kubectl exec:*)",
    "Bash(kubectl cordon:*)", "Bash(kubectl drain:*)",
    "Bash(kubectl scale:*)", "Bash(kubectl rollout:*)",
  ])

  post_install_script = file("${path.module}/scripts/report.sh")
}

resource "coder_ai_task" "task" {
  count  = data.coder_task.me.enabled ? data.coder_workspace.me.start_count : 0
  app_id = module.claude-code[0].task_app_id
}
```

- [ ] **Step 3: Write `templates/Investigate/scripts/report.sh`**

```sh
#!/usr/bin/env sh
set -eu

# Runs after Claude Code's own install/session completes. Emails
# ~/findings.md via the smtp-relay secret if Claude Code wrote one --
# mirrors homelab's restic-backup CronJob send_email pattern so there's
# one email-sending recipe in the whole homelab stack, not two.

FINDINGS="$HOME/findings.md"
if [ ! -f "$FINDINGS" ]; then
  echo "No findings.md written; skipping notification email." >&2
  exit 0
fi

if [ -z "${SMTP_HOST:-}" ] || [ -z "${SMTP_USER:-}" ] || [ -z "${SMTP_PASS:-}" ]; then
  echo "SMTP env not populated; skipping notification email." >&2
  exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl not available; skipping notification email." >&2
  exit 0
fi

{
  printf 'From: %s\r\n' "$SMTP_FROM"
  printf 'To: %s\r\n' "$SMTP_TO"
  printf 'Subject: [homelab] Investigate findings: %s\r\n' "${TASK_PROMPT_SUMMARY:-alert}"
  printf 'Date: %s\r\n' "$(date)"
  printf 'MIME-Version: 1.0\r\n'
  printf 'Content-Type: text/plain; charset=UTF-8\r\n'
  printf '\r\n'
  cat "$FINDINGS"
  printf '\r\n'
} | curl -sS --max-time 30 \
    --url "smtps://${SMTP_HOST}:${SMTP_PORT:-465}" \
    --user "$SMTP_USER:$SMTP_PASS" \
    --mail-from "$SMTP_FROM" \
    --mail-rcpt "$SMTP_TO" \
    --upload-file - >/dev/null 2>&1 || echo "email send failed, findings.md is still on disk" >&2
```

`SMTP_*`/`TASK_PROMPT_SUMMARY` env vars come from `coder_env` resources
this task's Step 4 still needs to add (mirroring `smtp-relay`'s
`envFrom` shape) — do not skip that wiring, this script silently no-ops
without it by design (same silent-degrade posture as the restic job's
own `send_email`), which means a missing `coder_env` block is easy to
not notice is missing. Verify by checking a real findings email arrives
during Task 8's live smoke test, not just that `tofu validate` passes.

- [ ] **Step 4: Wire the `smtp-relay` secret into `coder_agent.main` in
  `main.tf`**

```hcl
resource "coder_agent" "main" {
  # ...(as above, unchanged)...
}

resource "coder_env" "smtp_host" {
  agent_id = coder_agent.main.id
  name     = "SMTP_HOST"
  value    = "smtp.forwardemail.net"
}

resource "coder_env" "smtp_to" {
  agent_id = coder_agent.main.id
  name     = "SMTP_TO"
  value    = "vigihome-admin@vigiemail.com"
}
```

`SMTP_USER`/`SMTP_PASS`/`SMTP_FROM` are read from the `smtp-relay`
Kubernetes Secret directly at the pod level (`env_from` on the
container in `kubernetes_deployment_v1.main`, not `coder_env`, since
they're already a K8s Secret and don't need to round-trip through
Coder's own env mechanism):

```hcl
        container {
          # ...(as above)...
          env_from {
            secret_ref {
              name = "smtp-relay"
            }
          }
        }
```

This requires the `smtp-relay` Secret to be reflected into the `coder`
namespace (`homelab`'s existing `emberstack/reflector` annotation on
the source Secret already lists `backup,monitoring` — Task 7 in
`homelab` must add `coder` to that list, or this silently has no SMTP
env and `report.sh` silently no-ops forever).

- [ ] **Step 5: Write `templates/Investigate/README.md`**

```markdown
# Investigate

Read-only Coder Task template. Alertmanager -> the `alert-relay`
service -> `coder task create --template Investigate` -> this template
runs Claude Code non-interactively against the alert prompt, writes
`~/findings.md`, emails it, and the workspace auto-stops.

See `../../docs/design-investigate.md` for the full design and RBAC
rationale.

## Updating

\`\`\`bash
tofu fmt -recursive && tofu validate
coder templates push Investigate --directory . -y
\`\`\`
```

- [ ] **Step 6: `tofu fmt`, `tofu validate`**

```bash
cd templates/Investigate
tofu fmt -recursive
tofu validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 7: Commit via PR**

```bash
cd ~/git/nickvigilante/homelab-dev-templates
git checkout -b investigate-template-core
git add templates/Investigate
git commit -m "$(cat <<'EOF'
Wire the Investigate template's Task-mode Claude Code invocation

Pins the upstream claude-code module to v4.9.2 (the last release with
Coder Tasks support -- v5 dropped it) instead of Base's v5.2.0.
data.coder_task.me.prompt feeds ai_prompt; coder_ai_task wires to the
module's task_app_id output. disallowed_tools is a defense-in-depth
layer on top of the read-only RBAC from the previous PR, not a
substitute for it.

Assisted-by: AI
EOF
)"
git push -u origin investigate-template-core
gh pr create --title "Wire the Investigate template's Task-mode Claude Code invocation" --body "$(cat <<'EOF'
## Summary

Core `templates/Investigate/main.tf` + `modules.tf`: Task-mode wiring
via the upstream claude-code module pinned to v4.9.2 (v5 dropped Tasks
support), coder_ai_task -> module's task_app_id, disallowed_tools as a
second safety layer on top of the read-only RBAC from #<rbac-pr>.

## Testing

- `tofu validate` passes.
- Live smoke test (workspace boots, findings email arrives) happens in
  Task 8 once this and the RBAC/relay PRs are all mergeable together.

---
🤖 Built with AI assistance.
EOF
)"
```

**Do not merge.**

______________________________________________________________________

### Task 4: CI — extend `lint.yml`, add `alert-relay-image-build.yml`

**Files:**

- Modify: `.github/workflows/lint.yml`
- Create: `.github/workflows/alert-relay-image-build.yml`

**Interfaces:**

- Consumes: `services/alert-relay/` from Task 2, `templates/Investigate/`
  from Tasks 1 and 3.

- Produces: `lint` (existing required check) now also validates
  `templates/Investigate` and runs the relay's `pytest`; a new,
  path-filtered (not required) `alert-relay-image-build` workflow
  publishing `ghcr.io/nickvigilante/homelab-dev-templates-alert-relay`.

- [ ] **Step 1: Add a second `tofu validate` step and the relay's tests
  to `lint.yml`**

In `.github/workflows/lint.yml`, after the existing `tofu validate (templates/Base)` step, add:

```yaml
      - name: tofu validate (templates/Investigate)
        working-directory: templates/Investigate
        run: |
          tofu init -input=false
          tofu validate
      - name: relay unit tests
        working-directory: services/alert-relay
        run: python3 -m pytest test_relay.py -v
```

- [ ] **Step 2: Write `.github/workflows/alert-relay-image-build.yml`**

Mirror `images/base`'s `image-build.yml` shape exactly, but single-arch
(amd64 only -- this runs on gandalf, not the Pi nodes) and a different
path filter/image name:

```yaml
name: alert-relay-image-build

on:
  pull_request:
    branches: [main]
  push:
    branches: [main]

permissions:
  contents: read
  packages: write

jobs:
  changes:
    runs-on: ubuntu-latest
    outputs:
      image: ${{ steps.filter.outputs.image }}
    steps:
      - uses: actions/checkout@v4
      - uses: dorny/paths-filter@v3
        id: filter
        with:
          filters: |
            image:
              - 'services/alert-relay/**'
              - '.github/workflows/alert-relay-image-build.yml'

  validate:
    name: validate (build only)
    needs: changes
    if: needs.changes.outputs.image == 'true'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/build-push-action@v6
        with:
          context: services/alert-relay
          push: false
          tags: alert-relay:pr-validate

  publish:
    name: publish (main only)
    needs: changes
    if: github.event_name == 'push' && needs.changes.outputs.image == 'true'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/build-push-action@v6
        with:
          context: services/alert-relay
          push: true
          tags: |
            ghcr.io/nickvigilante/homelab-dev-templates-alert-relay:${{ github.sha }}
            ghcr.io/nickvigilante/homelab-dev-templates-alert-relay:latest
```

This is path-filtered — **must not** become a required branch-protection
check, same trap `design.md` already documents for `image-build.yml`.

- [ ] **Step 3: Commit via PR**

```bash
cd ~/git/nickvigilante/homelab-dev-templates
git checkout -b investigate-ci
git add .github/workflows/lint.yml .github/workflows/alert-relay-image-build.yml
git commit -m "$(cat <<'EOF'
Extend CI for the Investigate template and alert-relay image

lint.yml now also validates templates/Investigate and runs the relay's
pytest suite. New path-filtered alert-relay-image-build.yml publishes
the relay image to GHCR on merge, single-arch (amd64 only).

Assisted-by: AI
EOF
)"
git push -u origin investigate-ci
gh pr create --title "Extend CI for the Investigate template and alert-relay image" --body "$(cat <<'EOF'
## Summary

- `lint.yml`: adds `tofu validate` for `templates/Investigate` and the
  relay's `pytest` suite.
- New `alert-relay-image-build.yml`: path-filtered, publishes
  `ghcr.io/nickvigilante/homelab-dev-templates-alert-relay` on merge.
  Not a required check (same path-filter trap as `image-build.yml`).

## Testing

- Confirm this PR's own `lint` check goes green.

---
🤖 Built with AI assistance.
EOF
)"
```

**Do not merge.**

______________________________________________________________________

### Task 5: Alertmanager receiver + relay manifests (`homelab`)

**Files:**

- Modify: `k8s/kube-prometheus-stack/values.yaml`
- Create: `k8s/coder/relay-deployment.yaml`
- Create: `k8s/coder/relay-service.yaml`
- Create: `k8s/coder/relay-external-secret.yaml`
- Modify: `k8s/coder/kustomization.yaml`
- Modify: `k8s/authentik/external-secret.yaml` or wherever `smtp-relay`'s
  reflection-auto-namespaces annotation lives (found in Task 3's Step 4
  note above) to add `coder` to the reflected namespace list.

**Interfaces:**

- Consumes: `ghcr.io/nickvigilante/homelab-dev-templates-alert-relay`
  image (Task 4's CI, once merged and run at least once).

- Produces: the relay running in the `coder` namespace, reachable at
  `alert-relay.coder.svc.cluster.local:8080`; Alertmanager configured
  to POST there.

- [ ] **Step 1: Add the `coder-investigator` receiver + route to
  `k8s/kube-prometheus-stack/values.yaml`**

Alongside the existing `email` receiver and the `InfoInhibitor`/
`Watchdog` route overrides (this plan assumes the exact surrounding
YAML this task edits — read the file's current `alertmanager.config`
block before editing rather than guessing indentation):

```yaml
      routes:
        - matchers: ['alertname = "InfoInhibitor"']
          receiver: "null"
        - matchers: ['alertname = "Watchdog"']
          receiver: email
          repeat_interval: 24h
        - matchers: ['alertname != "InfoInhibitor"', 'alertname != "Watchdog"']
          receiver: coder-investigator
          continue: true # also still hits the default "email" receiver
    receivers:
      - name: "null"
      - name: email
        email_configs:
          - to: vigihome-admin@vigiemail.com
            from: noreply@vigihome.net
      - name: coder-investigator
        webhook_configs:
          - url: http://alert-relay.coder.svc.cluster.local:8080/alertmanager-webhook
            send_resolved: false
```

`continue: true` on the new route means alerts still also reach the
existing default `email` receiver rather than replacing it — matching
the design doc's "route on everything, dedupe downstream" decision
without silently dropping the existing email notifications on the
floor.

- [ ] **Step 2: Write `k8s/coder/relay-deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: alert-relay
  namespace: coder
spec:
  replicas: 1
  selector:
    matchLabels:
      app: alert-relay
  template:
    metadata:
      labels:
        app: alert-relay
    spec:
      containers:
        - name: alert-relay
          image: ghcr.io/nickvigilante/homelab-dev-templates-alert-relay:latest # pin to a short-SHA tag once Task 4's CI has published one
          ports:
            - containerPort: 8080
          envFrom:
            - secretRef:
                name: alert-relay-coder-token
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits: { cpu: 200m, memory: 256Mi }
```

- [ ] **Step 3: Write `k8s/coder/relay-service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: alert-relay
  namespace: coder
spec:
  selector:
    app: alert-relay
  ports:
    - port: 8080
      targetPort: 8080
```

- [ ] **Step 4: Write `k8s/coder/relay-external-secret.yaml`**

```yaml
# CODER_SESSION_TOKEN for the alert-relay service. Source of truth:
# Bitwarden item TBD (see docs/design-investigate.md "Decisions needing
# your sign-off" #3 in homelab-dev-templates) -- placeholder key below
# until that item exists; do not merge this PR until it's replaced with
# the real Bitwarden item UUID, same convention as every other
# ExternalSecret in this repo (restic-credentials, grafana-mcp-token).
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: alert-relay-coder-token
  namespace: coder
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: bitwarden
    kind: ClusterSecretStore
  target:
    name: alert-relay-coder-token
    creationPolicy: Owner
  data:
    - secretKey: CODER_SESSION_TOKEN
      remoteRef:
        key: REPLACE_WITH_BITWARDEN_ITEM_UUID # gitleaks:allow
```

- [ ] **Step 5: Add the three new files to `k8s/coder/kustomization.yaml`
  and add `coder` to `smtp-relay`'s reflection-auto-namespaces**

Read both files first (this plan doesn't reproduce their current full
contents) and make the minimal edit: append
`relay-deployment.yaml`/`relay-service.yaml`/
`relay-external-secret.yaml` to `kustomization.yaml`'s `resources:`
list, and add `,coder` to the `reflection-auto-namespaces` annotation
value wherever `smtp-relay`'s Secret is defined.

- [ ] **Step 6: `kustomize build` locally to confirm it renders**

```bash
cd k8s/coder
kubectl kustomize . > /dev/null && echo OK
```

Expected: `OK`, no errors.

- [ ] **Step 7: Commit via PR**

```bash
cd ~/git/nickvigilante/homelab
git checkout -b coder-alert-relay
git add k8s/kube-prometheus-stack/values.yaml k8s/coder/relay-deployment.yaml k8s/coder/relay-service.yaml k8s/coder/relay-external-secret.yaml k8s/coder/kustomization.yaml
# plus whatever file the smtp-relay reflection-auto-namespaces edit touched
git commit -m "$(cat <<'EOF'
Add the alert-relay Deployment and wire an Alertmanager receiver to it

New coder-investigator Alertmanager receiver (continue: true, so the
existing email receiver still also fires) posts to alert-relay's
in-cluster Service. Relay reads CODER_SESSION_TOKEN via a new
ExternalSecret against the bitwarden ClusterSecretStore, matching
restic-credentials/grafana-mcp-token's existing shape.

Companion to homelab-dev-templates' Investigate template and
alert-relay service (see that repo's docs/design-investigate.md).

Assisted-by: AI
EOF
)"
git push -u origin coder-alert-relay
gh pr create --title "Add the alert-relay Deployment and Alertmanager receiver" --body "$(cat <<'EOF'
## Summary

Wires Alertmanager to the new alert-relay service (companion PRs in
homelab-dev-templates). New coder-investigator receiver keeps
`continue: true` so existing email alerting is unaffected.

## Testing

- `kubectl kustomize k8s/coder` renders cleanly.
- Needs a real Bitwarden item + UUID before merge -- see the
  REPLACE_WITH_BITWARDEN_ITEM_UUID placeholder in
  relay-external-secret.yaml.

---
🤖 Built with AI assistance.
EOF
)"
```

**Do not merge** — this one especially: it changes live Alertmanager
routing and needs the real Bitwarden secret in place first (Task 6).

______________________________________________________________________

### Task 6: Create the Coder API token + Bitwarden item

**Files:** none (infra step, not a code change).

**Interfaces:**

- Consumes: nothing.

- Produces: a live Coder API token, stored in Bitwarden, referenced by
  Task 5's `relay-external-secret.yaml` `remoteRef.key`.

- [ ] **Step 1: Create the token**

```bash
export KUBECONFIG=~/.kube/config
coder tokens create --name alert-relay --lifetime 8760h
```

Copy the printed token — shown once.

- [ ] **Step 2: Store it in Bitwarden**

Create a new item (name matching whatever the user confirms per the
design doc's open item #3 — default to `Homelab Coder Alert Relay` if
no response by the time this task runs) with one field,
`CODER_SESSION_TOKEN`, holding the token from Step 1.

- [ ] **Step 3: Update `relay-external-secret.yaml`'s `REPLACE_WITH_ BITWARDEN_ITEM_UUID` placeholder with the real item UUID**, as its own
  small commit on the Task 5 branch (not a separate PR — same branch,
  since the ExternalSecret is meaningless without it).

**This task requires interactive `bw` unlock** (per the user's own
`bw sync after unlock` memory) — flag it explicitly rather than
attempting it silently if `bw` isn't already unlocked in the session
that executes this plan.

______________________________________________________________________

### Task 7: Live smoke test (once Tasks 1–6 are all reviewed and merged)

**Files:** none.

**Interfaces:**

- Consumes: every earlier task, merged.

- [ ] **Step 1: Push the template live**

```bash
export KUBECONFIG=~/.kube/config
cd templates/Investigate
coder templates push Investigate --directory . -y
```

- [ ] **Step 2: Trigger a real alert** (reuse the still-real
  `ResticBackupStale`/`KubeJobFailed` alerts from the 2026-09-25
  incident if either is still resolvable-and-refirable, or use
  `amtool alert add` / a synthetic test alert against the live
  Alertmanager) and confirm:

  - the relay logs show a `coder task create` call
  - a new workspace appears in the Coder dashboard
  - `~/findings.md` gets written
  - the notification email arrives at `vigihome-admin@vigiemail.com`

- [ ] **Step 3: Confirm the read-only contract holds** — from the new
  workspace's shell (or its Claude Code transcript), attempt (as a
  manual check, not something the agent does unprompted)
  `kubectl delete pod -n default anything` and confirm it's rejected
  with a `Forbidden` RBAC error, not merely discouraged by
  `disallowed_tools`.

- [ ] **Step 4: Report results back to the user** — this is the
  hand-back point; do not consider the feature "done" until a human has
  seen a real findings email land in their inbox.

## Self-review notes

- **Spec coverage:** RBAC (Task 1), relay + dedupe + injection-safety
  (Task 2), Task-mode template + report/email (Task 3), CI for both
  (Task 4), Alertmanager wiring + relay manifests + secrets (Tasks 5–6),
  live verification (Task 7). Every "Decisions locked in" bullet in the
  design doc maps to a task above.
- **Open items carried forward, not silently resolved:** the design
  doc's sign-off items #1 (namespace: resolved here as `coder`, but
  flagged again in Task 5), #3 (Bitwarden naming, Task 6), and #4
  (NetworkPolicy risk — not testable ahead of time given the
  intentionally-narrow RBAC; Task 7's live smoke test is where this
  actually gets proven, not assumed).
- **Type/interface consistency:** `Dedupe.seen_recently`, `build_prompt`,
  `create_task`, `handle_webhook` names match between Task 2's tests and
  implementation. `coder_ai_task.task.app_id` references
  `module.claude-code[0].task_app_id`, matching the upstream module's
  actual output name (confirmed against the real v4.9.2 source, not
  guessed).
