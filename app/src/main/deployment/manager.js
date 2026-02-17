const { SSHClient } = require('../ssh/client');
const { SSHTunnel } = require('../ssh/tunnel');
const fs = require('fs');
const path = require('path');
const http = require('http');

class DeploymentManager {
  constructor(window, scriptsRoot) {
    this.window = window;
    this.scriptsRoot = scriptsRoot;
    this.sshRoot = null;
    this.sshUser = null;
    this.tunnel = null;
    this.gatewayToken = null;

    this.steps = [
      { id: 'ssh-test', label: 'Testing SSH connection', status: 'pending' },
      { id: 'provision', label: 'Provisioning VPS', detail: 'Docker, firewall, user setup', status: 'pending' },
      { id: 'config', label: 'Configuring KryllBot', detail: 'Agent, API keys, Telegram', status: 'pending' },
      { id: 'deploy', label: 'Deploying containers', detail: 'Pull image, start gateway + browser', status: 'pending' },
      { id: 'tunnel', label: 'Establishing tunnel', detail: 'Gateway, bridge, noVNC', status: 'pending' },
      { id: 'verify', label: 'Verifying deployment', detail: 'Health check', status: 'pending' }
    ];
  }

  send(channel, data) {
    if (this.window && !this.window.isDestroyed()) {
      this.window.webContents.send(channel, data);
    }
  }

  log(message) {
    this.send('deployment:log', message);
  }

  updateSteps() {
    this.send('deployment:steps', this.steps);
  }

  async runStep(index, fn) {
    this.steps[index].status = 'running';
    this.updateSteps();

    try {
      await fn();
      this.steps[index].status = 'complete';
      this.updateSteps();
    } catch (err) {
      this.steps[index].status = 'error';
      this.steps[index].error = err.message;
      this.updateSteps();
      throw err;
    }
  }

