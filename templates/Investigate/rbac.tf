# Static RBAC for every Investigate-template workspace. NOT tied to
# data.coder_workspace.me.start_count -- a workspace stopping must not
# delete the ServiceAccount/ClusterRole a still-running sibling Task
# depends on. Deliberately read-only: no pods/exec, no secrets get/list,
# no write verbs anywhere. See docs/design-investigate.md for why
# pods/exec specifically is excluded even though it feels "read-only".

resource "kubernetes_service_account" "investigate" {
  metadata {
    name      = "coder-investigate"
    namespace = "coder"
  }
}

resource "kubernetes_cluster_role" "investigate_readonly" {
  metadata {
    name = "coder-investigate-readonly"
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log", "events", "nodes", "services", "namespaces"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "replicasets", "daemonsets", "statefulsets"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["batch"]
    resources  = ["jobs", "cronjobs"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding" "investigate_readonly" {
  metadata {
    name = "coder-investigate-readonly"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.investigate_readonly.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.investigate.metadata[0].name
    namespace = "coder"
  }
}
