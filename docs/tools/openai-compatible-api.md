# OpenAI-Compatible API Preview

Lemon exposes a preview OpenAI-compatible HTTP surface for clients that already
know the `/v1` API shape. The adapter is intentionally thin: it translates
OpenAI-shaped requests into supervised Lemon runs instead of bypassing the
router, run graph, events, approvals, checkpoints, or operator visibility.

## Endpoints

| Endpoint | Status | Behavior |
| --- | --- | --- |
| `GET /v1/health` | Preview | Returns Lemon API health metadata. |
| `GET /v1/capabilities` | Preview | Returns supported compatibility features and known gaps. |
| `GET /v1/models` | Preview | Returns Lemon's model catalog in OpenAI list shape, including Lemon capability metadata such as `supportsVision`. |
| `GET /v1/models/:model_id` | Preview | Returns one OpenAI-shaped model object from Lemon's catalog, including Lemon capability metadata such as `supportsVision`, or a 404 error. |
| `POST /v1/chat/completions` | Preview | Accepts OpenAI-style `model`, `messages`, redacted URL/file-id image metadata, data URL image pass-through, and opt-in allowlisted HTTPS image URL fetch, submits a Lemon run, returns queued metadata by default, assistant text when `wait: true` completes before the timeout, or `text/event-stream` chunks when `stream: true`. |
| `POST /v1/responses` | Preview | Accepts OpenAI-style `model`, `input`, redacted URL/file-id image metadata, data URL image pass-through, opt-in allowlisted HTTPS image URL fetch, and optional `previous_response_id`, submits a Lemon run, returns queued metadata by default, Responses-style output text when `wait: true` completes before the timeout, or Responses-style SSE events when `stream: true`. |
| `GET /v1/responses/:response_id` | Preview | Reads `resp_<run_id>` from the Lemon run store and returns a Responses-shaped object with completed output when available. |
| `GET /v1/runs/:run_id` | Preview | Returns redacted Lemon run status, timestamps, event count, session key, and completion state. |
| `POST /v1/runs/:run_id/cancel` | Preview | Requests cancellation through `LemonRouter.abort_run/2` for non-terminal runs and returns a cancelling status. |

Queued mode is the default. Clients can either use the returned `lemon.runId`
with `agent.wait`, subscribe to `/ws` events, or set `wait: true` plus optional
`timeout_ms` / `timeoutMs` to wait synchronously through the same `agent.wait`
path.

`stream: true` returns `text/event-stream` and subscribes the HTTP process to
the run topic. Chat Completions streams `chat.completion.chunk` objects for
`:delta` events, emits redacted `lemon.tool_progress` events for
`:engine_action` updates, and ends with `data: [DONE]`. Responses streams
`response.output_text.delta`, redacted `response.tool_progress`, and
`response.completed` events, also ending with `data: [DONE]`.

## Request Shape

`POST /v1/chat/completions`:

```json
{
  "model": "zai:glm-5-turbo",
  "messages": [
    {"role": "system", "content": "be brief"},
    {
      "role": "user",
      "content": [
        {"type": "text", "text": "hello"},
        {
          "type": "image_url",
          "image_url": {
            "url": "https://example.test/image.png",
            "detail": "high"
          }
        }
      ]
    }
  ],
  "metadata": {
    "session_key": "agent:default:openai"
  },
  "wait": true,
  "timeout_ms": 60000
}
```

`POST /v1/responses`:

```json
{
  "model": "openai:gpt-4o",
  "input": [
    {
      "type": "message",
      "role": "user",
      "content": [
        {"type": "input_text", "text": "hello"},
        {"type": "input_image", "image_url": "data:image/png;base64,..."}
      ]
    }
  ],
  "agent_id": "default",
  "previous_response_id": "resp_run_...",
  "wait": true
}
```

## Response Boundary

Both generation endpoints return Lemon metadata:

```json
{
  "lemon": {
    "runId": "run_...",
    "sessionKey": "agent:default:openai",
    "imageInputCount": 1,
    "status": "queued",
    "events": {
      "jsonRpc": "agent.wait",
      "webSocket": "/ws"
    }
  }
}
```

With `wait: true`, successful runs return `lemon.status: "completed"` and map
the completed Lemon answer into assistant text. Wait timeouts return HTTP `504`.
Responses use `resp_<run_id>` ids; `GET /v1/responses/:response_id` reads the
stored Lemon run and maps completed answers back into Responses output text.
`previous_response_id` validates the prior response and defaults the follow-up
run to the prior session key, so continuation stays on Lemon's supervised
session/run-history path.
`GET /v1/runs/:run_id` and `POST /v1/runs/:run_id/cancel` expose a minimal run
status/cancellation boundary without returning raw run events or assistant
answers from status calls.

