#!/usr/bin/env node
'use strict';

// Operator recovery for one explicitly configured voice TUI (#1002), not a provider adapter.
const fs = require('node:fs');
const path = require('node:path');
const net = require('node:net');
const { execFileSync } = require('node:child_process');
const { performance } = require('node:perf_hooks');
const WebSocket = require('ws');

class ControlError extends Error {
  constructor(code) { super(code); this.code = code; }
}
const refuse = code => { throw new ControlError(code); };
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));

class Control {
  constructor(socket, { timeoutMs = 5000, maxPayload = 4194304 } = {}) {
    this.timeoutMs = timeoutMs;
    this.next = 0;
    this.pending = new Map();
    this.ws = new WebSocket('ws://localhost/', {
      createConnection: () => net.connect(socket), handshakeTimeout: timeoutMs,
      maxPayload, perMessageDeflate: false,
    });
    this.opened = new Promise((resolve, reject) => {
      const timer = setTimeout(() => { reject(new ControlError('connect_timeout')); this.close(); }, timeoutMs);
      this.ws.once('open', () => { clearTimeout(timer); resolve(); });
      this.ws.once('error', () => { clearTimeout(timer); reject(new ControlError('connect_failed')); });
      this.ws.once('close', () => { clearTimeout(timer); reject(new ControlError('control_closed')); });
    });
    this.ws.on('message', raw => this.receive(raw));
    this.ws.on('error', () => this.fail('control_failed'));
    this.ws.on('close', () => this.fail('control_closed'));
  }
  receive(raw) {
    let message;
    try { message = JSON.parse(raw.toString()); } catch { return this.fail('invalid_json'); }
    if (!message || typeof message !== 'object' || Array.isArray(message)) return this.fail('invalid_envelope');
    if ('method' in message) {
      // Never answer an approval, authentication, tool, or attestation request.
      if ('id' in message) this.fail('server_request');
      return;
    }
    const waiter = this.pending.get(message.id);
    if (!waiter || ('result' in message) === ('error' in message)) return this.fail('invalid_response');
    this.pending.delete(message.id);
    clearTimeout(waiter.timer);
    if ('error' in message) waiter.reject(new ControlError('rpc_refused'));
    else waiter.resolve(message.result);
  }
  fail(code) {
    for (const item of this.pending.values()) { clearTimeout(item.timer); item.reject(new ControlError(code)); }
    this.pending.clear();
    this.close();
  }
  close() { this.ws.terminate(); }
  async request(method, params, timeoutMs = this.timeoutMs) {
    await this.opened;
    if (this.ws.readyState !== WebSocket.OPEN) refuse('control_closed');
    if (this.pending.size >= 1) refuse('control_busy');
    if (!(timeoutMs > 0)) refuse('rpc_timeout');
    return new Promise((resolve, reject) => {
      const id = ++this.next;
      const timer = setTimeout(() => this.fail('rpc_timeout'), Math.min(timeoutMs, this.timeoutMs));
      this.pending.set(id, { resolve, reject, timer });
      this.ws.send(JSON.stringify({ id, method, params }), error => { if (error) this.fail('write_failed'); });
    });
  }
  async initialize() {
    await this.request('initialize', {
      clientInfo: { name: 'hailing_station_recovery', title: 'Hailing Station recovery', version: '0.1.0' },
      capabilities: { experimentalApi: false },
    });
    this.ws.send(JSON.stringify({ method: 'initialized', params: {} }));
  }
  async snapshot(threadId) {
    const read = await this.request('thread/read', { threadId });
    if (read?.thread?.id !== threadId) refuse('wrong_thread');
    const listed = await this.request('thread/turns/list', {
      threadId, limit: 1, sortDirection: 'desc', itemsView: 'full',
    });
    if (!Array.isArray(listed?.data) || listed.data.length > 1) refuse('invalid_turns');
    return { thread: read.thread, turn: listed.data[0] ?? null };
  }
}