  async deploy(config) {
    const { vpsIp, rootPassword, agentName, llmProvider, apiKey, telegramToken, telegramUserId, installMode, hostingerApiToken } = config;
    // installMode: 'full' = provision + deploy, 'snapshot' = restore + deploy, 'deploy-only' = just deploy

    // If snapshot mode, restore from snapshot first
    if (installMode === 'snapshot' && hostingerApiToken) {
      await this.restoreSnapshot(hostingerApiToken, vpsIp);
    }

    try {
      // Step 1: Test SSH
      await this.runStep(0, async () => {
        this.log('Connecting to ' + vpsIp + ' as root...');
        this.sshRoot = new SSHClient(vpsIp, 'root', rootPassword);
        await this.sshRoot.connect();
        this.log('SSH connection established');
      });

      // Step 2: Provision VPS
      await this.runStep(1, async () => {
        if (installMode === 'deploy-only') {
          this.log('Skipping provisioning (deploy only mode)');
          return;
        }

        if (installMode === 'snapshot') {
          this.log('Running post-snapshot setup (user, repo, firewall)...');
          // Only run the parts of setup that aren't in the snapshot (user creation, repo clone)
          const postSnapshotScript = `
set -e
# Disable IPv6 (Hostinger VPS IPv6 drops GHCR connections)
sysctl -w net.ipv6.conf.all.disable_ipv6=1 2>/dev/null || true
sysctl -w net.ipv6.conf.default.disable_ipv6=1 2>/dev/null || true
mkdir -p /etc/docker
echo '{"ip6tables":false,"ipv6":false}' > /etc/docker/daemon.json
systemctl restart docker

# Detect or create deploy user (support legacy openclaw or new kryllbot)
if id kryllbot &>/dev/null; then
  DEPLOY_USER=kryllbot
elif id openclaw &>/dev/null; then
  DEPLOY_USER=openclaw
else
  useradd -m -s /bin/bash -G docker kryllbot
  echo "kryllbot ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/kryllbot
  mkdir -p /home/kryllbot/.ssh
  cp /root/.ssh/authorized_keys /home/kryllbot/.ssh/ 2>/dev/null || true
  chown -R kryllbot:kryllbot /home/kryllbot/.ssh
  chmod 700 /home/kryllbot/.ssh
  DEPLOY_USER=kryllbot
fi

# Ensure user has docker group and SSH keys
usermod -aG docker \$DEPLOY_USER 2>/dev/null || true
mkdir -p /home/\$DEPLOY_USER/.ssh
cp /root/.ssh/authorized_keys /home/\$DEPLOY_USER/.ssh/ 2>/dev/null || true
chown -R \$DEPLOY_USER:\$DEPLOY_USER /home/\$DEPLOY_USER/.ssh
chmod 700 /home/\$DEPLOY_USER/.ssh

# Clone repo if not exists (check both paths)
if [ ! -d /home/\$DEPLOY_USER/kryllbot-vps ] && [ ! -d /home/\$DEPLOY_USER/openclaw-vps ]; then
  su - \$DEPLOY_USER -c 'git clone https://github.com/phlongere/openclaw-vps.git ~/kryllbot-vps'
  su - \$DEPLOY_USER -c 'cp ~/kryllbot-vps/.env.example ~/kryllbot-vps/.env'
fi

echo "Post-snapshot setup complete (user: \$DEPLOY_USER)"
`;
          await this.sshRoot.execScript(postSnapshotScript, (line) => this.log(line));
          return;
        }

        const scriptPath = path.join(this.scriptsRoot, 'scripts', 'setup-vps.sh');
        const script = fs.readFileSync(scriptPath, 'utf-8');
        this.log('Running VPS provisioning (this takes a few minutes)...');
        await this.sshRoot.execScript(script, (line) => this.log(line));
        this.log('VPS provisioned successfully');
      });

      // Step 3: Configure
      await this.runStep(2, async () => {
        // Detect which user exists on the VPS (before disconnecting root)
        const userCheck = await this.sshRoot.exec('id kryllbot &>/dev/null && echo kryllbot || echo openclaw');
        this.vpsUser = userCheck.stdout.trim();
        this.sshRoot.disconnect();

        this.log(`Connecting as ${this.vpsUser} user...`);
        this.sshUser = new SSHClient(vpsIp, this.vpsUser, rootPassword);
        await this.sshUser.connect();

        // Detect repo path (new kryllbot-vps or legacy openclaw-vps)
        const repoCheck = await this.sshUser.exec('[ -d ~/kryllbot-vps ] && echo kryllbot-vps || echo openclaw-vps');
        this.repoDir = repoCheck.stdout.trim();

        // Pull latest repo
        this.log('Pulling latest deployment repo...');
        await this.sshUser.execStream(
          `cd ~/${this.repoDir} && git pull --rebase origin main 2>&1`,
          (line) => this.log(line)
        );

        // Read current gateway token from .env (support both old and new var names)
        const envResult = await this.sshUser.exec(
          `grep -E '(KRYLLBOT|OPENCLAW)_GATEWAY_TOKEN' ~/${this.repoDir}/.env | head -1 | cut -d= -f2`
        );
        this.gatewayToken = envResult.stdout.trim();
        this.log(`Gateway token from .env: ${this.gatewayToken ? this.gatewayToken.substring(0, 8) + '...' : '(empty)'}`);
        this.log(`Detected user: ${this.vpsUser}, repo: ${this.repoDir}`);

        // Determine provider-specific env var name
        const providerEnvKey = this.getProviderEnvKey(llmProvider);

        // Update .env with user config (support both old and new var names)
        this.log('Injecting configuration...');
        const sedCmds = [
          `sed -i "s|^\\(KRYLLBOT\\|OPENCLAW\\)_AGENT_NAME=.*|\\1_AGENT_NAME=${this.shellEscape(agentName)}|" .env`,
          `sed -i "s|^OPENAI_API_KEY=.*|${providerEnvKey}=${this.shellEscape(apiKey)}|" .env`,
          `sed -i "s|^TELEGRAM_BOT_TOKEN=.*|TELEGRAM_BOT_TOKEN=${this.shellEscape(telegramToken)}|" .env`,
          `sed -i "s|^TELEGRAM_ALLOWED_USER=.*|TELEGRAM_ALLOWED_USER=${this.shellEscape(telegramUserId)}|" .env`
        ].join(' && ');

        await this.sshUser.exec(`cd ~/${this.repoDir} && ${sedCmds}`);
        this.log('Configuration applied');
      });

      // Step 4: Deploy
      await this.runStep(3, async () => {
        this.log('Deploying containers...');
        await this.sshUser.execStream(
          `cd ~/${this.repoDir} && bash scripts/deploy.sh 2>&1`,
          (line) => this.log(line)
        );
        this.log('Containers deployed');

        // Re-read gateway token (deploy.sh may have generated a new one)
        const tokenResult = await this.sshUser.exec(
          `grep -E '(KRYLLBOT|OPENCLAW)_GATEWAY_TOKEN' ~/${this.repoDir}/.env | head -1 | cut -d= -f2`
        );
        const newToken = tokenResult.stdout.trim();
        if (newToken && newToken !== this.gatewayToken) {
          this.log(`Gateway token updated: ${newToken.substring(0, 8)}...`);
          this.gatewayToken = newToken;
        }

        // Inject browser CDP config for sandbox-browser container
        await this.configureBrowserCDP();
      });

      // Step 5: Tunnel
      await this.runStep(4, async () => {
        this.log('Establishing SSH tunnels...');
        this.tunnel = new SSHTunnel(vpsIp, this.vpsUser, rootPassword);
        await this.tunnel.connect();
        await this.tunnel.setupKryllBotTunnels();
        this.log('Tunnels active: Gateway (18789), Bridge (18790), noVNC (6080)');
      });

      // Step 6: Verify
      await this.runStep(5, async () => {
        this.log('Checking gateway health...');

        // Wait up to 15s for gateway to respond
        let healthy = false;
        for (let i = 0; i < 15; i++) {
          try {
            await this.httpGet('http://127.0.0.1:18789/');
            healthy = true;
            break;
          } catch {
            await this.sleep(1000);
          }
        }

        if (!healthy) {
          // Try checking via SSH logs
          const logsResult = await this.sshUser.exec(
            `cd ~/${this.repoDir} && docker compose logs --tail 5 2>&1`
          );
          if (logsResult.stdout.includes('listening on')) {
            healthy = true;
          }
        }

        if (healthy) {
          this.log('Gateway is healthy and responding');
        } else {
          throw new Error('Gateway did not respond within 15 seconds');
        }

        // Auto-approve any pending device pairing requests
        await this.autoApproveDevices();
      });

      // Done
      this.send('deployment:complete', {
        success: true,
        gatewayToken: this.gatewayToken,
        dashboardUrl: `http://127.0.0.1:18789/?token=${this.gatewayToken}`,
        vpsIp,
        agentName
      });

      // Cleanup SSH (keep tunnel alive)
      if (this.sshUser) this.sshUser.disconnect();

      return { gatewayToken: this.gatewayToken };

    } catch (err) {
      if (this.sshRoot) this.sshRoot.disconnect();
      if (this.sshUser) this.sshUser.disconnect();
      throw err;
    }
  }

