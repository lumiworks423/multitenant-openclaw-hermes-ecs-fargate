#!/bin/bash
# build-on-ec2.sh — Runs ON the temp EC2 instance
# Called by deploy.sh via SSM after source is downloaded from S3
# Does: docker build + push Provisioning image + mount EFS + write configs
#
# Required env vars (passed by SSM):
#   REGION, ACCOUNT, PROV_ECR, EFS_ID, CF_DOMAIN, SLOT_COUNT
set -euo pipefail

echo "=== build-on-ec2.sh START ==="
echo "Region: $REGION"
echo "Account: $ACCOUNT"
echo "Prov ECR: $PROV_ECR"
echo "EFS: $EFS_ID"
echo "CloudFront: $CF_DOMAIN"
echo "Slots: $SLOT_COUNT"

# --- Step 1: Install Docker ---
echo ""
echo "--- Step 1: Install Docker ---"
dnf install -y docker
systemctl start docker
docker version --format '{{.Server.Version}}' || true
echo "Docker is running"

# --- Step 2: ECR Login ---
echo ""
echo "--- Step 2: ECR Login ---"
aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"

# --- Step 3: Build + Push Provisioning Service ---
echo ""
echo "--- Step 3: Build Provisioning Service ---"
cd /tmp/build/provisioning
ls -la
docker build -t "${PROV_ECR}:latest" .
echo "--- Step 3: Push Provisioning Service ---"
docker push "${PROV_ECR}:latest"
echo "Provisioning push OK"

# --- Step 4: Mount EFS + Write configs ---
echo ""
echo "--- Step 4: Mount EFS + Write configs ---"
mkdir -p /mnt/efs
mount -t nfs4 -o nfsvers=4.1 "${EFS_ID}.efs.${REGION}.amazonaws.com:/" /mnt/efs
echo "EFS mounted"

for i in $(seq 1 "$SLOT_COUNT"); do
  SLOT_ID=$(printf "slot-%02d" "$i")
  SLOT_DIR="/mnt/efs/tenant-${SLOT_ID}/openclaw"
  mkdir -p "${SLOT_DIR}/workspace"

  # Preserve existing token — never regenerate once set
  # OpenClaw detects file modification (mtime) and triggers drift protection
  # even if the token value is the same. So we only write the file if it doesn't exist.
  if [ -f "${SLOT_DIR}/openclaw.json" ]; then
    TOKEN=$(python3 -c "import json; print(json.load(open('${SLOT_DIR}/openclaw.json'))['gateway']['auth']['token'])" 2>/dev/null || echo "")
    if [ -n "$TOKEN" ]; then
      echo "${SLOT_ID}:token=${TOKEN}"
      echo "  ${SLOT_ID}: config exists, preserving token (not overwriting)"
      continue
    fi
  fi

  # First time only: generate token and write config
  TOKEN=$(openssl rand -hex 16)

  cat > "${SLOT_DIR}/openclaw.json" <<EOFCONFIG
{
  "models": {
    "providers": {
      "amazon-bedrock": {
        "baseUrl": "https://bedrock-runtime.${REGION}.amazonaws.com",
        "api": "bedrock-converse-stream",
        "auth": "aws-sdk",
        "models": [
          {
            "id": "global.anthropic.claude-sonnet-4-20250514-v1:0",
            "name": "Claude Sonnet 4",
            "input": ["text", "image"],
            "contextWindow": 200000,
            "maxTokens": 8192
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "maxConcurrent": 4,
      "workspace": "/home/node/.openclaw/workspace",
      "model": {
        "primary": "amazon-bedrock/global.anthropic.claude-sonnet-4-20250514-v1:0"
      }
    }
  },
  "tools": {
    "profile": "full",
    "sessions": {
      "visibility": "all"
    }
  },
  "gateway": {
    "mode": "local",
    "auth": {
      "mode": "token",
      "token": "${TOKEN}"
    },
    "port": 18789,
    "bind": "lan",
    "trustedProxies": ["10.2.0.0/16"],
    "controlUi": {
      "enabled": true,
      "basePath": "/i/${SLOT_ID}",
      "allowedOrigins": ["https://${CF_DOMAIN}"],
      "dangerouslyAllowHostHeaderOriginFallback": true,
      "dangerouslyDisableDeviceAuth": true
    },
    "http": {
      "endpoints": {
        "chatCompletions": {
          "enabled": true
        }
      }
    }
  }
}
EOFCONFIG

  chown -R 1000:1000 "${SLOT_DIR}"
  echo "${SLOT_ID}:token=${TOKEN}"
done

# --- Hermes config ---
for i in $(seq 1 "$SLOT_COUNT"); do
  SLOT_ID=$(printf "slot-%02d" "$i")
  HERMES_DIR="/mnt/efs/tenant-${SLOT_ID}/hermes"
  mkdir -p "${HERMES_DIR}"

  # config.yaml — Bedrock 直连配置
  cat > "${HERMES_DIR}/config.yaml" <<EOFYAML
model:
  default: global.anthropic.claude-sonnet-4-20250514-v1:0
  provider: bedrock
bedrock:
  region: ${REGION}
EOFYAML

  # .env — API Server + 飞书占位
  # 复用 OpenClaw 的 gateway token 作为 API_SERVER_KEY
  OC_TOKEN=$(python3 -c "import json; print(json.load(open('/mnt/efs/tenant-${SLOT_ID}/openclaw/openclaw.json'))['gateway']['auth']['token'])" 2>/dev/null || openssl rand -hex 16)

  cat > "${HERMES_DIR}/.env" <<EOFENV
API_SERVER_ENABLED=true
API_SERVER_KEY=${OC_TOKEN}
GATEWAY_ALLOW_ALL_USERS=true
# --- Feishu (uncomment and fill to enable) ---
# FEISHU_APP_ID=cli_xxx
# FEISHU_APP_SECRET=secret_xxx
# FEISHU_DOMAIN=feishu
# FEISHU_CONNECTION_MODE=websocket
EOFENV

  chown -R 10000:10000 "${HERMES_DIR}"
  echo "  ${SLOT_ID}: Hermes config written"
done

umount /mnt/efs
echo ""
echo "=== build-on-ec2.sh DONE ==="
