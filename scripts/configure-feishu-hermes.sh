#!/bin/bash
# configure-feishu-hermes.sh — Configure Feishu credentials for a Hermes slot
# Updates EFS .env with Feishu credentials and restarts the Hermes ECS Service
#
# Usage: bash configure-feishu-hermes.sh
# Requires: AWS CLI, jq
set -euo pipefail

echo "=== Configure Feishu for Hermes ==="
echo ""

# ── Collect input (supports multiple slots via CSV file or interactive) ──
# CSV format: slot-id,feishu-app-id,feishu-app-secret (one per line)
SLOTS_FILE="${1:-}"
declare -a SLOTS=()

if [ -n "$SLOTS_FILE" ] && [ -f "$SLOTS_FILE" ]; then
  while IFS=',' read -r sid fid fsec; do
    [ -z "$sid" ] || [[ "$sid" == \#* ]] && continue
    SLOTS+=("${sid},${fid},${fsec}")
  done < "$SLOTS_FILE"
else
  echo "No CSV file provided. Enter slots interactively (empty Slot ID to finish):"
  while true; do
    read -p "Slot ID (e.g. slot-01, empty to finish): " SLOT_ID
    [ -z "$SLOT_ID" ] && break
    read -p "  Feishu App ID: " FEISHU_APP_ID
    read -p "  Feishu App Secret: " FEISHU_APP_SECRET
    [ -z "$FEISHU_APP_ID" ] || [ -z "$FEISHU_APP_SECRET" ] && { echo "  Skipped (missing fields)"; continue; }
    SLOTS+=("${SLOT_ID},${FEISHU_APP_ID},${FEISHU_APP_SECRET}")
  done
fi

if [ ${#SLOTS[@]} -eq 0 ]; then
  echo "ERROR: No slots provided"
  exit 1
fi
echo "  Will configure ${#SLOTS[@]} slot(s)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.."; pwd)"
TF_DIR="${PROJECT_DIR}/terraform"

# ── Read parameters from SSM Parameter Store ──
echo ""
echo "[1/5] Reading parameters from SSM..."
PROJECT_NAME=$(grep 'project_name' "$TF_DIR/terraform.tfvars" 2>/dev/null | awk -F'"' '{print $2}' || true)
PROJECT_NAME="${PROJECT_NAME:-${PROJECT_NAME_ENV:-mt-openclaw-hermes-ecs}}"
TF_REGION=$(grep 'aws_region' "$TF_DIR/terraform.tfvars" 2>/dev/null | awk -F'"' '{print $2}' || true)
REGION=$(curl -s --connect-timeout 2 -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null | xargs -I{} curl -s --connect-timeout 2 -H "X-aws-ec2-metadata-token: {}" http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || true)
REGION="${REGION:-${AWS_REGION:-${TF_REGION:-$(aws configure get region 2>/dev/null || echo us-east-1)}}}"

ssm_get() { aws ssm get-parameter --name "/${PROJECT_NAME}/$1" --query 'Parameter.Value' --output text --region "$REGION"; }

EFS_ID=$(ssm_get efs-id)
SUBNET_ID=$(ssm_get private-subnet-id)
ECS_SG=$(ssm_get ecs-sg-id)
SSM_PROFILE=$(ssm_get ssm-instance-profile)
ECS_CLUSTER=$(ssm_get ecs-cluster-name)

echo "  Region=$REGION EFS=$EFS_ID Cluster=$ECS_CLUSTER"

# ── Launch temp EC2 ──
echo ""
echo "[2/5] Launching temp EC2..."
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 \
  --instance-type t4g.micro \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$ECS_SG" \
  --iam-instance-profile Name="$SSM_PROFILE" \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=hermes-feishu-config}]' \
  --no-associate-public-ip-address \
  --query 'Instances[0].InstanceId' --output text \
  --region "$REGION")
echo "  Instance: $INSTANCE_ID"

# ── Wait for SSM ──
echo ""
echo "[3/5] Waiting for SSM..."
for i in $(seq 1 20); do
  STATUS=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query 'InstanceInformationList[0].PingStatus' --output text \
    --region "$REGION" 2>/dev/null || echo "None")
  [ "$STATUS" = "Online" ] && break
  sleep 10
done
if [ "$STATUS" != "Online" ]; then
  echo "ERROR: SSM not online after 200 seconds. Terminating instance."
  aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION"
  exit 1
fi
echo "  SSM Online"

# ── Update EFS .env for each slot ──
echo ""
echo "[4/5] Updating Hermes .env with Feishu credentials..."
for SLOT_ENTRY in "${SLOTS[@]}"; do
  IFS=',' read -r SLOT_ID FEISHU_APP_ID FEISHU_APP_SECRET <<< "$SLOT_ENTRY"
  echo "  Configuring ${SLOT_ID}..."

  CMD_ID=$(aws ssm send-command --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" --timeout-seconds 120 \
    --parameters '{"commands":[
      "mkdir -p /mnt/efs",
      "mount -t nfs4 -o nfsvers=4.1 '"${EFS_ID}"'.efs.'"${REGION}"'.amazonaws.com:/ /mnt/efs || true",
      "HERMES_DIR=/mnt/efs/tenant-'"${SLOT_ID}"'/hermes",
      "if [ ! -f $HERMES_DIR/.env ]; then echo \"ERROR: .env not found at $HERMES_DIR/.env — run deploy.sh first\"; umount /mnt/efs 2>/dev/null; exit 1; fi",
      "sed -i \"s|^# FEISHU_APP_ID=.*|FEISHU_APP_ID='"${FEISHU_APP_ID}"'|\" $HERMES_DIR/.env",
      "sed -i \"s|^# FEISHU_APP_SECRET=.*|FEISHU_APP_SECRET='"${FEISHU_APP_SECRET}"'|\" $HERMES_DIR/.env",
      "sed -i \"s|^# FEISHU_DOMAIN=.*|FEISHU_DOMAIN=feishu|\" $HERMES_DIR/.env",
      "sed -i \"s|^# FEISHU_CONNECTION_MODE=.*|FEISHU_CONNECTION_MODE=websocket|\" $HERMES_DIR/.env",
      "sed -i \"s|^# FEISHU_GROUP_POLICY=.*|FEISHU_GROUP_POLICY=open|\" $HERMES_DIR/.env",
      "echo \"Updated .env for '"${SLOT_ID}"':\"",
      "grep FEISHU $HERMES_DIR/.env",
      "umount /mnt/efs 2>/dev/null"
    ]}' \
    --query 'Command.CommandId' --output text --region "$REGION")

  for i in $(seq 1 30); do
    S=$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
      --query 'Status' --output text --region "$REGION" 2>/dev/null || echo "Pending")
    [ "$S" = "Success" ] && break
    [ "$S" = "Failed" ] && {
      echo "ERROR: Failed to update .env for ${SLOT_ID}"
      aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
        --query 'StandardOutputContent' --output text --region "$REGION"
      aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION"
      exit 1
    }
    sleep 5
  done

  aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
    --query 'StandardOutputContent' --output text --region "$REGION"
done

# ── Terminate temp EC2 ──
echo ""
echo "  Terminating temp EC2..."
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION" \
  --query 'TerminatingInstances[0].CurrentState.Name' --output text

# ── Restart Hermes ECS Services ──
echo ""
echo "[5/5] Restarting Hermes services..."
for SLOT_ENTRY in "${SLOTS[@]}"; do
  IFS=',' read -r SLOT_ID _ _ <<< "$SLOT_ENTRY"
  echo "  Restarting ${PROJECT_NAME}-hermes-${SLOT_ID}..."
  aws ecs update-service --cluster "$ECS_CLUSTER" \
    --service "${PROJECT_NAME}-hermes-${SLOT_ID}" \
    --force-new-deployment --region "$REGION" \
    --query 'service.serviceName' --output text
done

echo ""
echo "=== Done ==="
echo "Hermes services will restart with Feishu credentials in ~2 minutes."
for SLOT_ENTRY in "${SLOTS[@]}"; do
  IFS=',' read -r SLOT_ID _ _ <<< "$SLOT_ENTRY"
  echo "Check logs: aws logs tail /ecs/${PROJECT_NAME} --log-stream-name-prefix hermes-${SLOT_ID} --since 5m --region ${REGION}"
done