Image input is now a split boundary. Chat Completions accepts `image_url`
parts, and Responses accepts `input_image` parts with HTTP(S) URLs, data URLs,
or `file_id`. By default, HTTP(S) URLs and file ids remain metadata-only: they
are hashed, redacted, added as bounded `[image input ...]` placeholders, and
never returned raw. Base64 data URLs are validated at the API boundary,
size/count-limited, redacted from prompts and metadata, and threaded as
runtime-only image blocks through `RunRequest`, the router, gateway,
`LemonRunner`, and `CodingAgent.Session.prompt/3` so native Lemon providers can
receive `Ai.Types.ImageContent`. HTTPS image URL fetch is available only when
explicitly enabled and host-allowlisted. In that mode, fetched image bytes are
MIME-checked, size-limited, base64 encoded, redacted from prompt/metadata, and
sent through the same runtime-only image path as data URLs. Only redacted image
metadata and `lemon.imageInputCount` are exposed in HTTP responses or
run-status payloads.

For known provider-prefixed models, runtime image bytes are rejected before run
submission when Lemon's model catalog says the model is text-only. Metadata-only
URL/file references remain allowed because they are redacted prompt context, not
provider-visible image bytes. `/v1/models` and `/v1/models/:model_id` expose the
same `lemon.supportsVision` capability so clients can choose a compatible model
before sending data URL or allowlisted fetched-image requests.

URL image fetching is disabled unless `:openai_compat_image_url_fetch` or
`LEMON_OPENAI_COMPAT_IMAGE_URL_FETCH=true` is set. Fetching requires an allowed
host list through `:openai_compat_image_url_allowed_hosts`,
`LEMON_OPENAI_COMPAT_IMAGE_URL_ALLOWED_HOSTS`, or
`LEMON_OPENAI_COMPAT_IMAGE_HOST_ALLOWLIST`. The preview policy accepts HTTPS
only and rejects non-allowlisted hosts before starting a Lemon run.

By default the preview `/v1` surface is unauthenticated for local development.
Set `:openai_compat_api_token` in `:lemon_control_plane` application config or
`LEMON_OPENAI_COMPAT_API_TOKEN` / `LEMON_OPENAI_COMPAT_TOKEN` in the environment
to require either `Authorization: Bearer <token>` or `x-api-key: <token>`.

This keeps the compatibility slice honest while the stable adapter adds broader
Responses API fields, deployed editor UI coverage, and more provider-specific
image transport proof beyond the passing OpenRouter vision proof.

## Proof Lane

```bash
mix test apps/lemon_control_plane/test/lemon_control_plane/http/router_test.exs --seed 1
```

The latest focused lane passed locally on 2026-05-17 with `25 tests, 0
failures`. It covers health, capabilities, model list shape, single-model
retrieve shape, chat-completions run submission, responses run submission,
synchronous wait completion,
Responses output text mapping, wait timeout handling, session-key metadata,
`previous_response_id` continuation metadata, stored response retrieval,
unknown stored response errors, streaming flag metadata, redacted run status,
unknown-run errors, run cancellation dispatch, Chat Completions SSE over run bus
events, Responses SSE over run bus events, redacted tool-progress SSE events
without raw tool detail, optional bearer auth, optional `x-api-key` auth,
redacted image-input metadata normalization for Chat Completions and Responses,
data URL image pass-through into runtime-only Lemon image blocks, opt-in
allowlisted HTTPS image URL fetch into runtime-only image blocks, disallowed
remote image host rejection before submission, `supportsVision` model metadata,
known non-vision model rejection before runtime-image submission, prompt
normalization, and validation errors without starting a real model run.

The adapter also has a deterministic live HTTP smoke that starts a local Bandit
router, calls `/v1` through `:httpc`, exercises auth, synchronous wait,
redacted image-input metadata, data URL image pass-through, allowlisted remote
image URL fetch, an external Node `fetch` client, an official OpenAI Node SDK
client, an official OpenAI Python SDK client, single-model retrieval, stored Responses,
previous-response continuation, streaming tool progress, redacted run status, and cancellation, then writes
redacted proof JSON:

