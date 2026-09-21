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

# Git identity for the dotfiles' generated ~/.gitconfig. Deliberately template
# parameters rather than coder_workspace_owner data: the owner record carries
# the Coder account email, and substituting it would silently change the
# identity on every commit made from a workspace.
#
# Immutable because it is only read once. chezmoi's promptStringOnce caches the
# answer in ~/.config/chezmoi/chezmoi.toml on the home volume, so a later edit
# here would change nothing and only mislead. Fix a typo with
# `chezmoi edit-config`.
data "coder_parameter" "git_name" {
  name         = "git_name"
  display_name = "Git author name"
  description  = "Written to your git config on first start, then cached on the home volume."
  type         = "string"
  icon         = "/icon/git.svg"
  mutable      = false
}

data "coder_parameter" "git_email" {
  name         = "git_email"
  display_name = "Git author email"
  description  = "Written to your git config on first start. A GitHub noreply address keeps your real one out of commit metadata."
  type         = "string"
  icon         = "/icon/git.svg"
  mutable      = false
  # The empty alternative is load-bearing. Importing a template runs a plan
  # with every parameter at its default, and this one has no default, so it
  # evaluates as "" during import. A regex that rejects "" therefore fails the
  # import itself and the template cannot be pushed at all.
  #
  # Having no default still makes the parameter required when a workspace is
  # created, so an empty value cannot be chosen there -- only reached by the
  # import-time plan, which never builds anything.
  validation {
    regex = "^$|^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$"
    error = "Enter an email address, e.g. you@users.noreply.github.com."
  }
}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

resource "coder_agent" "main" {
  os   = "linux"
  arch = "amd64"

  # Read by dotfiles.sh (coder_script.dotfiles) on the workspace's first start
  # only.
  env = {
    DOTFILES_GIT_NAME  = data.coder_parameter.git_name.value
    DOTFILES_GIT_EMAIL = data.coder_parameter.git_email.value
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

resource "kubernetes_persistent_volume_claim_v1" "home" {
  metadata {
    name      = "coder-${data.coder_workspace.me.id}-home"
    namespace = "coder"
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
        storage = "${data.coder_parameter.home_disk_size.value}Gi"
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
    namespace = "coder"
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

        security_context {
          run_as_user     = 1000
          fs_group        = 1000
          run_as_non_root = true
        }

        container {
          name              = "dev"
          image             = "ghcr.io/nickvigilante/homelab-dev-templates:c4c96c8988a5300e875db67cf953bb3e62efcb68"
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
              "cpu"    = "${data.coder_parameter.cpu.value}"
              "memory" = "${data.coder_parameter.memory.value}Gi"
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
