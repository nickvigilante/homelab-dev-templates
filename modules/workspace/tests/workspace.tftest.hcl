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