```bash
MIX_ENV=test mix run scripts/live_openai_compat_smoke.exs
```

The latest smoke passed locally on 2026-05-17 with `completed_count: 14` and
`failed_count: 0`; the nested external `fetch` client completed 7 checks, the
official OpenAI Node SDK client completed 6 checks, and the official OpenAI
Python SDK client completed 6 checks. All three external clients verify
single-model retrieval plus `lemon.supportsVision` consistency, and both SDK
clients cover Chat Completions and Responses streaming through SDK stream
interfaces. The
top-level proof also includes `non_vision_image_rejection`, which posts runtime
image bytes to `openai:o3-mini`, expects the sanitized 400 response, and verifies
the stub submitter was not called. The proof is written to
`.lemon/proofs/openai-compat-smoke-latest.json` plus a timestamped archive.
`proofs.status`, support bundles, and `mix lemon.doctor --verbose` consume
those redacted result rows as `openai_compat_*` checks. The doctor check is
`openai_compat.api_preview`; rerun the smoke if it warns or skips.

There is also an opt-in live provider vision proof over the same `/v1`
Responses path:

```bash
LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 \
LEMON_OPENAI_COMPAT_LIVE_VISION_MODEL=openrouter:openai/gpt-4o-mini \
MIX_ENV=test mix run scripts/live_openai_compat_vision_smoke.exs
```

The vision smoke starts a local Bandit router without stubs, submits a data URL
image through `/v1/responses` with `wait: true`, then runs
`scripts/live_openai_compat_fetch_client.mjs` in vision-only mode against that
same local HTTP boundary. It writes redacted proof JSON to
`.lemon/proofs/openai-compat-vision-smoke-latest.json` and skips without a
model, live-credential opt-in, or resolvable provider credential. Credential
preflight uses `LemonAiRuntime.provider_has_credentials?/3`, the same
Lemon-owned resolver used by runtime calls, so env keys, encrypted secrets,
OAuth/default-secret paths, and provider-specific credentials are checked
consistently. If no model is configured, the script tries credential-ready
defaults in this order: OpenRouter `openai/gpt-4o-mini`, OpenAI
`gpt-4o-mini`, then Z.ai `glm-4.6v`. Its proof omits raw API keys, prompts,
answers, and image bytes.
On 2026-05-16 the live proof passed through OpenRouter
`openai/gpt-4o-mini` with `completed_count: 1`, `failed_count: 0`, external
Node fetch client vision sub-proof `completed_count: 1` /
`answer_matched_red: true`, and official OpenAI Node SDK vision sub-proof
`completed_count: 1` / `answer_matched_red: true`. Direct OpenAI returned
account quota errors in this environment, and Z.ai's coding endpoint accepted
the text-model credential but rejected image input, so those providers are not
used as the current proof source.

The external client used by that smoke can also be pointed at a running Lemon
HTTP server directly. Set `LEMON_OPENAI_COMPAT_CHECKS=vision` plus
`LEMON_OPENAI_COMPAT_IMAGE_BASE64` to run only the provider-backed vision
sub-proof in the fetch or SDK client; omit those variables for the default
deterministic external-client checks.

```bash
LEMON_OPENAI_COMPAT_BASE_URL=http://127.0.0.1:4000 \
LEMON_OPENAI_COMPAT_API_TOKEN=... \
node scripts/live_openai_compat_fetch_client.mjs
```

The OpenAI SDK client expects the `openai` package in the current Node working
directory; the live smoke installs it in a temporary directory automatically.
To point the SDK client at a running Lemon server directly:

```bash
LEMON_OPENAI_COMPAT_BASE_URL=http://127.0.0.1:4000 \
LEMON_OPENAI_COMPAT_API_TOKEN=... \
node scripts/live_openai_compat_openai_sdk_client.mjs
```

The Python SDK client expects the `openai` package in the Python environment;
the live smoke runs it with `uv run --with openai` automatically. To point the
Python SDK client at a running Lemon server directly:

```bash
LEMON_OPENAI_COMPAT_BASE_URL=http://127.0.0.1:4000 \
LEMON_OPENAI_COMPAT_API_TOKEN=... \
uv run --with openai python scripts/live_openai_compat_python_sdk_client.py
```

Together the clients exercise health, capabilities, synchronous Chat
Completions, Responses continuation, stored Responses, raw Chat Completions and
Responses SSE with tool-progress events, and official SDK Chat Completions and
Responses streaming, returning only hashes and counters in proof JSON.
