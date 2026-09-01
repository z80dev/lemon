# Release Checklist and Support Policy

Last reviewed: 2026-08-16

This document defines the operational checklist for Lemon 1.0 release
candidates, rollback handling, and public support boundaries.

## Initial 1.0 Support Matrix

The initial stable 1.0 release artifact support target is:

| Area | Supported for 1.0 | Notes |
| --- | --- | --- |
| Release artifacts | `linux-x86_64`, `linux-arm64`, `darwin-arm64` tarballs | Built by `.github/workflows/release.yml` on pinned `ubuntu-24.04`, `ubuntu-24.04-arm`, and `macos-15` runners; Linux artifacts carry a glibc 2.39 baseline |
| Release profiles | `lemon_runtime_min`, `lemon_runtime_full`, and `lemon_tui` on all platforms | All BEAM runtime artifacts must boot from extracted tarballs; the three `lemon_tui` artifacts are Bun binaries verified on native runners |
| Source install | Linux and macOS, best effort | Requires Elixir 1.19.5+ and Erlang/OTP 28.5+ |
| Windows and macOS `x86_64` | Not supported for 1.0 | Use WSL, the container image, or source-level experimentation |
| Install script | Supported with scope | `install.sh` on the `stable` channel for the three platform tags; `preview`/`nightly` require a pinned `LEMON_VERSION` |
| Update | Supported with scope | `lemon update` stages runtime plus TUI artifacts atomically for full/min installs, then flips the symlink plus operator restart, with `--rollback`. No hot upgrades, no background auto-update |
| Container image | `ghcr.io/z80dev/lemon` multi-arch | `amd64` and `arm64` under one tag |
| Hosted Lemon service | Not supported for 1.0 | Lemon is local-first/self-hosted |
| Stable remote channel | Telegram | Text-first support boundary; other channel adapters are preview unless promoted |

Expanding release artifacts to further platforms requires release-matrix work,
local artifact proof, and support-bundle verification for each target.

## Release Candidate Checklist

The Release workflow automates the repeatable candidate gates against the exact
tagged commit. It validates version/changelog consistency and release notes,
runs `scripts/verify_source_install`,
`scripts/verify_install_script`, `scripts/test fast`, `scripts/test quality`,
`scripts/test clients`, and `scripts/test eval-fast`, then builds and
boot-verifies the published artifacts. Do not repeat these manually for an
ordinary release.

The remaining checks in this section are credentialed or human-observed
promotion evidence. Run only the checks relevant to a surface whose support
status is being promoted by that release; they are not routine publication
steps.

- [ ] Run `scripts/test live-eval` with release-candidate eval credentials, or
      dispatch `.github/workflows/live-eval.yml` with `LEMON_EVAL_API_KEY`
      configured as a repository secret. Local runs may use
      `LEMON_EVAL_API_KEY_SECRET` or `INTEGRATION_API_KEY_SECRET` to point at a
      Lemon secret.

      ```bash
      gh secret set LEMON_EVAL_API_KEY --repo z80dev/lemon

      mix lemon.secrets.set release_eval_api_key <token>
      LEMON_EVAL_API_KEY_SECRET=release_eval_api_key scripts/test live-eval

      gh workflow run live-eval.yml \
        --ref v2026.05.0 \
        -f iterations=3 \
        -f live_timeout_ms=90000
      gh run list --workflow live-eval.yml --limit 5
      gh run watch {run-id} --exit-status
      ```

      This is the minimum live-model eval matrix for stable 1.0: the full
      current `scripts/test live-eval` lane must pass at least once for the
      release candidate. It covers prior-work memory search, skill capture,
      skill curation, blocked cron tooling for scheduled runs, and parallel
      child delegation before answering.
- [ ] Rerun the Telegram live matrix for the stable text-first plus
      document-delivery boundary using the established Telethon credentials and
      Lemonade Stand group/topics.

      ```bash
      scripts/live_telegram_matrix.py --timeout 90
      scripts/live_telegram_matrix.py --skip-dm --topic-id 35 \
        --topic-isolation \
        --isolation-topic-id 35 \
        --isolation-topic-id 16456 \
        --timeout 180
      scripts/live_telegram_matrix.py --skip-dm --topic-id 35 \
        --topic-cancel \
        --cancel-topic-id 35 \
        --timeout 95
      scripts/live_telegram_matrix.py --skip-dm --topic-id 35 \
        --topic-tool-rendering \
        --topic-markdown \
        --timeout 160
      scripts/live_telegram_matrix.py --skip-dm --topic-id 35 \
        --topic-approval \
        --approval-topic-id 35 \
        --timeout 180
      scripts/live_telegram_matrix.py --skip-dm --topic-id 35 \
        --topic-long-output \
        --long-output-topic-id 35 \
        --timeout 120
      scripts/live_telegram_matrix.py --skip-dm --skip-topic \
        --topic-file-get \
        --file-get-topic-id 35 \
        --timeout 90
      ```

      Also run the two-step topic restart/dedupe proof after restarting
      `./bin/lemon`. The proof must cover DM, group forum-topic routing, topic
      isolation, cancellation, approval buttons, tool success/failure status,
      markdown/code rendering, long output, document delivery, and duplicate
      avoidance after restart.
