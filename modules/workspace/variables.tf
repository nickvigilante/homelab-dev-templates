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
