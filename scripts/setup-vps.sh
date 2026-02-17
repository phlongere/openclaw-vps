#!/usr/bin/env bash
# KryllBot VPS provisioning script
# Run ONCE on a fresh VPS as root:
#   sshpass -p 'PASSWORD' ssh root@VPS_IP 'bash -s' < scripts/setup-vps.sh
#
# Or with SSH key:
#   ssh root@VPS_IP 'bash -s' < scripts/setup-vps.sh
set -euo pipefail

KRYLLBOT_USER="kryllbot"

echo "=== KryllBot VPS Provisioning ==="
echo ""

# 1) System update + base packages
echo "[1/7] Updating system and installing base packages..."

# Fix corrupted apt-show-versions hook (common on Hostinger templates)
if [[ -f /usr/bin/apt-show-versions ]] && ! apt-show-versions --version &>/dev/null; then
  echo "  Fixing broken apt-show-versions..."
  dpkg --remove --force-depends apt-show-versions 2>/dev/null || true
fi

apt-get update -qq || true
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq || true
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  ca-certificates curl git ufw sudo openssh-server

# 2) Create dedicated user
echo "[2/7] Creating user '${KRYLLBOT_USER}'..."
if id "${KRYLLBOT_USER}" &>/dev/null; then
  echo "  User '${KRYLLBOT_USER}' already exists, skipping."
else
  useradd -m -s /bin/bash "${KRYLLBOT_USER}"
  usermod -aG sudo "${KRYLLBOT_USER}"
  # No password login - SSH key only
  passwd -l "${KRYLLBOT_USER}"
  echo "  User created."
fi

# Passwordless sudo for kryllbot user
echo "${KRYLLBOT_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${KRYLLBOT_USER}
chmod 440 /etc/sudoers.d/${KRYLLBOT_USER}

# 3) Copy SSH authorized keys from root to new user
echo "[3/7] Setting up SSH keys..."
KRYLLBOT_HOME="/home/${KRYLLBOT_USER}"
mkdir -p "${KRYLLBOT_HOME}/.ssh"
if [[ -f /root/.ssh/authorized_keys ]]; then
  cp /root/.ssh/authorized_keys "${KRYLLBOT_HOME}/.ssh/authorized_keys"
fi
# Also add current Mac's public key if provided via env
if [[ -n "${SSH_PUBLIC_KEY:-}" ]]; then
  echo "${SSH_PUBLIC_KEY}" >> "${KRYLLBOT_HOME}/.ssh/authorized_keys"
fi
chmod 700 "${KRYLLBOT_HOME}/.ssh"
chmod 600 "${KRYLLBOT_HOME}/.ssh/authorized_keys" 2>/dev/null || true
chown -R "${KRYLLBOT_USER}:${KRYLLBOT_USER}" "${KRYLLBOT_HOME}/.ssh"

# 4) Install Docker
echo "[4/7] Installing Docker..."
if command -v docker &>/dev/null; then
  echo "  Docker already installed: $(docker --version)"
else
  curl -fsSL https://get.docker.com | sh || {
    echo "  Docker install script had errors, retrying apt..."
    apt-get update -qq || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  }
  echo "  Docker installed: $(docker --version)"
fi
usermod -aG docker "${KRYLLBOT_USER}"

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
mkdir -p "${KRYLLBOT_HOME}/.openclaw"
mkdir -p "${KRYLLBOT_HOME}/.openclaw/workspace"
mkdir -p "${KRYLLBOT_HOME}/.openclaw/agents/main/agent"
# Container runs as uid 1000 (node user)
chown -R 1000:1000 "${KRYLLBOT_HOME}/.openclaw"

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
echo "[7/7] Cloning kryllbot-vps deployment repo..."
DEPLOY_DIR="${KRYLLBOT_HOME}/kryllbot-vps"
if [[ -d "${DEPLOY_DIR}" ]]; then
  echo "  Repo already exists at ${DEPLOY_DIR}, pulling latest..."
  git config --global --add safe.directory "${DEPLOY_DIR}"
  cd "${DEPLOY_DIR}" && git pull --rebase
else
  git clone https://github.com/phlongere/openclaw-vps.git "${DEPLOY_DIR}"
fi
chown -R "${KRYLLBOT_USER}:${KRYLLBOT_USER}" "${DEPLOY_DIR}"

# Generate .env if not exists
ENV_FILE="${DEPLOY_DIR}/.env"
if [[ ! -f "${ENV_FILE}" ]]; then
  GATEWAY_TOKEN="$(openssl rand -hex 32)"
  cat > "${ENV_FILE}" <<EOF
KRYLLBOT_IMAGE=ghcr.io/phlongere/openclaw-vps:latest
KRYLLBOT_GATEWAY_TOKEN=${GATEWAY_TOKEN}
KRYLLBOT_GATEWAY_BIND=lan
KRYLLBOT_GATEWAY_PORT=18789
KRYLLBOT_BRIDGE_PORT=18790
KRYLLBOT_CONFIG_DIR=${KRYLLBOT_HOME}/.openclaw
KRYLLBOT_WORKSPACE_DIR=${KRYLLBOT_HOME}/.openclaw/workspace

# === User config (set before running deploy.sh) ===
KRYLLBOT_AGENT_NAME=Assistant
OPENAI_API_KEY=change-me
TELEGRAM_BOT_TOKEN=change-me
TELEGRAM_ALLOWED_USER=change-me
EOF
  chown "${KRYLLBOT_USER}:${KRYLLBOT_USER}" "${ENV_FILE}"
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
echo "     ssh-copy-id ${KRYLLBOT_USER}@$(hostname -I | awk '{print $1}')"
echo ""
echo "  2. Deploy KryllBot:"
echo "     ssh ${KRYLLBOT_USER}@$(hostname -I | awk '{print $1}') 'cd ~/kryllbot-vps && bash scripts/deploy.sh'"
echo ""
echo "  3. Connect from your Mac:"
echo "     bash scripts/connect.sh"