function configAt(file) {
  if (path.basename(file).toLowerCase() === '.codex-recovery-state') refuse('invalid_config');
  const parent = fs.lstatSync(path.dirname(file));
  if (!parent.isDirectory() || parent.uid !== process.getuid() || (parent.mode & 0o077)) refuse('unsafe_config');
  aclFree(path.dirname(file));
  const config = JSON.parse(privateRead(file, 16384, 'unsafe_config'));
  const stateDirectory = path.join(path.dirname(file), '.codex-recovery-state');
  if (fs.existsSync(stateDirectory)) protectedDirectory(stateDirectory);
  const keys = ['version', 'target', 'threadId', 'binding', 'firstResponseSeconds', 'statusFile'];
  if (Object.keys(config).some(key => !keys.includes(key))) refuse('invalid_config');
  if (config.version !== 1 || !/^tmux:[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(config.target)
      || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(config.threadId) || typeof config.binding !== 'string'
      || !/^\$\d+@\d+\/%\d+:\d+$/.test(config.binding)
      || !Number.isInteger(config.firstResponseSeconds) || config.firstResponseSeconds < 5
      || config.firstResponseSeconds > 600
      || config.statusFile !== path.join(stateDirectory, 'status.json')) refuse('invalid_config');
  return { ...config, stateDirectory };
}
function command(program, args) {
  try { return execFileSync(program, args, { encoding: 'utf8', timeout: 2000, maxBuffer: 1048576, stdio: ['ignore', 'pipe', 'pipe'] }); }
  catch { refuse('discovery_failed'); }
}
function aclFree(file) {
  if (process.platform === 'darwin' && command('/bin/ls', ['-lde', file]).split('\n').some(line => /^\s*\d+:/.test(line))) refuse('extended_acl');
}
function protectedDirectory(file) {
  const stat = fs.lstatSync(file);
  if (!stat.isDirectory() || stat.uid !== process.getuid() || (stat.mode & 0o077)) refuse('unsafe_directory');
  aclFree(file);
}
function privateRead(file, maxBytes, code) {
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
  try {
    const before = fs.fstatSync(fd);
    if (!before.isFile() || before.uid !== process.getuid() || (before.mode & 0o077) || before.size > maxBytes) refuse(code);
    aclFree(file);
    const bytes = Buffer.alloc(maxBytes + 1), length = fs.readSync(fd, bytes, 0, bytes.length, 0);
    const after = fs.fstatSync(fd), named = fs.lstatSync(file);
    if (length > maxBytes || before.size !== after.size || before.mtimeMs !== after.mtimeMs
        || before.ctimeMs !== after.ctimeMs || named.dev !== after.dev || named.ino !== after.ino) refuse(code);
    return bytes.subarray(0, length).toString('utf8');
  } finally { fs.closeSync(fd); }
}
function privateSocket(socket) {
  for (const [file, kind] of [[path.dirname(socket), 'directory'], [socket, 'socket']]) {
    const stat = fs.lstatSync(file);
    if (stat.uid !== process.getuid() || (stat.mode & 0o077)
        || (kind === 'directory' ? !stat.isDirectory() : !stat.isSocket())) refuse('unsafe_socket');
    aclFree(file);
  }
  const stat = fs.lstatSync(socket);
  return `${stat.dev}:${stat.ino}`;
}
function discover(config, run = command) {
  const rows = run('tmux', ['list-sessions', '-F', '#{session_name}|#{session_id}@#{session_created}/#{pane_id}:#{pane_pid}|#{pane_current_command}'])
    .trim().split('\n').map(line => line.split('|')).filter(row => row[0] === config.target.slice(5));
  if (rows.length !== 1 || rows[0][1] !== config.binding || rows[0][2] !== 'codex') refuse('binding_changed');
  const parent = Number(config.binding.split(':').at(-1));
  const children = run('ps', ['-axo', 'pid=,ppid=,uid=,comm=']).trim().split('\n')
    .map(line => line.trim().split(/\s+/, 4))
    .filter(row => Number(row[1]) === parent && Number(row[2]) === process.getuid() && path.basename(row[3] ?? '') === 'codex');
  const servers = children.filter(row => /(?:^|\s)app-server(?:\s|$)/.test(run('ps', ['-p', row[0], '-o', 'args='])));
  if (servers.length !== 1) refuse('ambiguous_server');
  const pid = servers[0][0];
  const born = run('ps', ['-p', pid, '-o', 'lstart=']).trim();
  if (!born) refuse('server_gone');
  const prefix = `/private/tmp/codex-daemon-${process.getuid()}/`;
  const sockets = [...new Set(run('lsof', ['-a', '-p', pid, '-U', '-Fn']).split('\n')
    .filter(line => line.startsWith(`n${prefix}`)).map(line => line.slice(1)))];
  if (sockets.length !== 1) refuse('ambiguous_socket');
  const socket = sockets[0];
  return { socket, identity: `${config.binding}|${pid}|${born}|${privateSocket(socket)}` };
}
function visibleActivity(turn) {
  if (!Array.isArray(turn.items) || turn.items.length > 2048) refuse('invalid_items');
  return turn.items.some(item => {
    if (!item || typeof item.type !== 'string') refuse('invalid_item');
    if (item.type === 'userMessage') return false;
    if (item.type === 'agentMessage') return typeof item.text !== 'string' || item.text.trim().length > 0;
    if (item.type === 'reasoning') {
      const arrays = [item.summary ?? [], item.content ?? []];
      if (('summary' in item && item.summary === null) || ('content' in item && item.content === null)
          || arrays.some(values => !Array.isArray(values) || values.some(value => typeof value !== 'string'))) refuse('invalid_reasoning');
      return arrays.some(values => values.length > 0);
    }
    // A tool, approval, unknown/new item, or actual output protects substantive work.
    return true;
  });
}
class FirstResponse {
  inspect(snapshot, seconds, wall = Date.now() / 1000, mono = performance.now() / 1000) {
    const { thread, turn } = snapshot;
    if (thread.status?.type === 'idle') { this.origin = null; return 'idle'; }
    if (thread.status?.type !== 'active' || !Array.isArray(thread.status.activeFlags)) return 'unavailable';
    if (!turn || turn.status !== 'inProgress') return 'unavailable';
    if (!Number.isInteger(turn.startedAt) || turn.startedAt < 0 || turn.startedAt > wall + 2) return 'unavailable';
    if (this.origin?.id !== turn.id) this.origin = { id: turn.id, start: turn.startedAt, wall, mono, age: Math.max(0, wall - turn.startedAt), responded: false };
    const base = this.origin;
    if (base.start !== turn.startedAt || Math.abs((wall - base.wall) - (mono - base.mono)) > 5) return 'clock_changed';
    if (thread.status.activeFlags.length || visibleActivity(turn)) base.responded = true;
    if (base.responded) return 'working';
    return base.age + mono - base.mono >= seconds ? 'stalled' : 'waiting';
  }
}
async function recover(control, config, snapshot, { validate, timeoutMs = 5000 } = {}) {
  const id = snapshot.turn?.id;
  if (!id || snapshot.turn.status !== 'inProgress') return 'idle';
  validate();
  const fresh = await control.snapshot(config.threadId);
  if (fresh.turn?.id !== id || fresh.turn.status !== 'inProgress' || fresh.turn.startedAt !== snapshot.turn.startedAt
      || visibleActivity(fresh.turn) || fresh.thread.status?.type !== 'active'
      || !Array.isArray(fresh.thread.status.activeFlags) || fresh.thread.status.activeFlags.length) return 'changed';
  validate();
  const accepted = await control.request('turn/interrupt', { threadId: config.threadId, turnId: id });
  if (!accepted || typeof accepted !== 'object' || Array.isArray(accepted)
      || Object.keys(accepted).length) refuse('invalid_interrupt');
  const deadline = performance.now() + timeoutMs;
  while (performance.now() < deadline) {
    const result = await control.request('thread/turns/list', {
      threadId: config.threadId, limit: 4, sortDirection: 'desc', itemsView: 'notLoaded',
    }, deadline - performance.now());
    if (performance.now() >= deadline) break;
    if (!Array.isArray(result?.data)) refuse('invalid_turns');
    const found = result.data.find(turn => turn.id === id);
    if (found?.status === 'interrupted') { validate(); return 'interrupted'; }
    if (found && ['completed', 'failed'].includes(found.status)) { validate(); return 'completed_race'; }
    await pause(50);
  }
  refuse('interrupt_unconfirmed');
}
function writeStatus(file, value) {
  protectedDirectory(path.dirname(file));
  const temporary = `${file}.${process.pid}.tmp`;
  const fd = fs.openSync(temporary, 'wx', 0o600);
  try {
    aclFree(temporary);
    fs.writeFileSync(fd, JSON.stringify({ ...value, updatedAt: new Date().toISOString() }) + '\n');
  }
  finally { fs.closeSync(fd); }
  fs.renameSync(temporary, file);
}
function readAttempt(config) {
  const file = `${config.statusFile}.attempt`;
  if (!fs.existsSync(file)) return new Set();
  protectedDirectory(path.dirname(file));
  const value = JSON.parse(privateRead(file, 2048, 'unsafe_checkpoint'));
  if (value.version !== 1 || typeof value.turnId !== 'string' || value.turnId.length > 128
      || !value.turnId.length || /\s/.test(value.turnId)) refuse('invalid_checkpoint');
  if (value.threadId !== config.threadId || value.binding !== config.binding) refuse('checkpoint_scope_mismatch');
  return new Set([value.turnId]);
}
async function cycle(config, clock = new FirstResponse(), seen = new Set(), { lookup = discover } = {}) {
  // Scope ownership is checked every cycle, not only at process startup.
  for (const turn of readAttempt(config)) seen.add(turn);
  const owned = lookup(config);
  const validate = () => { if (lookup(config).identity !== owned.identity) refuse('binding_changed'); };
  const control = new Control(owned.socket);
  try {
    await control.initialize();
    const snapshot = await control.snapshot(config.threadId);
    // One active turn per thread. A different observed ID retires the old attempt tombstone.
    if (snapshot.turn && !seen.has(snapshot.turn.id)) seen.clear();
    const state = clock.inspect(snapshot, config.firstResponseSeconds);
    if (state !== 'stalled') return { state, recovered: false };
    if (seen.has(snapshot.turn.id)) return { state: 'already_attempted', recovered: false };
    // Mark before the write: a lost acknowledgement must never cause a blind retry.
    seen.add(snapshot.turn.id);
    writeStatus(`${config.statusFile}.attempt`, {
      version: 1, threadId: config.threadId, binding: config.binding, turnId: snapshot.turn.id,
    });
    const outcome = await recover(control, config, snapshot, { validate });
    return { state: outcome, recovered: outcome === 'interrupted' };
  } finally { control.close(); }
}
async function main() {
  if (process.platform !== 'darwin') refuse('unsupported_platform');
  const [mode, flag, file] = process.argv.slice(2);
  if (!['status', 'recover', 'watch'].includes(mode) || flag !== '--config' || !file) refuse('usage');
  const config = configAt(file);
  const validateLock = () => {
    const fd = Number(process.env.HAIL_CODEX_RECOVERY_LOCK_FD);
    if (!Number.isInteger(fd) || fd < 3) refuse('kernel_lock_required');
    protectedDirectory(config.stateDirectory);
    const lock = path.join(config.stateDirectory, 'lock');
    const held = fs.fstatSync(fd), named = fs.lstatSync(lock);
    aclFree(lock);
    if (held.dev !== named.dev || held.ino !== named.ino || held.uid !== process.getuid()
        || !held.isFile() || (held.mode & 0o077)) refuse('kernel_lock_required');
  };
  if (mode !== 'status') validateLock();
  const clock = new FirstResponse(), seen = readAttempt(config);
  let failures = 0;
  do {
    let value;
    try {
      value = mode === 'status' ? await status(config) : await cycle(config, clock, seen, {
        lookup: current => { validateLock(); return discover(current); },
      });
      failures = 0;
    }
    catch (error) { value = { state: error instanceof ControlError ? error.code : 'unavailable', recovered: false }; failures++; }
    if (mode !== 'watch') { console.log(JSON.stringify(value)); process.exitCode = failures ? 1 : 0; return; }
    validateLock(); writeStatus(config.statusFile, value);
    await pause(Math.min(30000, 3000 * 2 ** Math.min(failures, 4)));
  } while (true);
}
async function status(config) {
  const owned = discover(config), control = new Control(owned.socket);
  try {
    await control.initialize();
    return { state: new FirstResponse().inspect(await control.snapshot(config.threadId), config.firstResponseSeconds), recovered: false };
  } finally { control.close(); }
}
module.exports = { Control, ControlError, FirstResponse, configAt, cycle, discover, privateSocket, readAttempt, recover, visibleActivity, writeStatus };
if (require.main === module) main().catch(() => { console.error('codex_recovery_unavailable'); process.exitCode = 1; });
