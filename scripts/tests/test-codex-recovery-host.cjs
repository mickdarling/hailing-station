'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { once } = require('node:events');
const { WebSocketServer } = require('../codex-recovery/node_modules/ws');
const { HostRecovery, ownsTurn, commandRecord, parseControl, requestBlock } = require('../codex-recovery/host.cjs');
const { Control, readAttempt } = require('../codex-recovery');
const request = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const generation = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const threadId = '11111111-1111-4111-8111-111111111111';
const record = op => ({ version: 1, op, request, generation });
async function fixture(t, custom = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'hail-host-recovery-'));
  fs.chmodSync(dir, 0o700);
  const socket = path.join(dir, 'control.sock'), server = http.createServer();
  const websocket = new WebSocketServer({ server });
  const state = { turn: null, status: 'idle', interrupts: 0, wall: 100, mono: 100,
    identity: 'authored-owned-binding', snapshotReads: 0, terminal: true };
  websocket.on('connection', peer => peer.on('message', raw => {
    const message = JSON.parse(raw);
    if (!message.id) return;
    let result;
    if (message.method === 'initialize') result = {};
    else if (message.method === 'thread/read') {
      state.snapshotReads++;
      custom.beforeRead?.(state, peer, message);
      result = { thread: { id: threadId, status: { type: state.status, activeFlags: [] } } };
    } else if (message.method === 'thread/turns/list') {
      if (custom.holdList?.(state, peer, message)) return;
      result = { data: state.turn ? [state.turn] : [] };
    } else {
      assert.equal(message.method, 'turn/interrupt');
      assert.deepEqual(message.params, { threadId, turnId: 'owned-turn' });
      state.interrupts++;
      if (custom.dropAck) { peer.close(); return; }
      if (state.terminal) state.turn.status = 'interrupted';
      result = {};
    }
    peer.send(JSON.stringify({ id: message.id, result }));
  }));
  server.listen(socket); await once(server, 'listening'); fs.chmodSync(socket, 0o600);
  const config = { threadId, target: 'tmux:authored', binding: '$1@2/%3:4', firstResponseSeconds: 5,
    statusFile: path.join(dir, 'status.json') };
  const events = [];
  const worker = new HostRecovery(config, {
    lookup: () => ({ socket, identity: state.identity }), lock: () => {},
    open: name => new Control(name, { timeoutMs: 100 }), emit: event => events.push(event),
    wall: () => state.wall, mono: () => state.mono, confirmMs: 45,
  });
  t.after(async () => {
    worker.retire(); for (const peer of websocket.clients) peer.terminate();
    await new Promise(resolve => websocket.close(resolve)); await new Promise(resolve => server.close(resolve));
    fs.rmSync(dir, { recursive: true, force: true });
  });
  const voice = () => {
    state.status = 'active';
    state.turn = { id: 'owned-turn', startedAt: 100, status: 'inProgress',
      items: [{ type: 'userMessage', content: [{ type: 'text', text: 'Authored request.' + requestBlock(config.target, request) }] }] };
    state.wall = state.mono = 110;
  };
  return { worker, state, config, events, voice, dir };
}
test('host recovery requires commit, exact generated request and child acknowledgement', async t => {
  const { worker, state, events, voice, config } = await fixture(t);
  await worker.command(record('prepare'));
  assert.equal(events.at(-1).state, 'ready');
  voice(); await worker.poll(); assert.equal(state.interrupts, 0);
  await worker.command(record('commit')); await worker.poll();
  assert.equal(events.at(-1).state, 'awaiting_child_ack'); assert.equal(state.interrupts, 0);
  await worker.command(record('authorize')); await worker.poll();
  assert.equal(state.interrupts, 1); assert.equal(events.at(-1).state, 'interrupted');
  assert.equal(events.at(-1).recovered, true); assert.deepEqual([...readAttempt(config)], ['owned-turn']);
});
test('manual or already-active work is never adopted', async t => {
  const { worker, state, voice } = await fixture(t);
  voice(); await assert.rejects(worker.command(record('prepare')), /provider_busy/);
  assert.equal(state.interrupts, 0);
});
test('foreign generation controls cannot authorize a request', async t => {
  const { worker, state, voice } = await fixture(t);
  await worker.command(record('prepare')); voice(); await worker.command(record('commit'));
  await assert.rejects(worker.command({ ...record('authorize'), generation: threadId }), /foreign_control/);
  await worker.poll(); assert.equal(state.interrupts, 0);
});
test('a quoted ID or a later user message never proves original turn ownership', () => {
  const config = { target: 'tmux:authored' };
  const matching = { type: 'userMessage', content: [{ type: 'text', text: requestBlock(config.target, request) }] };
  assert.equal(ownsTurn({ items: [matching] }, config, request), true);
  const manual = { type: 'userMessage', content: [{ type: 'text', text: 'A quoted reference ' + request }] };
  assert.equal(ownsTurn({ items: [manual, matching] }, config, request), false);
  assert.equal(ownsTurn({ items: [manual] }, config, request), false);
});
test('a different first request refuses control even when its turn is silent', async t => {
  const { worker, state, voice, events } = await fixture(t);
  await worker.command(record('prepare')); voice(); state.turn.items[0].content[0].text = 'Authored manual request.';
  await worker.command(record('commit')); await worker.command(record('authorize')); await worker.poll();
  assert.equal(state.interrupts, 0); assert.equal(events.at(-1).state, 'unavailable');
});
test('observed productive work remains protected when later history regresses', async t => {
  const { worker, state, voice, events } = await fixture(t);
  await worker.command(record('prepare')); voice();
  state.turn.items.push({ type: 'commandExecution', status: 'inProgress' });
  await worker.command(record('commit')); await worker.command(record('authorize')); await worker.poll();
  state.turn.items.pop(); state.wall = state.mono = 150; await worker.poll();
  assert.equal(state.interrupts, 0); assert.equal(events.at(-1).state, 'working');
});
test('retirement during a suspended snapshot prevents any later interrupt', async t => {
  let hold = false, waiting;
  const { worker, state, voice } = await fixture(t, {
    holdList: (_state, peer, message) => { if (!hold) return false; waiting = { peer, message }; return true; },
  });
  await worker.command(record('prepare')); voice(); await worker.command(record('commit'));
  await worker.command(record('authorize')); hold = true;
  const poll = worker.poll();
  for (let attempt = 0; !waiting && attempt < 50; attempt++) await new Promise(resolve => setTimeout(resolve, 2));
  assert.ok(waiting); worker.retire(); await poll; assert.equal(state.interrupts, 0);
});
test('ownership is rechecked in the final pre-interrupt snapshot', async t => {
  const { worker, state, voice } = await fixture(t, {
    beforeRead: value => { if (value.snapshotReads === 3) value.turn.items = [{ type: 'userMessage', content: [] }]; },
  });
  await worker.command(record('prepare')); voice(); await worker.command(record('commit'));
  await worker.command(record('authorize')); await worker.poll(); assert.equal(state.interrupts, 0);
});
test('missing terminal proof and lost acknowledgements never report recovered', async t => {
  for (const dropAck of [false, true]) await t.test(String(dropAck), async sub => {
    const { worker, state, voice, events, config } = await fixture(sub, { dropAck });
    await worker.command(record('prepare')); voice(); state.terminal = false;
    await worker.command(record('commit')); await worker.command(record('authorize')); await worker.poll();
    assert.equal(state.interrupts, 1); assert.equal(events.at(-1).recovered, false);
    assert.deepEqual([...readAttempt(config)], ['owned-turn']);
  });
});
test('natural completion remains distinct from recovery', async t => {
  const { worker, state, voice, events } = await fixture(t);
  await worker.command(record('prepare')); voice(); state.turn.status = 'completed'; state.status = 'idle';
  await worker.command(record('commit')); await worker.poll();
  assert.equal(events.at(-1).state, 'completed'); assert.equal(events.at(-1).recovered, false);
  assert.equal(state.interrupts, 0);
});
test('invalid envelopes are rejected and diagnostics never contain prompt text', async t => {
  assert.throws(() => commandRecord({ ...record('prepare'), extra: true }), /invalid_control/);
  const { worker, voice, events } = await fixture(t);
  await worker.command(record('prepare')); voice(); await worker.command(record('commit')); await worker.poll();
  assert.equal(JSON.stringify(events).includes('Authored request.'), false);
});

