#!/usr/bin/env bash
# OpenClaw VPS deployment script
# Run on the VPS (as openclaw user):
#   cd ~/openclaw-vps && bash scripts/deploy.sh
#
# Or from your Mac:
#   ssh openclaw@VPS_IP 'cd ~/openclaw-vps && bash scripts/deploy.sh'
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

cd "${ROOT_DIR}"

# Load .env
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
else
  echo "Error: .env not found. Run setup-vps.sh first or copy .env.example to .env" >&2
  exit 1
fi

IMAGE="${OPENCLAW_IMAGE:-ghcr.io/phlongere/openclaw-vps:latest}"
CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-/home/openclaw/.openclaw}"
AGENT_DIR="${CONFIG_DIR}/agents/main/agent"

echo "=== OpenClaw VPS Deploy ==="
echo ""

# 1) Pull latest gateway image
echo "[1/6] Pulling latest image: ${IMAGE}..."
docker pull "${IMAGE}"

# 2) Build sandbox-browser locally (small image, quick build)
echo "[2/6] Building sandbox-browser image..."
docker compose build openclaw-sandbox-browser

# 3) Generate openclaw.json config
echo "[3/6] Generating config files..."

sudo mkdir -p "${AGENT_DIR}"

# openclaw.json - main config (no secrets, uses env var substitution)
sudo tee "${CONFIG_DIR}/openclaw.json" > /dev/null <<OCJSON
{
  "gateway": {
    "port": 18789,
    "mode": "local",
    "bind": "lan",
    "auth": {
      "mode": "token",
      "token": "\${OPENCLAW_GATEWAY_TOKEN}"
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "openai/gpt-4o"
      },
      "workspace": "/home/node/.openclaw/workspace",
      "compaction": {
        "mode": "safeguard"
      }
    },
    "list": [
      {
        "id": "main",
        "default": true,
        "name": "${OPENCLAW_AGENT_NAME:-Assistant}"
      }
    ]
  },
  "channels": {
    "telegram": {
      "enabled": true,
      "botToken": "\${TELEGRAM_BOT_TOKEN}",
      "dmPolicy": "allowlist",
      "allowFrom": [${TELEGRAM_ALLOWED_USER:-0}],
      "groupPolicy": "disabled",
      "streamMode": "partial"
    }
  },
  "commands": {
    "native": "auto",
    "restart": true
  },
  "logging": {
    "level": "info",
    "consoleLevel": "info"
  }
}
OCJSON

# auth-profiles.json - secrets (API keys)
sudo tee "${AGENT_DIR}/auth-profiles.json" > /dev/null <<AUTHJSON
{
  "version": 1,
  "profiles": {
    "openai:default": {
      "type": "api_key",
      "provider": "openai",
      "key": "${OPENAI_API_KEY}"
    }
  },
  "order": {
    "openai": ["openai:default"]
  }
}
AUTHJSON

# Fix ownership (container runs as uid 1000 = node)
sudo chown -R 1000:1000 "${CONFIG_DIR}"

echo "  openclaw.json written to ${CONFIG_DIR}/openclaw.json"
echo "  auth-profiles.json written to ${AGENT_DIR}/auth-profiles.json"

# 4) Stop existing containers and start fresh
echo "[4/6] Restarting containers..."
docker compose down --remove-orphans 2>/dev/null || true
docker compose up -d

# 5) Wait for gateway to start
echo "[5/6] Waiting for gateway..."

HEALTHY=false
for i in $(seq 1 60); do
  if docker compose logs --tail 10 openclaw-gateway 2>&1 | grep -q "listening on"; then
    HEALTHY=true
    break
  fi
  sleep 1
done

# 6) Final status
echo "[6/6] Verifying gateway..."

if [[ "${HEALTHY}" == "true" ]]; then
  echo ""
  echo "=== Deploy successful ==="
  echo ""
  docker compose ps
  echo ""
  echo "Dashboard URL (via SSH tunnel):"
  echo "  http://127.0.0.1:18789/?token=${OPENCLAW_GATEWAY_TOKEN}"
  echo ""
  echo "From your Mac, connect with:"
  echo "  bash scripts/connect.sh"
  echo ""
  echo "Logs:"
  echo "  docker compose logs -f openclaw-gateway"
else
  echo ""
  echo "=== Warning: gateway may not be healthy ==="
  docker compose ps
  echo ""
  echo "Recent logs:"
  docker compose logs --tail 30 openclaw-gateway
  echo ""
  echo "Check full logs: docker compose logs -f openclaw-gateway"
fi
