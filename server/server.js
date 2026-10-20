#!/usr/bin/env node
// pmf-battle relay server — lobby, challenges, battle seeds.
//
// Protocol v2: JSON text messages over WebSocket (docs/design.md §4).
// With TLS_CERT/TLS_KEY set it serves https + wss (clients use
// https://host:port); without them, plain http + ws for local testing.
// The server never simulates battles. It pairs two clients, hands both the
// same random seed and both parties, and later compares the result digests
// the two clients report. Zero dependencies: Node >= 18.
//
// Env:
//   PORT=7777  HOST=0.0.0.0  MAX_CLIENTS=200  CHALLENGE_TIMEOUT_MS=30000
//   TLS_CERT=/certs/cert.pem  TLS_KEY=/certs/key.pem
//   SERVER_PASSWORD=...       ("" or unset = no password)
//   RESULTS_FILE=./data/results.jsonl   ("" disables result logging)

'use strict';

const http = require('http');
const https = require('https');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { acceptUpgrade } = require('./ws');

const SERVER_VERSION = '0.2.0';
const PROTO = 2;
const PORT = parseInt(process.env.PORT || '7777', 10);
const HOST = process.env.HOST || '0.0.0.0';
const MAX_CLIENTS = parseInt(process.env.MAX_CLIENTS || '200', 10);
const CHALLENGE_TIMEOUT_MS = parseInt(process.env.CHALLENGE_TIMEOUT_MS || '30000', 10);
const HELLO_TIMEOUT_MS = 10000;
const IDLE_TIMEOUT_MS = 90000;          // clients ping every 20 s
const MAX_MESSAGE = 256 * 1024;
const TLS_CERT = process.env.TLS_CERT || '';
const TLS_KEY = process.env.TLS_KEY || '';
const PASSWORD = process.env.SERVER_PASSWORD || '';
const WRONG_PASSWORD_DELAY_MS = 1000;
const RESULTS_FILE = process.env.RESULTS_FILE === undefined
  ? path.join(__dirname, 'data', 'results.jsonl')
  : process.env.RESULTS_FILE;

const GENDERS = new Set(['male', 'female', 'genderless']);
const IV_KEYS = ['hp', 'atk', 'def', 'spAtk', 'spDef', 'spe'];

function log(...args) {
  console.log(new Date().toISOString(), ...args);
}

// ---------------------------------------------------------------------------
// validation

const isInt = (v, lo, hi) => Number.isInteger(v) && v >= lo && v <= hi;

function cleanName(raw) {
  if (typeof raw !== 'string') return null;
  // strip control chars, collapse whitespace, max 16 code points
  const s = Array.from(raw.replace(/[\u0000-\u001f\u007f]/g, '').replace(/\s+/g, ' ').trim())
    .slice(0, 16).join('');
  return s.length > 0 ? s : null;
}

function cleanMon(m) {
  if (!m || typeof m !== 'object') return null;
  if (!isInt(m.dex, 1, 251) || !isInt(m.level, 1, 100)) return null;
  if (!Array.isArray(m.moves) || m.moves.length > 4 || !m.moves.every((x) => isInt(x, 0, 2000))) return null;
  const out = { dex: m.dex, level: m.level, moves: m.moves.slice(), gender: 'genderless' };
  if (GENDERS.has(m.gender)) out.gender = m.gender;
  if (Array.isArray(m.disabledMoves)) {
    if (m.disabledMoves.length > 4 || !m.disabledMoves.every((x) => isInt(x, 0, 2000))) return null;
    out.disabledMoves = m.disabledMoves.slice();
  }
  if (m.ivs !== undefined && m.ivs !== null) {
    if (typeof m.ivs !== 'object' || !IV_KEYS.every((k) => isInt(m.ivs[k], 0, 31))) return null;
    out.ivs = {};
    for (const k of IV_KEYS) out.ivs[k] = m.ivs[k];
  }
  return out;
}

