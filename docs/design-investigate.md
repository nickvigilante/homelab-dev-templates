# Alert-triggered investigator — design

**Goal:** when a real Alertmanager alert fires on the homelab k3s cluster,
automatically spin up a Coder Task running Claude Code, pre-loaded with the
alert's details, so a read-only investigation (root cause, evidence, a
suggested fix) is already written up by the time a human looks at it —
instead of the human doing that triage cold, as happened on 2026-09-25 with
the restic-backup stale-lock incident.

**Status:** design drafted 2026-09-26, authored solo while the user was AFK
per their explicit instruction to use best judgment and record decisions —
see "Decisions needing your sign-off" at the end. Not yet reviewed by the
user, not yet implemented.

**Related:** [`design.md`](design.md) (the `Base` template this builds
next to, not on top of), tonight's restic-backup incident (Alertmanager
alerts `KubeJobFailed` / `ResticBackupStale`, fixed manually this session).

## Context

Tonight's incident followed a familiar shape: an alert fires, sits until a
human notices it (here, until the user asked "investigate the alerts"), then
30+ minutes of `kubectl`/`restic`/Alertmanager-API archaeology to find and
fix a stale repository lock. The user's own idea, stated mid-incident: wire
Alertmanager to a Coder template so a Claude Code agent starts that
investigation itself, immediately, unattended.

This is new scope, not covered by [`design.md`](design.md) or
[`implementation-plan.md`](implementation-plan.md) — those two documents are
about the `Base` dev-workspace template and its image, explicitly scoped to
that alone.

## Decisions locked in (this design)

