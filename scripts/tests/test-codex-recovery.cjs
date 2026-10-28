'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { execFileSync } = require('node:child_process');
const { once } = require('node:events');
const { WebSocketServer } = require('../codex-recovery/node_modules/ws');
const { Control, FirstResponse, configAt, cycle, discover, privateSocket, readAttempt, recover, writeStatus } = require('../codex-recovery');

const threadId = '11111111-1111-4111-8111-111111111111';
const silent = (id = 'turn-one', startedAt = 100) => ({
  thread: { id: threadId, status: { type: 'active', activeFlags: [] } },
  turn: { id, status: 'inProgress', startedAt, items: [{ type: 'userMessage' }] },
});
async function fixture(t, handler, options = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'hailing-codex-fixture-'));
  fs.chmodSync(dir, 0o700);
  const socket = path.join(dir, 'control.sock');
  const server = http.createServer();
  const websocket = new WebSocketServer({ server });
  websocket.on('connection', peer => peer.on('message', raw => {
    const request = JSON.parse(raw);
    if (request.method === 'initialize') peer.send(JSON.stringify({ id: request.id, result: {} }));
    else if (request.id) handler(peer, request);
  }));
  server.listen(socket);
  await once(server, 'listening');
  fs.chmodSync(socket, 0o600);
  const control = new Control(socket, { timeoutMs: 1000, ...options });
  t.after(async () => {
    control.close();
    for (const peer of websocket.clients) peer.terminate();
    await new Promise(resolve => websocket.close(resolve));
    await new Promise(resolve => server.close(resolve));
    fs.rmSync(dir, { recursive: true, force: true });
  });
  await control.initialize();
  return { control, dir, socket };
}

test('Unix WebSocket handshake and notifications precede an exact-ID response', async t => {
  const { control, socket } = await fixture(t, (peer, request) => {
    peer.send(JSON.stringify({ method: 'public/notice', params: {} }));
    const result = request.method === 'thread/read'
      ? { thread: { id: threadId, status: { type: 'idle' } } } : { data: [] };
    peer.send(JSON.stringify({ id: request.id, result }));
  });
  assert.equal((await control.snapshot(threadId)).thread.id, threadId);
  assert.match(privateSocket(socket), /^\d+:\d+$/);
});
test('a silent RPC times out, closes the connection, and is never retried', async t => {
  let calls = 0;
  const { control } = await fixture(t, () => { calls++; }, { timeoutMs: 40 });
  await assert.rejects(control.request('thread/read', { threadId }), /rpc_timeout/);
  assert.equal(calls, 1);
  await assert.rejects(control.request('thread/read', { threadId }), /control_closed/);
});
test('provider refusal content is replaced with a fixed error', async t => {
  const { control } = await fixture(t, (peer, request) => peer.send(JSON.stringify({
    id: request.id, error: { code: -1, message: 'synthetic private body must not escape' },
  })));
  await assert.rejects(control.request('thread/read', {}), error => error.message === 'rpc_refused');
});
test('malformed JSON and ambiguous envelopes fail closed', async t => {
  for (const data of ['not-json', JSON.stringify({ id: 2, result: {}, error: {} })]) {
    await t.test(data === 'not-json' ? 'invalid JSON' : 'conflicting result', async sub => {
      const { control } = await fixture(sub, peer => peer.send(data));
      await assert.rejects(control.request('thread/read', {}), /invalid_json|invalid_response/);
    });
  }
});
test('an unsolicited approval request is not answered', async t => {
  let replies = 0;
  const { control } = await fixture(t, peer => {
    peer.on('message', raw => { if (JSON.parse(raw).id === 700) replies++; });
    peer.send(JSON.stringify({ id: 700, method: 'item/commandExecution/requestApproval', params: {} }));
  });
  await assert.rejects(control.request('thread/read', {}), /server_request/);
  assert.equal(replies, 0);
});
test('oversized frames stop control without logging their body', async t => {
  const { control } = await fixture(t, peer => peer.send('x'.repeat(2048)), { maxPayload: 512 });
  await assert.rejects(control.request('thread/read', {}), /control_failed|control_closed/);
});
test('a different returned thread never becomes the configured thread', async t => {
  const { control } = await fixture(t, (peer, request) => peer.send(JSON.stringify({
    id: request.id, result: { thread: { id: 'not-owned' } },
  })));
  await assert.rejects(control.snapshot(threadId), /wrong_thread/);
});

