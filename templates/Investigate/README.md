# Investigate

Read-only Coder Task template.
Alertmanager → the `alert-relay` service → `coder task create --template Investigate` → this template runs Claude Code non-interactively against
the alert prompt, writes `~/findings.md`, emails it, and the workspace
auto-stops.

The upstream `claude-code` module is pinned to **v4.9.2**, not the `Base`
template's v5.2.0 — v5's own changelog states it "drops support for Coder
Tasks."
v4.9.2 is the newest release that still wires `ai_prompt` /
`report_tasks` through to AgentAPI and exposes `task_app_id`, which
`coder_ai_task` needs.

See [`../../docs/design-investigate.md`](../../docs/design-investigate.md)
for the full design and RBAC rationale.

## Updating

```bash
tofu fmt -recursive && tofu validate
coder templates push Investigate --directory . -y
```