- **Scope: investigate + report only.** The agent never mutates cluster
  state. It gathers evidence, writes findings and a suggested fix, and
  notifies the user — the same shape as tonight's investigation phase, not
  the remediation phase. (User's explicit answer during brainstorming.)
- **New template, not an extension of `Base`.** `templates/Investigate/`,
  separate from `templates/Base/`. Reusing `Base` would inherit its broader
  dev-workspace permissions; a purpose-built template lets RBAC start from
  nothing and add only what read-only investigation needs.
- **Mechanism: Coder Tasks (`coder_ai_task` + `data.coder_task`), not
  `coder_external_agent`.** Confirmed against the *actual* installed
  provider schema (`registry.opentofu.org/coder/coder` v2.19.0, matching the
  live server's v2.37.0), not just docs, since the docs site describes
  `coder_ai_task` as deprecated-in-favor-of-"Coder Agents" starting v2.34 —
  language that coincidentally matches the user's own phrase, which briefly
  suggested `coder_external_agent` was the intended replacement. It isn't
  the right fit here: `coder_external_agent` connects an agent process
  running *outside* the Coder-provisioned pod, and it requires a Premium
  license feature (`workspace_external_agent`, confirmed entitled+enabled on
  this deployment, but still the wrong shape for "spin up a fresh in-cluster
  workspace per alert"). `coder_ai_task` is exactly the "create a workspace
  from a prompt" primitive, is present and non-deprecated in the pinned
  provider version, and is what `data.coder_task.me.prompt` (also present)
  is designed to feed.
- **RBAC: read-only, and deliberately narrower than what I used tonight.**
  Cluster-scoped `get`/`list`/`watch` on pods, deployments, jobs, cronjobs,
  events, nodes, services — but **no `pods/exec`, no `secrets` get.**
  Tonight's investigation used `kubectl exec` (to run diagnostic restic
  commands in throwaway pods) and read a Secret's decoded values directly.
  Granting `pods/exec` to an unattended template is not actually "read-only"
  — exec access to any pod is equivalent to whatever that pod's own
  privileges allow, which is a much larger blast radius than viewing
  objects. The investigator instead reaches Prometheus/Alertmanager over
  their in-cluster Service DNS directly (`kps-kube-prometheus-stack- prometheus.monitoring.svc:9090`, `...-alertmanager...:9093`), which needs
  no RBAC at all, just network reachability, already true for any in-cluster
  pod. This does mean the investigator can't reproduce every step of
  tonight's restic-specific diagnosis (e.g. checking repository locks needs
  restic credentials it deliberately isn't given) — it reports "likely a
  stale restic lock; run `restic unlock`, then re-run the job" rather than
  confirming and fixing it. That's the intended shape for "investigate and
  report only," not a gap.
- **Report-out: findings file in the workspace + email, both.** A markdown
  findings file written to the workspace's persistent home volume (durable,
  browsable later via Coder's file viewer/VS Code even after the workspace
  auto-stops) *and* an email via the existing `smtp-relay` secret, mirroring
  the `send_email` pattern already in `homelab`'s `restic-backup`
  CronJob — same recipient (`vigihome-admin@vigiemail.com`), no new
  notification channel to build or maintain.
- **Trigger path: Alertmanager `webhook_configs` → a small relay service →
  `coder task create`.** Alertmanager can't itself transform a firing alert
  into a Coder API call; something has to sit in between. Kept as small as
  possible (see "Relay service" below) rather than reaching for an
  orchestration tool like Argo Events — this is a single translation step,
  not a workflow engine's job.
- **Relay implementation: Python stdlib `http.server`, no framework.** The
  whole job is "parse Alertmanager's webhook JSON, build a prompt, shell out
  to the `coder` CLI (or hit its REST API), dedupe by alert fingerprint."
  That doesn't need Flask/FastAPI, and a security-sensitive service holding
  a live Coder API token is exactly the kind of thing that benefits from
  having the smallest, most auditable dependency footprint possible.
- **Relay repo placement: code + image in `homelab-dev-templates`, manifests
  in `homelab`.** `homelab` has no precedent for building custom container
  images (confirmed: no Dockerfile anywhere in that repo; every app is a
  Helm chart or plain manifests against off-the-shelf images).
  `homelab-dev-templates` already has the `images/base` → GHCR → CI pattern
  this needs. The relay's Kubernetes Deployment/Service/ExternalSecret,
  though, are cluster state Flux reconciles from `homelab`, matching every
  other in-cluster app there.
- **Secrets: `ExternalSecret` + the `bitwarden` `ClusterSecretStore`, not
  the older manual `kubectl create secret` pattern.** `authentik`/
  `smtp-relay`/`restic-credentials` predate the external-secrets operator
  and still use the manual pattern; `restic-credentials`, `requesty-sync`,
  `grafana-mcp-token`, `claude-mcp` already use `ExternalSecret` against the
  `bitwarden` store — the newer, self-syncing default for anything created
  from here on. The relay's `CODER_SESSION_TOKEN` follows that newer
  pattern: one Bitwarden item, one `ExternalSecret`, no manual
  `kubectl create secret` step to remember on rotation.
- **Alert routing: everything except the two already-null-routed alerts,
  deduped by fingerprint.** Route on the default receiver (matching
  `InfoInhibitor`'s and `Watchdog`'s existing overrides, which stay
  null/email-only respectively) rather than hand-picking alert names —
  otherwise every new alert added later needs a matching relay-route
  update too, which will be forgotten. The relay itself, not Alertmanager,
  dedupes by alert fingerprint with a TTL (proposed: 6h) so a long-firing
  alert doesn't spawn a fresh investigator workspace on every renotify
  cycle — Alertmanager's own `repeat_interval` (4h, cluster-wide) is a
  weaker guarantee here since it governs renotification of the *receiver*,
  not idempotency of *this specific side effect*.

## Architecture

```
Alertmanager (existing "email" receiver stays; new "coder-investigator"
receiver added, webhook_configs pointing in-cluster)
        │ POST alert JSON
        ▼
relay service (new: Deployment + Service, namespace TBD — see open
items)  — parses payload, dedupes by fingerprint (in-memory + TTL,
single replica, homelab-scale — a restart losing dedupe state just
risks one duplicate investigation, not a correctness bug worth solving
harder than that)
        │ `coder task create --template Investigate --input <prompt>`
        │ (exact CLI/API shape: implementation-time spike, see below)
        ▼
Coder: new Task-mode workspace from templates/Investigate/
        │ data.coder_task.me.prompt → fed into `claude -p "<prompt>"`
        │ (non-interactive, one-shot; read-only kubeconfig + curl access
        │ to Prometheus/Alertmanager Services)
        ▼
findings.md written to workspace home + email sent via smtp-relay
        (workspace auto-stops per Task lifecycle once the run completes)
```

## Template (`templates/Investigate/`)

- `data "coder_task" "me" {}` — reads `.prompt` (the alert-derived prompt
  the relay supplied) and `.enabled` (true only when created as a Task,
  false if someone opens this template as a plain workspace to iterate on
  it — in that case fall back to a placeholder prompt like "no task prompt;
  describe what to investigate").
- `resource "coder_ai_task"` with `app_id` referencing a `coder_app` this
  template defines for the sidebar/status UI. The `Base` template's vendored
  `claude-code` module (pinned v5.2.0) does **not** create a `coder_app` or
  wire AgentAPI at all — it only installs the Claude Code CLI via
  `coder-utils`' generic script runner. Whether a newer `claude-code` module
  version on the registry already wires the `coder_app`+AgentAPI+
  `coder_ai_task` combination end-to-end, or whether this template needs to
  hand-write a `coder_app` (e.g. backed by a small status/log-tail HTTP
  endpoint) is **not decided here** — flagged as an implementation-time
  spike, not a design gap glossed over. Same posture `design.md` already
  takes with `startup.sh` runtime-arch-detection: "a real design fork,
  deliberately left to implementation time."
- Kubernetes pod spec: dedicated `ServiceAccount` bound to a new read-only
  `ClusterRole` (see RBAC above), **not** the identity `Base` workspaces run
  as. `node_selector: kubernetes.io/arch: amd64` carried forward from `Base`
  (same cluster, same constraint — the base image is amd64/arm64 multi-arch
  but there's no reason yet to prove the investigator boots on the Pi
  nodes).
- Non-interactive invocation: a `coder_script` (`run_on_start`) that, when
  `data.coder_task.me.enabled`, runs `claude -p "$TASK_PROMPT" --output- format ...` once, writes `~/findings.md`, then sends the email (reusing
  the `smtp-relay` secret via `envFrom`, same `curl --url smtps://...`
  one-liner already proven in the `restic-backup` CronJob) and exits —
  no long-lived interactive chat session for this template, unlike `Base`.
- No dotfiles/rtk/general dev tooling baked in — this template forks from a
  minimal base (could still be the same `images/base` GHCR image, just
  without the dev-workspace expectations `Base`'s parameters imply), since
  its only job is running Claude Code against read-only cluster/Prometheus
  access.

## Relay service

- Single `net/http`-equivalent Python process (stdlib `http.server` +
  `json`), one route (`POST /alertmanager-webhook`), holds
  `CODER_SESSION_TOKEN` and shells out to the `coder` CLI (already the
  pattern `template-push.yml`'s design uses) rather than hand-rolling REST
  calls, so it inherits the CLI's own auth/retry/error handling.
- Fingerprint dedupe: an in-memory dict, alert fingerprint → last-triggered
  timestamp, TTL 6h, no persistence — a relay restart at worst re-triggers
  one already-firing alert once, not a correctness problem worth adding a
  PVC/database for.
- Prompt construction: alertname, labels, annotations (`description`,
  `summary`), `startsAt`, `generatorURL`, plus a fixed preamble describing
  the cluster (nodes, namespaces of interest, the "investigate and report,
  never mutate" contract, and where to write findings/send email).
- Image: `images/alert-relay/Dockerfile` in `homelab-dev-templates`
  (installs the `coder` CLI + Python, copies the relay script), published to
  GHCR via the same `image-build.yml` pattern as `images/base`, pinned by
  SHA in the `homelab` repo's Deployment manifest — matching the pinning
  discipline `design.md` already established for the base image.

## Alertmanager wiring (`homelab` repo)

- `k8s/kube-prometheus-stack/values.yaml`: add a `coder-investigator`
  receiver (`webhook_configs`, URL = the relay's in-cluster Service DNS),
  and a route entry alongside the existing `InfoInhibitor`/`Watchdog`
  overrides so it fires on everything else, matching the "route on
  everything, dedupe downstream" decision above.
- New `k8s/coder-alert-relay/` directory: `deployment.yaml`, `service.yaml`,
  `external-secret.yaml` (the `CODER_SESSION_TOKEN`, `ExternalSecret` +
  `bitwarden` `ClusterSecretStore`, mirroring `restic-credentials`'s shape),
  `kustomization.yaml`, `README.md` — one folder per app, matching every
  other directory under `k8s/`.

## Secrets

- New Bitwarden item (name TBD, e.g. `Homelab Coder Alert Relay`), one
  field: a Coder API token. Created via
  `coder tokens create --name alert-relay --lifetime 8760h` (same command
  shape `implementation-plan.md` Task 7 already uses for
  `CODER_SESSION_TOKEN`, just a second, narrower-scoped token rather than
  reusing CI's).
- `ExternalSecret` in `k8s/coder-alert-relay/external-secret.yaml`,
  `secretStoreRef: bitwarden`/`ClusterSecretStore`, one `remoteRef` key,
  same shape as `grafana-mcp-token`/`restic-credentials`.

## Deferred / explicitly out of scope

- Any remediation capability (the "investigate + apply safe fixes" or "full
  autonomy" options the user explicitly declined this round). Could be a
  later iteration once the investigate-only path has proven itself.
- Slack/Discord/other notification channels — email only, reusing existing
  infra.
- Persisting relay dedupe state across restarts.
- Making the investigator boot on the arm64 Pi nodes.
- A UI/dashboard for browsing past investigations beyond what Coder's own
  Task history already provides.

## Decisions needing your sign-off

Recorded per your instruction, rather than blocking on them tonight:

1. **Which namespace hosts the relay Deployment** — `coder` (colocated with
   Coder itself) vs. a new dedicated namespace. Leaning `coder`, since the
   relay only exists to talk to Coder's API; no strong reason for a new
   namespace, but it's your call.
2. **The exact `coder_ai_task`/`coder_app` wiring** (see "Template" above)
   is a real open technical question, not just an unstated preference —
   I'll resolve it during implementation by checking the current
   `claude-code` module registry versions and the live provider schema
   directly (as I did to ground this doc), and will note here what I found
   and chose.
3. **Bitwarden item naming** for the relay's token — I used a placeholder
   above; happy to match whatever naming convention you'd prefer alongside
   `Homelab Coder`, `Homelab Restic Repository`, etc.
4. **Whether `coder` should live in the `coder` namespace's own
   Alertmanager-reachable network path**, or whether a `NetworkPolicy`
   currently restricts pod-to-pod traffic in ways that would block the
   relay from reaching Alertmanager's webhook, or the investigator
   workspace from reaching Prometheus/Alertmanager — I haven't found any
   `NetworkPolicy` objects in the cluster yet, but haven't exhaustively
   ruled them out either, since the read-only RBAC this template gets won't
   let it read `NetworkPolicy` objects if a genuinely locked-down one exists
   in a namespace the investigator can't otherwise see into either.
5. **Final review before anything goes live.** I'll open every change as a
   PR (this repo and `homelab`, matching branch protection in both), but
   won't merge, won't run `coder templates push` against the live
   deployment, and won't let the Alertmanager receiver change reach the
   live cluster without you reviewing it first — those are exactly the
   "affects a live/shared system" actions I hold for your sign-off by
   default, distinct from the design/implementation judgment calls above.
