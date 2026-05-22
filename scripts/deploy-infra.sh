#!/bin/bash
# deploy-infra.sh — Idempotent Terraform/OpenTofu apply with auto-import on conflict
#
# Handles the case where apply was interrupted mid-way:
#   1. Ensures S3 backend exists
#   2. Runs terraform apply
#   3. If "already exists" errors → auto-imports conflicting resources → retries
#
# Usage:
#   bash deploy-infra.sh              # Apply
#   bash deploy-infra.sh destroy      # Destroy all
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)"
TF_DIR="${SCRIPT_DIR}/../terraform"
cd "$TF_DIR"

ACTION="${1:-apply}"
REGION=$(grep 'aws_region' terraform.tfvars 2>/dev/null | awk -F'"' '{print $2}')
REGION="${REGION:-us-east-1}"
PROJECT_NAME=$(grep 'project_name' terraform.tfvars 2>/dev/null | awk -F'"' '{print $2}')
PROJECT_NAME="${PROJECT_NAME:-mt-openclaw-hermes-ecs}"

ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null || echo "unknown")
STATE_BUCKET="${PROJECT_NAME}-tfstate-${REGION}-${ACCOUNT_ID}"

echo "=== deploy-infra.sh ==="
echo "  Region: $REGION"
echo "  Project: $PROJECT_NAME"
echo "  Action: $ACTION"
echo ""

