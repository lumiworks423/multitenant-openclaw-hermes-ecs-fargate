#!/bin/bash
# configure-feishu-hermes.sh — Configure Feishu credentials for a Hermes slot
# Updates EFS .env with Feishu credentials and restarts the Hermes ECS Service
#
# Usage: bash configure-feishu-hermes.sh
# Requires: AWS CLI, jq
set -euo pipefail

echo "=== Configure Feishu for Hermes ==="
echo ""

# ── Collect input ──
read -p "Slot ID (e.g. slot-01): " SLOT_ID
read -p "Feishu App ID: " FEISHU_APP_ID
read -p "Feishu App Secret: " FEISHU_APP_SECRET

if [ -z "$SLOT_ID" ] || [ -z "$FEISHU_APP_ID" ] || [ -z "$FEISHU_APP_SECRET" ]; then
  echo "ERROR: All fields are required"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)"

# ── Read parameters from SSM Parameter Store ──
echo ""
echo "[1/5] Reading parameters from SSM..."
PROJECT_NAME="${PROJECT_NAME:-mt-openclaw-hermes-ecs}"
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "${AWS_REGION:-us-east-1}")

ssm_get() { aws ssm get-parameter --name "/${PROJECT_NAME}/$1" --query 'Parameter.Value' --output text --region "$REGION"; }

EFS_ID=$(ssm_get efs-id)
SUBNET_ID=$(ssm_get private-subnet-id)
ECS_SG=$(ssm_get ecs-sg-id)
SSM_PROFILE=$(ssm_get ssm-instance-profile)
ECS_CLUSTER=$(ssm_get ecs-cluster-name)

echo "  EFS=$EFS_ID Cluster=$ECS_CLUSTER Slot=$SLOT_ID"

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

# ── Update EFS .env ──
echo ""
echo "[4/5] Updating Hermes .env with Feishu credentials..."
CMD_ID=$(aws ssm send-command --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" --timeout-seconds 120 \
  --parameters '{"commands":[
    "mkdir -p /mnt/efs",
    "mount -t nfs4 -o nfsvers=4.1 '"${EFS_ID}"'.efs.'"${REGION}"'.amazonaws.com:/ /mnt/efs",
    "HERMES_DIR=/mnt/efs/tenant-'"${SLOT_ID}"'/hermes",
    "if [ ! -f $HERMES_DIR/.env ]; then echo \"ERROR: .env not found at $HERMES_DIR/.env — run deploy.sh first\"; umount /mnt/efs; exit 1; fi",
    "sed -i \"s|^# FEISHU_APP_ID=.*|FEISHU_APP_ID='"${FEISHU_APP_ID}"'|\" $HERMES_DIR/.env",
    "sed -i \"s|^# FEISHU_APP_SECRET=.*|FEISHU_APP_SECRET='"${FEISHU_APP_SECRET}"'|\" $HERMES_DIR/.env",
    "sed -i \"s|^# FEISHU_DOMAIN=.*|FEISHU_DOMAIN=feishu|\" $HERMES_DIR/.env",
    "sed -i \"s|^# FEISHU_CONNECTION_MODE=.*|FEISHU_CONNECTION_MODE=websocket|\" $HERMES_DIR/.env",
    "echo \"Updated .env:\"",
    "grep FEISHU $HERMES_DIR/.env",
    "umount /mnt/efs"
  ]}' \
  --query 'Command.CommandId' --output text --region "$REGION")

for i in $(seq 1 30); do
  S=$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
    --query 'Status' --output text --region "$REGION" 2>/dev/null || echo "Pending")
  [ "$S" = "Success" ] && break
  [ "$S" = "Failed" ] && {
    echo "ERROR: Failed to update .env"
    aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
      --query 'StandardOutputContent' --output text --region "$REGION"
    aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION"
    exit 1
  }
  sleep 5
done

aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query 'StandardOutputContent' --output text --region "$REGION"

# ── Terminate temp EC2 ──
echo ""
echo "  Terminating temp EC2..."
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION" \
  --query 'TerminatingInstances[0].CurrentState.Name' --output text

# ── Restart Hermes ECS Service ──
echo ""
echo "[5/5] Restarting Hermes service for ${SLOT_ID}..."
aws ecs update-service --cluster "$ECS_CLUSTER" \
  --service "${PROJECT_NAME}-hermes-${SLOT_ID}" \
  --force-new-deployment --region "$REGION" --no-cli-pager \
  --query 'service.serviceName' --output text

echo ""
echo "=== Done ==="
echo "Hermes ${SLOT_ID} will restart with Feishu credentials in ~2 minutes."
echo "Check logs: aws logs tail /ecs/${PROJECT_NAME} --log-stream-name-prefix hermes-${SLOT_ID} --since 5m"
