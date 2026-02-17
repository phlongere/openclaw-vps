const { Client } = require('ssh2');
const fs = require('fs');
const os = require('os');
const path = require('path');

class SSHClient {
  constructor(host, username, password) {
    this.host = host;
    this.username = username;
    this.password = password;
    this.conn = null;
  }

  connect() {
    return new Promise((resolve, reject) => {
      this.conn = new Client();

      const config = {
        host: this.host,
        port: 22,
        username: this.username,
        readyTimeout: 30000,
        keepaliveInterval: 10000
      };

      // Try SSH key first, fallback to password
      const keyPaths = [
        path.join(os.homedir(), '.ssh', 'id_ed25519'),
        path.join(os.homedir(), '.ssh', 'id_rsa')
      ];
      const keyPath = keyPaths.find(p => fs.existsSync(p));

      if (keyPath) {
        config.privateKey = fs.readFileSync(keyPath);
        if (this.password) config.password = this.password;
      } else if (this.password) {
        config.password = this.password;
      }

      this.conn.on('ready', () => resolve());
      this.conn.on('error', (err) => reject(err));
      this.conn.connect(config);
    });
  }

  exec(command) {
    return new Promise((resolve, reject) => {
      this.conn.exec(command, (err, stream) => {
        if (err) return reject(err);
        let stdout = '';
        let stderr = '';
        stream.on('data', (data) => { stdout += data.toString(); });
        stream.stderr.on('data', (data) => { stderr += data.toString(); });
        stream.on('close', (code) => resolve({ stdout, stderr, code }));
      });
    });
  }

  execStream(command, onOutput) {
    return new Promise((resolve, reject) => {
      this.conn.exec(command, (err, stream) => {
        if (err) return reject(err);
        stream.on('data', (data) => {
          data.toString().split('\n').filter(Boolean).forEach(line => onOutput(line));
        });
        stream.stderr.on('data', (data) => {
          data.toString().split('\n').filter(Boolean).forEach(line => onOutput(line));
        });
        stream.on('close', (code) => {
          if (code !== 0) reject(new Error(`Command exited with code ${code}`));
          else resolve();
        });
      });
    });
  }

  execScript(scriptContent, onOutput) {
    return new Promise((resolve, reject) => {
      this.conn.exec('bash -s', (err, stream) => {
        if (err) return reject(err);
        stream.on('data', (data) => {
          data.toString().split('\n').filter(Boolean).forEach(line => onOutput(line));
        });
        stream.stderr.on('data', (data) => {
          data.toString().split('\n').filter(Boolean).forEach(line => onOutput(line));
        });
        stream.on('close', (code) => {
          if (code !== 0) reject(new Error(`Script exited with code ${code}`));
          else resolve();
        });
        stream.end(scriptContent);
      });
    });
  }

  disconnect() {
    if (this.conn) {
      this.conn.end();
      this.conn = null;
    }
  }
}

module.exports = { SSHClient };
