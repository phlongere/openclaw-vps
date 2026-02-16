#!/usr/bin/env bash
# OpenClaw VPS provisioning script
# Run ONCE on a fresh VPS as root:
#   sshpass -p 'PASSWORD' ssh root@VPS_IP 'bash -s' < scripts/setup-vps.sh
#
# Or with SSH key:
#   ssh root@VPS_IP 'bash -s' < scripts/setup-vps.sh
set -euo pipefail

OPENCLAW_USER="openclaw"

echo "=== OpenClaw VPS Provisioning ==="
echo ""

# 1) System update + base packages
echo "[1/7] Updating system and installing base packages..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  ca-certificates curl git ufw sudo openssh-server

# 2) Create dedicated user
echo "[2/7] Creating user '${OPENCLAW_USER}'..."
if id "${OPENCLAW_USER}" &>/dev/null; then
  echo "  User '${OPENCLAW_USER}' already exists, skipping."
else
  useradd -m -s /bin/bash "${OPENCLAW_USER}"
  usermod -aG sudo "${OPENCLAW_USER}"
  # No password login - SSH key only
  passwd -l "${OPENCLAW_USER}"
  echo "  User created."
fi

# Passwordless sudo for openclaw user
echo "${OPENCLAW_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${OPENCLAW_USER}
chmod 440 /etc/sudoers.d/${OPENCLAW_USER}

# 3) Copy SSH authorized keys from root to new user
echo "[3/7] Setting up SSH keys..."
OPENCLAW_HOME="/home/${OPENCLAW_USER}"
mkdir -p "${OPENCLAW_HOME}/.ssh"
if [[ -f /root/.ssh/authorized_keys ]]; then
  cp /root/.ssh/authorized_keys "${OPENCLAW_HOME}/.ssh/authorized_keys"
fi
# Also add current Mac's public key if provided via env
if [[ -n "${SSH_PUBLIC_KEY:-}" ]]; then
  echo "${SSH_PUBLIC_KEY}" >> "${OPENCLAW_HOME}/.ssh/authorized_keys"
fi
chmod 700 "${OPENCLAW_HOME}/.ssh"
chmod 600 "${OPENCLAW_HOME}/.ssh/authorized_keys" 2>/dev/null || true
chown -R "${OPENCLAW_USER}:${OPENCLAW_USER}" "${OPENCLAW_HOME}/.ssh"

# 4) Install Docker
echo "[4/7] Installing Docker..."
if command -v docker &>/dev/null; then
  echo "  Docker already installed: $(docker --version)"
else
  curl -fsSL https://get.docker.com | sh
  echo "  Docker installed: $(docker --version)"
fi
usermod -aG docker "${OPENCLAW_USER}"

# Ensure Docker starts on boot
systemctl enable docker
systemctl start docker

# Disable IPv6 (workaround for Hostinger <-> GHCR connectivity issues)
sysctl -w net.ipv6.conf.all.disable_ipv6=1
sysctl -w net.ipv6.conf.default.disable_ipv6=1
grep -q 'disable_ipv6' /etc/sysctl.conf || cat >> /etc/sysctl.conf <<'SYSCTL'
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
SYSCTL

# 5) Create persistent directories
echo "[5/7] Creating persistent directories..."
mkdir -p "${OPENCLAW_HOME}/.openclaw"
mkdir -p "${OPENCLAW_HOME}/.openclaw/workspace"
# Container runs as uid 1000 (node user)
chown -R 1000:1000 "${OPENCLAW_HOME}/.openclaw"

# 6) Firewall
echo "[6/7] Configuring firewall (ufw)..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
# Gateway ports stay on loopback only (via docker-compose binding)
# No need to open them in ufw
ufw --force enable
echo "  Firewall enabled: SSH only."

# 7) Clone deployment repo
echo "[7/7] Cloning openclaw-vps deployment repo..."
DEPLOY_DIR="${OPENCLAW_HOME}/openclaw-vps"
if [[ -d "${DEPLOY_DIR}" ]]; then
  echo "  Repo already exists at ${DEPLOY_DIR}, pulling latest..."
  cd "${DEPLOY_DIR}" && git pull --rebase
else
  git clone https://github.com/phlongere/openclaw-vps.git "${DEPLOY_DIR}"
fi
chown -R "${OPENCLAW_USER}:${OPENCLAW_USER}" "${DEPLOY_DIR}"

# Generate .env if not exists
ENV_FILE="${DEPLOY_DIR}/.env"
if [[ ! -f "${ENV_FILE}" ]]; then
  GATEWAY_TOKEN="$(openssl rand -hex 32)"
  cat > "${ENV_FILE}" <<EOF
OPENCLAW_IMAGE=ghcr.io/phlongere/openclaw-vps:latest
OPENCLAW_GATEWAY_TOKEN=${GATEWAY_TOKEN}
OPENCLAW_GATEWAY_BIND=lan
OPENCLAW_GATEWAY_PORT=18789
OPENCLAW_BRIDGE_PORT=18790
OPENCLAW_CONFIG_DIR=${OPENCLAW_HOME}/.openclaw
OPENCLAW_WORKSPACE_DIR=${OPENCLAW_HOME}/.openclaw/workspace
EOF
  chown "${OPENCLAW_USER}:${OPENCLAW_USER}" "${ENV_FILE}"
  echo ""
  echo "=== Gateway token (save this!) ==="
  echo "${GATEWAY_TOKEN}"
  echo "=================================="
fi

echo ""
echo "=== Provisioning complete ==="
echo ""
echo "VPS is ready. Next steps:"
echo "  1. From your Mac, add your SSH key:"
echo "     ssh-copy-id ${OPENCLAW_USER}@$(hostname -I | awk '{print $1}')"
echo ""
echo "  2. Deploy OpenClaw:"
echo "     ssh ${OPENCLAW_USER}@$(hostname -I | awk '{print $1}') 'cd ~/openclaw-vps && bash scripts/deploy.sh'"
echo ""
echo "  3. Connect from your Mac:"
echo "     bash scripts/connect.sh"
