#!/bin/bash
# deploy.sh — Build Provisioning image on ARM64 EC2 + Init EFS config + Init DynamoDB
#
# Token flow:
#   Full deploy: build-on-ec2.sh generates token → writes EFS → stdout "slot-XX:token=xxx"
#                → Step 7 parses stdout → writes token to DynamoDB
#   --skip-build: Step 7 resets slot status but PRESERVES existing gateway_token in DynamoDB
#
# Usage:
#   bash deploy.sh              # Full deploy (build + config + restart)
#   bash deploy.sh --skip-build # Skip image build (config + restart only)
set -euo pipefail

SKIP_BUILD=false
[[ "${1:-}" == "--skip-build" ]] && SKIP_BUILD=true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.."; pwd)"

echo "=== OpenClaw Multi-Tenant Deploy ==="
$SKIP_BUILD && echo "  (--skip-build: skipping image build)"

# ── Step 1: Read parameters from SSM Parameter Store ──
echo "[1/8] Reading parameters from SSM..."
PROJECT_NAME="${PROJECT_NAME:-mt-openclaw-hermes-ecs}"
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "${AWS_REGION:-us-east-1}")

ssm_get() { aws ssm get-parameter --name "/${PROJECT_NAME}/$1" --query 'Parameter.Value' --output text --region "$REGION"; }

ECS_CLUSTER=$(ssm_get ecs-cluster-name)
EFS_ID=$(ssm_get efs-id)
SUBNET_ID=$(ssm_get private-subnet-id)
ECS_SG=$(ssm_get ecs-sg-id)
SSM_PROFILE=$(ssm_get ssm-instance-profile)
PROV_ECR=$(ssm_get ecr-provisioning-url)
CF_DOMAIN=$(ssm_get cloudfront-domain)
SLOTS_TABLE=$(ssm_get dynamodb-slots-table)
USERS_TABLE=$(ssm_get dynamodb-users-table)
SLOT_COUNT=$(ssm_get slot-count)
ACCOUNT=$(echo "$PROV_ECR" | cut -d. -f1)

echo "  Region=$REGION Cluster=$ECS_CLUSTER Slots=$SLOT_COUNT"
echo "  CF=$CF_DOMAIN"

S3_BUCKET="${PROJECT_NAME}-build-tmp-${ACCOUNT}"
TOKENS_OUTPUT=""

if $SKIP_BUILD; then
  echo "[2-6/8] Skipping build (--skip-build)"
