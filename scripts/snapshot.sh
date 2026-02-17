#!/usr/bin/env bash
# Manage VPS snapshots via Hostinger API.
#
# Usage:
#   HOSTINGER_API_TOKEN=xxx bash scripts/snapshot.sh <action>
#
# Actions:
#   create   - Create a snapshot of the current VPS state
#   restore  - Restore the VPS from the saved snapshot
#   status   - Show current snapshot info
#   delete   - Delete the existing snapshot
#
# Required env: HOSTINGER_API_TOKEN
# Optional env: VPS_ID (auto-detected if not set)
set -euo pipefail

API_BASE="https://developers.hostinger.com/api/vps/v1"
ACTION="${1:-status}"

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

# Auto-detect VPS ID
if [[ -z "${VPS_ID:-}" ]]; then
  VPS_ID=$(api GET "/virtual-machines" | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['id'])")
  echo "Auto-detected VPS ID: ${VPS_ID}"
fi

case "${ACTION}" in
  create)
    echo "Creating snapshot..."
    RESULT=$(api POST "/virtual-machines/${VPS_ID}/snapshot")
    echo "${RESULT}" | python3 -m json.tool
    echo ""
    echo "Snapshot creation started. It may take a few minutes."
    echo "Check status with: bash scripts/snapshot.sh status"
    ;;

  restore)
    echo "Restoring VPS from snapshot..."
    RESULT=$(api POST "/virtual-machines/${VPS_ID}/snapshot/restore")
    echo "${RESULT}" | python3 -m json.tool
    echo ""
    echo "Restore started. Waiting for VPS to come back..."

    # Remove old host key
    VPS_IP=$(api GET "/virtual-machines/${VPS_ID}" | python3 -c "import json,sys; print(json.load(sys.stdin)['ipv4'][0]['address'])")
    ssh-keygen -R "${VPS_IP}" 2>/dev/null || true

    # Wait for running state
    for i in $(seq 1 60); do
      STATE=$(api GET "/virtual-machines/${VPS_ID}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('state','unknown'))" 2>/dev/null || echo "unknown")
      if [[ "${STATE}" == "running" ]]; then
        echo "VPS is running!"
        break
      fi
      printf "  [%02d/60] State: %s\r" "$i" "${STATE}"
      sleep 5
    done

    # Wait for SSH
    echo "Waiting for SSH..."
    for i in $(seq 1 30); do
      if ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new "root@${VPS_IP}" 'true' 2>/dev/null; then
        echo "SSH is up! VPS restored from snapshot."
        break
      fi
      sleep 5
    done
    ;;

  status)
    echo "Fetching snapshot info..."
    RESULT=$(api GET "/virtual-machines/${VPS_ID}/snapshot" 2>&1) || {
      echo "No snapshot found (or API error)."
      exit 0
    }
    echo "${RESULT}" | python3 -m json.tool
    ;;

  delete)
    echo "Deleting snapshot..."
    api DELETE "/virtual-machines/${VPS_ID}/snapshot"
    echo "Snapshot deleted."
    ;;

  *)
    echo "Unknown action: ${ACTION}" >&2
    echo "Usage: $0 <create|restore|status|delete>" >&2
    exit 1
    ;;
esac
