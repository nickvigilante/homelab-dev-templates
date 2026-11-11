terraform {
  # The claude-code module requires 1.9; Coder's provisioner runs 1.15.
  required_version = ">= 1.9"

  required_providers {
    coder = {
      source = "coder/coder"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}
