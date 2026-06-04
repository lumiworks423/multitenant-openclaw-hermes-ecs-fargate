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

  # Clean up OpenClaw drift protection artifacts and default files before writing config
  # These files cause OpenClaw to ignore new config on startup
  rm -f "${SLOT_DIR}/openclaw.json.last-good" 2>/dev/null || true
  rm -rf "${SLOT_DIR}/.last-good" "${SLOT_DIR}/.clobbered" 2>/dev/null || true
  rm -rf "${SLOT_DIR}/agents" "${SLOT_DIR}/canvas" "${SLOT_DIR}/identity" "${SLOT_DIR}/logs" "${SLOT_DIR}/tasks" 2>/dev/null || true
  rm -f "${SLOT_DIR}/update-check.json" 2>/dev/null || true

  # Preserve existing token if available, otherwise generate new one
  TOKEN=""
  if [ -f "${SLOT_DIR}/openclaw.json" ]; then
    TOKEN=$(python3 -c "import json; print(json.load(open('${SLOT_DIR}/openclaw.json'))['gateway']['auth']['token'])" 2>/dev/null || echo "")
  fi
  if [ -z "$TOKEN" ]; then
    TOKEN=$(openssl rand -hex 16)
  fi

  # Always write complete config (overwrite any default/drift config)

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
            "id": "moonshotai.kimi-k2.5",
            "name": "Kimi K2.5",
            "input": ["text"],
            "contextWindow": 256000,
            "maxTokens": 16384
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
        "primary": "amazon-bedrock/moonshotai.kimi-k2.5"
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
  echo "  ${SLOT_ID}: openclaw bind=$(python3 -c "import json; print(json.load(open('${SLOT_DIR}/openclaw.json')).get('gateway',{}).get('bind','MISSING'))" 2>/dev/null || echo PARSE_ERROR)"
done

# --- Hermes config ---
for i in $(seq 1 "$SLOT_COUNT"); do
  SLOT_ID=$(printf "slot-%02d" "$i")
  HERMES_DIR="/mnt/efs/tenant-${SLOT_ID}/hermes"
  mkdir -p "${HERMES_DIR}"

  # config.yaml — Bedrock 直连配置 + auxiliary 快速超时（避免阻塞主对话）
  cat > "${HERMES_DIR}/config.yaml" <<EOFYAML
model:
  default: moonshotai.kimi-k2.5
  provider: bedrock
  context_length: 256000
bedrock:
  region: ${REGION}
  discovery:
    enabled: true
auxiliary:
  title_generation:
    timeout: 1
  compression:
    timeout: 1
  memory_flush:
    timeout: 1
  web_extraction:
    timeout: 1
EOFYAML

  # patch-auxiliary.py — patches auxiliary_client.py to support Bedrock via Converse API
  cat > "${HERMES_DIR}/patch-auxiliary.py" <<'EOFPATCH'
"""Patch Hermes auxiliary_client.py to add Bedrock (aws_sdk) support.

This creates a lightweight OpenAI-compatible adapter around the existing
bedrock_adapter.call_converse() function, allowing auxiliary tasks
(title generation, compression, memory flush) to use Bedrock natively.
"""
import os
import sys

AUXILIARY_PATH = "/opt/hermes/agent/auxiliary_client.py"
MARKER = "BEDROCK_AUXILIARY_PATCH"

PATCH_CODE = '''
    # --- BEDROCK_AUXILIARY_PATCH: Bedrock via native Converse API ---
    if pconfig.auth_type == "aws_sdk":
        try:
            from agent.bedrock_adapter import call_converse, resolve_bedrock_region
            from hermes_cli.config import load_config as _load_cfg

            _bedrock_region = resolve_bedrock_region()
            _cfg = _load_cfg() or {}
            _default_model = _cfg.get("model", {}).get("default", "moonshotai.kimi-k2.5") if isinstance(_cfg, dict) else "moonshotai.kimi-k2.5"

            class _BedrockCompletions:
                def create(self, model=None, messages=None, max_tokens=4096,
                           temperature=None, stream=False, **kwargs):
                    conv_msgs = []
                    for m in (messages or []):
                        role = m.get("role", "user")
                        if role == "system":
                            role = "user"
                        content = m.get("content", "")
                        conv_msgs.append({"role": role, "content": content})
                    return call_converse(
                        region=_bedrock_region,
                        model=model or _default_model,
                        messages=conv_msgs,
                        max_tokens=max_tokens,
                        temperature=temperature,
                    )

            class _BedrockChat:
                completions = _BedrockCompletions()

            class _BedrockClient:
                chat = _BedrockChat()

            _final_model = model or _default_model
            logger.info("resolve_provider_client: bedrock via Converse API "
                        "(region=%s, model=%s)", _bedrock_region, _final_model)
            return _BedrockClient(), _final_model
        except Exception as _e:
            logger.warning("resolve_provider_client: bedrock adapter failed: %s", _e)
            return None, None

'''

