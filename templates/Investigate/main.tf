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

# Only the Task-mode prompt matters here -- if someone opens this
# template as a plain interactive workspace to iterate on it,
# data.coder_task.me.enabled is false and this falls back to a
# harmless placeholder rather than an empty prompt.
locals {
  task_prompt = data.coder_task.me.enabled ? data.coder_task.me.prompt : "No task prompt was supplied (this workspace was not created as a Coder Task). Describe what to investigate."
}

resource "coder_agent" "main" {
  os                      = "linux"
  arch                    = "amd64"
  startup_script_behavior = "blocking"
  startup_script          = <<-EOT
    set -e
    echo "Investigate workspace ready."
  EOT
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
          image   = "ghcr.io/nickvigilante/homelab-dev-templates:base-latest" # TODO: pin to the same short-SHA tag templates/Base uses, see this template's README
          command = ["sh", "-c", coder_agent.main.init_script]
          security_context {
            run_as_user = 1000
          }
          resources {
            requests = { cpu = "500m", memory = "1Gi" }
            limits   = { cpu = "2", memory = "4Gi" }
          }
          env_from {
            secret_ref {
              name = "smtp-relay"
            }
          }
        }
        restart_policy = "Always"
      }
    }
  }
}