- [ ] For Hermes-parity readiness, run the external-sender manual Discord matrix and
      keep the result JSON for the final audit.

      ```bash
      mix run --no-start scripts/live_discord_dedupe_proof.exs
      mix run --no-start scripts/live_discord_trigger_mode_proof.exs
      scripts/live_discord_matrix.py --channel-id 1475727417372049419 \
        --bot-token-index 0 \
        --sender-bot-token-index 1 \
        --manual-matrix \
        --reset-session-between-checks \
        --timeout 300 \
        --result-path tmp/discord-live-proof.json \
        --proof-path .lemon/proofs/discord-live-matrix-latest.json
      ```

      The prompts must be sent by a human Discord user or the second Lemonade
      Stand bot. Bot API smoke, self-authored responder messages, and webhooks
      do not count as Lemon inbound proof.
      Use `--reset-session-between-checks` with the second bot sender so each
      check starts from a clean Discord session.
      Keep `--result-path` for operator handoff data such as nonces and message
      ids; use `--proof-path` for the redacted artifact consumed by
      `proofs.status`, `./bin/lemon proofs`, support bundles, doctor gates,
      and.
      The runner stops on the first failed manual check by default; do not use
      `--continue-on-failure` for release evidence.
- [ ] Before promoting Discord free-response support, run the unmentioned
      external-sender matrix and confirm both the Discord Developer Portal
      Message Content Intent and `channel_diagnostics.json` readiness shape.

      ```bash
      scripts/live_discord_matrix.py --bot-token-index 0 \
        --wait-free-response-trigger \
        --per-check-thread \
        --sender-bot-token-index 1 \
        --reset-session-between-checks \
        --channel-id 1475727417372049419 \
        --result-path tmp/discord-free-response-proof.json \
        --proof-path .lemon/proofs/discord-free-response-latest.json \
        --timeout 120
      ```

      Do not promote this path from deterministic `/trigger` proof alone. The
      proof must embed redacted `local_channel_diagnostics`, report
      `message_content_intent_declared: true`, show trigger mode `all` with
      cleanup mode `clear`, and complete the unmentioned second-bot round trip.
      The runner preflights Discord application Message Content Intent flags
      against Lemon's local declaration; use `--skip-free-response-preflight`
      only for diagnostic waits. If `mix lemon.doctor` reports Message Content
      Intent or unmentioned-message delivery drift despite
      `message_content_intent_declared: true`, verify the privileged intent in
      the Discord Developer Portal, restart the runtime, and rerun the matrix
      before debugging lower-level routing. `runtime_requests_message_content_intent`
      should remain true in `channel_diagnostics.json`; if it does not, treat
      the local Discord transport startup path as the blocker before chasing
      portal drift.
- [ ] Before promoting Discord DM support, run `scripts/live_discord_matrix.py
      --wait-dm-inbound` against a human/open-DM channel and keep the redacted
      proof artifact for the final audit.

      ```bash
      scripts/live_discord_matrix.py --bot-token-index 0 \
        --wait-dm-inbound \
        --dm-recipient-id {human-open-dm-discord-user-id} \
        --result-path tmp/discord-dm-proof.json \
        --proof-path .lemon/proofs/discord-dm-latest.json \
        --timeout 120
      ```

      A Discord API `50007` setup failure must remain classified as
      `discord_dm_setup_refused` in support-bundle proof diagnostics and must not
      count as a promoted DM proof.
- [ ] Before promoting Discord live gateway reconnect support, run the two-phase
      Discord restart proof: `--restart-seed`, restart the runtime, then
      `--restart-verify --restart-runtime-confirmed` with the seed nonce and
      reply id. Include `--proof-path .lemon/proofs/discord-restart-verify-latest.json`
      on the verify run so doctor/support surfaces consume the redacted result.
      The seed phase alone is only setup evidence.
- [ ] Before promoting cron scheduler support beyond preview, run
      `MIX_ENV=test mix run scripts/live_cron_diagnostics_smoke.exs` and
      `MIX_ENV=dev mix run --no-start scripts/live_cron_runtime_restart_smoke.exs`.
      The proofs must show `cron_diagnostics_counts`,
      `cron_diagnostics_retry_policy`, `cron_diagnostics_redaction`,
      `cron_support_bundle_entry`, `runtime_booted`, `cron_api_ready`,
      `pre_restart_scheduled_run_observed`, `runtime_restarted`,
      `persisted_cron_state_loaded`, and
      `post_restart_scheduled_run_observed` with `failed_count: 0`.
- [ ] Before promoting channel-origin cron completion support, run
      `MIX_ENV=test mix run scripts/live_cron_channel_origin_smoke.exs`.
      The proof must show `telegram_channel_origin_cron_delivery` and
      `discord_channel_origin_cron_delivery` with `failed_count: 0`. `mix
      lemon.doctor --verbose` must report `cron.preview` as `pass` before cron
      preview claims are promoted. The final audit defaults to
      `LEMON_CRON_DIAGNOSTICS_PROOF_JSON=.lemon/proofs/cron-diagnostics-latest.json`,
      `LEMON_CRON_RUNTIME_RESTART_PROOF_JSON=.lemon/proofs/cron-runtime-restart-latest.json`,
      and
      `LEMON_CRON_CHANNEL_ORIGIN_PROOF_JSON=.lemon/proofs/cron-channel-origin-latest.json`;
      set them only when release evidence lives at different paths.
