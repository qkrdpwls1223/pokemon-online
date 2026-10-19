#!/usr/bin/env node
// Practice bot: joins the lobby with a sample party and accepts every
// challenge, so one person can test the client alone.
//
//   node tools/bot.js [host] [port] [name]
//   node tools/bot.js 127.0.0.1 7777 연습봇
//
// The bot never simulates. It frees itself after a while by reporting
// battleDone; the server skips the result cross-check for bot battles.

'use strict';

const net = require('net');

const host = process.argv[2] || '127.0.0.1';
const port = parseInt(process.argv[3] || '7777', 10);
const name = process.argv[4] || '연습봇';
const BATTLE_HOLD_MS = 45000;   // stay "battling" about as long as a playback

// Movesets: the last four level-up moves at each level (upstream gamedata).
const iv = { hp: 15, atk: 15, def: 15, spAtk: 15, spDef: 15, spe: 15 };
const PARTY = [
  { dex: 25, level: 30, moves: [56, 161, 129, 516], gender: 'male', ivs: iv },     // 피카츄
  { dex: 6, level: 36, moves: [106, 522, 81, 178], gender: 'male', ivs: iv },      // 리자몽
  { dex: 143, level: 30, moves: [3, 232, 25, 227], gender: 'female', ivs: iv },    // 잠만보
  { dex: 94, level: 35, moves: [515, 126, 472, 127], gender: 'male', ivs: iv },    // 팬텀
];

function log(...a) { console.log(new Date().toISOString(), ...a); }

function connect() {
  const sock = net.connect(port, host);
  sock.setEncoding('utf8');
  const send = (o) => sock.write(JSON.stringify(o) + '\n');
  let buf = '';
  let ping;

  sock.on('connect', () => {
    log(`connected to ${host}:${port}`);
    send({ t: 'hello', proto: 1, name, engine: 'bot', client: 'bot', bot: true, party: PARTY });
    ping = setInterval(() => send({ t: 'ping' }), 20000);
  });

  sock.on('data', (d) => {
    buf += d;
    let nl;
    while ((nl = buf.indexOf('\n')) >= 0) {
      const msg = JSON.parse(buf.slice(0, nl));
      buf = buf.slice(nl + 1);
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
          log(`server error: ${msg.message}`);
          break;
        default:
          break;
      }
    }
  });

  sock.on('close', () => {
    clearInterval(ping);
    log('disconnected, retrying in 5 s');
    setTimeout(connect, 5000);
  });
  sock.on('error', (e) => log(`socket error: ${e.message}`));
}

connect();
