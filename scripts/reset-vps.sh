#!/usr/bin/env bash
# Reset (recreate) VPS via Hostinger API, wait for it to come back, then run full setup + deploy.
#
# Usage:
#   HOSTINGER_API_TOKEN=xxx bash scripts/reset-vps.sh
#
# Required env vars:
#   HOSTINGER_API_TOKEN  - Hostinger API bearer token
#
# Optional env vars:
#   VPS_ID               - Hostinger VM ID (default: auto-detect first VM)
#   TEMPLATE_ID          - OS template ID (default: 1060 = Ubuntu 24.04 64bit)
#   VPS_IP               - VPS IP address (default: auto-detect from API)
#   OPENAI_API_KEY       - OpenAI API key (for deploy config)
#   TELEGRAM_BOT_TOKEN   - Telegram bot token (for deploy config)
#   TELEGRAM_ALLOWED_USER - Telegram user ID (for deploy config)
#   OPENCLAW_AGENT_NAME  - Agent display name (default: Assistant)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

API_BASE="https://developers.hostinger.com/api/vps/v1"
TEMPLATE_ID="${TEMPLATE_ID:-1060}"

if [[ -z "${HOSTINGER_API_TOKEN:-}" ]]; then
  echo "Error: HOSTINGER_API_TOKEN is required" >&2
  exit 1
fi

api() {
  local method="$1" endpoint="$2"
  shift 2
  curl -sf -X "${method}" "${API_BASE}${endpoint}" \
    -H "Authorization: Bearer ${HOSTINGER_API_TOKEN}" \
    -H "Content-Type: application/json" \
    "$@"
}

# Auto-detect VPS ID and IP if not provided
if [[ -z "${VPS_ID:-}" ]] || [[ -z "${VPS_IP:-}" ]]; then
  echo "[0/5] Fetching VPS info from Hostinger API..."
  VM_INFO=$(api GET "/virtual-machines")
  VPS_ID="${VPS_ID:-$(echo "${VM_INFO}" | jq -r '.[0].id')}"
  VPS_IP="${VPS_IP:-$(echo "${VM_INFO}" | jq -r '.[0].ipv4[0].address')}"
  echo "  VPS ID: ${VPS_ID}"
  echo "  VPS IP: ${VPS_IP}"
fi

echo ""
echo "=== OpenClaw VPS Full Reset ==="
echo ""

# 1) Recreate VPS
echo "[1/5] Recreating VPS (template ${TEMPLATE_ID})..."
RECREATE_RESULT=$(api POST "/virtual-machines/${VPS_ID}/recreate" \
  -d "{\"template_id\": ${TEMPLATE_ID}}" 2>&1) || {
  echo "  Recreate API call failed: ${RECREATE_RESULT}" >&2
  exit 1
}
echo "  Recreate triggered."

# 2) Wait for VPS to come back (poll API for state=running + SSH)
echo "[2/5] Waiting for VPS to come back online..."

# Remove old host key
ssh-keygen -R "${VPS_IP}" 2>/dev/null || true

# Wait for API to report running
for i in $(seq 1 60); do
  STATE=$(api GET "/virtual-machines/${VPS_ID}" | jq -r '.state' 2>/dev/null || echo "unknown")
  if [[ "${STATE}" == "running" ]]; then
    break
  fi
  printf "  [%02d/60] State: %s\r" "$i" "${STATE}"
  sleep 5
done
echo "  VPS state: ${STATE}         "

# Wait for SSH to accept connections
echo "  Waiting for SSH..."
for i in $(seq 1 60); do
  if ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o BatchMode=yes "root@${VPS_IP}" 'true' 2>/dev/null; then
    echo "  SSH is up."
    break
  fi
  sleep 5
done

# 3) Get root password from API
echo "[3/5] Retrieving root password..."

# Hostinger provides the password via the recreate response or VM details
# Try to get it - if not available, we rely on SSH key from previous setup
ROOT_PASSWORD=""

# Check if the recreate response had a password
if echo "${RECREATE_RESULT}" | jq -r '.root_password' 2>/dev/null | grep -qv null; then
  ROOT_PASSWORD=$(echo "${RECREATE_RESULT}" | jq -r '.root_password')
fi

# If no password, try the VM details endpoint
if [[ -z "${ROOT_PASSWORD}" ]]; then
  ROOT_PASSWORD=$(api GET "/virtual-machines/${VPS_ID}" | jq -r '.root_password // empty' 2>/dev/null || true)
fi

# Test SSH access - try key first, then password
SSH_CMD=""
if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes "root@${VPS_IP}" 'true' 2>/dev/null; then
  echo "  SSH key auth works."
  SSH_CMD="ssh -o StrictHostKeyChecking=no root@${VPS_IP}"
elif [[ -n "${ROOT_PASSWORD}" ]]; then
  echo "  Using password auth."
  if ! command -v sshpass &>/dev/null; then
    echo "Error: sshpass not installed. Run: brew install sshpass" >&2
    exit 1
  fi
  SSH_CMD="sshpass -p '${ROOT_PASSWORD}' ssh -o StrictHostKeyChecking=no root@${VPS_IP}"
else
  echo "Error: Cannot SSH into VPS - no key access and no password available." >&2
  echo "You may need to reset the VPS manually via the Hostinger panel." >&2
  exit 1
fi

# 4) Run setup-vps.sh
echo "[4/5] Running VPS provisioning..."

# First copy SSH key if using password auth
if [[ -n "${ROOT_PASSWORD}" ]]; then
  sshpass -p "${ROOT_PASSWORD}" ssh-copy-id -o StrictHostKeyChecking=no "root@${VPS_IP}" 2>/dev/null || true
fi

ssh -o StrictHostKeyChecking=no "root@${VPS_IP}" 'bash -s' < "${SCRIPT_DIR}/setup-vps.sh"

# Copy SSH key to openclaw user
ssh-copy-id -o StrictHostKeyChecking=no "openclaw@${VPS_IP}" 2>/dev/null || true

# 5) Inject user config into .env and deploy
echo "[5/5] Configuring and deploying..."

# Update .env with user-provided values
ssh -o StrictHostKeyChecking=no "openclaw@${VPS_IP}" bash -s <<REMOTE_DEPLOY
set -euo pipefail
cd ~/openclaw-vps

# Pull latest repo changes
git pull --rebase origin main

# Inject user config into .env
if [[ -n "${OPENAI_API_KEY:-}" ]]; then
  sed -i "s|^OPENAI_API_KEY=.*|OPENAI_API_KEY=${OPENAI_API_KEY}|" .env
fi
if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  sed -i "s|^TELEGRAM_BOT_TOKEN=.*|TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}|" .env
fi
if [[ -n "${TELEGRAM_ALLOWED_USER:-}" ]]; then
  sed -i "s|^TELEGRAM_ALLOWED_USER=.*|TELEGRAM_ALLOWED_USER=${TELEGRAM_ALLOWED_USER}|" .env
fi
if [[ -n "${OPENCLAW_AGENT_NAME:-}" ]]; then
  sed -i "s|^OPENCLAW_AGENT_NAME=.*|OPENCLAW_AGENT_NAME=${OPENCLAW_AGENT_NAME}|" .env
fi

# Run deploy
bash scripts/deploy.sh
REMOTE_DEPLOY

echo ""
echo "=== Full reset complete ==="
echo ""
echo "Connect from your Mac:"
echo "  bash scripts/connect.sh"
