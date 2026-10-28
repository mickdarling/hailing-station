#!/usr/bin/env node
'use strict';
// One host-owned voice request, using the existing controller and protected profile (#1002).
const { performance } = require('node:perf_hooks');
const {
  Control, ControlError, FirstResponse, configAt, discover, readAttempt, recover, writeStatus, validateKernelLock,
} = require('./index.cjs');
const UUID = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
const refuse = code => { throw new ControlError(code); };
function requestBlock(target, request) {
  return ' Reply: answer briefly; it is spoken aloud. The host plays any acknowledgement itself, so send no'
    + " acknowledgement of your own. If no reply bridge publishes this session's output, run haild reply "
    + target + ' --request ' + request.toLowerCase() + " --say '<spoken answer>' (single-quote the"
    + ' answer and keep it free of single quotes; the request reference sends it to the device that asked).';
}
function ownsTurn(turn, config, request) {
  if (!turn || !Array.isArray(turn.items) || turn.items.length > 2048) return false;
  const first = turn.items.find(item => item?.type === 'userMessage');
  if (!Array.isArray(first?.content) || first.content.length > 32) return false;
  // The random reference is minted by the host before dispatch, not chosen from a transcript.
  // Require its exact generated trailing block in the first user message, not a quoted ID elsewhere.
  return first.content.some(input => input?.type === 'text' && typeof input.text === 'string'
    && input.text.endsWith(requestBlock(config.target, request)));
}
function commandRecord(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || Object.keys(value).sort().join(',') !== 'generation,op,request,version'
      || value.version !== 1 || !['prepare', 'commit', 'authorize', 'retire'].includes(value.op)
      || typeof value.request !== 'string' || !UUID.test(value.request)
      || typeof value.generation !== 'string' || !UUID.test(value.generation)) refuse('invalid_control');
  return { ...value, request: value.request.toLowerCase(), generation: value.generation.toLowerCase() };
}
function parseControl(raw) {
  if (!Buffer.isBuffer(raw) || !raw.length || raw.length > 1024
      || !Buffer.from(raw.toString('utf8')).equals(raw)) refuse('invalid_control');
  const text = raw.toString('utf8');
  // Every allowed value is a scalar without object syntax. Count lexical object keys too,
  // so JSON.parse cannot silently accept duplicate (including escaped duplicate) keys.
  if ((text.match(/"(?:\\.|[^"\\])*"\s*:/g) ?? []).length !== 4) refuse('invalid_control');
  return commandRecord(JSON.parse(text));
}
class HostRecovery {
  constructor(config, { lookup = discover, emit = () => {}, lock = () => validateKernelLock(config),
    open = socket => new Control(socket), wall = () => Date.now() / 1000,
    mono = () => performance.now() / 1000, confirmMs = 5000 } = {}) {
    Object.assign(this, { config, lookup, emit, lock, open, wall, mono, confirmMs });
    this.clock = new FirstResponse(); this.done = false; this.busy = false;
  }
  validate() {
    if (this.done || !this.lease) refuse('lease_retired');
    this.lock();
    if (this.lookup(this.config).identity !== this.owned.identity) refuse('binding_changed');
  }
  report(state, recovered = false) {
    if (this.last === state) return;
    this.last = state;
    this.emit({ version: 1, state, request: this.lease?.request, generation: this.lease?.generation, recovered });
    // The inspectable diagnostic has states only; opaque routing IDs stay on the private control pipe.
    try { writeStatus(this.config.statusFile, { state, recovered }); } catch { /* Best effort; no raw error. */ }
  }
  retire(state = 'retired') {
    if (this.done) return;
    this.done = true; this.control?.close(); this.report(state);
  }
  async command(raw) {
    const value = commandRecord(raw);
    if (value.op === 'prepare') {
      if (this.lease || this.done) refuse('invalid_control');
      this.lease = value; this.busy = true;
      try {
        this.lock(); readAttempt(this.config); this.owned = this.lookup(this.config);
        this.control = this.open(this.owned.socket);
        await this.control.initialize(); this.validate();
        const snapshot = await this.control.snapshot(this.config.threadId); this.validate();
        if (snapshot.thread.status?.type !== 'idle' || snapshot.turn?.status === 'inProgress') refuse('provider_busy');
        this.baseline = snapshot.turn?.id ?? null;
        this.preparedWall = this.wall(); this.admissionDeadline = this.mono() + 30;
        this.ready = true; this.report('ready');
      } finally { this.busy = false; }
      return;
    }
    if (!this.lease || value.request !== this.lease.request || value.generation !== this.lease.generation) refuse('foreign_control');
    if (value.op === 'retire') { this.retire(); return; }
    if (!this.ready || this.done) refuse('invalid_control');
    if (this.mono() >= this.admissionDeadline) refuse('admission_expired');
    if (value.op === 'commit') {
      if (this.committed) refuse('invalid_control');
      this.committed = true; this.authorizationDeadline = this.mono() + 5;
    } else {
      if (!this.committed || this.authorized) refuse('invalid_control');
      if (this.mono() >= this.authorizationDeadline) refuse('child_ack_unconfirmed');
      // The host may authorize only after the exact RightyO child acknowledges accepted.
      this.authorized = true;
    }
  }
  validateSnapshot(snapshot) {
    this.validate();
    if (snapshot.turn?.id !== this.pinned?.id || snapshot.turn?.startedAt !== this.pinned?.startedAt
        || !ownsTurn(snapshot.turn, this.config, this.lease.request)) refuse('request_changed');
    return snapshot;
  }
  async poll() {
    if (this.done || this.busy || !this.ready) return;
    this.busy = true;
    try {
      this.validate();
      if (!this.committed) {
        if (this.mono() >= this.admissionDeadline) this.retire('commit_unconfirmed');
        return;
      }
      if (!this.authorized && this.mono() >= Math.min(this.authorizationDeadline, this.admissionDeadline)) {
        this.retire('child_ack_unconfirmed'); return;
      }
      const snapshot = await this.control.snapshot(this.config.threadId); this.validate();
      const turn = snapshot.turn;
      if (!this.pinned) {
        if (this.mono() >= this.admissionDeadline) { this.retire('request_unobserved'); return; }
        if (!turn || turn.id === this.baseline) {
          if (this.mono() >= this.admissionDeadline) this.retire('request_unobserved');
          return;
        }
        if (typeof turn.id !== 'string' || !turn.id.length || turn.id.length > 128 || /\s/.test(turn.id)
            || !Number.isInteger(turn.startedAt) || turn.startedAt < this.preparedWall - 2
            || !ownsTurn(turn, this.config, this.lease.request)) refuse('request_unmatched');
        this.pinned = { id: turn.id, startedAt: turn.startedAt };
      }
      this.validateSnapshot(snapshot);
      if (['completed', 'failed', 'interrupted'].includes(turn.status)) { this.retire(turn.status); return; }
      const state = this.clock.inspect(snapshot, this.config.firstResponseSeconds, this.wall(), this.mono());
      if (!['waiting', 'working', 'stalled'].includes(state)) refuse('control_unavailable');
      if (state !== 'stalled') { this.report(state); return; }
      if (!this.authorized) { this.report('awaiting_child_ack'); return; }
      if (readAttempt(this.config).has(turn.id)) { this.retire('already_attempted'); return; }
      this.validate();
      writeStatus(`${this.config.statusFile}.attempt`, {
        version: 1, threadId: this.config.threadId, binding: this.config.binding, turnId: turn.id,
      });
      // Reuse existing exact-ID interrupt/terminal proof. Every fresh snapshot rechecks request ownership.
      const scoped = {
        snapshot: async id => this.validateSnapshot(await this.control.snapshot(id)),
        request: (...args) => { this.validate(); return this.control.request(...args); },
      };
      const result = await recover(scoped, this.config, snapshot, { validate: () => this.validate(), timeoutMs: this.confirmMs });
      this.report(result, result === 'interrupted'); this.done = true; this.control.close();
    } catch {
      if (!this.done) this.retire('unavailable');
    } finally { this.busy = false; }
  }
}
async function main() {
  if (process.platform !== 'darwin') refuse('unsupported_platform');
  const [mode, flag, file] = process.argv.slice(2);
  if (mode !== 'host' || flag !== '--config' || !file) refuse('usage');
  const config = configAt(file);
  const worker = new HostRecovery(config, { emit: value => process.stdout.write(JSON.stringify(value) + '\n') });
  let pending = Buffer.alloc(0), queue = Promise.resolve(), queued = 0;
  process.stdin.on('data', chunk => {
    if (pending.length + chunk.length > 8192) { worker.retire('invalid_control'); return; }
    pending = Buffer.concat([pending, chunk]);
    while (pending.includes(10)) {
      const end = pending.indexOf(10), raw = pending.subarray(0, end); pending = pending.subarray(end + 1);
      try {
        const value = parseControl(raw);
        if (value.op === 'retire') {
          if (!worker.lease || value.request !== worker.lease.request || value.generation !== worker.lease.generation) refuse('foreign_control');
          worker.retire();
        } else {
          if (queued >= 4) refuse('invalid_control');
          queued++;
          queue = queue.then(() => worker.command(value)).catch(() => worker.retire('unavailable'))
            .finally(() => { queued--; });
        }
      } catch { worker.retire('invalid_control'); }
    }
    if (pending.length > 1024) worker.retire('invalid_control');
  });
  // EOF/SIGTERM revoke immediately, including during an awaited RPC. Never kill or restart Codex.
  process.stdin.on('end', () => worker.retire());
  process.stdin.on('error', () => worker.retire());
  process.stdout.on('error', () => worker.retire());
  process.on('SIGTERM', () => worker.retire());
  process.on('SIGINT', () => worker.retire());
  const timer = setInterval(() => {
    if (worker.done) { clearInterval(timer); process.stdin.destroy(); return; }
    void worker.poll();
  }, 500);
  process.stdin.resume();
}
module.exports = { HostRecovery, commandRecord, parseControl, ownsTurn, requestBlock };
if (require.main === module) main().catch(() => { process.stderr.write('codex_recovery_unavailable\n'); process.exitCode = 1; });
