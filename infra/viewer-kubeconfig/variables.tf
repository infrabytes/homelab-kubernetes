variable "kubeconfig_path" {
  description = "Path to the cluster kubeconfig (written by infra/cluster to artifacts/kubeconfig). Used by the kubernetes provider to create/approve the viewer CSR as cluster admin."
  type        = string
}

variable "artifacts_dir" {
  description = "Machine-invariant directory for the generated viewer kubeconfig (shared credential home, synced by scripts/sync-artifacts.sh)."
  type        = string
}

variable "cluster_name" {
  description = "Cluster name used in the viewer kubeconfig (cluster entry + context names)."
  type        = string
  default     = "talos-cluster"
}

variable "user_name" {
  description = "Kubernetes username (client cert CN) the viewer kubeconfig authenticates as. Must match the subject of the cluster-viewer ClusterRoleBindings in platform/cluster-viewer/rbac.yaml."
  type        = string
  default     = "viewer@talos-cluster"
}

variable "kubernetes_ca_certificate" {
  description = "Kubernetes API server CA certificate (PEM), from the cluster unit's outputs."
  type        = string
  sensitive   = true
}

variable "kubernetes_host" {
  description = "Kubernetes API server endpoint (https://host:6443), from the cluster unit's outputs."
  type        = string
}