function cleanParty(p) {
  if (!Array.isArray(p) || p.length < 1 || p.length > 6) return null;
  const out = p.map(cleanMon);
  return out.every(Boolean) ? out : null;
}

// ---------------------------------------------------------------------------
// state

/** @type {Map<string, Client>} */
const clients = new Map();
/** challenger id -> { from, to, timer } */
const challenges = new Map();
/** battleId -> { a, b, names, reports: Map<id, {winner, digest}>, startedAt } */
const battles = new Map();

class Client {
  constructor(conn) {
    this.id = crypto.randomBytes(6).toString('hex');
    this.conn = conn;             // WsConn
    this.ready = false;           // hello accepted
    this.name = null;
    this.engine = null;
    this.party = null;
    this.status = 'idle';         // idle | challenging | battling
    this.bot = false;             // practice bot (tools/bot.js): never simulates
    this.battleId = null;
    this.lastSeen = Date.now();
    this.addr = `${conn.remoteAddress}:${conn.remotePort}`;
  }

  send(obj) {
    this.conn.send(JSON.stringify(obj));
  }

  /** Send a final error, then close. */
  reject(code, message) {
    this.error(code, message);
    this.conn.close(1008, code);
  }

  error(code, message) {
    this.send({ t: 'error', code, message });
  }
}

function uniqueName(wanted) {
  const taken = new Set([...clients.values()].filter((c) => c.ready).map((c) => c.name));
  if (!taken.has(wanted)) return wanted;
  for (let i = 2; ; i++) {
    const n = `${Array.from(wanted).slice(0, 12).join('')}(${i})`;
    if (!taken.has(n)) return n;
  }
}

function lobbyFor(viewer) {
  const users = [];
  for (const c of clients.values()) {
    if (!c.ready || c === viewer) continue;
    users.push({
      id: c.id,
      name: c.name,
      status: c.status,
      lead: c.party && c.party[0] ? { dex: c.party[0].dex, level: c.party[0].level } : null,
      partySize: c.party ? c.party.length : 0,
      compatible: c.engine === viewer.engine || c.bot || viewer.bot,
      bot: c.bot,
    });
  }
  users.sort((x, y) => x.name.localeCompare(y.name));
  return { t: 'lobby', users };
}

function broadcastLobby() {
  for (const c of clients.values()) if (c.ready) c.send(lobbyFor(c));
}

// ---------------------------------------------------------------------------
// challenges

function endChallenge(fromId, reason, { notifyFrom = true, notifyTo = true } = {}) {
  const ch = challenges.get(fromId);
  if (!ch) return;
  clearTimeout(ch.timer);
  challenges.delete(fromId);
  const from = clients.get(ch.from);
  const to = clients.get(ch.to);
  if (from && from.status === 'challenging') from.status = 'idle';
  if (to && to.status === 'challenging') to.status = 'idle';
  if (from && notifyFrom) from.send({ t: 'challengeEnded', peer: ch.to, peerName: to ? to.name : null, reason });
  if (to && notifyTo) to.send({ t: 'challengeEnded', peer: ch.from, peerName: from ? from.name : null, reason });
}

function onChallenge(c, msg) {
  const target = clients.get(msg.to);
  const refuse = (reason) => c.send({
    t: 'challengeEnded', peer: msg.to, peerName: target ? target.name : null, reason,
  });
  if (c.status !== 'idle' || challenges.has(c.id)) return refuse('busy');
  if (!target || !target.ready || target === c) return refuse('offline');
  if (target.engine !== c.engine && !target.bot && !c.bot) return refuse('incompatible');
  if (target.status !== 'idle') return refuse('busy');

  const timer = setTimeout(() => {
    endChallenge(c.id, 'expired');
    broadcastLobby();
  }, CHALLENGE_TIMEOUT_MS);
  challenges.set(c.id, { from: c.id, to: target.id, timer });
  c.status = 'challenging';
  target.status = 'challenging';
  const secs = Math.round(CHALLENGE_TIMEOUT_MS / 1000);
  c.send({ t: 'challengeSent', to: target.id, toName: target.name, expiresIn: secs });
  target.send({ t: 'challenged', from: c.id, fromName: c.name, expiresIn: secs });
  log(`challenge ${c.name} -> ${target.name}`);
  broadcastLobby();
}