- [ ] Before promoting OpenAI-compatible API preview support, run
      `MIX_ENV=test mix run scripts/live_openai_compat_smoke.exs` and keep
      `.lemon/proofs/openai-compat-smoke-latest.json`. `mix lemon.doctor --verbose`
      must report `openai_compat.api_preview` as `pass`; failed or missing
      health/capability, Chat Completions, Responses, image metadata,
      streaming, stored-response, cancellation, external fetch, OpenAI Node SDK,
      or OpenAI Python SDK rows remain blockers for `/v1` support claims. The
      proof must not expose raw prompts, API keys, answers, or run events. The
      final audit defaults to
      `LEMON_OPENAI_COMPAT_PROOF_JSON=.lemon/proofs/openai-compat-smoke-latest.json`;
      set it only when release evidence lives at a different path.
- [ ] Before promoting ACP preview support, run the deterministic stdio smoke,
      external Node stdio client proof, and official ACP SDK client proof:

      ```bash
      MIX_ENV=test mix run scripts/live_acp_stdio_smoke.exs
      node scripts/live_acp_stdio_external_client.mjs
      node scripts/live_acp_official_sdk_client.mjs
      ```

      Keep `.lemon/proofs/acp-stdio-smoke-latest.json`,
      `.lemon/proofs/acp-stdio-external-client-latest.json`, and
      `.lemon/proofs/acp-official-sdk-client-latest.json`.
      `mix lemon.doctor --verbose` must report `acp.preview` as `pass`; failed
      or missing stdio, external client, or official SDK proof rows remain
      blockers for ACP support claims. The final audit defaults to
      `LEMON_ACP_STDIO_PROOF_JSON=.lemon/proofs/acp-stdio-smoke-latest.json`,
      `LEMON_ACP_EXTERNAL_CLIENT_PROOF_JSON=.lemon/proofs/acp-stdio-external-client-latest.json`,
      and
      `LEMON_ACP_OFFICIAL_SDK_PROOF_JSON=.lemon/proofs/acp-official-sdk-client-latest.json`;
      set them only when release evidence lives at different paths.
- [ ] Before promoting MCP preview support, run the stdio, Streamable HTTP, and
      legacy SSE smoke proofs:

      ```bash
      MIX_ENV=test mix run scripts/live_mcp_stdio_smoke.exs
      MIX_ENV=test mix run scripts/live_mcp_http_smoke.exs
      MIX_ENV=test mix run scripts/live_mcp_sse_smoke.exs
      ```

      Keep `.lemon/proofs/mcp-stdio-latest.json`,
      `.lemon/proofs/mcp-http-latest.json`, and
      `.lemon/proofs/mcp-sse-latest.json`.
      `mix lemon.doctor --verbose` must report `mcp.preview` as `pass`; failed
      or missing stdio, Streamable HTTP, or SSE proof rows remain blockers for
      MCP support claims. The proof artifacts must not expose raw paths,
      filenames, prompts, provider responses, tool arguments, tool results, or
      server IO. The final audit defaults to
      `LEMON_MCP_STDIO_PROOF_JSON=.lemon/proofs/mcp-stdio-latest.json`,
      `LEMON_MCP_HTTP_PROOF_JSON=.lemon/proofs/mcp-http-latest.json`, and
      `LEMON_MCP_SSE_PROOF_JSON=.lemon/proofs/mcp-sse-latest.json`; set them
      only when release evidence lives at different paths.
- [ ] Before promoting LSP diagnostics preview support, run the project-fixture
      and real-repo fixture editor-flow proofs:

      ```bash
      MIX_ENV=test mix run scripts/live_lsp_server_smoke.exs \
        --project-fixtures --editor-flow \
        --out .lemon/proofs/lsp-project-fixtures-latest.json
      MIX_ENV=test mix run scripts/live_lsp_server_smoke.exs \
        --real-repo-fixtures --editor-flow \
        --out .lemon/proofs/lsp-real-repo-fixtures-latest.json
      ```

      Keep `.lemon/proofs/lsp-project-fixtures-latest.json` and
      `.lemon/proofs/lsp-real-repo-fixtures-latest.json`.
      `mix lemon.doctor --verbose` must report `lsp.preview` as `pass`; failed
      or missing Pyright, gopls, clangd, rust-analyzer, TypeScript Language
      Server, or ElixirLS editor-flow rows remain blockers for LSP preview
      support claims. The proof artifacts must not expose raw paths, file
      contents, diagnostic output, raw session ids, or server IO. The final
      audit defaults to
      `LEMON_LSP_PROJECT_FIXTURES_PROOF_JSON=.lemon/proofs/lsp-project-fixtures-latest.json`
      and
      `LEMON_LSP_REAL_REPO_PROOF_JSON=.lemon/proofs/lsp-real-repo-fixtures-latest.json`;
      set them only when release evidence lives at different paths.
