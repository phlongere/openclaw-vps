const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('openclaw', {
  config: {
    devDefaults: () => ipcRenderer.invoke('config:devDefaults')
  },
  credentials: {
    save: (data) => ipcRenderer.invoke('credentials:save', data),
    load: () => ipcRenderer.invoke('credentials:load'),
    clear: () => ipcRenderer.invoke('credentials:clear')
  },
  deployment: {
    start: (config) => ipcRenderer.invoke('deployment:start', config),
    onSteps: (cb) => ipcRenderer.on('deployment:steps', (_, d) => cb(d)),
    onStep: (cb) => ipcRenderer.on('deployment:step', (_, d) => cb(d)),
    onLog: (cb) => ipcRenderer.on('deployment:log', (_, m) => cb(m)),
    onComplete: (cb) => ipcRenderer.on('deployment:complete', (_, d) => cb(d))
  },
  tunnel: {
    connect: (host, password) => ipcRenderer.invoke('tunnel:connect', { host, password }),
    disconnect: () => ipcRenderer.invoke('tunnel:disconnect'),
    reconnect: (config) => ipcRenderer.invoke('tunnel:reconnect', config)
  },
  shell: {
    openExternal: (url) => ipcRenderer.invoke('shell:openExternal', url),
    logs: (config) => ipcRenderer.invoke('shell:logs', config)
  },
  devices: {
    approveAll: (config) => ipcRenderer.invoke('devices:approve-all', config)
  }
});