def patch():
    if not os.path.exists(AUXILIARY_PATH):
        print(f"[patch-auxiliary] {AUXILIARY_PATH} not found, skipping")
        return

    with open(AUXILIARY_PATH, "r") as f:
        code = f.read()

    if MARKER in code:
        print("[patch-auxiliary] Already patched")
        return

    target = '    logger.warning("resolve_provider_client: unhandled auth_type %s for %s",'
    if target not in code:
        print("[patch-auxiliary] ERROR: Could not find patch target in auxiliary_client.py")
        return

    code = code.replace(target, PATCH_CODE + target)

    with open(AUXILIARY_PATH, "w") as f:
        f.write(code)
    print("[patch-auxiliary] Successfully patched auxiliary_client.py for Bedrock support")

if __name__ == "__main__":
    patch()
EOFPATCH

  # Get OpenClaw gateway token (used as API_SERVER_KEY and WEBUI_PASSWORD)
  OC_TOKEN=$(python3 -c "import json; print(json.load(open('/mnt/efs/tenant-${SLOT_ID}/openclaw/openclaw.json'))['gateway']['auth']['token'])" 2>/dev/null || openssl rand -hex 16)

  # run.sh — main startup script (executed by entrypoint after init)
  cat > "${HERMES_DIR}/run.sh" <<EOFRUN
#!/bin/sh
echo "[run.sh] Starting Hermes + WebUI (pid=\$\$)"

# Step 1: Patch auxiliary_client.py for Bedrock support
echo "[run.sh] Applying Bedrock auxiliary patch..."
python3 /opt/data/patch-auxiliary.py

# Step 2: Patch webui server.py for path prefix strip
echo "[run.sh] Patching webui path prefix..."
python3 -c "
import os
server_py = '/opt/data/webui/server.py'
prefix = '/h/${SLOT_ID}'
prefix_len = len(prefix)
with open(server_py, 'r') as f:
    code = f.read()
if 'PATH PREFIX STRIP' not in code:
    patch = chr(10) + '            # --- PATH PREFIX STRIP (auto-patched) ---' + chr(10) + '            if self.path.startswith(\"' + prefix + '\"):' + chr(10) + '                self.path = self.path[' + str(prefix_len) + ':] or \"/\"' + chr(10)
    code = code.replace('parsed = urlparse(self.path)', patch + '            parsed = urlparse(self.path)', 2)
    with open(server_py, 'w') as f:
        f.write(code)
    print('[run.sh] Patched webui for prefix ' + prefix)
else:
    print('[run.sh] webui already patched')
"

# Step 3: Start hermes gateway in background
echo "[run.sh] Starting hermes gateway run (background)..."
hermes gateway run &
GATEWAY_PID=\$!
echo "[run.sh] Gateway PID=\$GATEWAY_PID"

# Step 4: Wait for gateway API server to be ready
echo "[run.sh] Waiting for gateway API on :8642..."
for i in \$(seq 1 30); do
  if python3 -c "import socket; s=socket.socket(); s.settimeout(1); exit(0 if s.connect_ex(('127.0.0.1',8642))==0 else 1)" 2>/dev/null; then
    echo "[run.sh] Gateway API ready"
    break
  fi
  sleep 1
done

# Step 5: Start webui in foreground (ALB health check on :8787)
echo "[run.sh] Starting hermes-webui on :8787..."
mkdir -p /opt/data/webui-state
export HERMES_WEBUI_AGENT_DIR="/opt/hermes"
export HERMES_WEBUI_STATE_DIR="/opt/data/webui-state"
export HERMES_WEBUI_HOST="0.0.0.0"
export HERMES_WEBUI_PORT="8787"
export HERMES_WEBUI_PASSWORD="${OC_TOKEN}"
exec /opt/hermes/.venv/bin/python3 /opt/data/webui/server.py
EOFRUN
  chmod +x "${HERMES_DIR}/run.sh"

  # auth.json — tell webui that bedrock provider is active
  echo '{"active_provider":"bedrock"}' > "${HERMES_DIR}/auth.json"

  # .env — API Server + 飞书占位

  cat > "${HERMES_DIR}/.env" <<EOFENV
