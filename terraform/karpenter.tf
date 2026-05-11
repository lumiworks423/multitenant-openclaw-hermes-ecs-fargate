# ============================================================
# NOTE: Karpenter removed — using EKS Managed Node Group autoscaling instead.
# The bootstrap node group in eks.tf handles scaling (min=0, max=4).
# This simplifies the deployment and avoids Karpenter version compatibility issues.
# ============================================================
