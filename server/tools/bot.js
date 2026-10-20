#!/usr/bin/env node
// Practice bot: joins the lobby with a sample party and accepts every
// challenge, so one person can test the client alone. Node >= 22 (global WebSocket).
//
//   node tools/bot.js <server-url> [name] [--insecure]
//   node tools/bot.js https://10.10.33.36:7777 연습봇
//   SERVER_PASSWORD=... node tools/bot.js ws://127.0.0.1:7777
//
// The password comes from SERVER_PASSWORD (same variable the server uses).
// --insecure skips certificate checks — only for a bot talking to its own
// server over the docker network, where the certificate's IP does not match.
//
// The bot never simulates. It frees itself after a while by reporting
// battleDone; the server skips the result cross-check for bot battles.

'use strict';

const args = process.argv.slice(2);
const insecure = args.includes('--insecure');
const positional = args.filter((a) => !a.startsWith('--'));
const rawUrl = positional[0] || 'ws://127.0.0.1:7777';
const name = positional[1] || '연습봇';
const password = process.env.SERVER_PASSWORD || '';
const BATTLE_HOLD_MS = 45000;   // stay "battling" about as long as a playback

if (insecure) process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

/** https://host:port -> wss://host:port/ws (http -> ws). */
function wsUrl(u) {
  const url = new URL(u.includes('://') ? u : `https://${u}`);
  if (url.protocol === 'https:') url.protocol = 'wss:';
  if (url.protocol === 'http:') url.protocol = 'ws:';
  if (url.pathname === '/' || url.pathname === '') url.pathname = '/ws';
  return url.toString();
}

// Movesets: the last four level-up moves at each level (upstream gamedata).
const iv = { hp: 15, atk: 15, def: 15, spAtk: 15, spDef: 15, spe: 15 };
const PARTY = [
  { dex: 25, level: 30, moves: [56, 161, 129, 516], gender: 'male', ivs: iv },     // 피카츄
  { dex: 6, level: 36, moves: [106, 522, 81, 178], gender: 'male', ivs: iv },      // 리자몽
  { dex: 143, level: 30, moves: [3, 232, 25, 227], gender: 'female', ivs: iv },    // 잠만보
  { dex: 94, level: 35, moves: [515, 126, 472, 127], gender: 'male', ivs: iv },    // 팬텀
];

function log(...a) { console.log(new Date().toISOString(), ...a); }

const target = wsUrl(rawUrl);

function connect() {
  const ws = new WebSocket(target);
  const send = (o) => { if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(o)); };
  let ping;
  let rejected = false;

  ws.addEventListener('open', () => {
    log(`connected to ${target}`);
    send({ t: 'hello', proto: 2, password, name, engine: 'bot', client: 'bot', bot: true, party: PARTY });
    ping = setInterval(() => send({ t: 'ping' }), 20000);
  });

  ws.addEventListener('message', (ev) => {
    const msg = JSON.parse(ev.data);
    switch (msg.t) {
      case 'welcome':
        log(`joined as ${msg.name}`);
        break;
      case 'challenged':
        log(`challenge from ${msg.fromName} -> accepting`);
        setTimeout(() => send({ t: 'respond', from: msg.from, accept: true }), 1000);
        break;
      case 'battleStart': {
        const foe = msg.you === 'A' ? msg.b : msg.a;
        log(`battle ${msg.battleId} vs ${foe.name} (seed ${msg.seed})`);
        setTimeout(() => send({ t: 'battleDone', battleId: msg.battleId, winner: 'draw', digest: 'bot' }),
          BATTLE_HOLD_MS);
        break;
      }
      case 'error':
        log(`server error: ${msg.code} ${msg.message}`);
        if (msg.code === 'password' || msg.code === 'protocol') rejected = true;
        break;
      default:
        break;
    }
  });

  ws.addEventListener('close', () => {
    clearInterval(ping);
    if (rejected) { log('rejected by the server, giving up'); process.exit(1); }
    log('disconnected, retrying in 5 s');
    setTimeout(connect, 5000);
  });
  ws.addEventListener('error', (e) => log(`socket error: ${e.message || 'connection failed'}`));
}

connect();