API_SERVER_ENABLED=true
API_SERVER_KEY=${OC_TOKEN}
GATEWAY_ALLOW_ALL_USERS=true
# --- Feishu (uncomment and fill to enable) ---
# FEISHU_APP_ID=cli_xxx
# FEISHU_APP_SECRET=secret_xxx
# FEISHU_DOMAIN=feishu
# FEISHU_CONNECTION_MODE=websocket
# FEISHU_GROUP_POLICY=open
EOFENV

  # Pre-download hermes-webui to EFS
  WEBUI_VERSION="v0.51.30"
  WEBUI_EFS_DIR="${HERMES_DIR}/webui"
  # Always re-download to ensure clean server.py (patch modifies it at runtime)
  rm -rf "${WEBUI_EFS_DIR}"
  mkdir -p "${WEBUI_EFS_DIR}"
  if true; then
    curl -fsSL "https://github.com/nesquena/hermes-webui/archive/refs/tags/${WEBUI_VERSION}.tar.gz" | \
      tar xz --strip-components=1 -C "${WEBUI_EFS_DIR}"
    echo "  ${SLOT_ID}: hermes-webui ${WEBUI_VERSION} pre-downloaded to EFS"
  fi

  # run-all.sh — launched by entrypoint after init, runs gateway + webui
  cat > "${HERMES_DIR}/run-all.sh" <<EOFSH
#!/bin/sh
echo "[run-all] Starting (slot=${SLOT_ID}, pid=\$\$)"
echo "[run-all] HERMES_HOME=\${HERMES_HOME:-/opt/data}"
echo "[run-all] Contents of /opt/data:" && ls /opt/data/ 2>&1 | head -10

# Start hermes gateway in background
echo "[run-all] Launching hermes gateway run..."
hermes gateway run &
GATEWAY_PID=\$!
echo "[run-all] Gateway PID=\$GATEWAY_PID"

# Wait for API server to be ready
echo "Waiting for gateway API server..."
for i in \$(seq 1 30); do
  if python3 -c "import socket; s=socket.socket(); s.settimeout(1); exit(0 if s.connect_ex(('127.0.0.1',8642))==0 else 1)" 2>/dev/null; then
    echo "Gateway API ready on :8642"
    break
  fi
  sleep 1
done

echo "[run-all] Gateway wait complete. Patching webui..."
# Patch webui server.py to strip path prefix /h/${SLOT_ID}
python3 -c "
import os
server_py = '/opt/data/webui/server.py'
prefix = '/h/${SLOT_ID}'
prefix_len = len(prefix)
with open(server_py, 'r') as f:
    code = f.read()
if 'PATH PREFIX STRIP' not in code:
    patch = chr(10) + '            # --- PATH PREFIX STRIP (auto-patched) ---' + chr(10) + '            if self.path.startswith(\"' + prefix + '\"):' + chr(10) + '                self.path = self.path[' + str(prefix_len) + ':] or \"/\"' + chr(10)
    code = code.replace('parsed = urlparse(self.path)', patch + '            parsed = urlparse(self.path)', 2)
    with open(server_py, 'w') as f:
        f.write(code)
    print('[run-all] Patched server.py for prefix ' + prefix)
else:
    print('[run-all] server.py already patched')
"

# Start webui in foreground (PID 1 process for health check)
mkdir -p /opt/data/webui-state
export HERMES_WEBUI_AGENT_DIR="/opt/hermes"
export HERMES_WEBUI_STATE_DIR="/opt/data/webui-state"
export HERMES_WEBUI_HOST="0.0.0.0"
export HERMES_WEBUI_PORT="8787"
export HERMES_WEBUI_PASSWORD="${OC_TOKEN}"

echo "[run-all] webui server.py exists: \$(ls /opt/data/webui/server.py 2>&1)"
echo "[run-all] Starting hermes-webui on :8787"
exec /opt/hermes/.venv/bin/python3 /opt/data/webui/server.py
EOFSH
  chmod +x "${HERMES_DIR}/run-all.sh"

  chown -R 10000:10000 "${HERMES_DIR}"
  echo "  ${SLOT_ID}: Hermes config written"
done

umount /mnt/efs
echo ""
echo "=== build-on-ec2.sh DONE ==="
