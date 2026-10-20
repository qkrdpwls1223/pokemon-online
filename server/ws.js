// Minimal server-side WebSocket (RFC 6455), zero dependencies.
//
// Supports what pmf-battle needs: text messages (with fragmentation),
// ping/pong, close handshake, a message size cap. Binary frames and
// extensions (permessage-deflate) are not negotiated.

'use strict';

const crypto = require('crypto');
const { EventEmitter } = require('events');

const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

/**
 * Complete the HTTP upgrade. Returns a WsConn, or null after answering the
 * request with an HTTP error.
 */
function acceptUpgrade(req, socket, head, { maxMessage = 256 * 1024 } = {}) {
  const key = req.headers['sec-websocket-key'];
  const upgrade = (req.headers.upgrade || '').toLowerCase();
  const version = req.headers['sec-websocket-version'];
  if (req.method !== 'GET' || upgrade !== 'websocket' || !key || version !== '13') {
    socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n');
    return null;
  }
  const accept = crypto.createHash('sha1').update(key + GUID).digest('base64');
  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\n'
    + 'Upgrade: websocket\r\n'
    + 'Connection: Upgrade\r\n'
    + `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
  );
  const conn = new WsConn(socket, maxMessage);
  if (head && head.length) conn._onData(head);
  return conn;
}

class WsConn extends EventEmitter {
  constructor(socket, maxMessage) {
    super();
    this.socket = socket;
    this.maxMessage = maxMessage;
    this.buffer = Buffer.alloc(0);
    this.fragments = [];
    this.fragmentBytes = 0;
    this.closed = false;
    this.remoteAddress = socket.remoteAddress;
    this.remotePort = socket.remotePort;
    socket.setNoDelay(true);
    socket.setKeepAlive(true, 30000);
    socket.on('data', (d) => this._onData(d));
    socket.on('close', () => this._finish());
    socket.on('error', () => {});   // 'close' follows
  }

  get destroyed() { return this.closed || this.socket.destroyed; }

  send(text) {
    if (this.destroyed) return;
    this._writeFrame(0x1, Buffer.from(text, 'utf8'));
  }

  /** Close handshake: send a close frame, then end the TCP stream. */
  close(code = 1000, reason = '') {
    if (this.destroyed) return;
    const r = Buffer.from(reason, 'utf8').subarray(0, 120);
    const payload = Buffer.alloc(2 + r.length);
    payload.writeUInt16BE(code, 0);
    r.copy(payload, 2);
    this._writeFrame(0x8, payload);
    this.closed = true;
    this.socket.end();
    // a peer that never answers must not keep the socket alive
    setTimeout(() => this.socket.destroy(), 2000).unref();
  }

  /** Hard close, no handshake. */
  destroy() {
    this.closed = true;
    this.socket.destroy();
  }

  _writeFrame(opcode, payload) {
    const len = payload.length;
    let header;
    if (len < 126) {
      header = Buffer.from([0x80 | opcode, len]);
    } else if (len < 65536) {
      header = Buffer.alloc(4);
      header[0] = 0x80 | opcode; header[1] = 126;
      header.writeUInt16BE(len, 2);
    } else {
      header = Buffer.alloc(10);
      header[0] = 0x80 | opcode; header[1] = 127;
      header.writeBigUInt64BE(BigInt(len), 2);
    }
    this.socket.write(Buffer.concat([header, payload]));
  }

  _fail(code, reason) {
    this.close(code, reason);
  }

  _onData(chunk) {
    if (this.closed) return;
    this.buffer = this.buffer.length ? Buffer.concat([this.buffer, chunk]) : chunk;
    for (;;) {
      const b = this.buffer;
      if (b.length < 2) return;
      const fin = (b[0] & 0x80) !== 0;
      const rsv = b[0] & 0x70;
      const opcode = b[0] & 0x0f;
      const masked = (b[1] & 0x80) !== 0;
      let len = b[1] & 0x7f;
      let off = 2;
      if (rsv) return this._fail(1002, 'no extensions');
      if (!masked) return this._fail(1002, 'client frames must be masked');
      if (len === 126) {
        if (b.length < 4) return;
        len = b.readUInt16BE(2); off = 4;
      } else if (len === 127) {
        if (b.length < 10) return;
        const big = b.readBigUInt64BE(2);
        if (big > BigInt(this.maxMessage)) return this._fail(1009, 'message too big');
        len = Number(big); off = 10;
      }
      if (len > this.maxMessage) return this._fail(1009, 'message too big');
      if (b.length < off + 4 + len) return;
      const mask = b.subarray(off, off + 4);
      const payload = Buffer.from(b.subarray(off + 4, off + 4 + len));
      for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];
      this.buffer = b.subarray(off + 4 + len);

      if (opcode >= 0x8) {
        // control frames: never fragmented, payload <= 125
        if (!fin || len > 125) return this._fail(1002, 'bad control frame');
        if (opcode === 0x8) {
          if (!this.closed) {
            const code = payload.length >= 2 ? payload.readUInt16BE(0) : 1000;
            this.close(code === 1005 || code === 1006 ? 1000 : code);
          }
          return;
        }
        if (opcode === 0x9) { this._writeFrame(0xA, payload); continue; }   // ping -> pong
        if (opcode === 0xA) continue;                                        // pong
        return this._fail(1002, 'unknown opcode');
      }

      if (opcode === 0x2) return this._fail(1003, 'text only');
      if (opcode === 0x1) {
        if (this.fragments.length) return this._fail(1002, 'unexpected new message');
      } else if (opcode === 0x0) {
        if (!this.fragments.length) return this._fail(1002, 'unexpected continuation');
      } else {
        return this._fail(1002, 'unknown opcode');
      }
      this.fragments.push(payload);
      this.fragmentBytes += payload.length;
      if (this.fragmentBytes > this.maxMessage) return this._fail(1009, 'message too big');
      if (fin) {
        const text = Buffer.concat(this.fragments).toString('utf8');
        this.fragments = [];
        this.fragmentBytes = 0;
        this.emit('message', text);
        if (this.closed) return;
      }
    }
  }

  _finish() {
    if (this._finished) return;
    this._finished = true;
    this.closed = true;
    this.emit('close');
  }
}

module.exports = { acceptUpgrade, WsConn };