function onCancelChallenge(c) {
  if (!challenges.has(c.id)) return;
  endChallenge(c.id, 'cancelled');
  broadcastLobby();
}

function onRespond(c, msg) {
  const ch = challenges.get(msg.from);
  if (!ch || ch.to !== c.id) {
    return c.error('noChallenge', '이미 끝났거나 존재하지 않는 대전 신청입니다.');
  }
  if (msg.accept !== true) {
    endChallenge(msg.from, 'declined', { notifyTo: false });
    log(`declined ${clients.get(msg.from)?.name} -> ${c.name}`);
    return broadcastLobby();
  }
  const challenger = clients.get(ch.from);
  clearTimeout(ch.timer);
  challenges.delete(msg.from);
  if (!challenger) {
    c.status = 'idle';
    c.send({ t: 'challengeEnded', peer: msg.from, peerName: null, reason: 'offline' });
    return broadcastLobby();
  }
  startBattle(challenger, c);
}

// ---------------------------------------------------------------------------
// battles

function randomSeed() {
  return crypto.randomBytes(8).readBigUInt64LE().toString();
}

function startBattle(p1, p2) {
  const battleId = crypto.randomBytes(8).toString('hex');
  const seed = randomSeed();
  // Random side assignment: side A is the engine's "player" (wins speed ties).
  const [a, b] = crypto.randomInt(2) === 0 ? [p1, p2] : [p2, p1];
  const payload = (you) => ({
    t: 'battleStart',
    battleId,
    seed,
    mode: 'auto',
    you,
    a: { id: a.id, name: a.name, party: a.party },
    b: { id: b.id, name: b.name, party: b.party },
  });
  for (const c of [a, b]) { c.status = 'battling'; c.battleId = battleId; }
  battles.set(battleId, {
    a: a.id, b: b.id, names: { A: a.name, B: b.name }, seed,
    reports: new Map(), startedAt: Date.now(), engine: a.engine,
    bot: a.bot || b.bot,
    humans: [a, b].filter((x) => !x.bot).map((x) => x.id),
  });
  a.send(payload('A'));
  b.send(payload('B'));
  log(`battle ${battleId} start: A=${a.name} B=${b.name} seed=${seed}`);
  broadcastLobby();
}

function leaveBattle(c) {
  if (c.status === 'battling') c.status = 'idle';
  c.battleId = null;
}

function onBattleDone(c, msg) {
  const bt = battles.get(msg.battleId);
  if (!bt || (bt.a !== c.id && bt.b !== c.id)) {
    leaveBattle(c);
    return broadcastLobby();
  }
  const winner = ['A', 'B', 'draw'].includes(msg.winner) ? msg.winner : 'invalid';
  const digest = typeof msg.digest === 'string' ? msg.digest.slice(0, 64) : 'invalid';
  bt.reports.set(c.id, { winner, digest });
  leaveBattle(c);
  if (bt.reports.size === 2) finishBattle(msg.battleId, bt);
  broadcastLobby();
}