- [ ] Before promoting plugin/extension host preview support, run the BEAM
      extension host, WASM telemetry, WASM policy, extension registry audit,
      and WASM lifecycle proofs:

      ```bash
      MIX_ENV=test mix run scripts/live_extension_host_smoke.exs
      MIX_ENV=test mix run scripts/live_wasm_telemetry_smoke.exs
      MIX_ENV=test mix run scripts/live_wasm_policy_smoke.exs
      MIX_ENV=test mix run scripts/live_extension_registry_audit_smoke.exs
      MIX_ENV=test mix run scripts/live_wasm_lifecycle_smoke.exs
      ```

      Keep `.lemon/proofs/extension-host-smoke-latest.json`,
      `.lemon/proofs/wasm-tool-telemetry-latest.json`,
      `.lemon/proofs/wasm-policy-latest.json`,
      `.lemon/proofs/extension-registry-audit-latest.json`, and
      `.lemon/proofs/wasm-lifecycle-latest.json`.
      `mix lemon.doctor --verbose` must report `extensions.telemetry`,
      `extensions.wasm_telemetry`, `extensions.wasm_policy`,
      `extensions.registry_audit`, and `extensions.wasm_lifecycle` as `pass`;
      failed or missing rows remain blockers for plugin/extension host preview
      support claims. Support bundles and `proofs.status` must expose the
      proof-level `redaction` maps for these artifacts without raw paths, cwd,
      session ids, params, manifest contents, distribution URLs, or tool
      payloads. The final audit defaults to
      `LEMON_EXTENSION_HOST_PROOF_JSON=.lemon/proofs/extension-host-smoke-latest.json`,
      `LEMON_WASM_TELEMETRY_PROOF_JSON=.lemon/proofs/wasm-tool-telemetry-latest.json`,
      `LEMON_WASM_POLICY_PROOF_JSON=.lemon/proofs/wasm-policy-latest.json`,
      `LEMON_EXTENSION_REGISTRY_AUDIT_PROOF_JSON=.lemon/proofs/extension-registry-audit-latest.json`,
      and `LEMON_WASM_LIFECYCLE_PROOF_JSON=.lemon/proofs/wasm-lifecycle-latest.json`;
      set them only when release evidence lives at different paths.
- [ ] Before promoting terminal backend support beyond preview, run
      `MIX_ENV=test mix run scripts/live_terminal_backend_smoke.exs` and keep
      `.lemon/proofs/terminal-backend-latest.json`. `mix lemon.doctor --verbose`
      must report `terminal.backends_live` as `pass`; failed or missing
      `local`, `local_pty`, `docker`, or `ssh` rows remain blockers unless the
      release explicitly scopes that backend out. The proof and support
      surfaces must not expose command text, environment values, process output,
      raw SSH targets, or raw proof paths.
      The final audit defaults to
      `LEMON_TERMINAL_BACKEND_PROOF_JSON=.lemon/proofs/terminal-backend-latest.json`;
      set it only when release evidence lives at a different path.
- [ ] Run `mix lemon.doctor --verbose` after collecting Discord proof artifacts.
      Treat `channels.discord.dm`, `channels.discord.free_response`,
      `channels.discord.reconnect`, `channels.discord.slash_client_click`, and
      `media.provider_live` warnings as release blockers for broad Discord and
      provider-backed media parity until each is promoted to `pass` by live
      proof. The channel and media doctor checks must remain redacted: no raw
      Discord IDs, message bodies, bot tokens, secret names, media prompts,
      provider responses, artifact bytes, or raw transcript text.
      When Discord DM, free-response, or real slash client-click proof artifacts
      are present but incomplete, the final readiness audit may print bounded
      `reason_kind` labels from those artifacts. It must not print Discord IDs,
      interaction tokens, bot tokens, secret names, or message bodies.
      When a provider-backed media proof is incomplete, the final readiness
      audit may print a bounded `reason_kind` label from the proof artifact
      such as `openai_image_http_error:billing_limit_user_error` or
      `vertex_imagen_http_error:permission_denied` or
      `google_tts_http_error:permission_denied` or
      `elevenlabs_tts_http_error:payment_required`, but must not print
      provider response bodies, prompts, transcripts, keys, or media bytes. If
      the incomplete proof identifies a safe provider id for a multi-provider
      lane, the audit may print a copy-ready rerun command with the matching
      `--provider` flag.
