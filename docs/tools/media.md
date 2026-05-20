# Media Tools

Lemon's media tools are preview surfaces built around BEAM supervision,
redacted metadata, and managed local artifacts.

- `media_status`: model-facing read-only status for generated-media jobs,
  recent artifacts, cleanup policy, and worker supervisor state.
- `media_generate_image`: model-facing image generation through
  `LemonCore.MediaJobSupervisor`.
- `media_generate_speech`: model-facing speech generation through
  `LemonCore.MediaJobSupervisor`.
- `media_transcribe_audio`: model-facing local audio transcription through
  `LemonCore.MediaJobSupervisor`.
- `media_analyze_image`: model-facing local image analysis through
  `LemonCore.MediaJobSupervisor`.
- `media_generate_video`: model-facing video generation through
  `LemonCore.MediaJobSupervisor`.

## Image Generation

`media_generate_image` supports three providers:

| Provider | Behavior |
| --- | --- |
| `local_svg` | Deterministic local SVG preview for tests and no-credential flows. |
| `openai_image` | Provider-backed OpenAI image generation using Lemon runtime credentials. |
| `vertex_imagen` | Provider-backed Google Vertex AI Imagen generation using Lemon `providers.google_vertex` credentials. |

Example:

```json
{
  "prompt": "A simple flat icon of a yellow lemon on a white background. No text.",
  "provider": "openai_image",
  "model": "gpt-image-1",
  "filename": "lemon-icon",
  "size": "1024x1024",
  "outputFormat": "png",
  "maxRetries": 1,
  "sendToChannel": true
}
```

OpenAI image jobs resolve credentials through the normal Lemon runtime provider
path: `OPENAI_API_KEY`, `[providers.openai] api_key`, `api_key_secret`, or the
default Lemon secret. Provider base URLs can come from `[providers.openai]
base_url` or `OPENAI_BASE_URL`; otherwise Lemon uses `https://api.openai.com/v1`.
Vertex Imagen jobs resolve `providers.google_vertex` project, location, and
service-account JSON through Lemon runtime config/secrets. The live image proof
can be run with `--provider vertex_imagen`, defaulting to
`imagen-4.0-generate-001` in `us-central1`.

`maxRetries` retries bounded transient provider failures such as 429 and 5xx
responses. Non-transient provider errors are recorded as failed media jobs with
redacted error kind only. When a provider returns a safe structured status or
type, Lemon appends that bounded label to the job error kind, for example
`openai_image_http_error:billing_limit_user_error`,
`vertex_imagen_http_error:permission_denied`,
`openai_tts_http_error:invalid_request_error`,
`google_tts_http_error:permission_denied`, or
`elevenlabs_tts_http_error:payment_required`; raw provider messages stay
hashed only.

## Speech Generation

`media_generate_speech` supports four providers:

| Provider | Behavior |
| --- | --- |
| `local_wav` | Deterministic local WAV preview for tests and no-credential flows. |
| `openai_tts` | Provider-backed OpenAI text-to-speech using Lemon runtime credentials. |
| `elevenlabs_tts` | Provider-backed ElevenLabs text-to-speech using voice config, env, or Lemon secrets. |
| `google_tts` | Provider-backed Google Cloud Text-to-Speech using Lemon `providers.google_vertex` service-account credentials. |

Example:

```json
{
  "text": "The build is green and ready for review.",
  "provider": "openai_tts",
  "model": "gpt-4o-mini-tts",
  "voice": "alloy",
  "filename": "status-update",
  "responseFormat": "mp3",
  "maxRetries": 1,
  "sendToChannel": true
}
```

OpenAI TTS jobs resolve credentials through the same Lemon runtime provider path
as image jobs. Google TTS jobs resolve service-account credentials through
`providers.google_vertex` and call Cloud Text-to-Speech `text:synthesize` with
MP3 output. ElevenLabs TTS jobs use `ELEVENLABS_API_KEY`, the configured
gateway voice secret, or the `ELEVENLABS_API_KEY` / `elevenlabs_api_key` Lemon
secret names, and use the configured ElevenLabs voice id when `voice` is not
provided. The tool records text hash/chars instead of raw text, writes managed
speech artifacts, retries bounded transient provider failures, and records only
redacted provider error kinds.

## Speech To Text

`media_transcribe_audio` supports three providers:

| Provider | Behavior |
| --- | --- |
| `local_transcript` | Deterministic transcript preview from a local audio hash. |
| `openai_transcribe` | Provider-backed OpenAI speech-to-text using Lemon runtime credentials. |
| `deepgram_transcribe` | Provider-backed Deepgram speech-to-text using voice config, env, or Lemon secrets. |

Example:

