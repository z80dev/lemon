# Standalone complexity decision adapter

This is a **standalone, shadow-default library**, not an activated factory routing
hook. It does not change existing factory modules, policy files, coordinator
models, installed releases, worker admission, CI, review, merging or lifecycle.
Integration belongs to the parent routing task. No automatic mode is enabled by
shipping or testing this package. No extra coordinator turn is needed to consume
or ignore a shadow receipt.

## Verified protocol and sources

Checked 2026-10-15 against official OpenRouter sources:

- [Clef Flash catalog/endpoints](https://openrouter.ai/api/v1/models/cloudflare/clef-flash/endpoints):
  actual API model ID **`cloudflare/clef-flash`**, architecture output modality
  `decisions`, active endpoints. The OMP role identifier
  `openrouter/cloudflare/clef-flash` includes the OMP provider prefix; it is **not**
  the wire model ID. [Model page](https://openrouter.ai/cloudflare/clef-flash).
- [System One API reference](https://openrouter.ai/docs/api/api-reference/systemone/submit-a-system-one-request):
  **POST `https://openrouter.ai/api/v1/systemone`**, bearer auth, JSON
  `{model, state, questions}`. Each fixed choice question has `type: "choice"`,
  `instructions`, and a `criteria` map. The response has `model`, `answers`, and
  `usage`; choice answers contain `type`, `choice`, and optional `confidence` and
  `probabilities`. Usage can supply `input_tokens`, `output_tokens`, and `cost`.
- [Official SDK base URL explanation](https://openrouter.ai/docs/guides/community/typesafe-sdk)
  confirms `/api/v1/systemone`. The older
  [Jev tutorial](https://openrouter.ai/docs/guides/community/jev-tutorial) also
  shows the separate `/api/alpha/decisions` route. We use the documented System
  One route, **never `/chat/completions`**, and never send System One payloads to
  a chat API. A catalog listing alone is not proof that inference works.

The native typed decision API does **not** document `max_tokens` for this
request. We do not invent that parameter. A single fixed question with four
fixed choices bounds the answer space; the smoke uses tiny synthetic state,
request/response byte bounds and a strict deadline instead. No explanation,
chain of thought, subsystem or security flags are requested or fabricated.

Every real transport invocation checks the public catalog before resolving the
credential or issuing a paid POST. Wrong model, absent `decisions` modality,
missing active endpoint, catalog failure, malformed response or incompatible
protocol fails closed. There is no Cloudflare-direct, other-model, or chat
fallback. The caller retains its existing coordinator/Opus/manual model.

## Library interface

Use `PYTHONPATH=tools/factory` for examples (the existing factory test discovery
already adds this directory):

```python
from decision import DecisionAdapter, DecisionConfig, select_model

# Policy supplies approved models. Empty default mapping does not invent one.
config = DecisionConfig(mode="shadow", tier_models={
    "simple": "approved-provider/approved-small-model",
    "standard": "approved-provider/approved-standard-model",
    "complex": "approved-provider/approved-deep-model",
})
classifier = DecisionAdapter(config)  # retain one instance; no network on import
receipt = classifier.classify({
    "id": "F-0053", "revision": 1,
    "goal": "A sanitized compact implementation goal.",
    "acceptance": ["A bounded, sanitized acceptance criterion."],
    "evidence": [{"path": "relative/file.py", "summary": "Sanitized repository evidence."}],
})
actual_model = select_model(config, receipt, coordinator_model="existing/model")
```

The model is asked to choose exactly `simple`, `standard`, `complex`, or
`insufficient_information`. Fixed questions/criteria live in `adapter.py`, not
in task data. Task instructions are kept in the untrusted `state` fields and
cannot replace questions, choices or endpoints. This is a structural boundary,
**not a claim that a model is immune to prompt injection**. Keep shadow mode
until measured adversarial/evaluation results justify a policy change.

Only the documented task fields are sent. Unknown ledger fields, raw requests,
transcripts, environment and policy are not serialized. Evidence allows at most
20 acceptance criteria (1,000 characters each), 20 evidence entries (300-character
path, 1,500-character summary), a 128-character task ID, positive integer revision,
and total serialized state within `max_input_bytes`. Oversized input is rejected,
not silently truncated/classified as a smaller task. Obvious credential syntax is
rejected. **The caller must sanitize summaries before calling**; pattern checks
cannot recognize every secret and are not a secret-scanning guarantee. Never pass
raw transcripts or arbitrary files as summaries.

Receipts contain status `available|unavailable|invalid|off`, fixed choice,
optional probability distribution/confidence, uncertainty, input/revision hash,
semantic cache key, UTC timestamp, latency, whitelisted genuine usage fields,
fixed error class, HTTP status and optional mapped recommendation. They contain
no goal/evidence text, credential, headers, provider message, raw answer, or
exception text. Unknown usage/cost remains absent, never estimated as zero.

`uncertainty` is explicitly **1 − max(probabilities)**, not the provider's optional
confidence and not calibrated error probability. Missing probabilities remain
`None`; negative, non-finite, boolean, string, incomplete, extra-choice,
non-normalized (tolerance 0.001), or choice-inconsistent distributions are invalid.
No distribution is fabricated or renormalized. Thresholds are tunable policy,
not claims of correctness. A choice without probabilities can be available but
cannot qualify for automatic routing.

`select_model` always honors `explicit_override` first. Passing the override to
`classify(..., explicit_override=...)` also avoids the network call. `off` and
`enabled=False` do no work. Shadow and advisory leave the actual coordinator
model unchanged; advisory exposes the recommendation for a coordinator to accept
explicitly. Only an explicitly configured automatic consumer can apply a mapped
simple/standard/complex tier, and only on a valid sufficiently certain result.
Insufficient, invalid, unavailable, missing mapping or uncertain judgments fall
back. Automatic is implemented for integration, **not enabled**.

No API here grants merge permission, dependencies, slots, scheduling, promotion,
review approval, CI truth or task transitions. Persisting sanitized receipts and
joining `actual_model`/later review and repair outcomes is an integration
responsibility; this library deliberately does not mutate the factory ledger.

## Configuration and deduplication

`decision/config.schema.json` documents the factory-local schema;
`DecisionConfig.from_mapping` enforces it without an extra dependency. Unknown
fields, credentials, endpoints/models, versions, non-finite values and unbounded
limits are rejected with constant errors. Only the verified OpenRouter model and
System One endpoint are currently supported; adding another requires protocol
work, not silently swapping a model string.

Defaults: enabled, mode `shadow`, 20-second total deadline, zero retries, 12,000
state bytes, 256 cache entries, minimum selected probability 0.75, maximum
uncertainty 0.25, empty tier mapping, prompt `factory-complexity-1`, schema `1`.
Deadline is capped at 60 seconds, input at 32,000 bytes, cache at 4,096 entries,
and retries at one. Optional retry applies only to transient timeout/network,
HTTP 429 or 5xx errors inside the **same total deadline**, not missing credentials,
catalog/protocol failures or auth errors. Requests/responses have a second
64-KiB transport limit; redirects are refused.

The bounded process-local LRU caches failures as well as success. Keys include
canonical task ID/revision/evidence, fixed questions, prompt/schema version,
model and endpoint. A lock covers the request, so simultaneous identical events
make one call. Waiting for the lock is included in each caller's deadline.
`classifier.invalidate()` is the explicit recovery mechanism after a credential
or catalog issue; no timer or polling retries are installed. Retain one adapter
owner across events. Cross-process dedup/durable receipts and triggering only on
semantic intake/revision changes belong to integration. There are no heartbeat,
polling, or ledger hooks in this standalone package.

## Credential boundary

Python never receives the credential. `transport.py` discovers the installed OMP
source using the existing `omp_adapter` locator and starts a finite Bun helper.
Only a credential-free JSON payload goes through stdin. The child gets a minimal
environment, not inherited provider keys, proxy/preload hooks or credentials.

`omp_transport.ts` reuses OMP's **existing `AuthStorage.reload/getApiKey` resolver**
with a narrow `ReadOnlyCredentialStore` facade. OMP's normal
`SqliteAuthCredentialStore.open`/constructor performs DDL/hygiene and therefore
cannot be used on the operator's store under this task's read-only requirement.
The facade opens `~/.omp/agent/agent.db` with SQLite `readonly`, `create:false`,
`query_only`, rejects non-owner or group/world-accessible database files, and
exposes only enabled `openrouter` `api_key` records. Key bytes/source are preserved;
no shell/config expansion, OAuth refresh, cache write, hygiene or store migration
is allowed. The unmodified key becomes an Authorization header **only in memory
inside that same process**. Nothing copies it into Python, argv, child env, files,
receipts or logs. All output/diagnostics from imported OMP code are suppressed in
the helper. Missing credentials or any resolver incompatibility returns explicit
`unavailable`; it is never treated as a successful decision.

Tests inject transports/key resolvers and use private disposable fake databases;
they never read the real store. Provider errors are discarded rather than trying
to redact arbitrary echoed text. Only fixed error classes, numeric status and
whitelisted typed response fields leave the transport.

## Offline replay and checks

```sh
python3 -m compileall -q tools/factory
python3 -m unittest discover -s tools/factory/tests -t tools/factory -p 'test_decision*.py'
bun test tools/factory/decision/transport_mock_test.ts
PYTHONPATH=tools/factory python3 -m decision.replay
python3 -m unittest discover -s tools/factory/tests -t tools/factory
```

Replay is offline: it never instantiates an adapter, resolves credentials or
makes a network call. The bundled examples are **explicitly labelled MOCK**:
sanitized actual F-0052/F-0053 task goals and factory ledger revision-conflict /
kernel-lock examples, paired with mock judgments, not real model responses or
measured history. Actual model/outcome is unknown. Supply sanitized recorded
data to compare recommendations against the actual choices:

```sh
PYTHONPATH=tools/factory python3 -m decision.replay --input sanitized-records.json \
  --tier-model simple=approved/small --tier-model standard=approved/standard \
  --tier-model complex=approved/deep
```

Each record has `task_id`, `recommendation:{status,choice,uncertainty}`,
`actual_model` (nullable), optional `outcome:{review,repair_count}`. Unknown keys
are rejected. Input is capped at 1 MB and 1,000 records; output is aggregate
agreement/exclusions grouped by tier/status/review/repair. Actual choices are
**not ground truth**, and agreement is not accuracy or calibration. Null actual
models and insufficient information do not count as comparable. No broad paid
benchmark is present.

The operator-only `PYTHONPATH=tools/factory python3 -m decision.smoke --live`
executes **one** tiny synthetic POST with zero retries after fail-closed catalog
verification. Never run it automatically or without remaining explicit paid-call
authorization. This implementation's authorization is **at most two total**;
normal tests/replay consume zero. Sanitized real-smoke evidence is recorded in the
handoff, distinct from the deterministic mock tests.

### Sanitized real smoke (not a mock)

One authorized inference POST was actually sent on 2026-10-15; no retry or second
POST was sent. Catalog/protocol gating succeeded before credential resolution.
The observed typed response passed the classifier validator:

```json
{
  "model": "cloudflare/clef-flash",
  "endpoint_path": "/api/v1/systemone",
  "status": "available",
  "http_status": 200,
  "latency_ms": 1559,
  "usage": {"input_tokens": 318, "output_tokens": 0, "cost": 0.000006678},
  "error_class": null,
  "protocol_verified": true
}
```

Only synthetic non-sensitive state was sent. Credential bytes were resolved and
used solely inside the helper, never emitted in diagnostics, argv, env, fixtures
or this evidence. One of the parent's two authorized inference requests remains;
this package does not use it automatically.

When running the full suite from a factory worker shell, use
`env -u FACTORY_PROJECT python3 -m unittest discover -s tools/factory/tests -t tools/factory`.
Worker shells inherit `FACTORY_PROJECT=lemon`, whereas existing CLI fixtures
register a disposable `widget` project; the inherited selector otherwise makes
unrelated ledger/supervisor tests fail with `not_registered`. This is a test
environment override, not a decision-layer failure or policy modification.

## Rollout / rollback

Implemented does not mean merged, installed or shadow-active. This package is not
wired into existing routing, no installed release was changed, and no coordinator
was restarted. Activation/reload requires the parent integration and external
F-0050 drain/cutover handoff. Roll back an integrated deployment by setting decision
mode `off` through its factory-local policy and retaining existing routing; this
standalone package itself creates no running service or durable state to remove.