- [ ] For provider-backed media readiness, run all live media smoke scripts with
      usable provider credentials and quota before claiming image, TTS, STT,
      vision, or video parity.

      Optional local checkpoint, useful before spending provider quota:

      ```bash
      MIX_ENV=test mix run scripts/live_media_image_smoke.exs --local
      MIX_ENV=test mix run scripts/live_media_speech_smoke.exs --local
      MIX_ENV=test mix run scripts/live_media_transcription_smoke.exs --local
      MIX_ENV=test mix run scripts/live_media_vision_smoke.exs --local
      MIX_ENV=test mix run scripts/live_media_video_smoke.exs --local
      ```

      The local lane must complete five `proof_scope: media_local` artifacts
      for `local_svg`, `local_wav`, `local_transcript`, `local_vision`, and
      `local_mp4`. These artifacts prove deterministic worker health only. They
      are not accepted by the final audit and are not a substitute for
      provider-backed image, TTS, STT, vision, or video proof.

      ```bash
      LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 MIX_ENV=test mix run --no-start scripts/live_media_image_smoke.exs \
        --proof-path .lemon/proofs/media-image-smoke-latest.json
      LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 MIX_ENV=test mix run --no-start scripts/live_media_image_smoke.exs \
        --provider vertex_imagen \
        --proof-path .lemon/proofs/media-image-smoke-latest.json
      LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 MIX_ENV=test mix run --no-start scripts/live_media_speech_smoke.exs \
        --proof-path .lemon/proofs/media-speech-smoke-latest.json
      LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 MIX_ENV=test mix run --no-start scripts/live_media_speech_smoke.exs \
        --provider google_tts \
        --proof-path .lemon/proofs/media-speech-smoke-latest.json
      LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 MIX_ENV=test mix run --no-start scripts/live_media_transcription_smoke.exs \
        --proof-path .lemon/proofs/media-transcription-smoke-latest.json
      LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 MIX_ENV=test mix run --no-start scripts/live_media_vision_smoke.exs \
        --proof-path .lemon/proofs/media-vision-smoke-latest.json
      LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 MIX_ENV=test mix run --no-start scripts/live_media_video_smoke.exs \
        --proof-path .lemon/proofs/media-video-smoke-latest.json
      LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 MIX_ENV=test mix run --no-start scripts/live_media_video_smoke.exs \
        --provider vertex_veo \
        --proof-path .lemon/proofs/media-video-smoke-latest.json
      ```

      If the provider key is stored in Lemon's encrypted secret store, append
      `--api-key-secret SECRET_NAME` to the relevant command instead of
      exporting a raw API key. Provider-prefixed OpenAI-compatible routing is
      a media vision proof feature; for image, TTS, STT, and video compatible
      endpoint checks, use `--base-url` with an unprefixed model. TTS proof can
      use either OpenAI or ElevenLabs evidence; the ElevenLabs proof script uses
      the ElevenLabs default voice id unless `--voice` is explicitly supplied.
      TTS proof can also use Google Cloud Text-to-Speech evidence through
      `google_tts`, backed by the same `providers.google_vertex`
      service-account credential path.
      Image proof can use either OpenAI or Vertex Imagen evidence; Vertex uses
      `providers.google_vertex` project, location, and service-account JSON
      config/secrets and writes the `media_provider_vertex_imagen` check row.
      Video proof can use either OpenAI or Vertex Veo evidence; Vertex Veo uses
      the same `providers.google_vertex` credential path and writes the
      `media_provider_vertex_veo` check row.
      STT proof can use either OpenAI or Deepgram evidence, as long as the
      redacted proof artifact is completed.

      The final audit defaults to the latest redacted proof artifacts:
      `LEMON_MEDIA_IMAGE_PROOF_JSON=.lemon/proofs/media-image-smoke-latest.json`,
      `LEMON_MEDIA_SPEECH_PROOF_JSON=.lemon/proofs/media-speech-smoke-latest.json`,
      `LEMON_MEDIA_TRANSCRIPTION_PROOF_JSON=.lemon/proofs/media-transcription-smoke-latest.json`,
      `LEMON_MEDIA_VISION_PROOF_JSON=.lemon/proofs/media-vision-smoke-latest.json`,
      and
      `LEMON_MEDIA_VIDEO_PROOF_JSON=.lemon/proofs/media-video-smoke-latest.json`.
      Set those environment variables only when the release evidence lives at a
      different path. Skipped credential-preflight artifacts for image, TTS, STT,
      or video are blockers; completed vision proof alone is insufficient for
      provider-backed media parity.
- [ ] Before promoting browser automation preview support, run
      `MIX_ENV=test mix run scripts/live_browser_smoke.exs` and keep
      `.lemon/proofs/browser-smoke-latest.json`. `mix lemon.doctor --verbose`
      must report `browser.preview` as `pass`; missing or incomplete local
      driver, CDP attach, route guardrail, interaction, upload/download,
      screenshot, cookie/state, progress-redaction, or browser-to-media vision
      coverage remains a browser preview blocker. The proof artifact must omit
      raw local paths, URLs, selectors, typed text, cookie values, page text,
      artifact paths, and screenshot bytes. The final audit defaults to
      `LEMON_BROWSER_PROOF_JSON=.lemon/proofs/browser-smoke-latest.json`; set
      it only when release evidence lives at a different path.