```json
{
  "audioPath": ".lemon/media-artifacts/voice-note.wav",
  "provider": "openai_transcribe",
  "model": "gpt-4o-mini-transcribe",
  "language": "en",
  "filename": "voice-note-transcript",
  "responseFormat": "json",
  "maxRetries": 1,
  "sendToChannel": true
}
```

The tool only accepts local audio files under the current project directory and
rejects path escapes. Job metadata stores an audio fingerprint hash/size/MIME
summary instead of raw paths or audio bytes. The model-facing result includes
the transcript text because that is the requested output, but the tool result is
marked `trust: :untrusted` and carries `trustMetadata` for the model-visible
`text` field so the pre-LLM untrusted-content boundary wraps it. Support
surfaces and media job metadata do not store the transcript body. Deepgram STT
uses `DEEPGRAM_API_KEY`, the configured gateway voice secret, or the
`DEEPGRAM_API_KEY` / `deepgram_api_key` Lemon secret names.

## Image Analysis

`media_analyze_image` supports two providers:

| Provider | Behavior |
| --- | --- |
| `local_vision` | Deterministic image-analysis preview from a local image hash. |
| `openai_vision` | Provider-backed OpenAI or OpenAI-compatible vision analysis using Lemon runtime credentials. |

Example:

```json
{
  "imagePath": ".lemon/media-artifacts/screenshot.png",
  "provider": "openai_vision",
  "model": "gpt-4o-mini",
  "prompt": "Describe the UI and identify any visible error text.",
  "detail": "auto",
  "filename": "screenshot-analysis",
  "responseFormat": "json",
  "maxRetries": 1,
  "sendToChannel": true
}
```

The tool only accepts local image files under the current project directory and
rejects path escapes. Job metadata stores an image fingerprint hash/size/MIME
summary plus a prompt hash instead of raw paths, prompts, or image bytes. The
model-facing result includes the analysis text because that is the requested
output, but the tool result is marked `trust: :untrusted` and carries
`trustMetadata` for the model-visible `text` field so the pre-LLM
untrusted-content boundary wraps it. Support surfaces and media job metadata do
not store the analysis body.
OpenAI vision currently accepts PNG, JPEG, WebP, or GIF input.
Provider-prefixed OpenAI-compatible models are supported for vision. For
example, `model: "openrouter:openai/gpt-4o-mini"` resolves the OpenRouter
credential and base URL from Lemon config/secrets, sends `openai/gpt-4o-mini`
to the compatible `/chat/completions` endpoint, and keeps the full prefixed
model id in redacted job metadata for operator visibility.

## Video Generation

`media_generate_video` supports three providers:

| Provider | Behavior |
| --- | --- |
| `local_mp4` | Deterministic local MP4 preview for tests and no-credential flows. |
| `openai_video` | Provider-backed OpenAI video job create/poll/download using Lemon runtime credentials. |
| `vertex_veo` | Provider-backed Google Vertex AI Veo long-running prediction using Lemon `providers.google_vertex` credentials. |

Example:

```json
{
  "prompt": "Create a four second product-style clip of a lemon on a clean white table.",
  "provider": "openai_video",
  "model": "sora-2",
  "filename": "lemon-preview",
  "size": "1280x720",
  "seconds": "4",
  "maxRetries": 1,
  "sendToChannel": true
}
```

OpenAI video jobs resolve credentials through the same Lemon runtime provider
path as the other OpenAI-backed media tools. The tool records prompt hash/chars
instead of raw prompt text, creates the provider job, polls until completion,
downloads the final MP4 into the managed artifact directory, retries bounded
transient provider failures, redacts provider errors and provider job ids, and
can request generated-file channel delivery metadata.

Vertex Veo jobs resolve `providers.google_vertex` service-account credentials,
exchange them for a Google access token, call Vertex AI
`:predictLongRunning`, poll with `:fetchPredictOperation`, and write inline
MP4 bytes into the same managed artifact path. If Veo returns only a Cloud
Storage URI, Lemon fails closed with a safe unsupported-GCS response label
rather than leaking provider output or attempting unmanaged downloads.

## Artifact and Redaction Contract

Artifacts are written under `.lemon/media-artifacts/` by default. Job metadata
is written under `.lemon/media-jobs/`.

Public surfaces return:

- job id
- status/type/provider/model
- prompt hash and prompt character count
- artifact filename, MIME type, byte count, and managed local path
- redacted `media_job` metadata

Public surfaces do not return raw prompts, raw provider responses, raw generated
bytes, API keys, or channel message bodies. Support bundles and Web `/ops`
reuse the same redacted metadata. Web `/ops` groups provider proof readiness by
launch lane, so alternate providers such as `vertex_imagen`, `google_tts`, and
`deepgram_transcribe` can satisfy the image, TTS, and STT lanes while exposing
copy-ready per-provider rerun commands.

