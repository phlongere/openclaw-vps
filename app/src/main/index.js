const { app, BrowserWindow, ipcMain, safeStorage } = require('electron');
const path = require('path');
const fs = require('fs');
const { DeploymentManager } = require('./deployment/manager');
const { SSHTunnel } = require('./ssh/tunnel');
const { CredentialStore } = require('./credentials/store');

let mainWindow = null;
let activeTunnel = null;
const credStore = new CredentialStore();

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1000,
    height: 950,
    minWidth: 720,
    minHeight: 600,
    titleBarStyle: 'hiddenInset',
    backgroundColor: '#0f0f1a',
    vibrancy: 'under-window',
    webPreferences: {
      preload: path.join(__dirname, '..', 'renderer', 'js', 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      webviewTag: true
    }
  });

  mainWindow.loadFile(path.join(__dirname, '..', 'renderer', 'index.html'));
}

app.whenReady().then(createWindow);

app.on('window-all-closed', () => {
  if (activeTunnel) activeTunnel.disconnect();
  app.quit();
});

// ── Dev Defaults (from .env.dev if present) ──
ipcMain.handle('config:devDefaults', async () => {
  const envPath = path.resolve(__dirname, '..', '..', '..', '.env.dev');
  if (!fs.existsSync(envPath)) return null;
  const lines = fs.readFileSync(envPath, 'utf-8').split('\n');
  const env = {};
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq < 0) continue;
    env[trimmed.slice(0, eq)] = trimmed.slice(eq + 1);
  }
  return {
    vpsIp: env.VPS_IP || '',
    rootPassword: env.ROOT_PASSWORD || '',
    hostingerApiToken: env.HOSTINGER_API_TOKEN || '',
    agentName: env.AGENT_NAME || '',
    llmProvider: env.LLM_PROVIDER || '',
    apiKey: env.API_KEY || '',
    telegramToken: env.TELEGRAM_TOKEN || '',
    telegramUserId: env.TELEGRAM_USER_ID || '',
    userName: env.USER_NAME || '',
    userLanguage: env.USER_LANGUAGE || 'fr'
  };
});

// ── Credentials ──
ipcMain.handle('credentials:save', async (_event, data) => {
  credStore.save(data);
});

ipcMain.handle('credentials:load', async () => {
  return credStore.load();
});

ipcMain.handle('credentials:clear', async () => {
  credStore.clear();
});

// ── Deployment ──
ipcMain.handle('deployment:start', async (_event, config) => {
  const scriptsRoot = path.resolve(__dirname, '..', '..', '..');
  const manager = new DeploymentManager(mainWindow, scriptsRoot);

  try {
    const result = await manager.deploy(config);
    activeTunnel = manager.tunnel;
    return { success: true, ...result };
  } catch (err) {
    return { success: false, error: err.message };
  }
});

// ── Helpers ──
async function detectVpsUser(host, password) {
  const { SSHClient } = require('./ssh/client');
  // Try kryllbot first, fallback to openclaw
  for (const user of ['kryllbot', 'openclaw']) {
    try {
      const ssh = new SSHClient(host, user, password);
      await ssh.connect();
      ssh.disconnect();
      return user;
    } catch {}
  }
  return 'kryllbot';
}

// ── Tunnel ──
ipcMain.handle('tunnel:reconnect', async (_event, config) => {
  if (activeTunnel) activeTunnel.disconnect();

  try {
    const user = await detectVpsUser(config.vpsIp, config.rootPassword);
    activeTunnel = new SSHTunnel(config.vpsIp, user, config.rootPassword);
    await activeTunnel.connect();
    await activeTunnel.setupKryllBotTunnels();
    return { success: true };
  } catch (err) {
    return { success: false, error: err.message };
  }
});

// ── Devices (auto-approve) ──
ipcMain.handle('devices:approve-all', async (_event, config) => {
  const { SSHClient } = require('./ssh/client');
  let ssh;
  try {
    const user = await detectVpsUser(config.vpsIp, config.rootPassword);
    ssh = new SSHClient(config.vpsIp, user, config.rootPassword);
    await ssh.connect();
    const repoCheck = await ssh.exec('[ -d ~/kryllbot-vps ] && echo kryllbot-vps || echo openclaw-vps');
    const repoDir = repoCheck.stdout.trim();

    // Find gateway container
    const containerResult = await ssh.exec(
      `cd ~/${repoDir} && docker compose ps --format '{{.Name}}' 2>/dev/null | grep gateway | head -1`
    );
    const container = containerResult.stdout.trim();
    if (!container) { ssh.disconnect(); return { success: false, error: 'No gateway container' }; }

    // List devices and approve all pending
    const listResult = await ssh.exec(
      `docker exec ${container} node dist/index.js devices list 2>/dev/null`
    );
    const uuidRegex = /([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/g;
    const pendingSection = listResult.stdout.split('Paired')[0];
    const matches = pendingSection.match(uuidRegex) || [];
    let approved = 0;
    for (const requestId of matches) {
      await ssh.exec(`docker exec ${container} node dist/index.js devices approve ${requestId} 2>/dev/null`);
      approved++;
    }
    ssh.disconnect();
    return { success: true, approved };
  } catch (err) {
    if (ssh) ssh.disconnect();
    return { success: false, error: err.message };
  }
});

// ── Shell (logs) ──
ipcMain.handle('shell:logs', async (_event, config) => {
  const { SSHClient } = require('./ssh/client');
  let ssh;
  try {
    const user = await detectVpsUser(config.vpsIp, config.rootPassword);
    ssh = new SSHClient(config.vpsIp, user, config.rootPassword);
    await ssh.connect();
    // Detect repo dir and get logs from whichever gateway service exists
    const repoCheck = await ssh.exec('[ -d ~/kryllbot-vps ] && echo kryllbot-vps || echo openclaw-vps');
    const repoDir = repoCheck.stdout.trim();
    const result = await ssh.exec(`cd ~/${repoDir} && docker compose logs --tail 100 2>&1`);
    ssh.disconnect();
    return { success: true, logs: result.stdout };
  } catch (err) {
    if (ssh) ssh.disconnect();
    return { success: false, error: err.message };
  }
});