- [ ] For Discord application-command readiness, run the live Discord API
      schema proofs and keep the result JSON for the final audit.

      ```bash
      scripts/live_discord_matrix.py --bot-token-index 0 \
        --check-media-slash-registration \
        --result-path tmp/discord-media-slash-proof-check.json \
        --proof-path .lemon/proofs/discord-media-slash-registration-latest.json
      scripts/live_discord_matrix.py --bot-token-index 0 \
        --check-rollback-slash-registration \
        --result-path tmp/discord-rollback-slash-proof-check.json \
        --proof-path .lemon/proofs/discord-rollback-slash-registration-latest.json
      scripts/live_discord_matrix.py --bot-token-index 0 \
        --check-all-slash-registration \
        --result-path tmp/discord-all-slash-proof-check.json \
        --proof-path .lemon/proofs/discord-all-slash-registration-latest.json
      ```

      These prove the live Zeebot application has the in-repo `/media status`
      slash schema and all expected Lemon command names registered. They do not
      prove client-click execution. Keep `--result-path` for raw command
      ids/versions and `--proof-path` for redacted support/status artifacts.
- [ ] For Hermes-compatible final-answer `MEDIA:<path>` delivery readiness, run
      the Telegram and Discord live matrix checks and keep the redacted proof
      artifacts for the final audit.

      ```bash
      scripts/live_telegram_matrix.py --skip-dm --skip-topic \
        --topic-media-directive-delivery \
        --media-directive-topic-id 35 \
        --timeout 120 \
        --result-path tmp/telegram-media-directive-proof.json \
        --proof-path .lemon/proofs/telegram-media-directive-latest.json
      scripts/live_discord_matrix.py --channel-id 1475727417372049419 \
        --bot-token-index 0 \
        --sender-bot-token-index 1 \
        --wait-media-directive-delivery \
        --reset-session-between-checks \
        --timeout 120 \
        --result-path tmp/discord-media-directive-proof.json \
        --proof-path .lemon/proofs/discord-media-directive-latest.json
      ```

      These prove final-answer MEDIA directives are converted into real
      Telegram documents or Discord attachments and do not leak raw
      `MEDIA:<path>` lines into channel-facing text.
- [ ] Before promoting broad Discord slash-command parity, deploy or hot reload
      the runtime, run the wait-mode handoff, click the requested real Discord
      slash command such as `/media status` or `/checkpoint status`, then
      validate the redacted client-click proof artifact.

      ```bash
      scripts/live_discord_matrix.py --wait-slash-client-click-proof \
        --channel-id "$DISCORD_PROOF_CHANNEL_ID" \
        --slash-client-click-proof-path .lemon/proofs/discord-slash-client-click-proof-latest.json \
        --result-path tmp/discord-slash-client-click-proof-wait.json \
        --proof-path .lemon/proofs/discord-slash-client-click-check-latest.json
      ```

      The wait mode rejects stale artifacts generated before the watcher
      started. Use `--check-slash-client-click-proof` only for an already
      captured proof artifact.
      Deterministic slash decoder proof and Discord API registration proof are
      insufficient for this promotion gate.
- [ ] Run `scripts/test clients`.
- [ ] Build `lemon_runtime_min` with `MIX_ENV=prod mix release lemon_runtime_min --overwrite`.
- [ ] Build `lemon_runtime_full` with `MIX_ENV=prod mix release lemon_runtime_full --overwrite`.
- [ ] Confirm `release-smoke.yml` builds both runtime profiles and evaluates the
      packaged releases directly, while `scripts/verify_release_runtime_boot`
      repeats the same check on each min/full release tarball. Each release must
      load `LemonMCP.Client`, report `LemonSkills.McpSource.mcp_enabled?/0`, keep
      `:lemon_mcp` loaded but not started, expose no application callback, and
      contain no `LemonMCP.Application` module.
- [ ] Build and package the `clients/tui` Bun binary for
      `linux-x86_64`, `linux-arm64`, and `darwin-arm64` as the `lemon_tui`
      artifacts.
- [ ] Verify SHA-256 for all nine tarballs and include all nine in `manifest.json`.
- [ ] Run `scripts/verify_release_artifacts {artifact-directory}` against the
      assembled artifact directory. The verifier must see
      the BEAM runtime tarballs plus the three `lemon_tui` tarballs (nine total).
- [ ] Run `scripts/verify_release_runtime_boot {artifact-directory}` against
      the assembled artifact directory. The verifier extracts the six BEAM
      tarballs and skips the `lemon_tui` pseudo-profile. Min/full check
      `/healthz` and generate support bundles through release `eval`.
      Min/full bundle inspection still requires `channel_readiness.json`,
      `readiness_summary.json`, shared readiness proof-gate ids, and
      `proof_gate_summary.gateCount`.
- [ ] Run product smoke against the release candidate.
- [ ] Run `scripts/verify_docs_site`. It installs docs dependencies in a temp
      copy, runs `npm audit --audit-level=high`, builds the VitePress site, and
      checks markdown links without leaving generated artifacts in the repo.
- [ ] Confirm docs generated artifacts are not left in the repository.
- [ ] Confirm issue templates and support-bundle docs reference the current artifact names.
- [ ] Confirm known dependency audit findings are recorded and accepted or fixed.
- [ ] Confirm the OSV Scanner workflow is present and scoped to the first-party
      Mix, npm, and Bun lockfiles before publishing a release candidate.
- [ ] Confirm the History Check workflow is present and blocks
      unrelated-history PRs before merge.