test('first response uses original turn time and user steering does not renew it', () => {
  const clock = new FirstResponse(), value = silent();
  assert.equal(clock.inspect(value, 90, 120, 10), 'waiting');
  value.turn.items.push({ type: 'userMessage' }, { type: 'userMessage' });
  assert.equal(clock.inspect(value, 90, 190, 80), 'stalled');
});
test('assistant commentary, visible reasoning and every tool item protect active work', () => {
  for (const item of [{ type: 'agentMessage', text: 'Working on the request.' },
    { type: 'reasoning', summary: ['A visible step'] }, { type: 'commandExecution', status: 'inProgress' },
    { type: 'mcpToolCall' }, { type: 'unknownFutureTool' }]) {
    const value = silent(); value.turn.items.push(item);
    assert.equal(new FirstResponse().inspect(value, 90, 300, 10), 'working');
  }
});
test('empty reasoning is not a first visible response', () => {
  const value = silent(); value.turn.items.push({ type: 'reasoning', summary: [], content: [] });
  assert.equal(new FirstResponse().inspect(value, 90, 300, 10), 'stalled');
});
test('first response stays latched when a later same-turn snapshot regresses', () => {
  const value = silent(), clock = new FirstResponse();
  value.turn.items.push({ type: 'agentMessage', text: 'Working on it.' });
  assert.equal(clock.inspect(value, 90, 300, 10), 'working');
  value.turn.items = [{ type: 'userMessage' }];
  assert.equal(clock.inspect(value, 90, 301, 11), 'working');
  value.turn.id = 'new-turn'; value.turn.startedAt = 301;
  assert.equal(clock.inspect(value, 90, 302, 12), 'waiting');
});
test('unknown reasoning shapes never establish silence or interruption authority', async () => {
  for (const fields of [{ summary: {} }, { content: { text: 'authored visible step' } },
    { summary: 42 }, { summary: null }, { summary: [{}] }, { content: [false] }]) {
    const value = silent(); value.turn.items.push({ type: 'reasoning', summary: [], content: [], ...fields });
    assert.throws(() => new FirstResponse().inspect(value, 90, 300, 10), /invalid_reasoning/);
    const control = recoveryMock(value, []);
    await assert.rejects(recover(control, { threadId }, silent(), { validate() {} }), /invalid_reasoning/);
    assert.equal(control.requests.length, 0);
  }
});
test('waiting for owner input or approval is protected', () => {
  for (const flag of ['waitingOnApproval', 'waitingOnUserInput', 'unknownFutureWait']) {
    const value = silent(); value.thread.status.activeFlags = [flag];
    assert.equal(new FirstResponse().inspect(value, 90, 300, 10), 'working');
  }
});
test('clock steps and changed start-time authority do not cause interruption', () => {
  const clock = new FirstResponse(), value = silent();
  assert.equal(clock.inspect(value, 90, 120, 10), 'waiting');
  assert.equal(clock.inspect(value, 90, 500, 11), 'clock_changed');
  value.turn.startedAt++;
  assert.equal(clock.inspect(value, 90, 121, 11), 'clock_changed');
});
test('missing timing or unknown runtime state is unavailable', () => {
  for (const mutate of [value => { delete value.turn.startedAt; }, value => { value.turn.startedAt = 501; },
    value => { value.turn.startedAt = -1; },
    value => { value.thread.status = { type: 'notLoaded' }; }, value => { delete value.thread.status.activeFlags; }]) {
    const value = silent(); mutate(value);
    assert.equal(new FirstResponse().inspect(value, 90, 300, 10), 'unavailable');
  }
});
test('a stored completed turn cannot substitute for a live idle runtime', () => {
  for (const status of [{ type: 'notLoaded' }, { type: 'active', activeFlags: [] }, { type: 'unknown' }]) {
    const value = silent(); value.thread.status = status; value.turn.status = 'completed';
    assert.equal(new FirstResponse().inspect(value, 90, 300, 10), 'unavailable');
  }
});
test('idle and a different new turn retire the previous deadline', () => {
  const clock = new FirstResponse();
  assert.equal(clock.inspect(silent(), 90, 300, 10), 'stalled');
  assert.equal(clock.inspect({ thread: { status: { type: 'idle' } }, turn: null }, 90, 301, 11), 'idle');
  assert.equal(clock.inspect(silent('new-turn', 301), 90, 302, 12), 'waiting');
});