function finishBattle(battleId, bt) {
  battles.delete(battleId);
  if (bt.bot) {
    // A bot never simulates, so there is nothing to cross-check.
    const r = bt.humans.map((id) => bt.reports.get(id)).find(Boolean);
    log(`battle ${battleId} done (practice): ${bt.names.A} vs ${bt.names.B} -> ${r ? r.winner : '?'}`);
    return;
  }
  const [r1, r2] = [...bt.reports.values()];
  const consistent = r1.winner === r2.winner && r1.digest === r2.digest;
  for (const id of [bt.a, bt.b]) clients.get(id)?.send({ t: 'battleCheck', battleId, consistent });
  const result = {
    at: new Date().toISOString(),
    battleId,
    a: bt.names.A,
    b: bt.names.B,
    winner: consistent ? r1.winner : 'mismatch',
    engine: bt.engine,
    seconds: Math.round((Date.now() - bt.startedAt) / 1000),
  };
  log(`battle ${battleId} done: ${result.a} vs ${result.b} -> ${result.winner}`
      + (consistent ? '' : ` (DESYNC ${r1.digest}/${r1.winner} vs ${r2.digest}/${r2.winner})`));
  if (RESULTS_FILE) {
    fs.mkdir(path.dirname(RESULTS_FILE), { recursive: true }, () => {
      fs.appendFile(RESULTS_FILE, JSON.stringify(result) + '\n', () => {});
    });
  }
}

// ---------------------------------------------------------------------------
// connection handling

function passwordOk(given) {
  if (!PASSWORD) return true;
  if (typeof given !== 'string') return false;
  // constant-time compare on fixed-length digests
  const a = crypto.createHash('sha256').update(given, 'utf8').digest();
  const b = crypto.createHash('sha256').update(PASSWORD, 'utf8').digest();
  return crypto.timingSafeEqual(a, b);
}

function onHello(c, msg) {
  if (msg.proto !== PROTO) {
    return c.reject('protocol', `프로토콜 버전이 다릅니다 (서버 ${PROTO}, 클라이언트 ${msg.proto}). 클라이언트를 업데이트해 주세요.`);
  }
  if (!passwordOk(msg.password)) {
    log(`wrong password from ${c.addr}`);
    c.helloDone = true;
    // a short delay makes guessing slow
    return setTimeout(() => c.reject('password', '입장 비밀번호가 틀렸습니다.'), WRONG_PASSWORD_DELAY_MS);
  }
  const name = cleanName(msg.name);
  const party = cleanParty(msg.party);
  const engine = typeof msg.engine === 'string' && msg.engine.length <= 120 ? msg.engine : null;
  if (!name) return c.reject('name', '닉네임이 올바르지 않습니다.');
  if (!party) return c.reject('party', '파티 데이터가 올바르지 않습니다.');
  if (!engine) return c.reject('engine', '엔진 버전 정보가 없습니다.');
  if (clients.size > MAX_CLIENTS) return c.reject('full', '서버가 가득 찼습니다.');
  c.name = uniqueName(name);
  c.party = party;
  c.engine = engine;
  c.bot = msg.bot === true;
  c.ready = true;
  clearTimeout(c.helloTimer);
  c.send({ t: 'welcome', id: c.id, name: c.name, serverVersion: SERVER_VERSION });
  log(`join ${c.name} (${c.addr}) engine=${engine} party=${party.length}`);
  broadcastLobby();
}

function handle(c, msg) {
  if (!msg || typeof msg.t !== 'string') return c.error('bad', '잘못된 메시지입니다.');
  if (!c.ready) {
    if (c.helloDone) return;   // rejected hello in flight
    if (msg.t === 'hello') return onHello(c, msg);
    return c.error('hello', '먼저 hello 메시지를 보내야 합니다.');
  }
  switch (msg.t) {
    case 'ping': return c.send({ t: 'pong' });
    case 'party': {
      const party = cleanParty(msg.party);
      if (!party) return c.error('party', '파티 데이터가 올바르지 않습니다.');
      if (c.status === 'battling') return;   // takes effect for the next battle anyway
      c.party = party;
      return broadcastLobby();
    }
    case 'challenge': return onChallenge(c, msg);
    case 'cancelChallenge': return onCancelChallenge(c);
    case 'respond': return onRespond(c, msg);
    case 'battleDone': return onBattleDone(c, msg);
    default: return c.error('unknown', `알 수 없는 메시지: ${msg.t}`);
  }
}