Transcription and image-analysis outputs are treated as untrusted external
content even when they come from deterministic local preview workers. The
model-facing transcript/analysis `text` is still returned, but the tool result
is marked untrusted and includes trust metadata so any prompt-injection text
inside media-derived output is wrapped before a later model turn.

`sendToChannel: true` adds generated `auto_send_files` metadata. Telegram and
Discord delivery still require the channel file settings to opt into generated
files with `auto_send_generated_files` (or the legacy
`auto_send_generated_images` alias), count limits, and size limits.
For Hermes-style host-visible delivery from a final answer, a line containing
`MEDIA:<project-relative-path>` is converted at router finalization time into an
explicit `auto_send_files` entry when the file exists under the run working
directory. The directive line is removed from the channel text before
Telegram/Discord rendering.

## Proof Lanes

Focused deterministic media tool lane:

```bash
mix test apps/coding_agent/test/coding_agent/tools/media_status_test.exs \
  apps/coding_agent/test/coding_agent/tools/media_generate_image_test.exs \
  apps/coding_agent/test/coding_agent/tools/media_generate_speech_test.exs \
  apps/coding_agent/test/coding_agent/tools/media_transcribe_audio_test.exs \
  apps/coding_agent/test/coding_agent/tools/media_analyze_image_test.exs \
  apps/coding_agent/test/coding_agent/tools/media_generate_video_test.exs \
  apps/coding_agent/test/coding_agent/tools_test.exs \
  apps/coding_agent/test/coding_agent/tool_registry_test.exs \
  apps/coding_agent/test/coding_agent/tool_policy_test.exs \
  apps/coding_agent/test/coding_agent_test.exs \
  apps/coding_agent/test/coding_agent/cli_runners/lemon_runner_test.exs \
  apps/lemon_channels/test/lemon_channels/adapters/discord/renderer_test.exs \
  apps/lemon_channels/test/lemon_channels/adapters/telegram/renderer_test.exs --seed 1
```

The latest lane passed locally on 2026-05-16 with `256 tests, 0 failures`.

Deterministic local media proof lane:

```bash
MIX_ENV=test mix run scripts/live_media_image_smoke.exs --local
MIX_ENV=test mix run scripts/live_media_speech_smoke.exs --local
MIX_ENV=test mix run scripts/live_media_transcription_smoke.exs --local
MIX_ENV=test mix run scripts/live_media_vision_smoke.exs --local
MIX_ENV=test mix run scripts/live_media_video_smoke.exs --local
```

The local smoke mode exercises the same supervised media worker boundary without
credentials or provider quota. It writes separate redacted artifacts under
`.lemon/proofs/`:

- `media-image-local-smoke-latest.json` for `local_svg`
- `media-speech-local-smoke-latest.json` for `local_wav`
- `media-transcription-local-smoke-latest.json` for `local_transcript`
- `media-vision-local-smoke-latest.json` for `local_vision`
- `media-video-local-smoke-latest.json` for `local_mp4`

Those artifacts use `proof_scope: media_local` and
`lemon.media_*_local_smoke` proof objects. They are regression proof for the
deterministic BEAM media path only. They do not satisfy `media.provider_live`,
the release audit provider-backed gate, or any claim that image, TTS, STT,
vision, or video provider parity is complete.

Opt-in live provider proof:

```bash
LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 \
  MIX_ENV=test mix run scripts/live_media_image_smoke.exs \
    --proof-path .lemon/proofs/media-image-smoke-latest.json \
    --api-key-env OPENAI_API_KEY
```

```bash
LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 \
  MIX_ENV=test mix run scripts/live_media_speech_smoke.exs \
    --proof-path .lemon/proofs/media-speech-smoke-latest.json \
    --api-key-env OPENAI_API_KEY
```

```bash
LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 \
  MIX_ENV=test mix run scripts/live_media_transcription_smoke.exs \
    --proof-path .lemon/proofs/media-transcription-smoke-latest.json \
    --api-key-env OPENAI_API_KEY
```

```bash
LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 \
  MIX_ENV=test mix run scripts/live_media_vision_smoke.exs \
    --proof-path .lemon/proofs/media-vision-smoke-latest.json \
    --model openrouter:openai/gpt-4o-mini
```

```bash
LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 \
  MIX_ENV=test mix run scripts/live_media_video_smoke.exs \
    --proof-path .lemon/proofs/media-video-smoke-latest.json \
    --api-key-env OPENAI_API_KEY
```

