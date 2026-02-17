const { safeStorage } = require('electron');
const Store = require('electron-store');

const SENSITIVE_KEYS = ['rootPassword', 'hostingerApiToken', 'apiKey', 'telegramToken', 'gatewayToken'];

class CredentialStore {
  constructor() {
    this.store = new Store({ name: 'kryllbot-deployer' });
  }

  save(data) {
    for (const [key, value] of Object.entries(data)) {
      if (!value) continue;

      if (SENSITIVE_KEYS.includes(key) && safeStorage.isEncryptionAvailable()) {
        const encrypted = safeStorage.encryptString(value);
        this.store.set(`secure.${key}`, encrypted.toString('base64'));
      } else {
        this.store.set(key, value);
      }
    }
  }

  load() {
    const result = {};

    for (const key of ['vpsIp', 'agentName', 'llmProvider', 'telegramUserId']) {
      result[key] = this.store.get(key, '');
    }

    for (const key of SENSITIVE_KEYS) {
      const encrypted = this.store.get(`secure.${key}`);
      if (encrypted && safeStorage.isEncryptionAvailable()) {
        try {
          const buffer = Buffer.from(encrypted, 'base64');
          result[key] = safeStorage.decryptString(buffer);
        } catch {
          result[key] = '';
        }
      } else {
        result[key] = '';
      }
    }

    return result;
  }

  clear() {
    this.store.clear();
  }
}

module.exports = { CredentialStore };
