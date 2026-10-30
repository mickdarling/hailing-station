# Spike #1073: talk to a Claude Code cloud session from the Mac

Throwaway spike tooling for [#1073](https://github.com/mickdarling/hailing-station/issues/1073). It does what `haild` would do: send with the documented `claude -p … --cloud`, and read the reply back from the private sessions events API (read-only). It is not meant to merge to `main`.

Run everything on the Mac, signed in to the same claude.ai account as your cloud sessions (`claude auth status`). Use a **throwaway** cloud session and synthetic text only.

## Get the script without touching your working checkout

```sh
cd ~/Developer/hailing-station
git fetch origin claude/friendly-cerf-a7r9zu
mkdir -p ~/hail-spike-1073
git show origin/claude/friendly-cerf-a7r9zu:spikes/1073-cloud-session/cloud_session_spike.py > ~/hail-spike-1073/spike.py
```

## Steps

0. **Create a throwaway cloud session** with the documented CLI. This also tests the "start a new session" fallback for Wake/Restore. Run it from the repository so the session clones it:

   ```sh
   cd ~/Developer/hailing-station
   claude --cloud "Hailing Station spike #1073 throwaway. Do no work. Reply to every message with one short plain sentence."
   ```

   Copy the session ID (`session_…`) from its output, or from the session's `claude.ai/code/…` URL, and set `SID=session_…` in your shell. Don't paste it anywhere public.

1. **Token and session shape.** Reads only. Your Mac may ask for Keychain access for `security`: allow it.

   ```sh
   python3 ~/hail-spike-1073/spike.py info --session "$SID"
   ```

2. **Round trip.** Notes the newest event, sends the synthetic ping with `claude -p --cloud`, then streams events until the turn ends:

   ```sh
   python3 ~/hail-spike-1073/spike.py roundtrip --session "$SID" --show-text
   ```

   Expect `cli_send` `ok: true`, then a `user` event (delivery evidence), `assistant` events, and a `result` event, plus `timings_seconds`. The assistant text goes to stderr marked "do not paste".

3. **Billing check for the send.** Note your usage on claude.ai before and after a `send`. The send should add nothing; only the cloud session's reply should count.

   ```sh
   python3 ~/hail-spike-1073/spike.py send --session "$SID"
   ```

4. **Idle wake.** Leave the session alone until its cloud machine has been reclaimed (the session page shows it as stopped or expired, typically after a period of inactivity). Then repeat step 2 and note the `first_assistant` and `result` timings: does a send alone revive it?

5. **Archived refusal.** Archive the throwaway on claude.ai/code (session menu → Archive), then:

   ```sh
   python3 ~/hail-spike-1073/spike.py send --session "$SID"
   ```

   Record the refusal (`ok: false` with `error`, or the stderr line). Then unarchive it on claude.ai/code/sessions → Archived and repeat step 2, to confirm unarchive revives it.

6. **History shape** (optional):

   ```sh
   python3 ~/hail-spike-1073/spike.py history --session "$SID" --limit 10
   ```

## Reporting

stdout is designed to be pasted into #1073: session and organization IDs are redacted, and message text appears only as character counts. Never paste stderr from `--show-text`. If a step fails, paste the `spike:` error line; it carries only the HTTP status and error type.

## What the script does not do

- It never refreshes, prints or stores the claude.ai token. If the token has expired it stops; run any `claude` command that talks to the service, then retry, and note whether that refreshed it.
- It makes no write to the private API. The only write is the documented CLI send.
- Stop-hook fallback (spike step 4 in the issue) needs a cloud environment setup script and is tested separately.
