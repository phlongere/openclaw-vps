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

echo "=== OpenClaw VPS Deploy ==="
echo ""

# 1) Pull latest gateway image
echo "[1/5] Pulling latest image: ${IMAGE}..."
docker pull "${IMAGE}"

# 2) Build sandbox-browser locally (small image, quick build)
echo "[2/5] Building sandbox-browser image..."
docker compose build openclaw-sandbox-browser

# 3) Stop existing containers and start fresh
echo "[3/5] Restarting containers..."
docker compose down --remove-orphans 2>/dev/null || true
docker compose up -d

# 4) Wait for gateway to produce logs, then auto-configure if needed
echo "[4/5] Checking gateway config..."

# Wait up to 30s for the gateway to emit at least one log line
GATEWAY_READY=false
for i in $(seq 1 30); do
  LOGS="$(docker compose logs --tail 5 openclaw-gateway 2>&1)"
  if [[ -n "${LOGS}" ]]; then
    GATEWAY_READY=true
    break
  fi
  sleep 1
done

if [[ "${GATEWAY_READY}" != "true" ]]; then
  echo "  Warning: gateway produced no logs after 30s. Continuing anyway..."
fi

# Check if gateway needs first-time configuration
if docker compose logs --tail 20 openclaw-gateway 2>&1 | grep -q "Missing config"; then
  echo "  First-time setup: configuring gateway..."
  docker compose run --rm openclaw-gateway node dist/index.js config set gateway.mode local
  docker compose run --rm openclaw-gateway node dist/index.js config set gateway.auth.mode token
  docker compose run --rm openclaw-gateway node dist/index.js config set gateway.auth.token "${OPENCLAW_GATEWAY_TOKEN}"
  echo "  Restarting gateway with new config..."
  docker compose restart openclaw-gateway

  # Wait for gateway to actually start listening
  echo "  Waiting for gateway to start..."
  for i in $(seq 1 30); do
    if docker compose logs --tail 10 openclaw-gateway 2>&1 | grep -q "listening on"; then
      break
    fi
    sleep 1
  done
fi

# 5) Final health check: verify gateway is listening
echo "[5/5] Verifying gateway..."

HEALTHY=false
for i in $(seq 1 15); do
  if docker compose logs --tail 10 openclaw-gateway 2>&1 | grep -q "listening on"; then
    HEALTHY=true
    break
  fi
  sleep 1
done

if [[ "${HEALTHY}" == "true" ]]; then
  echo ""
  echo "=== Deploy successful ==="
  echo ""
  docker compose ps
  echo ""
  echo "Gateway token: ${OPENCLAW_GATEWAY_TOKEN}"
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
  docker compose logs --tail 20 openclaw-gateway
  echo ""
  echo "Check full logs: docker compose logs -f openclaw-gateway"
fi
