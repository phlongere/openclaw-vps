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

# 1) Pull latest images
echo "[1/4] Pulling latest image: ${IMAGE}..."
docker pull "${IMAGE}"

# Build sandbox-browser locally (small image, quick build)
echo "[2/4] Building sandbox-browser image..."
docker compose build openclaw-sandbox-browser

# 3) Stop existing containers (if any)
echo "[3/4] Restarting containers..."
docker compose down --remove-orphans 2>/dev/null || true
docker compose up -d

# 4) Health check
echo "[4/4] Waiting for gateway to start..."
sleep 3

if docker compose ps --format json | grep -q '"running"'; then
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
  echo "=== Warning: containers may not be healthy ==="
  docker compose ps
  echo ""
  echo "Check logs: docker compose logs"
fi
