// ── KryllBot Deployer — Client App ──

const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => document.querySelectorAll(sel);

let currentConfig = {};

// ── Default values (loaded from .env.dev if present, otherwise empty) ──
let DEFAULTS = {
  vpsIp: '',
  rootPassword: '',
  hostingerApiToken: '',
  agentName: '',
  llmProvider: 'openai',
  apiKey: '',
  telegramToken: '',
  telegramUserId: ''
};

// ── Screen Navigation ──
function showView(id) {
  $$('.view').forEach(v => v.classList.remove('active'));
  $(`#${id}`).classList.add('active');
}

// ── Init: Load saved credentials or defaults ──
async function init() {
  // Load dev defaults from .env.dev (if present)
  try {
    const devDefaults = await window.openclaw.config.devDefaults();
    if (devDefaults) {
      DEFAULTS = { ...DEFAULTS, ...Object.fromEntries(
        Object.entries(devDefaults).filter(([, v]) => v)
      )};
    }
  } catch {}

  let saved = {};
  try {
    saved = await window.openclaw.credentials.load() || {};
  } catch (err) {
    console.warn('Could not load credentials:', err);
  }

  // Merge: saved values take priority over dev defaults
  const merged = { ...DEFAULTS, ...Object.fromEntries(
    Object.entries(saved).filter(([, v]) => v)
  )};

  for (const [key, value] of Object.entries(merged)) {
    const input = document.querySelector(`[name="${key}"]`);
    if (input && value) {
      if (input.type === 'checkbox') {
        input.checked = !!value;
      } else {
        input.value = value;
      }
    }
  }

  // Show Connect button if we have a previous deployment (token + IP)
  if (merged.gatewayToken && merged.vpsIp) {
    $('#btn-connect').style.display = 'flex';
  }
}

// ── Log Output (always visible) ──
function appendLog(msg) {
  const log = $('#log-output');
  if (!log) return;
  const line = document.createElement('div');
  line.className = 'log-line';
  line.textContent = msg;
  log.appendChild(line);
  log.scrollTop = log.scrollHeight;
}

// Wire up log listener early
window.openclaw.deployment.onLog((msg) => {
  appendLog(msg);
});

// ── Config Form Submit ──
$('#config-form').addEventListener('submit', async (e) => {
  e.preventDefault();

  // Warn if existing deployment detected
  if ($('#btn-connect').style.display !== 'none') {
    if (!confirm('An existing deployment was detected. Re-deploying will replace it and generate a new gateway token.\n\nContinue?')) {
      return;
    }
  }

  const form = new FormData(e.target);
  currentConfig = Object.fromEntries(form.entries());
  // installMode: 'deploy-only' | 'full' | 'snapshot'

  // Save credentials for next time
  try {
    await window.openclaw.credentials.save(currentConfig);
  } catch {}

  // Disable button
  const btn = $('.btn-deploy');
  btn.disabled = true;
  btn.textContent = 'Deploying...';

  // Switch to progress view
  showView('view-progress');
  appendLog('Starting deployment...');

  // Start deployment
  const result = await window.openclaw.deployment.start(currentConfig);

  if (result.success) {
    currentConfig.gatewayToken = result.gatewayToken;
    try {
      await window.openclaw.credentials.save({ gatewayToken: result.gatewayToken });
    } catch {}
  } else {
    appendLog(`ERROR: ${result.error}`);
    btn.disabled = false;
    btn.textContent = 'Deploy';
  }
});

