#!/usr/bin/env node
// End-to-end smoke test: starts server.js on a free port and drives it with
// fake clients over real TCP. Run: npm test  (or node test/smoke.js)

'use strict';

const net = require('net');
const path = require('path');
const { spawn } = require('child_process');
const assert = require('assert');

const ENGINE = 'testcommit/pvp1/proto1';
const PARTY = [
  { dex: 25, level: 40, moves: [84, 85, 86, 87], gender: 'male', ivs: { hp: 15, atk: 15, def: 15, spAtk: 15, spDef: 15, spe: 15 } },
  { dex: 6, level: 40, moves: [52, 53], gender: 'female' },
];

function freePort() {
  return new Promise((resolve) => {
    const s = net.createServer();
    s.listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => resolve(p)); });
  });
}

class Fake {
  constructor(port, label) {
    this.label = label;
    this.inbox = [];
    this.waiters = [];
    this.sock = net.connect(port, '127.0.0.1');
    this.sock.setEncoding('utf8');
    let buf = '';
    this.closed = new Promise((r) => this.sock.on('close', r));
    this.sock.on('data', (d) => {
      buf += d;
      let nl;
      while ((nl = buf.indexOf('\n')) >= 0) {
        const msg = JSON.parse(buf.slice(0, nl));
        buf = buf.slice(nl + 1);
        this.inbox.push(msg);
        this.flush();
      }
    });
  }
  ready() { return new Promise((r) => this.sock.once('connect', r)); }
  send(o) { this.sock.write(JSON.stringify(o) + '\n'); }
  flush() {
    for (const w of [...this.waiters]) {
      const i = this.inbox.findIndex(w.pred);
      if (i >= 0) {
        const [m] = this.inbox.splice(i, 1);
        this.waiters.splice(this.waiters.indexOf(w), 1);
        clearTimeout(w.timer);
        w.resolve(m);
      }
    }
  }
  /** next message of type t (optionally matching pred), consumed */
  next(t, pred = () => true, ms = 3000) {
    return new Promise((resolve, reject) => {
      const w = { pred: (m) => m.t === t && pred(m), resolve };
      w.timer = setTimeout(() => {
        this.waiters.splice(this.waiters.indexOf(w), 1);
        reject(new Error(`${this.label}: timed out waiting for ${t}; inbox=${JSON.stringify(this.inbox.map((m) => m.t))}`));
      }, ms);
      this.waiters.push(w);
      this.flush();
    });
  }
  /** latest lobby (drains older ones) */
  async lobby(pred = () => true) {
    for (;;) {
      const m = await this.next('lobby');
      if (pred(m)) return m;
    }
  }
  close() { this.sock.end(); }
}

async function join(port, name, { engine = ENGINE, party = PARTY } = {}) {
  const c = new Fake(port, name);
  await c.ready();
  c.send({ t: 'hello', proto: 1, name, engine, client: 'smoke', party });
  const w = await c.next('welcome');
  c.id = w.id;
  c.name = w.name;
  return c;
}

let passed = 0;
async function step(name, fn) {
  await fn();
  passed++;
  console.log(`  PASS  ${name}`);
}

