# ============================================================
# Spark on EKS — Namespace + Spark Operator + RBAC
# Agents submit Spark jobs via kubectl (SparkApplication CR)
# ============================================================

resource "kubernetes_namespace" "emr_spark" {
  metadata {
    name = "emr-spark"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
  depends_on = [module.eks]
}

# Spark Operator — manages SparkApplication CRDs
resource "helm_release" "spark_operator" {
  namespace        = "emr-spark"
  name             = "spark-operator"
  repository       = "https://kubeflow.github.io/spark-operator"
  chart            = "spark-operator"
  version          = "2.5.0"
  wait             = true
  timeout          = 600
  create_namespace = false

  set {
    name  = "webhook.enable"
    value = "true"
  }

  set {
    name  = "spark.jobNamespaces[0]"
    value = "emr-spark"
  }

  depends_on = [kubernetes_namespace.emr_spark]
}

# Service account for Spark driver/executor pods
resource "kubernetes_service_account" "spark" {
  metadata {
    name      = "spark"
    namespace = "emr-spark"
  }
  depends_on = [kubernetes_namespace.emr_spark]
}

# RBAC: Spark service account needs permissions to manage pods
resource "kubernetes_role" "spark" {
  metadata {
    name      = "spark-role"
    namespace = "emr-spark"
  }
  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log", "services", "configmaps", "persistentvolumeclaims"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete", "deletecollection"]
  }
  rule {
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete", "deletecollection"]
  }
  depends_on = [kubernetes_namespace.emr_spark]
}

resource "kubernetes_role_binding" "spark" {
  metadata {
    name      = "spark-role-binding"
    namespace = "emr-spark"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.spark.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.spark.metadata[0].name
    namespace = "emr-spark"
  }
  depends_on = [kubernetes_namespace.emr_spark]
}

# RBAC: ECS agent roles can manage SparkApplications and view pods/logs
resource "kubernetes_role" "ecs_agents" {
  metadata {
    name      = "ecs-agent-access"
    namespace = "emr-spark"
  }
  rule {
    api_groups = ["sparkoperator.k8s.io"]
    resources  = ["sparkapplications", "sparkapplications/status"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log", "configmaps", "services"]
    verbs      = ["get", "list", "watch", "create", "delete"]
  }
  rule {
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["get", "list", "watch", "create", "delete"]
  }
  depends_on = [kubernetes_namespace.emr_spark]
}

resource "kubernetes_role_binding" "ecs_agents" {
  metadata {
    name      = "ecs-agents-access"
    namespace = "emr-spark"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.ecs_agents.metadata[0].name
  }
  subject {
    kind      = "Group"
    name      = "ecs-agents"
    api_group = "rbac.authorization.k8s.io"
  }
  depends_on = [kubernetes_namespace.emr_spark]
}
