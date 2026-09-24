# Local bounded intent evaluation

This is an offline, synthetic-only investigation for [#108](https://github.com/mickdarling/hailing-station/issues/108). It is **not** a shipped classifier or an authorization mechanism. The iPhone/iPad already performs speech recognition; any semantic categorizer in this design runs on the Mac host and may use a locally served model. No transcript needs to leave the host for classification, and no external LLM is required for the initial read-only service.

The candidate output space is `connection_check`, `host_status`, `list_destinations`, `clarify`, or `unsupported`. The first three are proposed read-only diagnostics, not generic agent commands. The model never supplies arguments, commands, paths, or response wording. A future host service must still check the current authenticated client, catalog generation, capability policy, and observed action result before returning a deterministic reply. `clarify`, `unsupported`, malformed output, timeout, and unavailable model all fail closed. Consequential actions are outside this candidate set and require the independent confirmation design in #89.

## Reproduce locally

The standard-library-only script [`Tests/LocalIntentEvalTests/eval_local_intents.py`](../Tests/LocalIntentEvalTests/eval_local_intents.py) uses only `127.0.0.1` and never downloads a model. Its committed fixtures are invented examples, not recorded user speech. Keep real transcripts out of the fixtures, logs, issues, and PRs.

```sh
python3 Tests/LocalIntentEvalTests/eval_local_intents.py --provider ollama --model llama3:latest
python3 Tests/LocalIntentEvalTests/eval_local_intents.py --provider lmstudio --model qwen2.5-7b-instruct-1m
```

The local Ollama service or LM Studio server must already be running, and the named model must already be installed/loaded. A nonzero exit means classification failed or at least one expected label was missed. No Hailing Station daemon, mobile app, target, or action is involved.

## Initial result (September 24, 2026)

| Existing local model | Correct / 27 | Unsafe routes* | Warm median |
| --- | ---: | ---: | ---: |
| Llama 3 8B Q4 via Ollama | 18 | 9 | 208 ms |
| Qwen 2.5 7B Instruct via LM Studio | 24 | 3 | 166 ms |

\*An `unsupported` or `clarify` fixture was classified as one of the three actionable diagnostics. This is a semantic error even though the JSON schema is valid. The Qwen 3 0.6B and Qwen 3.5 9B MLX local attempts returned no structured content under this script's short-output setting; that is inconclusive about those models generally, but they are not working candidates in this configuration. Measurements are single-machine, single-run, synthetic, warm-path observations—not latency guarantees or a representative accuracy estimate.

Neither scored model meets the safety bar for live routing. Before enabling even read-only action selection, expand the held-out fixture set with misrecognition, negation, conflicting requests, injection, duplicate utterances, and out-of-domain speech; repeat across model starts; require **zero** unsafe routes in the evaluated corpus; check tail latency and memory; and separately test host authorization and stale-catalog behavior. A zero score in a finite test set still does not prove the classifier safe. A host-side deterministic gate can handle exact built-in diagnostics while ambiguous semantic requests receive clarification. The mobile UI must not claim that an action happened until the host reports an observed outcome.

The model is replaceable. Ollama and LM Studio are local evaluation transports, not product dependencies or a requirement to use cloud inference. A future supervised local model or locally hosted LLM can use the same typed intent contract, subject to the same fail-closed host boundary.