  getProviderEnvKey(provider) {
    switch (provider) {
      case 'anthropic': return 'ANTHROPIC_API_KEY';
      case 'openrouter': return 'OPENROUTER_API_KEY';
      default: return 'OPENAI_API_KEY';
    }
  }

  shellEscape(str) {
    return str.replace(/['"\\$`!]/g, '\\$&');
  }

  httpGet(url) {
    return new Promise((resolve, reject) => {
      const req = http.get(url, { timeout: 3000 }, (res) => {
        let data = '';
        res.on('data', (chunk) => { data += chunk; });
        res.on('end', () => resolve(data));
      });
      req.on('error', reject);
      req.on('timeout', () => { req.destroy(); reject(new Error('timeout')); });
    });
  }

  sleep(ms) {
    return new Promise(r => setTimeout(r, ms));
  }

  async configureBrowserCDP() {
    try {
      // Find sandbox-browser container and its IP
      const sandboxResult = await this.sshUser.exec(
        `cd ~/${this.repoDir} && docker compose ps --format '{{.Name}}' 2>/dev/null | grep sandbox-browser | head -1`
      );
      const sandboxContainer = sandboxResult.stdout.trim();
      if (!sandboxContainer) {
        this.log('No sandbox-browser container found, skipping browser config');
        return;
      }

      const ipResult = await this.sshUser.exec(
        `docker inspect ${sandboxContainer} --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'`
      );
      const sandboxIp = ipResult.stdout.trim();
      if (!sandboxIp) {
        this.log('Could not determine sandbox-browser IP, skipping browser config');
        return;
      }

      const cdpUrl = `http://${sandboxIp}:9222`;
      this.log(`Sandbox browser CDP: ${cdpUrl}`);

      // Find gateway container and inject browser config
      const gatewayResult = await this.sshUser.exec(
        `cd ~/${this.repoDir} && docker compose ps --format '{{.Name}}' 2>/dev/null | grep gateway | head -1`
      );
      const gatewayContainer = gatewayResult.stdout.trim();
      if (!gatewayContainer) return;

      // Inject browser config into openclaw.json inside gateway container
      const nodeScript = `
        const fs = require('fs');
        const p = '/home/node/.openclaw/openclaw.json';
        const c = JSON.parse(fs.readFileSync(p, 'utf8'));
        c.agents = c.agents || {};
        c.agents.defaults = c.agents.defaults || {};
        c.agents.defaults.sandbox = { browser: { enabled: true } };
        c.browser = c.browser || {};
        c.browser.enabled = true;
        c.browser.cdpUrl = '${cdpUrl}';
        c.browser.defaultProfile = 'openclaw';
        c.browser.profiles = c.browser.profiles || {};
        c.browser.profiles.openclaw = { cdpUrl: '${cdpUrl}', color: '#FF4500' };
        fs.writeFileSync(p, JSON.stringify(c, null, 2));
        console.log('ok');
      `.replace(/\n/g, ' ');

      const injectResult = await this.sshUser.exec(
        `docker exec ${gatewayContainer} node -e "${nodeScript}"`
      );

      if (injectResult.stdout.trim() === 'ok') {
        this.log('Browser control configured');
      } else {
        this.log('Browser config injection may have failed');
      }
    } catch (err) {
      this.log(`Browser config skipped: ${err.message}`);
    }
  }

  async autoApproveDevices() {
    try {
      // Find the gateway container name
      const containerResult = await this.sshUser.exec(
        `cd ~/${this.repoDir} && docker compose ps --format '{{.Name}}' 2>/dev/null | grep gateway | head -1`
      );
      const container = containerResult.stdout.trim();
      if (!container) return;

      // List pending devices and approve them all
      const listResult = await this.sshUser.exec(
        `docker exec ${container} node dist/index.js devices list --json 2>/dev/null || echo "[]"`
      );
      try {
        const devices = JSON.parse(listResult.stdout.trim());
        const pending = Array.isArray(devices) ? devices.filter(d => d.status === 'pending') : [];
        for (const device of pending) {
          const id = device.requestId || device.id;
          if (!id) continue;
          this.log(`Auto-approving device ${id.substring(0, 8)}...`);
          await this.sshUser.exec(
            `docker exec ${container} node dist/index.js devices approve ${id} 2>/dev/null`
          );
        }
        if (pending.length > 0) {
          this.log(`Approved ${pending.length} device(s)`);
        }
      } catch {
        // --json may not be supported, try plain text parsing
        const lines = listResult.stdout;
        const uuidRegex = /([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/g;
        const pendingSection = lines.split('Paired')[0]; // only look at pending section
        const matches = pendingSection.match(uuidRegex) || [];
        for (const requestId of matches) {
          this.log(`Auto-approving device ${requestId.substring(0, 8)}...`);
          await this.sshUser.exec(
            `docker exec ${container} node dist/index.js devices approve ${requestId} 2>/dev/null`
          );
        }
        if (matches.length > 0) {
          this.log(`Approved ${matches.length} device(s)`);
        }
      }
    } catch (err) {
      this.log(`Device auto-approve skipped: ${err.message}`);
    }
  }

  async restoreSnapshot(apiToken, vpsIp) {
    const https = require('https');
    const apiBase = 'https://developers.hostinger.com/api/vps/v1';

    const apiCall = (method, endpoint, body) => {
      return new Promise((resolve, reject) => {
        const url = new URL(`${apiBase}${endpoint}`);
        const opts = {
          method,
          hostname: url.hostname,
          path: url.pathname,
          headers: {
            'Authorization': `Bearer ${apiToken}`,
            'Content-Type': 'application/json'
          }
        };
        const req = https.request(opts, (res) => {
          let data = '';
          res.on('data', (c) => { data += c; });
          res.on('end', () => {
            try { resolve(JSON.parse(data)); }
            catch { resolve(data); }
          });
        });
        req.on('error', reject);
        if (body) req.write(JSON.stringify(body));
        req.end();
      });
    };

    this.log('Restoring VPS from snapshot...');
    this.send('deployment:step', { id: 'snapshot', status: 'running' });

    // Get VPS ID
    const vms = await apiCall('GET', '/virtual-machines');
    const vm = Array.isArray(vms) ? vms.find(v => v.ipv4?.some(ip => ip.address === vpsIp)) : null;
    if (!vm) throw new Error('Could not find VPS in Hostinger API');

    // Trigger restore
    await apiCall('POST', `/virtual-machines/${vm.id}/snapshot/restore`);
    this.log('Snapshot restore triggered, waiting for VPS...');

    // Wait for VPS to come back
    for (let i = 0; i < 60; i++) {
      await this.sleep(5000);
      try {
        const status = await apiCall('GET', `/virtual-machines/${vm.id}`);
        if (status.state === 'running') {
          this.log('VPS is running after snapshot restore');
          break;
        }
        this.log(`VPS state: ${status.state} (${i + 1}/60)`);
      } catch {}
    }

    // Wait for SSH
    this.log('Waiting for SSH...');
    for (let i = 0; i < 30; i++) {
      try {
        const testSSH = new SSHClient(vpsIp, 'root', '');
        await testSSH.connect();
        testSSH.disconnect();
        this.log('SSH is up after restore');
        this.send('deployment:step', { id: 'snapshot', status: 'done' });
        return;
      } catch {
        await this.sleep(3000);
      }
    }
    this.send('deployment:step', { id: 'snapshot', status: 'done' });
    this.log('SSH wait timeout, continuing anyway...');
  }
}

module.exports = { DeploymentManager };