The smokes resolve OpenAI credentials through the same runtime path as the
tools by default. They accept `--proof-path PATH` for the redacted proof artifact,
keep `--out PATH` as a backward-compatible alias, and also accept
`--api-key-env ENV_NAME`, `--api-key-secret SECRET_NAME`, and `--base-url URL`
for one-off live proof without editing Lemon config or exporting raw keys;
those override values are passed directly into the tool runtime and are not
written to the proof JSON. The smokes write redacted proof JSON under
`.lemon/proofs/` with stable
`lemon.media_*_smoke` proof objects, `media_provider` proof scope, and
per-provider check names. `mix lemon.doctor` consumes those artifacts as
`media.provider_live`, while `media.channel_delivery` is tracked separately
from Telegram/Discord generated-media, generated-audio, and final-answer
`MEDIA:<path>` delivery proofs. The provider smokes fail only on
provider execution errors. Doctor remediation maps safe `reason_kind` labels to
bounded operator hints for permission-denied, billing/quota, payment-required,
request-shape, and generic provider HTTP failures without exposing raw provider
responses. When an incomplete multi-provider lane has a safe failed/skipped
provider id in the redacted proof, doctor remediation includes the matching
`--provider` flag, such as `--provider vertex_imagen`,
`--provider google_tts`, or `--provider vertex_veo`, so reruns target the
actual blocked lane instead of the default. The vision smoke passed on
2026-05-16 through
OpenRouter `openai/gpt-4o-mini` and wrote `tmp/media-vision-live-proof.json`
with `completed_count: 1` and `failed_count: 0`. Without
`LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1`, or without a resolvable credential for
the configured provider from config or `--api-key-env`, they write skipped
proofs with `failed_count: 0` and `reason_kind: credential_preflight_skipped`.
Support bundles include the same redacted provider-live lane summary in
`media_diagnostics.json`, including target-provider rerun commands for failed
or skipped multi-provider lanes while omitting raw prompts, provider responses,
artifact bytes, API keys, and secret names.

Opt-in live channel delivery proof:

```bash
uv run scripts/live_telegram_matrix.py --skip-dm --skip-topic \
  --topic-generated-media-delivery \
  --generated-media-topic-id 35 \
  --timeout 180 \
  --result-path tmp/telegram-generated-media-proof.json
```

```bash
uv run scripts/live_telegram_matrix.py --skip-dm --skip-topic \
  --topic-generated-audio-delivery \
  --generated-audio-topic-id 35 \
  --timeout 120 \
  --result-path tmp/telegram-generated-audio-proof.json \
  --proof-path .lemon/proofs/telegram-generated-audio-latest.json
```

```bash
uv run scripts/live_discord_matrix.py \
  --channel-id 1475727417372049419 \
  --bot-token-index 0 \
  --sender-bot-token-index -1 \
  --wait-generated-media-delivery \
  --reset-session-between-checks \
  --timeout 180 \
  --result-path tmp/discord-generated-media-proof.json
```

```bash
uv run scripts/live_discord_matrix.py \
  --channel-id 1475727417372049419 \
  --bot-token-index 0 \
  --sender-bot-token-index 1 \
  --wait-generated-audio-delivery \
  --reset-session-between-checks \
  --timeout 120 \
  --result-path tmp/discord-generated-audio-proof.json \
  --proof-path .lemon/proofs/discord-generated-audio-latest.json
```

The generated-media probes ask the channel agent to run `media_generate_image`
with `provider local_svg` and `sendToChannel: true`, then verify that the
generated SVG arrives through the normal Telegram/Discord attachment path. The
generated-audio probes use `media_generate_speech` with `provider local_wav`
and `sendToChannel: true`, then verify that the generated WAV arrives through
the normal Telegram/Discord attachment path. They require the channel file
settings to opt into generated files with `auto_send_generated_files` or the
legacy `auto_send_generated_images` alias.

The Telegram generated-SVG proof passed on 2026-05-16 in forum topic `35`; SVG
outputs are uploaded as documents because Telegram rejects SVG photo
processing. The Telegram generated-audio proof passed on 2026-05-17 in topic
`35`, with `telegram_has_document: true` and `marker_seen: true` in the
sanitized proof artifact.

The Discord proof passed on 2026-05-16 in channel `1475727417372049419` after
`gateway.discord.files` was preserved through core config normalization and
parsed by the gateway. The proof delivered the generated SVG through the normal
Discord attachment path. The Discord generated-audio proof passed on
2026-05-17 in the same channel with one generated WAV attachment; the renderer
regression fixed in this slice keeps generated-file auto-send working when the
final answer edits an existing Discord presentation message.

## Remaining Preview Gaps

- successful live image-provider proof under usable OpenAI or Vertex quota
- successful live speech-provider proof under usable OpenAI, ElevenLabs, or
  Google TTS quota
- successful live video-provider proof under usable OpenAI or Vertex Veo quota
