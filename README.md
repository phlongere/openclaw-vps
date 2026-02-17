# kryllbot-vps

Docker images and deployment scripts for running [KryllBot](https://kryll.io) on a VPS (Hostinger).

## Architecture

- **Gateway image** (`ghcr.io/phlongere/openclaw-vps:latest`): Built from OpenClaw source, multi-arch (amd64/arm64)
- **Sandbox browser** (`kryllbot-sandbox-browser:bookworm-slim`): Chromium + noVNC for browser tool access
- **SSH tunnels**: Secure access to Gateway UI and noVNC from your Mac

## Quick Start

### 1. Provision VPS (once)

```bash
sshpass -p 'ROOT_PASSWORD' ssh -o StrictHostKeyChecking=accept-new root@VPS_IP 'bash -s' < scripts/setup-vps.sh
```

### 2. Deploy

```bash
ssh kryllbot@VPS_IP 'cd ~/kryllbot-vps && bash scripts/deploy.sh'
```

### 3. Connect

```bash
bash scripts/connect.sh
# Gateway UI: http://localhost:18789
# noVNC:      http://localhost:6080
```

## Updating

```bash
ssh kryllbot@VPS_IP 'cd ~/kryllbot-vps && git pull && bash scripts/deploy.sh'
```

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Gateway image (built from OpenClaw source) |
| `Dockerfile.sandbox-browser` | Chromium + Xvfb + noVNC sandbox |
| `docker-compose.yml` | Service orchestration |
| `scripts/setup-vps.sh` | One-time VPS provisioning |
| `scripts/deploy.sh` | Pull + restart containers |
| `scripts/connect.sh` | SSH tunnels to VPS |
