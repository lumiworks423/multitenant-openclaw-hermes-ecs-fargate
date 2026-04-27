#!/bin/bash
# batch-provision.sh — Batch create Workshop users via Provisioning API
# Usage: ./batch-provision.sh [count] [admin_password]
#
# Requires: curl, jq
# Output: workshop-users.csv

set -euo pipefail

CLOUDFRONT_URL="${CLOUDFRONT_URL:-$(cd ../terraform && terraform output -raw workshop_url 2>/dev/null || echo "https://localhost")}"
API_URL="${CLOUDFRONT_URL}/api"
NUM_USERS=${1:-10}
ADMIN_PASSWORD=${2:-"change-me-workshop-2026"}
OUTPUT_FILE="workshop-users.csv"

echo "=== OpenClaw Workshop Batch Provisioning ==="
echo "API: ${API_URL}"
echo "Users: ${NUM_USERS}"
echo ""

# 1. Login as admin
echo "Logging in as admin..."
ADMIN_TOKEN=$(curl -s -X POST "${API_URL}/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"admin\",\"password\":\"${ADMIN_PASSWORD}\"}" \
  | jq -r '.token')

if [ -z "$ADMIN_TOKEN" ] || [ "$ADMIN_TOKEN" = "null" ]; then
  echo "ERROR: Admin login failed"
  exit 1
fi
echo "Admin login OK"

# 2. Batch create
echo "Creating ${NUM_USERS} users..."
RESULT=$(curl -s -X POST "${API_URL}/tenants/batch" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"count\":${NUM_USERS},\"username_prefix\":\"user\"}")

# 3. Write CSV
echo "username,password,slot_id,access_url,gateway_token" > "$OUTPUT_FILE"
echo "$RESULT" | jq -r '.created[] | [.username, .password, .slot_id, .access_url, .gateway_token // ""] | @csv' >> "$OUTPUT_FILE"

CREATED=$(echo "$RESULT" | jq '.created | length')
echo ""
echo "=== Done ==="
echo "Created: ${CREATED} users"
echo "Output: ${OUTPUT_FILE}"
echo ""
echo "Workshop URL: ${CLOUDFRONT_URL}"
head -5 "$OUTPUT_FILE"
[ "$CREATED" -gt 4 ] && echo "... (${CREATED} total)"