# ── Helper: create S3 bucket (handles us-east-1 special case) ──
create_s3_bucket() {
  local bucket_name="$1"
  local region="$2"
  if [ "$region" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$bucket_name" --region "$region" > /dev/null
  else
    aws s3api create-bucket --bucket "$bucket_name" --region "$region" \
      --create-bucket-configuration LocationConstraint="$region" > /dev/null
  fi
}

# ── Step 1: Ensure S3 backend resources exist ──
ensure_backend() {
  echo "[1] Ensuring S3 backend..."
  if ! aws s3api head-bucket --bucket "$STATE_BUCKET" --region "$REGION" 2>/dev/null; then
    echo "  Creating state bucket: $STATE_BUCKET"
    create_s3_bucket "$STATE_BUCKET" "$REGION"
    aws s3api put-bucket-versioning --bucket "$STATE_BUCKET" \
      --versioning-configuration Status=Enabled --region "$REGION"
  else
    echo "  State bucket exists"
  fi

  # DynamoDB lock table no longer needed (using S3 native lockfile)
  echo ""
}

# ── Step 2: Init ──
do_init() {
  echo "[2] terraform init..."

  # Generate backend.tf if not present (Workshop Studio provides its own)
  if [ ! -f backend.tf ]; then
    cat > backend.tf <<EOF
terraform {
  backend "s3" {
    key          = "terraform.tfstate"
    use_lockfile = true
    encrypt      = true
  }
}
EOF
    echo "  Generated backend.tf"
  fi

  BACKEND_ARGS="-backend-config=bucket=${STATE_BUCKET} -backend-config=region=${REGION}"
  if [ -d .terraform/providers ] && [ -f .terraform.lock.hcl ]; then
    echo "  Already initialized, running reconfigure..."
    terraform init -reconfigure $BACKEND_ARGS 2>&1 | tail -5
  else
    rm -f terraform.tfstate terraform.tfstate.backup 2>/dev/null || true
    terraform init $BACKEND_ARGS
  fi
  echo ""
}

# ── Step 3: Apply with auto-import on conflict ──
do_apply() {
  local max_retries=3
  local attempt=1

  while [ $attempt -le $max_retries ]; do
    echo "[3] terraform apply (attempt $attempt/$max_retries)..."
    echo "    (real-time output below, this may take 15-20 min)"
    echo ""
    set +e
    terraform apply -var-file=terraform.tfvars -auto-approve -input=false 2>&1 | tee /tmp/tf-apply-output.log
    EXIT_CODE=${PIPESTATUS[0]}
    set -e
    OUTPUT=$(cat /tmp/tf-apply-output.log)

    if [ $EXIT_CODE -eq 0 ]; then
      echo ""
      echo "=== Infrastructure deployed successfully ==="
      terraform output -json > /tmp/tf-outputs.json 2>/dev/null || true
      return 0
    fi

    # Check if errors are "already exists" type — auto-import them
    CONFLICTS=$(echo "$OUTPUT" | grep -E "already exists|AlreadyExists|ResourceInUse" || true)
    if [ -z "$CONFLICTS" ]; then
      echo ""
      echo "ERROR: Non-recoverable error (see output above)"
      return 1
    fi

    echo ""
    echo "  Found conflicts, attempting auto-import..."
    import_conflicts "$OUTPUT"
    attempt=$((attempt + 1))
  done

  echo "ERROR: Failed after $max_retries attempts"
  echo "$OUTPUT" | grep -A2 "Error:" | head -30
  return 1
}

# ── Auto-import conflicting resources ──
import_conflicts() {
  local output="$1"

  # IAM Roles
  echo "$output" | sed -n 's/.*IAM Role (\([^)]*\)).*/\1/p' | while read -r role_name; do
    local tf_addr=$(grep_tf_addr_for_role "$role_name")
    if [ -n "$tf_addr" ]; then
      echo "  Importing $tf_addr ← $role_name"
      terraform import -var-file=terraform.tfvars "$tf_addr" "$role_name" 2>/dev/null || true
    fi
  done

  # IAM Instance Profile
  echo "$output" | sed -n 's/.*Instance Profile \([^ ]*\).*/\1/p' | while read -r name; do
    echo "  Importing aws_iam_instance_profile.ssm ← $name"
    terraform import -var-file=terraform.tfvars aws_iam_instance_profile.ssm "$name" 2>/dev/null || true
  done

  # DynamoDB Tables
  echo "$output" | sed -n 's/.*Table already exists: \([^ ]*\).*/\1/p' | while read -r table; do
    local tf_addr=$(grep_tf_addr_for_table "$table")
    if [ -n "$tf_addr" ]; then
      echo "  Importing $tf_addr ← $table"
      terraform import -var-file=terraform.tfvars "$tf_addr" "$table" 2>/dev/null || true
    fi
  done

  # ECR Repository
  echo "$output" | sed -n "s/.*repository with name '\([^']*\)'.*/\1/p" | while read -r repo; do
    echo "  Importing aws_ecr_repository.provisioning ← $repo"
    terraform import -var-file=terraform.tfvars aws_ecr_repository.provisioning "$repo" 2>/dev/null || true
  done

  # CloudWatch Log Group
  echo "$output" | grep "CreateLogGroup.*ResourceAlreadyExistsException" > /dev/null 2>&1 && {
    echo "  Importing aws_cloudwatch_log_group.main ← /ecs/${PROJECT_NAME}"
    terraform import -var-file=terraform.tfvars aws_cloudwatch_log_group.main "/ecs/${PROJECT_NAME}" 2>/dev/null || true
  }

  # ECS Cluster
  echo "$output" | grep "ClusterAlreadyExists" > /dev/null 2>&1 && {
    local arn=$(aws ecs describe-clusters --clusters "${PROJECT_NAME}-cluster" --region "$REGION" --query 'clusters[0].clusterArn' --output text 2>/dev/null)
    if [ -n "$arn" ] && [ "$arn" != "None" ]; then
      echo "  Importing aws_ecs_cluster.main ← $arn"
      terraform import -var-file=terraform.tfvars aws_ecs_cluster.main "$arn" 2>/dev/null || true
    fi
  }

  # ELBv2 Target Groups
  echo "$output" | sed -n 's/.*Target Group (\([^)]*\)).*/\1/p' | while read -r tg_name; do
    local arn=$(aws elbv2 describe-target-groups --names "$tg_name" --region "$REGION" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)
    if [ -n "$arn" ] && [ "$arn" != "None" ]; then
      local tf_addr=$(grep_tf_addr_for_tg "$tg_name")
      if [ -n "$tf_addr" ]; then
        echo "  Importing $tf_addr ← $arn"
        terraform import -var-file=terraform.tfvars "$tf_addr" "$arn" 2>/dev/null || true
      fi
    fi
  done

  # CloudFront Cache Policy
  echo "$output" | grep "CachePolicyAlreadyExists" > /dev/null 2>&1 && {
    local pol_id=$(aws cloudfront list-cache-policies --type custom --query "CachePolicyList.Items[?CachePolicy.CachePolicyConfig.Name=='${PROJECT_NAME}-no-cache'].CachePolicy.Id" --output text 2>/dev/null)
    if [ -n "$pol_id" ] && [ "$pol_id" != "None" ]; then
      echo "  Importing aws_cloudfront_cache_policy.disabled ← $pol_id"
      terraform import -var-file=terraform.tfvars aws_cloudfront_cache_policy.disabled "$pol_id" 2>/dev/null || true
    fi
  }

  # CloudFront Origin Request Policy
  echo "$output" | grep "OriginRequestPolicyAlreadyExists" > /dev/null 2>&1 && {
    local pol_id=$(aws cloudfront list-origin-request-policies --type custom --query "OriginRequestPolicyList.Items[?OriginRequestPolicy.OriginRequestPolicyConfig.Name=='${PROJECT_NAME}-all-viewer'].OriginRequestPolicy.Id" --output text 2>/dev/null)
    if [ -n "$pol_id" ] && [ "$pol_id" != "None" ]; then
      echo "  Importing aws_cloudfront_origin_request_policy.all_viewer ← $pol_id"
      terraform import -var-file=terraform.tfvars aws_cloudfront_origin_request_policy.all_viewer "$pol_id" 2>/dev/null || true
    fi
  }
}

# ── Helper: map IAM role name → TF address ──
grep_tf_addr_for_role() {
  local name="$1"
  case "$name" in
    *execution-role) echo "aws_iam_role.execution" ;;
    *openclaw-task-role) echo "aws_iam_role.openclaw_task" ;;
    *provisioning-task-role) echo "aws_iam_role.provisioning_task" ;;
    *ssm-role) echo "aws_iam_role.ssm" ;;
    *hermes-task-role) echo "aws_iam_role.hermes_task" ;;
    *) echo "" ;;
  esac
}