- [ ] Confirm the Bun TUI package and release lanes validate `clients/tui` and
      publish all three `lemon_tui` platform artifacts without publishing a
      separate package.
- [ ] Run `scripts/test all` from the tagged commit.
- [ ] Run the applicable provider-backed and external-channel smoke tests, then
      verify their redacted proof artifacts through the supported diagnostics.

## Dependency Audit Policy

Runtime dependencies and docs-site tooling are handled differently for 1.0.

Runtime release artifacts must not ship known high or critical dependency
advisories without a release-blocking issue, an explicit mitigation, and a
maintainer decision recorded in the launch ledger.

`.github/workflows/osv-scanner.yml` scans the first-party lockfiles on pull
requests and pushes that touch dependency manifests, on a weekly `main`
schedule, and through manual dispatch. It uses Google's pinned reusable OSV
scanner workflow, grants `security-events: write` for SARIF upload, and scans
      `mix.lock`, the Lemon web/browser npm lockfiles, `clients/tui/bun.lock`,
      the gateway private npm lockfile, and the diagrams npm lockfile. The workflow is
configured with `fail-on-vuln: false` so findings are detection signals, not
automatic release decisions; release candidates still require maintainer triage
for high or critical runtime findings.

## Repository History Integrity

`.github/workflows/history-check.yml` protects `main` from unrelated-history
pull requests. It checks out the PR head with full history, fetches the target
base branch, and requires `git merge-base "origin/${GITHUB_BASE_REF}" HEAD` to
return a non-empty common ancestor.

This keeps accidental orphan branches, reinitialized `.git/` directories, or
force-pushes from another repository from grafting a second root into Lemon's
history and collapsing blame across a large umbrella snapshot. Failed PRs
should be recreated from the current target branch, then the intended changes
should be cherry-picked or re-applied.

## Bun TUI Package Check

The client-quality lane validates `clients/tui` with the pinned Bun toolchain,
`bun install --frozen-lockfile`, `bun run check`, `bun run lint`, and `bun test`.
The release lane additionally compiles the `lemon_tui` pseudo-profile for each
supported platform. It is a client binary packaged alongside the BEAM runtime,
not a separately published package.

The docs site is static output. VitePress, Vite, esbuild, and
`markdown-link-check` are development/build-time tooling for `docs/`; they are
not included in `lemon_runtime_min` or `lemon_runtime_full` release tarballs.
For the docs package:

- high and critical advisories block release candidates
- moderate advisories are allowed only when all of these are true:
  - the advisory affects docs build/dev tooling, not runtime tarballs
  - the static docs build succeeds
  - markdown link checking succeeds
  - `npm audit` reports `fixAvailable: false` or the available fix would require
    an unsafe/manual major upgrade
  - the finding is recorded in the launch ledger
- generated docs artifacts such as `docs/node_modules` and
  `docs/.vitepress/dist` must not remain in the repository after local
  verification; `docs/package-lock.json` is tracked for `npm ci` parity

As of 2026-05-11, the accepted docs-tooling findings are three moderate
advisories in the VitePress dependency chain:

- `vitepress <= 1.6.4` via `vite`
- `vite <= 6.4.1`
- `esbuild <= 0.24.2`

`npm audit --json` reports no high or critical advisories and no available fix
for that chain. These findings do not block the runtime release while the docs
site is served as static output only.

## Publish Checklist

Publishing is one manually triggered workflow after the release-readiness
gates above pass. Before starting it, ensure the intended release notes are
under `## [Unreleased]` in `CHANGELOG.md` and the readiness changes are already
on `main`.

```bash
gh workflow run release.yml --ref main -f channel=stable -f draft=false
gh run list --workflow release.yml --limit 5
gh run watch {run-id} --exit-status
```

The `version` input is optional. Blank derives the next CalVer from the current
UTC month and `mix.exs`; `-f version=2026.08.2` requests an explicit,
strictly-increasing version. The workflow then:

1. consumes and validates the Unreleased changelog notes
2. updates every first-party product version
3. commits the release cut to `main` and creates its annotated tag
4. runs the canonical fast, quality, deterministic eval, and client lanes
   against the exact tagged commit
5. builds and verifies all native artifacts and the multi-arch container
6. publishes the GitHub Release, `manifest.json`, `install.sh`, and all nine
   tarballs
7. promotes the selected container channel; stable also promotes `latest`

Release runs are serialized. A failed preparation creates neither a commit nor
a tag. If a later job fails, use **Re-run failed jobs** on the same workflow
run; the successful preparation job and its exact tag are retained. If a new
workflow run is required, dispatch from the existing tag:

```bash
gh workflow run release.yml --ref v2026.08.2 -f channel=stable -f draft=false
```

Tag-ref dispatches skip release preparation and rebuild the existing release
cut. Mutable container channel tags do not move until the complete GitHub
Release exists.

The expected assets are:

- three `lemon_runtime_min` tarballs
- three `lemon_runtime_full` tarballs
- three `lemon_tui` tarballs
- `manifest.json` schema 2
- `install.sh`

For an intentionally prepared new external tag, direct tag push remains
supported:

