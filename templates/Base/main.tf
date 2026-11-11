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
