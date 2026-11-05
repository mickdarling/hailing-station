# Spike #1076: ACP plug probe

Spike tooling for [#1076](https://github.com/mickdarling/hailing-station/issues/1076), kept so the evidence can be re-run. It is not part of `haild`. `acp_probe.py` drives an ACP agent the way a `haild` plug would, and prints shapes, kinds, lengths and timings only.

## Rules for running it

- Run on the Mac, in a scratch directory outside any repository, for example `~/hail-spike-acp/scratch-claude`.
- Install adapters into a private prefix (`npm install --prefix ~/hail-spike-acp/node …`, or a downloaded binary under `~/hail-spike-acp/bin`). Never install globally, and never change `~/.claude` or `~/.codex` configuration.
- The probe removes credential variables (`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, `OPENAI_API_KEY`, `CODEX_API_KEY`) from the agent's environment, so the harness must use its own stored login. That is the seat principle (#1074).
- It advertises no file or terminal access, and rejects every permission request it receives. The second and third default prompts ask for a file write and a shell `touch`, to capture the permission flow; `actions_ran` reports whether either happened (`write`, `execute`). In an asking mode both should be `false`. If one is `true`, the harness's own settings let it act without asking (for example an accept-edits or bypass mode, or Codex with approvals off): the probe can only reject requests it is sent. Record the mode from `session_modes`, and use `--mode` to choose an asking one. If `--mode` cannot be applied, the probe stops before sending any prompt (exit 5).
- Paste only stdout. Never paste `--show-text` stderr, `agent-stderr.log` or `agent-stderr-resume.log`.

## Usage

```sh
python3 acp_probe.py --cwd ~/hail-spike-acp/scratch-claude -- <adapter command and args>
```

The default prompts are a one-sentence reply, a file write and a shell command (`touch`). The last two leave marker files if they run, and `actions_ran` reports them. Add `--prompt TEXT` to replace the defaults. Each run needs a fresh scratch directory; the probe refuses one that already holds marker files.

## Round 2: permission requests, listing and resume

```sh
python3 acp_probe.py --cwd ~/hail-spike-acp/r2-claude --mode default --list --load -- <claude adapter>
python3 acp_probe.py --cwd ~/hail-spike-acp/r2-codex --mode read-only --list --load -- <codex adapter>
```

- `--mode` switches the new session into a mode that asks before acting (`session/set_mode`), so `permission_request` lines show the request's shape: tool kind, option kinds, and the keys of the tool's input. The probe answers each request with a reject option, so `actions_ran` should report `false` for both.
- `--list` calls `session/list` and reports whether this session is listed.
- `--load` restarts the agent, resumes the session with `session/load` (which replays history as updates), then asks one question that needs the earlier turns.

## Claude Code's own structured mode, for comparison

```sh
cd ~/hail-spike-acp/scratch-stream && printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Hailing Station spike #1076. Reply with one short sentence and use no tools."}]}}' \
  | env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN \
    claude -p --input-format stream-json --output-format stream-json --verbose \
  | python3 -c 'import sys,json
for l in sys.stdin:
    e=json.loads(l); print(json.dumps({"type":e.get("type"),"subtype":e.get("subtype"),"keys":sorted(e)}))'
```

Record the event types, and whether the `system`/`init` event's `apiKeySource` (if present) shows the subscription login.