function recoveryMock(value, result) {
  const requests = [];
  return { requests, snapshot: async () => value, request: async (method, params) => {
    requests.push({ method, params });
    return method === 'turn/interrupt' ? {} : { data: result };
  } };
}
test('binding loss before admission writes no interrupt', async () => {
  const value = silent(), control = recoveryMock(value, []);
  await assert.rejects(recover(control, { threadId }, value, { validate: () => { throw Error('binding_changed'); } }), /binding_changed/);
  assert.equal(control.requests.length, 0);
});
test('new turn, changed timestamp, missing wait flags or new tool before interruption writes nothing', async () => {
  for (const mutate of [value => { value.turn.id = 'new-turn'; }, value => { value.turn.startedAt++; },
    value => { delete value.thread.status.activeFlags; }, value => { value.turn.items.push({ type: 'commandExecution' }); }]) {
    const current = silent(); mutate(current); const control = recoveryMock(current, []);
    assert.equal(await recover(control, { threadId }, silent(), { validate() {} }), 'changed');
    assert.equal(control.requests.length, 0);
  }
});
test('only the exact interrupted terminal is successful recovery', async () => {
  const value = silent(), control = recoveryMock(value, [{ id: 'other', status: 'interrupted' }, { id: 'turn-one', status: 'interrupted' }]);
  let validations = 0;
  assert.equal(await recover(control, { threadId }, value, { validate: () => { validations++; } }), 'interrupted');
  assert.deepEqual(control.requests[0], { method: 'turn/interrupt', params: { threadId, turnId: 'turn-one' } });
  assert.equal(validations, 3);
});
test('an accepted interrupt without its terminal is unconfirmed, with exactly one interrupt', async () => {
  const value = silent(), control = recoveryMock(value, [{ id: 'other', status: 'interrupted' }]);
  await assert.rejects(recover(control, { threadId }, value, { validate() {}, timeoutMs: 20 }), /interrupt_unconfirmed/);
  assert.equal(control.requests.filter(request => request.method === 'turn/interrupt').length, 1);
});
test('natural completion racing cancellation is not renamed interrupted', async () => {
  const value = silent(), control = recoveryMock(value, [{ id: 'turn-one', status: 'completed' }]);
  assert.equal(await recover(control, { threadId }, value, { validate() {} }), 'completed_race');
});
test('an invalid interrupt response cannot be promoted by a later terminal', async () => {
  for (const bad of [null, [], { unexpected: true }]) {
    const value = silent(), control = recoveryMock(value, [{ id: 'turn-one', status: 'interrupted' }]);
    const request = control.request; control.request = async (method, params) => method === 'turn/interrupt' ? bad : request(method, params);
    await assert.rejects(recover(control, { threadId }, value, { validate() {} }), /invalid_interrupt/);
  }
});
test('binding loss during terminal confirmation prevents a ready claim', async () => {
  const value = silent(), control = recoveryMock(value, [{ id: 'turn-one', status: 'interrupted' }]);
  let count = 0;
  await assert.rejects(recover(control, { threadId }, value, { validate() { if (++count === 3) throw Error('binding_changed'); } }), /binding_changed/);
});

test('config is private, bounded, exact-shape and cannot redirect status outside its directory', t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'hailing-codex-config-')); fs.chmodSync(dir, 0o700);
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const file = path.join(dir, 'config.json');
  const state = path.join(dir, '.codex-recovery-state');
  const value = { version: 1, target: 'tmux:voice', threadId, binding: '$1@2/%3:4', firstResponseSeconds: 90, statusFile: path.join(state, 'status.json') };
  const write = data => { fs.writeFileSync(file, JSON.stringify(data), { mode: 0o600 }); fs.chmodSync(file, 0o600); };
  write(value); assert.equal(configAt(file).target, 'tmux:voice');
  for (const change of [{ target: 'tmux:-option' }, { firstResponseSeconds: 0 }, { firstResponseSeconds: 601 },
    { arbitrary: true }, { statusFile: '/tmp/not-this-config.json' },
    { statusFile: file }, { statusFile: file + '.lock' }, { statusFile: path.join(state, 'lock') },
    { statusFile: path.join(state, 'STATUS.json') }, { statusFile: path.join(state, 'status.json.attempt') }]) {
    write({ ...value, ...change }); assert.throws(() => configAt(file), /invalid_config/);
  }
  write(value); fs.chmodSync(file, 0o644); assert.throws(() => configAt(file), /unsafe_config/);
  fs.chmodSync(file, 0o600); fs.chmodSync(dir, 0o777); assert.throws(() => configAt(file), /unsafe_config/);
});
test('macOS ACLs refuse private config files, directories and socket parents despite private mode bits',
  { skip: process.platform !== 'darwin' }, async t => {
    const { dir, socket } = await fixture(t, () => {});
    const file = path.join(dir, 'config.json');
    const value = { version: 1, target: 'tmux:voice', threadId, binding: '$1@2/%3:4', firstResponseSeconds: 90,
      statusFile: path.join(dir, '.codex-recovery-state/status.json') };
    fs.writeFileSync(file, JSON.stringify(value), { mode: 0o600 });
    execFileSync('/bin/chmod', ['+a', `user:${os.userInfo().username} allow read`, file]);
    assert.equal(fs.statSync(file).mode & 0o777, 0o600);
    assert.throws(() => configAt(file), /extended_acl/);
    execFileSync('/bin/chmod', ['-N', file]);
    execFileSync('/bin/chmod', ['+a', `user:${os.userInfo().username} allow list,search`, dir]);
    assert.equal(fs.statSync(dir).mode & 0o777, 0o700);
    assert.throws(() => configAt(file), /extended_acl/);
    assert.throws(() => privateSocket(socket), /extended_acl/);
    execFileSync('/bin/chmod', ['-N', dir]);
  });
