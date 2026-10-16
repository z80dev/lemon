# Media Tools

Lemon's media tools are preview surfaces built around BEAM supervision,
redacted metadata, and managed local artifacts.

- `media_status`: model-facing read-only status for generated-media jobs,
  recent artifacts, cleanup policy, and worker supervisor state.
- `media_generate_image`: model-facing image generation through
  `LemonMedia.MediaJobSupervisor`.
- `media_generate_speech`: model-facing speech generation through
  `LemonMedia.MediaJobSupervisor`.
- `media_transcribe_audio`: model-facing local audio transcription through
  `LemonMedia.MediaJobSupervisor`.
- `media_analyze_image`: model-facing local image analysis through
  `LemonMedia.MediaJobSupervisor`.
- `media_generate_video`: model-facing video generation through
  `LemonMedia.MediaJobSupervisor`.

## Defaults and limits

When `provider` is omitted, every tool uses its deterministic local preview
provider (`local_svg`, `local_wav`, `local_transcript`, `local_vision`,
`local_mp4`). Pass a provider-backed value explicitly for real generation or
analysis. Common optional parameters are `filename` (always written under the
managed artifact directory), `maxRetries` (default 1, clamped to 0–3),
`sendToChannel` (default false) and `timeoutMs`, which is clamped to 100 ms up to
a per-tool maximum:

| Tool | Default `timeoutMs` | Maximum | Input limit |
| --- | --- | --- | --- |
| `media_generate_image` | 5000 | 30000 | |
| `media_generate_speech` | 10000 | 120000 | |
| `media_transcribe_audio` | 15000 | 120000 | 25 MiB audio file |
| `media_analyze_image` | 15000 | 120000 | 20 MiB image file |
| `media_generate_video` | 20000 | 300000 | |

`media_status` takes an optional `limit` (default 10, clamped to 0–50) of recent jobs.

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
service-account JSON through Lemon runtime config/secrets.

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

Optional video parameters: `size`, `seconds` (Vertex clamps to 1–60), `maxPolls`
(default 30, clamped 1–120) and `pollIntervalMs` (default 2000, clamped 0–30000)
for OpenAI status polling, and `storageUri` for a Vertex Veo Google Cloud Storage
output URI. Without `storageUri`, Lemon expects inline video bytes from the
operation response.

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
bytes, API keys, or channel message bodies. Support bundles and the `media_status`
tool reuse the same redacted metadata.

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

## Focused Test Coverage

From the umbrella root:

```bash
mix test apps/lemon_media/test apps/lemon_skills/test/lemon_skills/tools/media_status_test.exs \
  apps/lemon_skills/test/lemon_skills/tools/media_generate_image_test.exs \
  apps/lemon_skills/test/lemon_skills/tools/media_generate_speech_test.exs \
  apps/lemon_skills/test/lemon_skills/tools/media_transcribe_audio_test.exs \
  apps/lemon_skills/test/lemon_skills/tools/media_analyze_image_test.exs \
  apps/lemon_skills/test/lemon_skills/tools/media_generate_video_test.exs --seed 1
```

Provider credentials and real channel delivery require separate opt-in operator
checks. See [testing](../testing.md) for the supported manual smoke lanes; no
stored live-proof artifact is required by the runtime.
