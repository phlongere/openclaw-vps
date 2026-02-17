# KryllBot VPS - Project Guidelines

## What This Is
VPS deployment toolkit for KryllBot (OpenClaw-based AI agent). Includes:
- **VPS scripts**: provisioning, deploy, connect, reset (`scripts/`)
- **Electron Mac app**: one-click deployer (`app/`)
- **Docker setup**: gateway + sandbox-browser containers (`docker-compose.yml`)

## Architecture
- **Gateway**: OpenClaw gateway in Docker (`ghcr.io/phlongere/openclaw-vps:latest`)
- **Sandbox Browser**: Chromium + Xvfb + noVNC + socat for browser control via CDP
- **Electron App**: Node.js main process (ssh2, electron-store) + vanilla JS renderer
- **SSH tunnels**: 3 ports forwarded (18789 gateway, 18790 bridge, 6080 noVNC)

## Key File Layout
```
scripts/
  setup-vps.sh          # Full VPS provisioning (Docker, firewall, user)
  deploy.sh             # Pull image, generate openclaw.json, docker compose up
  connect.sh            # SSH tunnel helper
  reset-vps.sh          # Factory reset
  sandbox-browser-entrypoint.sh  # Chrome + Xvfb + VNC + CDP socat proxy
app/
  .env.dev              # Dev defaults (gitignored, secrets go here)
  src/main/
    index.js            # Electron main, IPC handlers
    deployment/manager.js  # 6-step deploy orchestration
    ssh/client.js       # SSH via ssh2
    ssh/tunnel.js       # Port forwarding
    credentials/store.js  # safeStorage + electron-store
  src/renderer/
    index.html          # 3 views: config, progress, dashboard
    js/app.js           # UI logic
    js/preload.js       # contextBridge IPC
    styles/main.css     # Dark theme
docker-compose.yml      # Gateway + sandbox-browser services
Dockerfile.sandbox-browser
.env.example
```

## Commands
```bash
# Run Electron app (dev)
cd app && npx electron .

# Kill + relaunch
pkill -f "electron \." 2>/dev/null; sleep 1; cd app && npx electron . &>/dev/null &

# VPS direct access
ssh kryllbot@76.13.36.58
cd ~/kryllbot-vps && docker compose logs --tail 50
```

## Dev Defaults
Put your dev/test credentials in `app/.env.dev` (gitignored):
```env
VPS_IP=...
ROOT_PASSWORD=...
API_KEY=sk-...
TELEGRAM_TOKEN=...
TELEGRAM_USER_ID=...
```
The app loads these automatically at startup. Never hardcode secrets in source files.

## Important Technical Details

### Rename State (OPENCLAW -> KRYLLBOT)
- Local files use KRYLLBOT_* (env vars, services, paths)
- VPS may still run old code from GitHub with OPENCLAW_*
- manager.js handles both via regex: `(KRYLLBOT|OPENCLAW)_*`
- deploy.sh has migration block for legacy .env files

### Browser Control (CDP)
- Chrome CDP rejects non-IP `Host` headers -> must use container IP, not Docker DNS
- Gateway needs: `browser.enabled: true`, `browser.cdpUrl: http://<container-ip>:9222`
- Also needs: `agents.defaults.sandbox.browser.enabled: true`
- Container IP found via: `docker inspect <container> --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'`
- Sandbox entrypoint uses `--remote-allow-origins=*` + socat proxy for CDP access

### Gateway Auth (2 layers)
1. **Gateway token**: shared secret in .env, passed via `?token=` URL param
2. **Device pairing**: Ed25519 per-device identity, auto-approved via SSH post-deploy

### Deploy Flow (manager.js)
1. SSH test (root)
2. Provision (setup-vps.sh or post-snapshot minimal)
3. Configure (detect user/repo, inject .env, read token)
4. Deploy (deploy.sh) + re-read token + inject browser CDP config
5. Tunnel (3 SSH port forwards)
6. Verify (health check + auto-approve devices)

## Workflow Rules
- **Commit after important changes** - don't batch too many unrelated changes
- **Never commit secrets** - use `.env.dev` for dev defaults, GitHub push protection is on
- **Test the app** after UI changes: `pkill -f "electron \."; cd app && npx electron .`
- Keep retrocompatibility with OPENCLAW_* until GitHub code is fully migrated
