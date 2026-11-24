# Service contracts

What the Jarvis services promise each other, in one place.

| File | What it is |
|---|---|
| [`COMMUNICATION-MAP.md`](COMMUNICATION-MAP.md) | who calls whom, over what, with which credentials; RabbitMQ messages; data ownership; known gaps |
| [`openapi/*.json`](openapi/) | the HTTP API of each FastAPI service (`backend`, `conversation-service`, `file-service`), generated from the code |
| [`export_openapi.py`](export_openapi.py) | regenerates those files, or checks that they are current |

## Commands

Run from the workspace root (the repos side by side, each with its `.venv`):

```bash
python3 jarvis-deploy/contracts/export_openapi.py              # regenerate all three, print what changed
python3 jarvis-deploy/contracts/export_openapi.py backend      # just one
python3 jarvis-deploy/contracts/export_openapi.py --check      # exit 1 if a spec on disk is stale (for CI)
```

The script imports each service's FastAPI app and calls `app.openapi()`. Nothing is started and no database or
broker is contacted; the few settings an app needs just to import are filled with dummy values.

## Workflow

1. Change an endpoint or a request / response model in a service.
2. Run the export, read any `BREAKING` lines, commit the updated JSON in `jarvis-deploy`.
3. Whoever works on a caller sees the change as a diff of these files.

`--check` in CI fails when the code and the committed spec disagree, so a changed endpoint cannot ship without
its contract being updated. It classifies a removed endpoint, a removed or retyped field and a field or parameter
that became required as `BREAKING`. It compares names, types and required lists only, not enums, formats or
constraints, so treat it as a screen rather than a proof.

## What is not covered yet

RabbitMQ messages (`ocr.ingest`, `ocr.embed`) are described in the map but have no machine-readable spec, and
there are no contract tests between services. See "Known gaps" in the map.
