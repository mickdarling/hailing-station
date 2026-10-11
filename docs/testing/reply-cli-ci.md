# Reply CLI on CI: `Network is down` (#144)

## Symptom

On GitHub's macOS runners, reply CLI tests occasionally fail with `POSIXErrorCode(rawValue: 50): Network is down` (ENETDOWN). The failing call goes from `haild reply` (or `rightyo --reply-to`) to the local reply endpoint's Unix socket, or to a test's fake socket server.

The same tests pass on rerun and locally.

Occurrences are listed on #144. They include runs 36636897674 (attempt 2), 36645247002, 37058535863, 38168331092 and 38170291544 (attempt 2).

## What is known

- **Never reproduced locally,** including three CLI suites run in parallel on macOS.
- **The errors fall into two groups:**
  - **Before send:** the connection fails before `.ready`, so nothing reached the endpoint (run 38168331092).
  - **After send:** the request was written, then the connection failed before an answer arrived (run 38170291544). The CLI reports this as `unanswered`.
- **More frequent since #466 and #472:** long replies now open one socket connection per frame, so a suite makes hundreds more connections. The rate per connection has not been shown to change.
- **Not caused by leaked jobs:** detached reply jobs that outlived their tests were a separate cause of CI failures, fixed in #474. Each test uses its own socket directory, so a leaked job could not cause ENETDOWN in another test.

## Evidence boundary

Nothing here shows whether ENETDOWN comes from the runner, Network.framework's handling of Unix sockets under load, or the fixture. No claim about the root cause is made.

## Mitigation

**#475, before-send failures:** a connection that fails before anything is written is retried on a fresh connection after 0.1, 0.3, 0.9 and 2 s. Nothing was sent, so a retry cannot deliver twice.

**Still covered by the #204 rule:**
- After a write, nothing is retried.
- Refusal codes and messages are unchanged.
- When every attempt fails, the final error reads as before.

## Still open

Failures after send. #144 lists two options:
- resend the identical correlated frame, which is safe because a request refuses duplicate frame ids;
- use one connection per reply job instead of one per frame.

To keep evidence, link each new occurrence's run on #144 before rerunning.
