#!/usr/bin/env bash
# KryllBot VPS deployment script
# Run on the VPS (as kryllbot user):
#   cd ~/kryllbot-vps && bash scripts/deploy.sh
#
# Or from your Mac:
#   ssh kryllbot@VPS_IP 'cd ~/kryllbot-vps && bash scripts/deploy.sh'
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

cd "${ROOT_DIR}"

# Load .env
if [[ -f .env ]]; then
  # Migrate legacy OPENCLAW_* vars to KRYLLBOT_* if needed
  if grep -q '^OPENCLAW_' .env 2>/dev/null; then
    echo "Migrating .env from OPENCLAW_* to KRYLLBOT_*..."
    sed -i 's/^OPENCLAW_IMAGE=/KRYLLBOT_IMAGE=/' .env
    sed -i 's/^OPENCLAW_GATEWAY_TOKEN=/KRYLLBOT_GATEWAY_TOKEN=/' .env
    sed -i 's/^OPENCLAW_GATEWAY_BIND=/KRYLLBOT_GATEWAY_BIND=/' .env
    sed -i 's/^OPENCLAW_GATEWAY_PORT=/KRYLLBOT_GATEWAY_PORT=/' .env
    sed -i 's/^OPENCLAW_BRIDGE_PORT=/KRYLLBOT_BRIDGE_PORT=/' .env
    sed -i 's/^OPENCLAW_CONFIG_DIR=/KRYLLBOT_CONFIG_DIR=/' .env
    sed -i 's/^OPENCLAW_WORKSPACE_DIR=/KRYLLBOT_WORKSPACE_DIR=/' .env
    sed -i 's/^OPENCLAW_AGENT_NAME=/KRYLLBOT_AGENT_NAME=/' .env
    # Fix paths from /home/openclaw to /home/kryllbot
    sed -i 's|/home/openclaw/|/home/kryllbot/|g' .env
  fi
  set -a
  source .env
  set +a
else
  echo "Error: .env not found. Run setup-vps.sh first or copy .env.example to .env" >&2
  exit 1
fi

IMAGE="${KRYLLBOT_IMAGE:-ghcr.io/phlongere/openclaw-vps:latest}"
CONFIG_DIR="${KRYLLBOT_CONFIG_DIR:-/home/kryllbot/.openclaw}"
AGENT_DIR="${CONFIG_DIR}/agents/main/agent"

# Auto-generate gateway token if not set or still default
if [[ -z "${KRYLLBOT_GATEWAY_TOKEN:-}" ]] || [[ "${KRYLLBOT_GATEWAY_TOKEN}" == "change-me" ]]; then
  KRYLLBOT_GATEWAY_TOKEN=$(openssl rand -hex 32)
  sed -i "s|^KRYLLBOT_GATEWAY_TOKEN=.*|KRYLLBOT_GATEWAY_TOKEN=${KRYLLBOT_GATEWAY_TOKEN}|" .env
  echo "Generated gateway token: ${KRYLLBOT_GATEWAY_TOKEN:0:8}..."
fi

echo "=== KryllBot VPS Deploy ==="
echo ""

# 1) Pull latest gateway image
echo "[1/6] Pulling latest image: ${IMAGE}..."
docker pull "${IMAGE}"

# 2) Build sandbox-browser locally (small image, quick build)
echo "[2/6] Building sandbox-browser image..."
docker compose build kryllbot-sandbox-browser

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
      "token": "\${KRYLLBOT_GATEWAY_TOKEN}"
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
      },
      "sandbox": {
        "browser": {
          "enabled": true
        }
      }
    },
    "list": [
      {
        "id": "main",
        "default": true,
        "name": "${KRYLLBOT_AGENT_NAME:-Assistant}"
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
  },
  "browser": {
    "enabled": true,
    "defaultProfile": "openclaw"
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

# Ensure workspace dir exists
WORKSPACE_DIR="${KRYLLBOT_WORKSPACE_DIR:-/home/kryllbot/.openclaw/workspace}"
sudo mkdir -p "${WORKSPACE_DIR}"

# Fix ownership (container runs as uid 1000 = node)
sudo chown -R 1000:1000 "${CONFIG_DIR}"

echo "  openclaw.json written to ${CONFIG_DIR}/openclaw.json"
echo "  auth-profiles.json written to ${AGENT_DIR}/auth-profiles.json"

# 4) Stop existing containers and start fresh
echo "[4/6] Restarting containers..."
docker compose down --remove-orphans 2>/dev/null || true
docker compose up -d

# 4b) Inject sandbox-browser CDP URL into gateway config
# Chrome CDP rejects non-IP Host headers, so we must use the container IP
SANDBOX_CONTAINER=$(docker compose ps --format '{{.Name}}' 2>/dev/null | grep sandbox-browser | head -1)
if [[ -n "${SANDBOX_CONTAINER}" ]]; then
  SANDBOX_IP=$(docker inspect "${SANDBOX_CONTAINER}" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
  if [[ -n "${SANDBOX_IP}" ]]; then
    echo "  Sandbox browser IP: ${SANDBOX_IP}"
    CDP_URL="http://${SANDBOX_IP}:9222"
    # Patch openclaw.json with browser CDP URL using jq if available, otherwise node
    if command -v jq &>/dev/null; then
      sudo jq --arg url "${CDP_URL}" '.browser.cdpUrl = $url | .browser.profiles.openclaw = {"cdpUrl": $url, "color": "#FF4500"}' \
        "${CONFIG_DIR}/openclaw.json" > /tmp/openclaw.json.tmp && sudo mv /tmp/openclaw.json.tmp "${CONFIG_DIR}/openclaw.json"
    else
      # Fallback: use node inside the gateway container
      GATEWAY_CONTAINER=$(docker compose ps --format '{{.Name}}' 2>/dev/null | grep gateway | head -1)
      if [[ -n "${GATEWAY_CONTAINER}" ]]; then
        docker exec "${GATEWAY_CONTAINER}" node -e "
          const fs = require('fs');
          const p = '/home/node/.openclaw/openclaw.json';
          const c = JSON.parse(fs.readFileSync(p, 'utf8'));
          c.browser = c.browser || {};
          c.browser.cdpUrl = '${CDP_URL}';
          c.browser.profiles = c.browser.profiles || {};
          c.browser.profiles.openclaw = { cdpUrl: '${CDP_URL}', color: '#FF4500' };
          fs.writeFileSync(p, JSON.stringify(c, null, 2));
        "
      fi
    fi
    sudo chown 1000:1000 "${CONFIG_DIR}/openclaw.json"
    echo "  Browser CDP URL injected: ${CDP_URL}"
  fi
fi

# 5) Wait for gateway to start
echo "[5/6] Waiting for gateway..."

HEALTHY=false
for i in $(seq 1 60); do
  if docker compose logs --tail 10 kryllbot-gateway 2>&1 | grep -q "listening on"; then
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
  echo "  http://127.0.0.1:18789/?token=${KRYLLBOT_GATEWAY_TOKEN}"
  echo ""
  echo "From your Mac, connect with:"
  echo "  bash scripts/connect.sh"
  echo ""
  echo "Logs:"
  echo "  docker compose logs -f kryllbot-gateway"
else
  echo ""
  echo "=== Warning: gateway may not be healthy ==="
  docker compose ps
  echo ""
  echo "Recent logs:"
  docker compose logs --tail 30 kryllbot-gateway
  echo ""
  echo "Check full logs: docker compose logs -f kryllbot-gateway"
fi
