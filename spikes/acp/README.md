# Spike #1076: ACP plug probe

Throwaway tooling for [#1076](https://github.com/mickdarling/hailing-station/issues/1076), not for `main`. `acp_probe.py` drives an ACP agent the way a `haild` plug would, and prints shapes, kinds, lengths and timings only.

## Rules for running it

- Run on the Mac, in a scratch directory outside any repository, for example `~/hail-spike-acp/scratch-claude`.
- Install adapters into a private prefix (`npm install --prefix ~/hail-spike-acp/node …`, or a downloaded binary under `~/hail-spike-acp/bin`). Never install globally, and never change `~/.claude` or `~/.codex` configuration.
- The probe removes credential variables (`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, `OPENAI_API_KEY`, `CODEX_API_KEY`) from the agent's environment, so the harness must use its own stored login. That is the seat principle (#1074).
- It advertises no file or terminal access, and rejects every permission request. The second default prompt asks for a file write, to capture the permission flow. `probe_file_written` must be `false`.
- Paste only stdout. Never paste `--show-text` stderr or `agent-stderr.log`.

## Usage

```sh
python3 acp_probe.py --cwd ~/hail-spike-acp/scratch-claude -- <adapter command and args>
```

The default prompts are a one-sentence reply and a refused file write. Add `--prompt TEXT` to replace them.

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
