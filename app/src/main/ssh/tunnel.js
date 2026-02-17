const { Client } = require('ssh2');
const net = require('net');
const fs = require('fs');
const os = require('os');
const path = require('path');

class SSHTunnel {
  constructor(host, username, password) {
    this.host = host;
    this.username = username;
    this.password = password;
    this.conn = null;
    this.servers = [];
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

  forwardPort(localPort, remotePort) {
    return new Promise((resolve, reject) => {
      const server = net.createServer((sock) => {
        this.conn.forwardOut('127.0.0.1', localPort, '127.0.0.1', remotePort, (err, stream) => {
          if (err) { sock.end(); return; }
          sock.pipe(stream);
          stream.pipe(sock);
        });
      });

      server.on('error', (err) => {
        if (err.code === 'EADDRINUSE') resolve();
        else reject(err);
      });

      server.listen(localPort, '127.0.0.1', () => {
        this.servers.push(server);
        resolve();
      });
    });
  }

  async setupKryllBotTunnels() {
    await this.forwardPort(18789, 18789); // Gateway
    await this.forwardPort(18790, 18790); // Bridge
    await this.forwardPort(6080, 6080);   // noVNC
  }

  disconnect() {
    for (const server of this.servers) {
      try { server.close(); } catch {}
    }
    this.servers = [];
    if (this.conn) {
      this.conn.end();
      this.conn = null;
    }
  }
}

module.exports = { SSHTunnel };
