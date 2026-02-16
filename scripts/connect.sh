#!/usr/bin/env bash
# SSH tunnel to OpenClaw VPS
# Opens port forwards for Gateway UI, Bridge, and noVNC (browser sandbox)
#
# Usage:
#   bash scripts/connect.sh
#   VPS_IP=1.2.3.4 bash scripts/connect.sh
#   VPS_IP=1.2.3.4 VPS_USER=root bash scripts/connect.sh
set -euo pipefail

VPS_IP="${VPS_IP:-76.13.36.58}"
VPS_USER="${VPS_USER:-openclaw}"

# Load .env from repo root to get gateway token
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

# Try to read gateway token from VPS .env via SSH
GATEWAY_TOKEN=""
REMOTE_TOKEN=$(ssh -o ConnectTimeout=5 "${VPS_USER}@${VPS_IP}" \
  'grep OPENCLAW_GATEWAY_TOKEN ~/openclaw-vps/.env 2>/dev/null | cut -d= -f2' 2>/dev/null || true)
if [[ -n "${REMOTE_TOKEN}" ]]; then
  GATEWAY_TOKEN="${REMOTE_TOKEN}"
fi

echo "=== OpenClaw VPS Tunnel ==="
echo ""
echo "Connecting to ${VPS_USER}@${VPS_IP}..."
echo ""
echo "Forwarded ports:"
if [[ -n "${GATEWAY_TOKEN}" ]]; then
  echo "  Dashboard  : http://localhost:18789/?token=${GATEWAY_TOKEN}"
else
  echo "  Gateway UI : http://localhost:18789"
fi
echo "  Bridge     : ws://localhost:18790"
echo "  noVNC      : http://localhost:6080"
echo ""
echo "Press Ctrl+C to disconnect."
echo ""

ssh -N \
  -L 18789:127.0.0.1:18789 \
  -L 18790:127.0.0.1:18790 \
  -L 6080:127.0.0.1:6080 \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  "${VPS_USER}@${VPS_IP}"