function drop(c) {
  if (!clients.has(c.id)) return;
  clients.delete(c.id);
  clearTimeout(c.helloTimer);
  // challenges involving c
  if (challenges.has(c.id)) endChallenge(c.id, 'offline', { notifyFrom: false });
  for (const [fromId, ch] of [...challenges]) {
    if (ch.to === c.id) endChallenge(fromId, 'offline', { notifyTo: false });
  }
  // a battle in progress: tell the peer (its local playback carries on)
  // If c already reported and the peer is still watching, the record stays so
  // the peer's report can still be cross-checked; otherwise it is dropped and
  // the peer's later battleDone just frees the peer.
  for (const [battleId, bt] of [...battles]) {
    if (bt.a !== c.id && bt.b !== c.id) continue;
    const peerId = bt.a === c.id ? bt.b : bt.a;
    const peer = clients.get(peerId);
    if (bt.reports.has(c.id) && peer) continue;
    peer?.send({ t: 'peerLeft', battleId, name: c.name });
    battles.delete(battleId);
  }
  if (c.ready) log(`leave ${c.name}`);
  broadcastLobby();
}

function statusPayload() {
  const online = [...clients.values()].filter((c) => c.ready).length;
  return { name: 'pmf-battle', version: SERVER_VERSION, proto: PROTO, online, battles: battles.size,
           password: Boolean(PASSWORD) };
}

/** Plain HTTP(S) requests: a tiny status page; the lobby itself is /ws. */
function onRequest(req, res) {
  const url = (req.url || '/').split('?')[0];
  if (req.method === 'GET' && url === '/health') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    return res.end('ok');
  }
  if (req.method === 'GET' && (url === '/' || url === '/status')) {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    return res.end(JSON.stringify(statusPayload(), null, 2));
  }
  res.writeHead(404, { 'Content-Type': 'text/plain' });
  res.end('not found');
}

function onUpgrade(req, socket, head) {
  const url = (req.url || '/').split('?')[0];
  if (url !== '/ws' && url !== '/') {
    socket.end('HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n');
    return;
  }
  const conn = acceptUpgrade(req, socket, head, { maxMessage: MAX_MESSAGE });
  if (!conn) return;
  const c = new Client(conn);
  clients.set(c.id, c);
  c.helloTimer = setTimeout(() => { if (!c.ready) conn.destroy(); }, HELLO_TIMEOUT_MS);
  conn.on('message', (text) => {
    c.lastSeen = Date.now();
    let msg;
    try { msg = JSON.parse(text); } catch { return c.error('json', 'JSON 형식이 아닙니다.'); }
    try { handle(c, msg); } catch (e) { log('handler error', e); c.error('internal', '서버 오류'); }
  });
  conn.on('close', () => drop(c));
}

let server;
if (TLS_CERT && TLS_KEY) {
  server = https.createServer({ cert: fs.readFileSync(TLS_CERT), key: fs.readFileSync(TLS_KEY) }, onRequest);
} else {
  server = http.createServer(onRequest);
}
server.on('upgrade', onUpgrade);
server.on('clientError', (err, socket) => { socket.destroy(); });

// Drop connections that went silent (crashed client behind NAT, etc.)
setInterval(() => {
  const now = Date.now();
  for (const c of clients.values()) {
    if (now - c.lastSeen > IDLE_TIMEOUT_MS) c.conn.destroy();
  }
}, 15000).unref();

server.on('error', (e) => { log('server error', e.message); process.exit(1); });
server.listen(PORT, HOST, () => {
  const a = server.address();
  const scheme = TLS_CERT && TLS_KEY ? 'https/wss' : 'http/ws (no TLS)';
  log(`pmf-battle server ${SERVER_VERSION} listening on ${a.address}:${a.port} `
      + `(${scheme}, proto ${PROTO}, password ${PASSWORD ? 'on' : 'off'})`);
});

for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => {
    log(`${sig}: shutting down`);
    for (const c of clients.values()) c.conn.destroy();
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 2000).unref();
  });
}