// ── Progress: Pipeline Steps ──
window.openclaw.deployment.onSteps((steps) => {
  const pipeline = $('#pipeline');

  steps.forEach((step, i) => {
    let el = $(`#step-${step.id}`);

    // Create step element if it doesn't exist yet
    if (!el) {
      el = document.createElement('div');
      el.id = `step-${step.id}`;
      el.innerHTML = `
        <div class="step-icon">
          <span class="step-number">${i + 1}</span>
        </div>
        <span class="step-label">${step.label}</span>
      `;
      pipeline.appendChild(el);
    }

    // Normalize status: main sends 'complete', CSS expects 'done'
    const status = (step.status === 'complete') ? 'done' : step.status;
    el.className = `step ${status}`;

    const icon = el.querySelector('.step-icon');
    if (status === 'running') {
      icon.innerHTML = '<div class="spinner"></div>';
      $('#progress-subtitle').textContent = step.label + '...';
    } else if (status === 'done') {
      icon.innerHTML = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"><polyline points="20 6 9 17 4 12"/></svg>`;
    } else if (status === 'error') {
      icon.innerHTML = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>`;
    } else {
      // pending — show number
      icon.innerHTML = `<span class="step-number">${i + 1}</span>`;
    }
  });
});

// ── Progress: Individual step update (snapshot) ──
window.openclaw.deployment.onStep(({ id, status }) => {
  const pipeline = $('#pipeline');
  let el = $(`#step-${id}`);

  if (!el) {
    el = document.createElement('div');
    el.id = `step-${id}`;
    const labelMap = { snapshot: 'Restoring from snapshot' };
    el.innerHTML = `
      <div class="step-icon"><div class="spinner"></div></div>
      <span class="step-label">${labelMap[id] || id}</span>
    `;
    pipeline.prepend(el);
  }

  const normalized = (status === 'complete') ? 'done' : status;
  el.className = `step ${normalized}`;
  const icon = el.querySelector('.step-icon');

  if (normalized === 'running') {
    icon.innerHTML = '<div class="spinner"></div>';
    $('#progress-subtitle').textContent = el.querySelector('.step-label').textContent + '...';
  } else if (normalized === 'done') {
    icon.innerHTML = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"><polyline points="20 6 9 17 4 12"/></svg>`;
  } else if (normalized === 'error') {
    icon.innerHTML = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>`;
  }
});

// ── Progress: Complete → Dashboard ──
window.openclaw.deployment.onComplete((data) => {
  if (!data.success) return;

  $('#progress-subtitle').textContent = 'Deployment complete!';
  appendLog('Deployment complete! Loading dashboard...');

  setTimeout(() => {
    showDashboard(data.gatewayToken);
  }, 1500);
});

// ── Dashboard ──
function showDashboard(gatewayToken) {
  showView('view-dashboard');

  $('#toolbar-agent').textContent = currentConfig.agentName || 'Assistant';
  $('#toolbar-ip').textContent = currentConfig.vpsIp || '-';

  // Show loading overlay while auth/pairing completes
  let loader = $('#dashboard-loader');
  if (!loader) {
    loader = document.createElement('div');
    loader.id = 'dashboard-loader';
    loader.className = 'dashboard-loader';
    loader.innerHTML = '<div class="spinner"></div><p>Connecting to gateway...</p>';
    $('#view-dashboard').appendChild(loader);
  }
  loader.style.display = 'flex';

  const webview = $('#dashboard-webview');
  const url = gatewayToken
    ? `http://127.0.0.1:18789/?token=${gatewayToken}`
    : 'http://127.0.0.1:18789/';
  webview.src = url;

  webview.addEventListener('did-start-loading', () => {
    $('#status-dot').classList.remove('offline');
  });

  webview.addEventListener('did-fail-load', () => {
    $('#status-dot').classList.add('offline');
  });

  // Auto-approve device pairing after the dashboard loads
  let pairingHandled = false;
  webview.addEventListener('dom-ready', async () => {
    if (pairingHandled) return;
    pairingHandled = true;

    // Give the WebSocket time to connect and create a pairing request
    await new Promise(r => setTimeout(r, 4000));

    const result = await window.openclaw.devices.approveAll({
      vpsIp: currentConfig.vpsIp,
      rootPassword: currentConfig.rootPassword
    });

    if (result.success && result.approved > 0) {
      loader.querySelector('p').textContent = 'Approving device...';
      await new Promise(r => setTimeout(r, 1000));
      webview.reload();
      // Wait for the reload to settle
      await new Promise(r => setTimeout(r, 3000));
    }

    // Hide loader
    loader.style.display = 'none';
  });
}

// ── Dashboard: noVNC / Back toggle ──
let dashboardUrl = '';

$('#btn-novnc').addEventListener('click', () => {
  const webview = $('#dashboard-webview');
  dashboardUrl = webview.src;
  webview.src = 'http://127.0.0.1:6080/vnc.html?autoconnect=true';
  $('#btn-novnc').style.display = 'none';
  $('#btn-dashboard').style.display = 'flex';
});

$('#btn-dashboard').addEventListener('click', () => {
  const webview = $('#dashboard-webview');
  webview.src = dashboardUrl || `http://127.0.0.1:18789/?token=${currentConfig.gatewayToken || ''}`;
  $('#btn-dashboard').style.display = 'none';
  $('#btn-novnc').style.display = 'flex';
});

// ── Dashboard: Logs ──
$('#btn-logs').addEventListener('click', async () => {
  const overlay = document.createElement('div');
  overlay.className = 'modal-overlay';
  overlay.innerHTML = `
    <div class="modal">
      <div class="modal-header">
        <h3>Gateway Logs</h3>
        <button class="modal-close">&times;</button>
      </div>
      <div class="modal-body">Loading logs...</div>
    </div>
  `;
  document.body.appendChild(overlay);

  overlay.querySelector('.modal-close').addEventListener('click', () => overlay.remove());
  overlay.addEventListener('click', (e) => {
    if (e.target === overlay) overlay.remove();
  });

  const result = await window.openclaw.shell.logs({
    vpsIp: currentConfig.vpsIp,
    rootPassword: currentConfig.rootPassword
  });

  const body = overlay.querySelector('.modal-body');
  body.textContent = result.success ? result.logs : `Error: ${result.error}`;
});

// ── Dashboard: Reconnect ──
$('#btn-reconnect').addEventListener('click', async () => {
  const btn = $('#btn-reconnect');
  btn.disabled = true;
  btn.textContent = 'Reconnecting...';

  const result = await window.openclaw.tunnel.reconnect({
    vpsIp: currentConfig.vpsIp,
    rootPassword: currentConfig.rootPassword
  });

  if (result.success) {
    btn.innerHTML = `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="20 6 9 17 4 12"/></svg> Connected`;
    setTimeout(() => {
      btn.innerHTML = `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="23 4 23 10 17 10"/><path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10"/></svg> Reconnect`;
      btn.disabled = false;
    }, 2000);

    const webview = $('#dashboard-webview');
    if (webview.src !== 'about:blank') webview.reload();
  } else {
    btn.textContent = 'Failed';
    setTimeout(() => {
      btn.innerHTML = `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="23 4 23 10 17 10"/><path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10"/></svg> Reconnect`;
      btn.disabled = false;
    }, 2000);
  }
});

// ── Connect (reconnect tunnel + open dashboard) ──
$('#btn-connect').addEventListener('click', async () => {
  const form = new FormData($('#config-form'));
  currentConfig = Object.fromEntries(form.entries());

  // Load saved gateway token
  let saved = {};
  try { saved = await window.openclaw.credentials.load() || {}; } catch {}
  currentConfig.gatewayToken = saved.gatewayToken;

  const btn = $('#btn-connect');
  btn.disabled = true;
  btn.textContent = 'Connecting...';

  const result = await window.openclaw.tunnel.reconnect({
    vpsIp: currentConfig.vpsIp,
    rootPassword: currentConfig.rootPassword
  });

  if (result.success) {
    showDashboard(currentConfig.gatewayToken);
  } else {
    btn.textContent = 'Failed — ' + (result.error || 'unknown error');
    setTimeout(() => {
      btn.innerHTML = `<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="23 4 23 10 17 10"/><path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10"/></svg> Connect`;
      btn.disabled = false;
    }, 3000);
  }
});

// ── Dashboard: Back to config ──
$('#btn-settings').addEventListener('click', () => {
  // Reset deploy button state
  const btn = $('.btn-deploy');
  btn.disabled = false;
  btn.innerHTML = `<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"/></svg> Deploy`;

  // Show Connect button since we have an active deployment
  if (currentConfig.gatewayToken) {
    $('#btn-connect').style.display = 'flex';
  }

  showView('view-config');
});

// ── Reset Config ──
$('#btn-reset-config').addEventListener('click', async () => {
  if (!confirm('Delete all saved credentials and tokens?\n\nThe form will revert to defaults.')) return;
  await window.openclaw.credentials.clear();
  $('#btn-connect').style.display = 'none';
  // Reload form with defaults only
  for (const [key, value] of Object.entries(DEFAULTS)) {
    const input = document.querySelector(`[name="${key}"]`);
    if (input) input.value = value || '';
  }
});

// ── Boot ──
init();
