# ============================================================
# EKS Cluster — Reuses existing VPC/private subnets
# Karpenter bootstrap node group (1x ARM64 small instance)
# ============================================================

module "eks" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-eks.git?ref=v20.31.6"

  cluster_name    = "${var.project_name}-eks"
  cluster_version = var.eks_cluster_version

  vpc_id     = aws_vpc.main.id
  subnet_ids = aws_subnet.private[*].id

  cluster_endpoint_public_access = true

  # Managed Node Group with autoscaling for Spark workloads
  eks_managed_node_groups = {
    spark_workers = {
      instance_types = var.eks_node_instance_types
      ami_type       = "AL2023_ARM_64_STANDARD"
      min_size       = 1
      max_size       = 4
      desired_size   = 1

      iam_role_additional_policies = {
        s3_read = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
      }

      labels = {
        workload = "emr-spark"
      }
    }
  }

  # Cluster creator automatically gets admin access
  enable_cluster_creator_admin_permissions = true

  # Map ECS task roles so containers can authenticate via kubectl
  access_entries = {
    openclaw_task = {
      principal_arn     = aws_iam_role.openclaw_task.arn
      type              = "STANDARD"
      kubernetes_groups = ["ecs-agents"]
      policy_associations = {
        emr_ns = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy"
          access_scope = {
            type       = "namespace"
            namespaces = ["emr-spark"]
          }
        }
      }
    }
    hermes_task = {
      principal_arn     = aws_iam_role.hermes_task.arn
      type              = "STANDARD"
      kubernetes_groups = ["ecs-agents"]
      policy_associations = {
        emr_ns = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy"
          access_scope = {
            type       = "namespace"
            namespaces = ["emr-spark"]
          }
        }
      }
    }
  }

  cluster_addons = {
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
    vpc-cni    = { most_recent = true }
  }

  # Allow ECS tasks to reach EKS API
  cluster_security_group_additional_rules = {
    ecs_to_eks_api = {
      description              = "ECS tasks to EKS API"
      protocol                 = "tcp"
      from_port                = 443
      to_port                  = 443
      type                     = "ingress"
      source_security_group_id = aws_security_group.ecs.id
    }
  }

  tags = { Name = "${var.project_name}-eks" }
}
