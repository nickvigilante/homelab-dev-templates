module "claude-code" {
  count   = data.coder_workspace.me.start_count
  source  = "registry.coder.com/coder/claude-code/coder"
  version = "4.9.2" # NOT 5.x -- v5 dropped Coder Tasks support, see this
  # template's README and docs/design-investigate.md.

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