(async () => {
  const port = await freePort();
  const srv = spawn(process.execPath, [path.join(__dirname, '..', 'server.js')], {
    env: { ...process.env, PORT: String(port), HOST: '127.0.0.1', CHALLENGE_TIMEOUT_MS: '700', RESULTS_FILE: '' },
    stdio: ['ignore', 'pipe', 'inherit'],
  });
  let srvOut = '';
  srv.stdout.on('data', (d) => { srvOut += d; });
  await new Promise((r) => { const t = setInterval(() => { if (srvOut.includes('listening')) { clearInterval(t); r(); } }, 20); });

  try {
    let alice, bob, carol;

    await step('hello -> welcome, lobby shows others', async () => {
      alice = await join(port, '앨리스');
      bob = await join(port, 'Bob');
      const l = await alice.lobby((m) => m.users.some((u) => u.id === bob.id));
      const u = l.users.find((x) => x.id === bob.id);
      assert.strictEqual(u.name, 'Bob');
      assert.strictEqual(u.compatible, true);
      assert.deepStrictEqual(u.lead, { dex: 25, level: 40 });
      assert.strictEqual(u.partySize, 2);
      assert.ok(!l.users.some((x) => x.id === alice.id), 'lobby excludes self');
    });

    await step('duplicate names are made unique', async () => {
      const dup = await join(port, 'Bob');
      assert.notStrictEqual(dup.name, 'Bob');
      dup.close();
      await dup.closed;
    });

    await step('bad hello is rejected', async () => {
      const bad = new Fake(port, 'bad');
      await bad.ready();
      bad.send({ t: 'hello', proto: 1, name: 'x', engine: ENGINE, party: [{ dex: 999, level: 5, moves: [] }] });
      const e = await bad.next('error');
      assert.strictEqual(e.code, 'party');
      await bad.closed;
    });

    await step('challenge -> decline', async () => {
      alice.send({ t: 'challenge', to: bob.id });
      const sent = await alice.next('challengeSent');
      assert.strictEqual(sent.to, bob.id);
      const got = await bob.next('challenged');
      assert.strictEqual(got.from, alice.id);
      bob.send({ t: 'respond', from: alice.id, accept: false });
      const end = await alice.next('challengeEnded');
      assert.strictEqual(end.reason, 'declined');
    });

    await step('challenge -> expire', async () => {
      alice.send({ t: 'challenge', to: bob.id });
      await bob.next('challenged');
      const a = await alice.next('challengeEnded', () => true, 2000);
      const b = await bob.next('challengeEnded', () => true, 2000);
      assert.strictEqual(a.reason, 'expired');
      assert.strictEqual(b.reason, 'expired');
      bob.send({ t: 'respond', from: alice.id, accept: true });   // too late
      const e = await bob.next('error');
      assert.strictEqual(e.code, 'noChallenge');
    });

    await step('challenge -> cancel', async () => {
      alice.send({ t: 'challenge', to: bob.id });
      await bob.next('challenged');
      alice.send({ t: 'cancelChallenge' });
      assert.strictEqual((await bob.next('challengeEnded')).reason, 'cancelled');
      assert.strictEqual((await alice.next('challengeEnded')).reason, 'cancelled');
    });

    let battleId;
    await step('challenge -> accept -> identical battleStart on both sides', async () => {
      alice.send({ t: 'challenge', to: bob.id });
      await bob.next('challenged');
      bob.send({ t: 'respond', from: alice.id, accept: true });
      const sa = await alice.next('battleStart');
      const sb = await bob.next('battleStart');
      assert.strictEqual(sa.battleId, sb.battleId);
      assert.strictEqual(sa.seed, sb.seed);
      assert.match(sa.seed, /^\d+$/);
      assert.ok(BigInt(sa.seed) <= 0xFFFFFFFFFFFFFFFFn);
      assert.deepStrictEqual(sa.a, sb.a);
      assert.deepStrictEqual(sa.b, sb.b);
      assert.notStrictEqual(sa.you, sb.you);
      const mine = sa.you === 'A' ? sa.a : sa.b;
      assert.strictEqual(mine.id, alice.id);
      assert.deepStrictEqual(mine.party[0].moves, PARTY[0].moves);
      battleId = sa.battleId;
    });

    await step('busy while battling', async () => {
      carol = await join(port, 'Carol');
      const l = await carol.lobby((m) => m.users.length >= 2);
      assert.ok(l.users.filter((u) => u.id !== carol.id).every((u) => u.status === 'battling'));
      carol.send({ t: 'challenge', to: alice.id });
      assert.strictEqual((await carol.next('challengeEnded')).reason, 'busy');
    });

    await step('both report same digest -> consistent', async () => {
      alice.send({ t: 'battleDone', battleId, winner: 'A', digest: 'abc123' });
      bob.send({ t: 'battleDone', battleId, winner: 'A', digest: 'abc123' });
      assert.strictEqual((await alice.next('battleCheck')).consistent, true);
      assert.strictEqual((await bob.next('battleCheck')).consistent, true);
      const l = await carol.lobby((m) => m.users.every((u) => u.status === 'idle'));
      assert.strictEqual(l.users.length, 2);
    });

    await step('different digests -> inconsistent', async () => {
      carol.send({ t: 'challenge', to: bob.id });
      await bob.next('challenged');
      bob.send({ t: 'respond', from: carol.id, accept: true });
      const s = await carol.next('battleStart');
      await bob.next('battleStart');
      carol.send({ t: 'battleDone', battleId: s.battleId, winner: 'A', digest: 'aaa' });
      bob.send({ t: 'battleDone', battleId: s.battleId, winner: 'A', digest: 'bbb' });
      assert.strictEqual((await carol.next('battleCheck')).consistent, false);
    });

    await step('incompatible engine cannot be challenged', async () => {
      const old = await join(port, 'Old', { engine: 'othercommit/pvp1/proto1' });
      const l = await alice.lobby((m) => m.users.some((u) => u.id === old.id));
      assert.strictEqual(l.users.find((u) => u.id === old.id).compatible, false);
      alice.send({ t: 'challenge', to: old.id });
      assert.strictEqual((await alice.next('challengeEnded')).reason, 'incompatible');
      old.close();
      await old.closed;
    });

    await step('peer leaving mid-battle -> peerLeft', async () => {
      alice.send({ t: 'challenge', to: carol.id });
      await carol.next('challenged');
      carol.send({ t: 'respond', from: alice.id, accept: true });
      const s = await alice.next('battleStart');
      await carol.next('battleStart');
      carol.close();
      await carol.closed;
      const pl = await alice.next('peerLeft');
      assert.strictEqual(pl.battleId, s.battleId);
      alice.send({ t: 'battleDone', battleId: s.battleId, winner: 'B', digest: 'x' });
      await alice.lobby((m) => !m.users.some((u) => u.name === 'Carol'));
    });

    await step('target going offline ends the challenge', async () => {
      const dave = await join(port, 'Dave');
      alice.send({ t: 'challenge', to: dave.id });
      await dave.next('challenged');
      dave.close();
      assert.strictEqual((await alice.next('challengeEnded')).reason, 'offline');
    });

    await step('party update reflects in lobby', async () => {
      bob.send({ t: 'party', party: [{ dex: 143, level: 50, moves: [1, 2], gender: 'male' }] });
      const l = await alice.lobby((m) => m.users.some((u) => u.id === bob.id && u.lead && u.lead.dex === 143));
      assert.strictEqual(l.users.find((u) => u.id === bob.id).partySize, 1);
    });

    await step('practice bot: compatible with any engine, no cross-check', async () => {
      const bot = new Fake(port, 'bot');
      await bot.ready();
      bot.send({ t: 'hello', proto: 1, name: 'Bot', engine: 'bot', client: 'bot', bot: true, party: PARTY });
      bot.id = (await bot.next('welcome')).id;
      const l = await alice.lobby((m) => m.users.some((u) => u.id === bot.id));
      const u = l.users.find((x) => x.id === bot.id);
      assert.strictEqual(u.compatible, true);
      assert.strictEqual(u.bot, true);
      alice.send({ t: 'challenge', to: bot.id });
      await bot.next('challenged');
      bot.send({ t: 'respond', from: alice.id, accept: true });
      const s = await alice.next('battleStart');
      await bot.next('battleStart');
      alice.send({ t: 'battleDone', battleId: s.battleId, winner: 'A', digest: 'real' });
      bot.send({ t: 'battleDone', battleId: s.battleId, winner: 'draw', digest: 'bot' });
      await alice.lobby((m) => m.users.some((x) => x.id === bot.id && x.status === 'idle'));
      assert.ok(!alice.inbox.some((m) => m.t === 'battleCheck'), 'no battleCheck for bot battles');
      bot.close();
      await bot.closed;
    });

    await step('ping -> pong, unknown message -> error', async () => {
      alice.send({ t: 'ping' });
      await alice.next('pong');
      alice.send({ t: 'nope' });
      assert.strictEqual((await alice.next('error')).code, 'unknown');
    });

    alice.close();
    bob.close();
    console.log(`\nALL ${passed} PASS`);
    srv.kill('SIGTERM');
    process.exit(0);
  } catch (e) {
    console.error('\nFAIL:', e.message);
    console.error('--- server log ---\n' + srvOut);
    srv.kill('SIGKILL');
    process.exit(1);
  }
})();