```bash
git push origin v2026.08.2
```

Do not combine a `main` dispatch with a separate tag push for the same version.


## Rollback Checklist

Rollback means recommending or restoring a previous known-good release artifact.
Rollback is always an operator action; nothing rolls back on its own.

For runtimes installed by `install.sh` into `~/.lemon`, the two most recent
previous versions are retained on disk:

```bash
lemon update history
lemon update rollback --receipt <apply-receipt-id> --confirm <rollback-digest>
lemon stop && lemon daemon
lemon status
```

For manual tarball and container installs, use the full procedure:

- [ ] Identify the previous known-good artifact profile.
- [ ] Download the previous artifact and `manifest.json`.
- [ ] Verify the artifact checksum.
- [ ] Stop the current release runtime.
- [ ] Preserve `~/.lemon/config.toml`, secrets, and store paths before replacing runtime files.
- [ ] Extract the previous artifact into a clean runtime directory.
- [ ] Start the previous runtime with the same environment variables.
- [ ] Check `/healthz`.
- [ ] Generate a release-runtime support bundle if rollback was caused by a defect.
- [ ] Open or update the tracking issue with the failing version, rollback target, support bundle, and reproduction steps.

## Support Policy

Supported for stable 1.0:

- Installation from source on machines with supported Elixir/Erlang versions.
- Linux `x86_64` release tarballs for `lemon_runtime_min` and `lemon_runtime_full`.
- Provider configuration through documented secrets and setup paths.
- TUI, web, Telegram, Discord, and control-plane issues that can be reproduced on a
  supported source install or Linux release artifact.
- X/Twitter, XMTP, SMS, voice, and other channel adapters only as
  preview surfaces unless promoted by release notes.
- First-party text web search/fetch issues that can be reproduced in a
  supported agent run.
- Operator-controlled cron and scheduled automation as preview surfaces when
  failures are reproducible through first-party runtime or Web operations paths.
- Bugs accompanied by a redacted support bundle when diagnostics are needed.

Supported with scope:

- The one-line install script (`install.sh`) on the `stable` channel for
  `linux-x86_64`, `linux-arm64`, and `darwin-arm64`. It requires `curl`, `tar`,
  and `python3`, verifies every artifact's SHA-256 against the release manifest,
  and installs into the `~/.lemon` layout. Installing a `preview` or `nightly`
  release requires an explicit `LEMON_VERSION` pin.
- Remote update through `lemon update` for runtimes installed in that layout.
  Update is a non-mutating plan followed by exact-confirm, checksum/size
  verification, archive confinement, atomic symlink flip, private content-free
  receipt, and operator restart. Rollback requires the exact apply
  receipt/digest and verified retained checkpoint. Manual tarball and container
  installs are not managed by the updater. Schema-2 manifests are
  checksum-authenticated but not publisher-signed.
- Multi-arch container images on `ghcr.io/z80dev/lemon` (`amd64`, `arm64`).

Not supported for stable 1.0:

- Windows-native release artifacts.
- macOS `x86_64` release artifacts.
- Unverified platform-specific packaging, including OS package managers
  (Homebrew, apt, AUR) and desktop bundles.
- Hot code upgrades. Applying an update always requires a restart.
- Background or unattended auto-update. `[runtime] auto_update` is read and
  reported only; there is no update timer.
- Signed or notarized macOS binaries.
- Hosted multi-tenant operation.
- Stable support guarantees for preview channel adapters.
- Production-grade scheduling guarantees, external scheduler integrations, or
  unrestricted model-facing cron management.
- First-class browser automation, generated media, image analysis, or TTS/voice
  behavior unless a release note explicitly promotes a narrower path.
- Production support for third-party plugins, public plugin registries,
  sandboxed non-BEAM plugin hosts, unofficial MCP servers, or local model
  endpoints beyond documented OpenAI-compatible configuration. The local BEAM
  extension-host proof only covers explicitly trusted extension paths, tool
  execution through the registry, and built-in conflict precedence.

Security issues should use `SECURITY.md`. General defects should use the bug
report template and include:

- source-dev commit or release artifact version
- operating system and CPU architecture
- install path: source-dev or release-runtime
- support bundle command output or attached reviewed bundle
- expected behavior and actual behavior

Support bundle manifests include the Lemon app version, release name/version,
release channel when available, source/release runtime mode, git commit/branch
state, Elixir/OTP versions, OS, and CPU architecture.

## Required Evidence Files

Keep these release contracts current:

- `docs/release/versioning_and_channels.md`
- `docs/release/deployment_flows.md`
- `.github/workflows/release.yml`
- `.github/workflows/product-smoke.yml`
- `.github/workflows/docs-site.yml`
- `.github/workflows/live-eval.yml`
- `.github/workflows/history-check.yml`
- `.github/workflows/osv-scanner.yml`
- `.github/workflows/release-smoke.yml`
- `scripts/bump_version.sh`
- `scripts/prepare_release_notes`
- `scripts/prepare_product_release`
- `scripts/verify_release_artifacts`
- `scripts/verify_release_runtime_boot`
- `install.sh`
- `scripts/verify_install_script`