# ── Helper: map DynamoDB table name → TF address ──
grep_tf_addr_for_table() {
  local name="$1"
  case "$name" in
    *-slots) echo "aws_dynamodb_table.slots" ;;
    *-users) echo "aws_dynamodb_table.users" ;;
    *) echo "" ;;
  esac
}

# ── Helper: map Target Group name → TF address ──
grep_tf_addr_for_tg() {
  local name="$1"
  case "$name" in
    oc-slot-*-tg)
      local idx=$(echo "$name" | sed 's/.*slot-\([0-9]*\).*/\1/')
      idx=$((10#$idx - 1))
      echo "aws_lb_target_group.openclaw[$idx]"
      ;;
    *-prov-tg) echo "aws_lb_target_group.provisioning" ;;
    *) echo "" ;;
  esac
}

# ── Step 4: Prepare datasets ──
prepare_datasets() {
  local DATASET_BUCKET="${PROJECT_NAME}-datasets-${REGION}-${ACCOUNT_ID}"

  echo "[4] Preparing analysis datasets..."
  if ! aws s3api head-bucket --bucket "$DATASET_BUCKET" --region "$REGION" 2>/dev/null; then
    echo "  Creating dataset bucket: $DATASET_BUCKET"
    create_s3_bucket "$DATASET_BUCKET" "$REGION"
  else
    echo "  Dataset bucket exists"
  fi

  # NYC Taxi data (free public dataset, ~45MB Parquet)
  if aws s3api head-object --bucket "$DATASET_BUCKET" --key "nyc-taxi/yellow_tripdata_2023-01.parquet" --region "$REGION" > /dev/null 2>&1; then
    echo "  NYC Taxi data already present"
  else
    echo "  Downloading NYC Taxi data (~45MB)..."
    curl -sfo /tmp/yellow_tripdata_2023-01.parquet \
      "https://d37ci6vzurychx.cloudfront.net/trip-data/yellow_tripdata_2023-01.parquet" && \
    aws s3 cp /tmp/yellow_tripdata_2023-01.parquet \
      "s3://${DATASET_BUCKET}/nyc-taxi/yellow_tripdata_2023-01.parquet" \
      --region "$REGION" && echo "  NYC Taxi data uploaded" || \
    echo "  WARNING: NYC Taxi download/upload failed (non-critical, can retry later)"
  fi
  echo ""
}

# ── Main ──
if [ "$ACTION" = "destroy" ]; then
  echo "Destroying infrastructure..."
  terraform destroy -var-file=terraform.tfvars -auto-approve -input=false
  exit $?
fi

ensure_backend
do_init
do_apply
prepare_datasets
