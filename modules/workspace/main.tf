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