test('missing child acceptance expires the host authority instead of waiting forever', async t => {
  const { worker, state, voice, events } = await fixture(t);
  await worker.command(record('prepare')); voice(); await worker.command(record('commit'));
  state.wall = state.mono = 116; await worker.poll();
  assert.equal(events.at(-1).state, 'child_ack_unconfirmed'); assert.equal(state.interrupts, 0);
});
test('bounded UTF-8 controls reject duplicate and escaped duplicate keys', () => {
  assert.deepEqual(parseControl(Buffer.from(JSON.stringify(record('prepare')))), record('prepare'));
  const valid = JSON.stringify(record('prepare'));
  assert.throws(() => parseControl(Buffer.from('{"op":"retire",' + valid.slice(1))), /invalid_control/);
  assert.throws(() => parseControl(Buffer.from('{"\\u006fp":"retire",' + valid.slice(1))), /invalid_control/);
  assert.throws(() => parseControl(Buffer.alloc(1025, 32)), /invalid_control/);
  assert.throws(() => parseControl(Buffer.from([0xff])), /invalid_control/);
});

test('a late commit cannot renew expired admission when the timer has not run', async t => {
  const { worker, state, voice } = await fixture(t);
  await worker.command(record('prepare')); voice(); state.wall = state.mono = 131;
  await assert.rejects(worker.command(record('commit')), /admission_expired/);
  await worker.poll(); assert.equal(state.interrupts, 0);
});
test('late child authorization cannot revive original expired admission', async t => {
  const { worker, state, voice } = await fixture(t);
  await worker.command(record('prepare')); voice(); state.wall = state.mono = 129;
  await worker.command(record('commit')); await worker.poll();
  state.wall = state.mono = 131;
  await assert.rejects(worker.command(record('authorize')), /admission_expired/);
  await worker.poll(); assert.equal(state.interrupts, 0);
});
test('a matching snapshot returned after admission expiry cannot bind or interrupt', async t => {
  const { worker, state, voice } = await fixture(t, {
    beforeRead: value => { if (value.snapshotReads === 2) value.wall = value.mono = 131; },
  });
  await worker.command(record('prepare')); voice(); await worker.command(record('commit'));
  await worker.command(record('authorize')); await worker.poll();
  assert.equal(worker.pinned, undefined); assert.equal(state.interrupts, 0);
});
