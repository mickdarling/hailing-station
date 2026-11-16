# RightyO started-event replay (#1247)

`started-all-options.json` is verbatim emitter output from RightyO
`b9216d7db02f81a62b6f536bc4faf2daddad2d5e` (rightyo#286). The config is the
unchanged `maximal_config(asset)` authored in its `tests/test_host_contract.py`:
write its returned dictionary as JSON to a scratch `all-options.json`, using an
empty scratch `inert-asset.txt` for `asset`. All paths are inert placeholders;
never run this config as a listener. From that detached RightyO checkout:

```sh
taskpolicy -b env PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=src python3 scripts/emit_started_event.py \
  --config /path/to/scratch/all-options.json \
  --out /path/to/hailing-station/Tests/Fixtures/RightyO/started-all-options.json
```

`started-pre-286.json` is the incident counterexample from RightyO
`cfe45116ee4d2be1f7dd3a9abaaddbef51154c84` (rightyo#284), with the same config
(`dismissal.min_attend = 0.6`). That revision predates the emitter CLI. In a
separate detached checkout of cfe45116, run the b9216d7d emitter function against
the **old checkout's** `PYTHONPATH=src` imports, without invoking `main()`:

```sh
taskpolicy -b env PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=src python3 - <<'PY'
import runpy
from pathlib import Path
emitter = runpy.run_path('/path/to/rightyo-b9216d7d/scripts/emit_started_event.py')
config = emitter['PrototypeConfig'].load(Path('/path/to/scratch/all-options.json'))
event = emitter['started_event'](config)
assert event['dismissal']['min_attend'] == 0.6
Path('/path/to/hailing-station/Tests/Fixtures/RightyO/started-pre-286.json').write_text(
    emitter['encode_json'](event) + '\n')
PY
```

These events contain authored names only, no live assets or configuration. The
replay loads them relative to `#filePath` to keep `Package.swift` unchanged
(it counts as production under PR-shape). It uses `RightyoInputEvent.decode`
and dry `RightyoInputConsumer.consume`, the ambient pipeline's actual admission
path. This proves wire compatibility/refusal, not audio, models, or live delivery.