else
  # ── Step 2: Package source → S3 ──
  echo "[2/8] Packaging source → S3..."
  aws s3 ls "s3://${S3_BUCKET}" --region "$REGION" 2>/dev/null || \
    aws s3 mb "s3://${S3_BUCKET}" --region "$REGION"
  COPYFILE_DISABLE=1 tar czf /tmp/mt-build.tar.gz \
    -C "$PROJECT_DIR" provisioning scripts
  aws s3 cp /tmp/mt-build.tar.gz "s3://${S3_BUCKET}/mt-build.tar.gz" --region "$REGION" --quiet
  echo "  Uploaded"

  # ── Step 2.5: Ensure IAM permissions ──
  echo "[2.5/8] Ensuring IAM permissions..."
  aws iam put-role-policy \
    --role-name ${PROJECT_NAME}-ssm-role \
    --policy-name build-permissions \
    --policy-document "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [
        {\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:ListBucket\"],\"Resource\":[\"arn:aws:s3:::${S3_BUCKET}\",\"arn:aws:s3:::${S3_BUCKET}/*\"]},
        {\"Effect\":\"Allow\",\"Action\":[\"ecr:GetAuthorizationToken\",\"ecr:BatchCheckLayerAvailability\",\"ecr:GetDownloadUrlForLayer\",\"ecr:BatchGetImage\",\"ecr:PutImage\",\"ecr:InitiateLayerUpload\",\"ecr:UploadLayerPart\",\"ecr:CompleteLayerUpload\"],\"Resource\":\"*\"}
      ]
    }"
  sleep 10

  # ── Step 3: Launch temp EC2 ──
  echo "[3/8] Launching ARM64 EC2..."
  INSTANCE_ID=$(aws ec2 run-instances \
    --image-id resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 \
    --instance-type t4g.medium \
    --subnet-id "$SUBNET_ID" \
    --security-group-ids "$ECS_SG" \
    --iam-instance-profile Name="$SSM_PROFILE" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT_NAME}-build}]" \
    --no-associate-public-ip-address \
    --query 'Instances[0].InstanceId' --output text \
    --region "$REGION")
  echo "  Instance: $INSTANCE_ID"

  # ── Step 4: Wait for SSM ──
  echo "[4/8] Waiting for SSM..."
  for i in $(seq 1 30); do
    STATUS=$(aws ssm describe-instance-information \
      --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
      --query 'InstanceInformationList[0].PingStatus' --output text \
      --region "$REGION" 2>/dev/null || echo "None")
    [ "$STATUS" = "Online" ] && break
    sleep 10
  done
  if [ "$STATUS" != "Online" ]; then
    echo "ERROR: SSM not online. Terminating."
    aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION"
    exit 1
  fi
  echo "  SSM Online"

  # ── Step 5a: Download source ──
  echo "[5/8] Running build on EC2..."
  echo "  5a: Downloading source..."
  CMD1=$(aws ssm send-command --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" --timeout-seconds 120 \
    --parameters '{"commands":["aws s3 cp s3://'"${S3_BUCKET}"'/mt-build.tar.gz /tmp/mt-build.tar.gz --region '"${REGION}"'","mkdir -p /tmp/build","tar xzf /tmp/mt-build.tar.gz -C /tmp/build"]}' \
    --query 'Command.CommandId' --output text --region "$REGION")
  for i in $(seq 1 30); do
    S=$(aws ssm get-command-invocation --command-id "$CMD1" --instance-id "$INSTANCE_ID" \
      --query 'Status' --output text --region "$REGION" 2>/dev/null || echo "Pending")
    [ "$S" = "Success" ] && break
    [ "$S" = "Failed" ] && { echo "ERROR: Download failed"; exit 1; }
    sleep 5
  done
  echo "  5a: Source ready"

  # ── Step 5b: Run build-on-ec2.sh ──
  echo "  5b: Building Provisioning image + EFS config (5-10 min)..."
  CMD2=$(aws ssm send-command --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" --timeout-seconds 900 \
    --parameters '{"commands":["export REGION='"${REGION}"'","export ACCOUNT='"${ACCOUNT}"'","export PROV_ECR='"${PROV_ECR}"'","export EFS_ID='"${EFS_ID}"'","export CF_DOMAIN='"${CF_DOMAIN}"'","export SLOT_COUNT='"${SLOT_COUNT}"'","chmod +x /tmp/build/scripts/build-on-ec2.sh","bash /tmp/build/scripts/build-on-ec2.sh"]}' \
    --query 'Command.CommandId' --output text --region "$REGION")
  echo "  Command: $CMD2"
  for i in $(seq 1 120); do
    S=$(aws ssm get-command-invocation --command-id "$CMD2" --instance-id "$INSTANCE_ID" \
      --query 'Status' --output text --region "$REGION" 2>/dev/null || echo "Pending")
    if [ "$S" = "Success" ]; then echo "  5b: Build completed!"; break
    elif [ "$S" = "Failed" ] || [ "$S" = "TimedOut" ]; then
      echo "ERROR: Build failed ($S)"
      aws ssm get-command-invocation --command-id "$CMD2" --instance-id "$INSTANCE_ID" \
        --query 'StandardErrorContent' --output text --region "$REGION" | tail -20
      aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION"; exit 1
    fi; sleep 10
  done
  # Capture build output — contains "slot-XX:token=xxx" lines
  TOKENS_OUTPUT=$(aws ssm get-command-invocation --command-id "$CMD2" --instance-id "$INSTANCE_ID" \
    --query 'StandardOutputContent' --output text --region "$REGION" 2>/dev/null || echo "")

  # ── Step 6: Terminate EC2 ──
  echo "[6/8] Terminating build EC2..."
  aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION" \
    --query 'TerminatingInstances[0].CurrentState.Name' --output text
fi

# ── Step 7: Clean users table + Init/Reset DynamoDB slots ──
# Full deploy: parse tokens from build output → write to DynamoDB
# --skip-build: preserve existing gateway_token, only reset status
echo "[7/8] Cleaning users table + initializing slots..."
python3 - "$SLOTS_TABLE" "$USERS_TABLE" "$REGION" "$SLOT_COUNT" "$SKIP_BUILD" "$TOKENS_OUTPUT" "$PROJECT_NAME" << 'PYEOF'
import sys, boto3, re, secrets
from datetime import datetime, timezone

slots_table_name = sys.argv[1]
users_table_name = sys.argv[2]
region = sys.argv[3]
slot_count = int(sys.argv[4])
skip_build = sys.argv[5] == "true"
build_output = sys.argv[6] if len(sys.argv) > 6 else ""
project_name = sys.argv[7] if len(sys.argv) > 7 else "mt-openclaw-hermes-ecs"

ddb = boto3.resource("dynamodb", region_name=region)
now = datetime.now(timezone.utc).isoformat()

# Clean users table
users_table = ddb.Table(users_table_name)
resp = users_table.scan(ProjectionExpression="username")
deleted = 0
for item in resp.get("Items", []):
    users_table.delete_item(Key={"username": item["username"]})
    deleted += 1
while "LastEvaluatedKey" in resp:
    resp = users_table.scan(ProjectionExpression="username", ExclusiveStartKey=resp["LastEvaluatedKey"])
    for item in resp.get("Items", []):
        users_table.delete_item(Key={"username": item["username"]})
        deleted += 1
print(f"  Users table cleaned ({deleted} deleted)")

# Parse tokens from build output (full deploy only)
tokens = {}
if not skip_build:
    for line in build_output.split("\n"):
        m = re.match(r"(slot-\d+):token=([a-f0-9]+)", line.strip())
        if m:
            tokens[m.group(1)] = m.group(2)
    print(f"  Parsed {len(tokens)} tokens from build output")

# Init/reset slots
slots_table = ddb.Table(slots_table_name)
for i in range(1, slot_count + 1):
    slot_id = f"slot-{i:02d}"

    if skip_build:
        # --skip-build: only reset status + assignment, PRESERVE token
        slots_table.update_item(
            Key={"slot_id": slot_id},
            UpdateExpression="SET #s = :available, assigned_username = :empty, assigned_at = :empty",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={
                ":available": "available",
                ":empty": "",
            },
        )
        print(f"  {slot_id}: reset status (token preserved)")
    else:
        # Full deploy: write token from build output
        token = tokens.get(slot_id, secrets.token_hex(16))
        slots_table.put_item(Item={
            "slot_id": slot_id, "status": "available", "gateway_token": token,
            "task_private_ip": "", "ecs_service_name": f"{project_name}-{slot_id}",
            "assigned_username": "", "assigned_at": "", "created_at": now,
        })
        print(f"  {slot_id}: token={token[:12]}...")

print(f"  Done: {slot_count} slots")
PYEOF

# ── Step 8: Restart ECS services ──
echo "[8/8] Restarting services..."
for i in $(seq -w 1 "$SLOT_COUNT"); do
  aws ecs update-service --cluster "$ECS_CLUSTER" --service "${PROJECT_NAME}-slot-${i}" \
    --force-new-deployment --region "$REGION" --no-cli-pager \
    --query 'service.serviceName' --output text 2>/dev/null || true
done
# Restart Hermes services
for i in $(seq -w 1 "$SLOT_COUNT"); do
  aws ecs update-service --cluster "$ECS_CLUSTER" --service "${PROJECT_NAME}-hermes-slot-${i}" \
    --force-new-deployment --region "$REGION" --no-cli-pager \
    --query 'service.serviceName' --output text 2>/dev/null || true
done
aws ecs update-service --cluster "$ECS_CLUSTER" --service "${PROJECT_NAME}-provisioning" \
  --force-new-deployment --region "$REGION" --no-cli-pager \
  --query 'service.serviceName' --output text 2>/dev/null || true

echo "  Services restarting. Wait 2-3 min for tasks to stabilize."
echo ""
echo "=== Deploy Complete ==="
echo "Workshop URL: https://${CF_DOMAIN}"
echo "Admin login: admin / (password from terraform.tfvars)"