test('configuration bytes are bounded and state directories cannot be symlink aliases', t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'hailing-codex-bounds-')); fs.chmodSync(dir, 0o700);
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const file = path.join(dir, 'config.json');
  fs.writeFileSync(file, 'x'.repeat(16385), { mode: 0o600 });
  assert.throws(() => configAt(file), /unsafe_config/);
  fs.writeFileSync(file, JSON.stringify({ version: 1, target: 'tmux:voice', threadId,
    binding: '$1@2/%3:4', firstResponseSeconds: 90, statusFile: path.join(dir, '.codex-recovery-state/status.json') }));
  const outside = path.join(dir, 'outside'); fs.mkdirSync(outside, { mode: 0o700 });
  fs.symlinkSync(outside, path.join(dir, '.codex-recovery-state'));
  assert.throws(() => configAt(file), /unsafe_directory/);
});
test('discovery refuses replaced or non-agent panes before process or socket access', () => {
  for (const row of ['voice|$1@2/%3:5|codex', 'voice|$1@2/%3:4|zsh', 'different|$1@2/%3:4|codex']) {
    let commands = 0;
    assert.throws(() => discover({ target: 'tmux:voice', binding: '$1@2/%3:4' }, program => {
      commands++; assert.equal(program, 'tmux'); return row;
    }), /binding_changed/);
    assert.equal(commands, 1);
  }
});
test('status files are owner-only and contain only explicitly supplied status fields', t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'hailing-codex-status-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const file = path.join(dir, 'status.json'); writeStatus(file, { state: 'idle', recovered: false });
  assert.equal(fs.statSync(file).mode & 0o777, 0o600);
  assert.deepEqual(Object.keys(JSON.parse(fs.readFileSync(file, 'utf8'))).sort(), ['recovered', 'state', 'updatedAt']);
});

test('automatic decision reaches exact-ID interruption over the real Unix WebSocket fixture', async t => {
  let stopped = false, interrupts = 0;
  const value = silent();
  const { socket, dir } = await fixture(t, (peer, request) => {
    let result;
    if (request.method === 'thread/read') result = { thread: value.thread };
    else if (request.method === 'turn/interrupt') {
      assert.deepEqual(request.params, { threadId, turnId: 'turn-one' }); interrupts++; stopped = true; result = {};
    } else {
      assert.equal(request.method, 'thread/turns/list');
      result = { data: [{ ...value.turn, status: stopped ? 'interrupted' : 'inProgress' }] };
    }
    peer.send(JSON.stringify({ id: request.id, result }));
  });
  const config = { threadId, binding: '$1@2/%3:4', firstResponseSeconds: 90, statusFile: path.join(dir, 'status.json') };
  const result = await cycle(config, new FirstResponse(), new Set(), { lookup: () => ({ socket, identity: 'authored-owner' }) });
  assert.deepEqual(result, { state: 'interrupted', recovered: true });
  assert.equal(interrupts, 1);
  assert.deepEqual([...readAttempt(config)], ['turn-one']);
});
test('lost interruption acknowledgement is checkpointed before write and not retried after watcher restart', async t => {
  let interrupts = 0;
  const value = silent();
  const { socket, dir } = await fixture(t, (peer, request) => {
    if (request.method === 'turn/interrupt') { interrupts++; peer.close(); return; }
    const result = request.method === 'thread/read' ? { thread: value.thread } : { data: [value.turn] };
    peer.send(JSON.stringify({ id: request.id, result }));
  });
  const config = { threadId, binding: '$1@2/%3:4', firstResponseSeconds: 90, statusFile: path.join(dir, 'status.json') };
  const services = { lookup: () => ({ socket, identity: 'authored-owner' }) };
  await assert.rejects(cycle(config, new FirstResponse(), new Set(), services), /control_closed/);
  assert.equal(interrupts, 1);
  const result = await cycle(config, new FirstResponse(), readAttempt(config), services);
  assert.deepEqual(result, { state: 'already_attempted', recovered: false });
  assert.equal(interrupts, 1);
});
