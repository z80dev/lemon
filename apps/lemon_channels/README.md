# LemonChannels

Channel adapter layer for the Lemon AI assistant platform. Provides a pluggable adapter system for external messaging platforms (Telegram, Discord, X/Twitter, XMTP), a router-facing semantic delivery dispatcher, channel-owned presentation state, a reliable outbox delivery queue with retry, chunking, deduplication, and rate limiting, and inbound message normalization that submits canonical `LemonCore.RunRequest` structs to the router.

This app depends only on `lemon_core` (in-umbrella), plus `jason`, `earmark_parser`, `req`, and `nostrum` (runtime: false).

## Architecture Overview

```
                         Inbound Path
              +--------------------------------------+
              |                                      |
  [Platform]  |  Transport  ->  normalize_inbound()  |
  (Telegram,  |  (polling/   ->  RunRequest          |  -> LemonRouter
   Discord,   |   webhook)                           |
   etc.)      |                                      |
              +--------------------------------------+

                    Semantic Outbound Path
              +--------------------------------------+
              |                                      |
  [Router]  ->|  Dispatcher -> Renderer ->           |
              |  PresentationState -> Outbox         |
              |                                      |
              |          ->  deliver()               |  -> [Platform]
              +--------------------------------------+

                       Direct Outbound Path
              +--------------------------------------+
              |                                      |
  [Caller]  ->|  Outbox  ->  Chunker  ->  Dedupe  -> |
              |  (queue)    (split)     (ETS)        |
              |                                      |
              |          ->  RateLimiter -> deliver() |  -> [Platform]
              |             (token bucket)            |
              +--------------------------------------+
```

**Inbound**: Each adapter's transport receives raw events from the external platform, normalizes them into `LemonCore.InboundMessage` structs locally, converts them with `LemonChannels.RunRequestBuilder`, and submits only `LemonCore.RunRequest` structs to the session engine through `LemonCore.RouterBridge.submit_run/1`.

Channel adapters also use `LemonCore.RouterBridge` for busy-session and active-run queries. They must not read router-internal session registries or read models directly.

**Semantic outbound**: Router emits `LemonCore.DeliveryIntent` values into `LemonChannels.Dispatcher`. Channel renderers decide truncation, send-vs-edit, buttons, media batching, and other platform UX details, while `LemonChannels.PresentationState` tracks message ids, pending creates/edits, deferred chunk sets, and post-edit follow-up chunks per `{route, run, surface}` so coalesced Telegram and Discord updates do not lose overflow chunks, leak superseded tails, detach long-answer follow-up chunks from the original prompt thread, enqueue long-answer tails before the final edit ack, or strand those tails or deferred final edits if the ack arrives before they finish staging. Discord streaming snapshots are truncated to one editable message; finalized Discord text is split at the safe 1,900-character outbound size and delivered as an edit plus ordered follow-ups, and repeated identical finals are suppressed when a newer sequence replays the same answer. Final idempotency includes auto-send file metadata so a later final with the same text but newly attached files still delivers those attachments.

**Direct outbound**: Adapter helpers and other low-level callers may still enqueue `OutboundPayload` structs into the Outbox. The Outbox applies chunking (splitting long messages at sentence/word boundaries), deduplication (idempotency keys with a 1-hour TTL), and rate limiting (token bucket per channel/account). Messages are then delivered via the adapter's `deliver/1` callback with exponential-backoff retry on transient failures.

**Script send**: `LemonChannels.ScriptSend` gives shell scripts, cron jobs, and CI a Hermes-style notification path for the promoted Telegram and Discord platforms. It builds direct text or file `OutboundPayload` structs and calls the platform outbound adapter directly without starting inbound transports.

### Delivery Groups

The Outbox preserves FIFO ordering within each "delivery group" while allowing full concurrency across independent groups. A delivery group is identified by the tuple `{channel_id, account_id, peer.kind, peer.id, peer.thread_id}`. When a long message is chunked into multiple parts, all chunks share the same group and are delivered sequentially to prevent reordering.

## Supervision Tree

```
LemonChannels.Application
+-- LemonChannels.Registry                (GenServer - plugin registry)
+-- LemonChannels.PresentationState       (GenServer - message-id/send-vs-edit state)
+-- LemonChannels.Outbox.RateLimiter      (GenServer - token bucket rate limiter)
+-- LemonChannels.Outbox.Dedupe           (GenServer - ETS-based deduplication)
+-- Outbox.WorkerSupervisor               (Task.Supervisor)
+-- LemonChannels.Outbox                  (GenServer - delivery queue)
+-- LemonChannels.AdapterSupervisor       (DynamicSupervisor)
    +-- Telegram.Supervisor               (if configured)
    |   +-- Telegram.AsyncSupervisor      (Task.Supervisor)
    |   +-- Telegram.Transport            (GenServer - long-polling)
    +-- Discord.Supervisor                (if configured)
    |   +-- Discord.Transport             (Nostrum consumer)
    +-- XAPI.TokenManager                 (if configured, GenServer)
    +-- XMTP.Transport                    (if configured, GenServer + Port)
```

Adapters are selected from `config :lemon_channels, :adapters` during application boot. Each adapter runs under the `AdapterSupervisor` DynamicSupervisor; adapter modules may still no-op internally when credentials or transport-specific enablement are absent.

```elixir
config :lemon_channels,
  adapters: [
    LemonChannels.Adapters.Telegram,
    LemonChannels.Adapters.Discord,
    LemonChannels.Adapters.Xmtp
  ]
```

## Plugin System

All channel adapters implement the `LemonChannels.Plugin` behaviour, which defines six callbacks:

| Callback | Return | Purpose |
|----------|--------|---------|
| `id/0` | `String.t()` | Unique channel identifier (e.g. `"telegram"`, `"discord"`) |
| `meta/0` | `map()` | Label, capabilities map, and docs URL |
| `child_spec/1` | `Supervisor.child_spec()` | OTP child spec for the adapter's supervision subtree |
| `normalize_inbound/1` | `{:ok, InboundMessage.t()} \| {:error, term()}` | Convert raw platform data to normalized inbound message |
| `deliver/1` | `{:ok, term()} \| {:error, term()}` | Deliver an `OutboundPayload` to the external platform |
| `gateway_methods/0` | `[map()]` | Control plane methods exposed through the gateway |

```elixir
defmodule MyAdapter do
  @behaviour LemonChannels.Plugin

  @impl true
  def id, do: "my_adapter"

  @impl true
  def meta do
    %{
      label: "My Adapter",
      capabilities: %{
        chunk_limit: 4096,
        rate_limit: 30,
        edit_support: true,
        delete_support: false,
        voice_support: false,
        image_support: false,
        file_support: false,
        reaction_support: false,
        thread_support: false
      },
      docs: "https://example.com/docs"
    }
  end

  @impl true
  def child_spec(opts) do
    %{id: __MODULE__, start: {MyAdapter.Supervisor, :start_link, [opts]}, type: :supervisor}
  end

  @impl true
  def normalize_inbound(raw), do: {:ok, %LemonCore.InboundMessage{...}}

  @impl true
  def deliver(payload), do: {:ok, delivery_ref}

  @impl true
  def gateway_methods, do: []
end
```

### Capabilities

Each adapter declares its capabilities in `meta/0`. The `LemonChannels.Capabilities` module defines:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `chunk_limit` | integer | `4096` | Maximum characters per message |
| `rate_limit` | integer or nil | `nil` | Messages per time window |
| `edit_support` | boolean | `false` | Can edit sent messages |
| `delete_support` | boolean | `false` | Can delete sent messages |
| `voice_support` | boolean | `false` | Can handle voice/audio |
| `image_support` | boolean | `false` | Can send/receive images |
| `file_support` | boolean | `false` | Can send/receive files |
| `reaction_support` | boolean | `false` | Can add reactions |
| `thread_support` | boolean | `false` | Supports threaded conversations |

### Registry

The `LemonChannels.Registry` GenServer manages adapter registration and lookup:

```elixir
# Register / unregister
LemonChannels.Registry.register(MyAdapter)
LemonChannels.Registry.unregister("my_adapter")
LemonChannels.Registry.logout("telegram")  # stop + unregister

# Lookup
LemonChannels.Registry.get_plugin("telegram")       # module | nil
LemonChannels.Registry.get_meta("telegram")          # meta map | nil
LemonChannels.Registry.get_capabilities("telegram")  # capabilities map | nil

# Status
LemonChannels.Registry.list_plugins()  # [module()]
LemonChannels.Registry.list()          # [{channel_id, info_map}]
LemonChannels.Registry.status()        # %{configured: [...], connected: [...]}
```

Adapter runtime status (`running`/`stopped` and `connected`) is derived from live `AdapterSupervisor` children by matching each plugin's child start module.

### Top-Level Facade

The `LemonChannels` module delegates to the Registry and Outbox:

```elixir
LemonChannels.get_plugin("telegram")   # Registry.get_plugin/1
LemonChannels.list_plugins()            # Registry.list_plugins/0
LemonChannels.enqueue(payload)          # Outbox.enqueue/1
```

### Script Notifications

Use `mix lemon.send` or the source wrapper `./bin/lemon send` to send a text notification or up to 10 file attachments from scripts:

```bash
./bin/lemon send --to telegram:<chat_id> "deploy finished"
echo "RAM 92%" | ./bin/lemon send --to telegram:<chat_id>
./bin/lemon send --to telegram:<chat_id>:<thread_id> --subject "[CI]" --file report.txt
./bin/lemon send --to discord:<channel_id> "deploy finished"
./bin/lemon send --to discord:#ops "deploy finished"
./bin/lemon send --to discord:#ops:deploys "deploy finished"
./bin/lemon send --account work --to discord:#ops "deploy finished"
./bin/lemon send --to discord:#ops --thread deploys "deploy finished"
./bin/lemon send --to discord:#ops --reply-to 123456789 "deploy finished"
./bin/lemon send --to telegram:<chat_id> --attach report.txt --attach trace.log "deploy report"
./bin/lemon send --dry-run --to discord:#ops --attach report.txt "validate only"
./bin/lemon send --list --json
./bin/lemon send --list telegram
./bin/lemon send --account work --list telegram
```

Target forms are `telegram:<chat_id>[:thread_id]` and `discord:<channel_id>[:thread_id]`. Platform-only targets use `LEMON_TELEGRAM_DEFAULT_CHAT_ID`, `LEMON_DISCORD_DEFAULT_CHANNEL_ID`, and optional `LEMON_TELEGRAM_DEFAULT_THREAD_ID` / `LEMON_DISCORD_DEFAULT_THREAD_ID` first, then durable config fallbacks from `[gateway.telegram] default_chat_id`, `default_thread_id`, `default_topic_id`, `[gateway.discord] default_channel_id`, and `default_thread_id`. Default account ids use `LEMON_TELEGRAM_DEFAULT_ACCOUNT_ID` / `LEMON_DISCORD_DEFAULT_ACCOUNT_ID` first, then `[gateway.telegram] default_account_id` and `[gateway.discord] default_account_id`, so named-target resolution can be account-scoped without repeating `--account`. `--thread <id-or-name>` and Telegram-friendly `--topic <id-or-name>` set the thread/topic separately from `--to`; specifying a thread in both places fails as a usage error. `--reply-to <message-id>` sets `OutboundPayload.reply_to` so Telegram/Discord adapters can reply under an existing platform message. `--account <id>` selects the channel account for outbound payloads and scopes known-target listing/name resolution so duplicate names in other bot/workspace accounts do not make a valid account-scoped target ambiguous. List mode includes env/config defaults plus recent Telegram chats/topics captured in `LemonChannels.Telegram.KnownTargetStore` and Discord channels/threads captured in `LemonChannels.Discord.KnownTargetStore` as bounded `known_targets` metadata with `known_target_count`, `known_targets_truncated`, and exact reusable `aliases` for named targets. Telegram can resolve unique known names with `telegram:#chat`, `telegram:@username`, `telegram:#chat:topic-name`, or `telegram:<chat_id>:topic-name`; Discord can resolve unique known names with `discord:#channel`, `discord:#channel:thread-name`, or `discord:<channel_id>:thread-name`; missing or ambiguous names fail as usage errors. `--dry-run` validates target parsing, known-name/default resolution, body/caption resolution, and attachment metadata without sending or requiring Telegram/Discord credentials. `--file` reads the message body from a file and does not upload an attachment. `--attach` uploads a local file through the existing Telegram/Discord file-delivery adapters and can be repeated up to 10 times, using positional text, `--file`, or stdin as the caption.
Use `--file -` to force stdin.
`--json` returns bounded delivery metadata, including `dry_run`, `message_id`, `extra_message_ids`, `attachment_filename`, `attachment_filenames`, `attachment_count`, and `attachment_bytes` when available, but not the raw message body, raw attachment paths, or full platform response. Batch Telegram file sends preserve the first delivered id as `message_id` and remaining ids as `extra_message_ids`.
Exit code `0` means send/list/help succeeded, `1` means platform delivery failed, and `2` means usage, argument, or local config/input failed.

## Semantic Rendering

`LemonChannels.Dispatcher` is the router-facing entrypoint for semantic delivery. It selects a renderer from `DeliveryIntent.route.channel_id`, lets that renderer turn semantic output into platform operations, and relies on `LemonChannels.PresentationState` to keep platform message-id tracking inside `lemon_channels`.

This ownership boundary matters: channels own truncation, send-vs-edit behavior, tool-status rendering, file/media batching, and Telegram message-id indices. Rendering should be a projection of canonical events plus channel capabilities. Router owns run semantics, session defaults, and prompt rewriting. In particular, pending compaction prompt mutation happens in the router submission path, not in channel transports.

## Outbox Pipeline

The Outbox (`LemonChannels.Outbox`) is a GenServer-based delivery queue.

### Enqueue

```elixir
alias LemonChannels.{OutboundPayload, Outbox}

payload = OutboundPayload.text(
  "telegram",           # channel_id
  "default",            # account_id
  %{kind: :dm, id: "123456", thread_id: nil},  # peer
  "Hello, world!",      # content
  idempotency_key: "msg-123"
)

{:ok, ref} = Outbox.enqueue(payload)
```

### Payload Kinds

| Kind | Constructor | Description |
|------|-------------|-------------|
| `:text` | `OutboundPayload.text/5` | Send a new text message |
| `:edit` | `OutboundPayload.edit/6` | Edit an existing message |
| `:delete` | -- | Delete a message |
| `:reaction` | -- | Add a reaction |
| `:file` | -- | Send a file |
| `:voice` | -- | Send a voice message |

### Delivery Acknowledgment

Set `notify_pid` and `notify_ref` on a payload to receive a message when delivery completes or fails:

```elixir
ref = make_ref()
payload = %{payload | notify_pid: self(), notify_ref: ref}
{:ok, _} = Outbox.enqueue(payload)

receive do
  {:outbox_delivered, ^ref, result} -> result
end
```

### Subcomponents

| Module | Purpose |
|--------|---------|
| `Outbox.Chunker` | Splits long messages at sentence/word boundaries respecting per-channel `chunk_limit` |
| `Outbox.Dedupe` | ETS-based deduplication using idempotency keys with a 1-hour TTL and periodic cleanup |
| `Outbox.RateLimiter` | Token bucket algorithm (GenServer), per channel/account, default 30 msg/sec with burst of 5 |

### Retry Behavior

- Exponential backoff: 1s, 2s, 4s (3 max attempts by default)
- 429 responses: parses `retry_after` from JSON `parameters.retry_after` or body text
- Non-retryable errors: `:unknown_channel`, 4xx HTTP errors (except 429), worker exits
- Max queue size: 5000 (configurable)

### Stats

```elixir
Outbox.stats()
# %{queue_length: 0, processing_count: 0, queue_depth: 0, max_queue_size: 5000, enqueued_total: 42}
```

### Rate Limit Status

```elixir
LemonChannels.Outbox.RateLimiter.status("telegram", "default")
# %{tokens: 28.5, rate: 30, burst: 5}

LemonChannels.Outbox.RateLimiter.check("telegram", "default")
# :ok | {:rate_limited, wait_ms}
```

## Supported Channels

### Telegram

**Plugin ID**: `"telegram"` | **Chunk limit**: 4096 | **Rate limit**: 30 msg/sec

The most mature adapter. Supports edit, delete, voice, images, files, reactions, and threads.

#### Module Layout

**Adapter modules** (`lib/lemon_channels/adapters/telegram/`):

| Module | Purpose |
|--------|---------|
| `Telegram` (plugin) | Plugin behaviour implementation, id/meta/child_spec/deliver |
| `Telegram.Supervisor` | Starts `AsyncSupervisor` (Task.Supervisor) and `Transport` |
| `Telegram.Transport` | Long-polling GenServer via `getUpdates`, command handling, inbound routing |
| `Telegram.Transport.ApprovalRequest` | Approval-request rendering and callback payload helpers for exec approvals |
| `Telegram.Transport.CallbackHandler` | Inline keyboard callback handling for approvals and model-picker flows |
| `Telegram.Transport.ChatPreferences` | Trigger gating plus `/trigger`, `/thinking`, and `/cwd` command handling |
| `Telegram.Transport.Poller` | Poll loop and update dispatch extracted from `Transport` |
| `Telegram.Transport.CommandRouter` | Command/message decision tree extracted from `Transport` |
| `Telegram.Transport.Commands` | Pure functions for command detection, scope keys, message joining |
| `Telegram.Transport.FileOperations` | `/file put`/`get` commands, auto-put for document uploads, media group file handling |
| `Telegram.Transport.InboundActions` | Router submission path for normal inbound messages, including progress reactions and session metadata |
| `Telegram.Transport.InboundContext` | Normalized transport event context shared across normalize/pipeline/action-runner |
| `Telegram.Transport.MediaGroups` | Media group coalescence with debounce timer |
| `Telegram.Transport.MemoryReflection` | `/new` memory-reflection transcript assembly and prompt generation |
| `Telegram.Transport.MessageBuffer` | Debounce buffering for rapid-fire user messages |
| `Telegram.Transport.ModelPicker` | `/model` picker flow, provider/model pagination, and selection-state transitions |
| `Telegram.Transport.Normalize` | Raw update/timer normalization into Telegram-local inbound context |
| `Telegram.Transport.PerChatState` | Telegram per-thread state, generation bookkeeping, and last-engine helpers |
| `Telegram.Transport.Pipeline` | Telegram-local ingress coordinator for normalized events and emitted actions |
| `Telegram.Transport.RuntimeState` | Helper for adapter-owned runtime state without a dedicated struct migration |
| `Telegram.Transport.SessionRouting` | Session-key derivation, reply routing, and parallel-session bookkeeping |
| `Telegram.Transport.TopicCommand` | `/topic` command handler extracted from the transport shell |
| `Telegram.Transport.UpdateProcessor` | Authorization, dedup, routing pipeline, known-target indexing, engine directive parsing |
| `Telegram.Transport.VoiceHandler` | Voice-download and transcription orchestration before normal inbound routing |
| `Telegram.Renderer` | Telegram semantic renderer for stream snapshots, finals, edits, and presentation-state-aware delivery |
| `Telegram.StatusRenderer` | Telegram-specific tool-status formatting and controls rendering |
| `Telegram.FileBatcher` | Telegram media/file batching strategy for renderer-owned outbound UX |
| `Telegram.Inbound` | Normalizes raw Telegram updates to `InboundMessage` |
| `Telegram.Outbound` | Delivers via Bot API with retry for rate limits and transient errors |
| `Telegram.VoiceTranscriber` | OpenAI-compatible audio transcription |

**Support modules** (`lib/lemon_channels/telegram/`):

| Module | Purpose |
|--------|---------|
| `Telegram.API` | Raw Bot API calls: send_message, edit_message_text, get_updates, send_document, send_photo, send_media_group, etc. |
| `Telegram.Delivery` | High-level enqueue helpers: `enqueue_send/3`, `enqueue_edit/3` backed by Outbox |
| `Telegram.Formatter` | Converts markdown to plain text + Telegram entities (avoids fragile MarkdownV2 escaping) |
| `Telegram.Markdown` | EarmarkParser-based AST renderer producing Telegram entity format with UTF-16 offsets |
| `Telegram.ResumeIndexStore` | Typed wrapper for Telegram message-id resume/session indices |
| `Telegram.StateStore` | Typed wrapper for Telegram per-session/per-topic preference state |
| `Telegram.Truncate` | Truncates messages to 4096 chars preserving resume lines |
| `Telegram.TriggerMode` | Per-chat/topic `:all` vs `:mentions` mode (ETS-backed) |
| `Telegram.OffsetStore` | Persists `getUpdates` offset via `LemonCore.Store` |
| `Telegram.PollerLock` | Global + file-based lock to prevent duplicate pollers for the same account/token |
| `Telegram.TransportShared` | Shared deduplication helpers across transport modules |

#### Transport Commands

| Command | Description |
|---------|-------------|
| `/new` | Start a new session (acknowledges immediately, cleans up async) |
| `/resume` | Resume a previous session |
| `/model` | Interactive provider/model picker via reply keyboard |
| `/goal` | Preview durable goal status/set with optional max-continuation budget/pause/resume/continue/loop controls, opt-in auto loop scheduling, and clear for the current session |
| `/kanban` | Preview durable kanban board/task/archive/dispatcher controls with redacted board/task output |
| `/checkpoint` | Preview checkpoint status with redacted lifecycle event counts, redacted event history, redacted diff count, pushed active-run checkpoint event notices, and restore via `/checkpoint restore <id> confirm` |
| `/rollback` | Hermes-style alias for preview checkpoint rollback, including `/rollback diff <id>` and `/rollback <id> confirm` |
| `/media` | Preview generated-media job status with redacted type/status/artifact counts and cleanup policy |

The Telegram picker should only surface models that are healthy enough for the
current transport UX. Known-bad variants may remain in provider registries for
manual use, but the picker should filter them out and prefer task-capable
Google preview variants over dead or weaker direct IDs.
| `/thinking` | Toggle extended thinking |
| `/trigger` | Switch between `:all` and `:mentions` mode |
| `/cwd` | Set working directory |
| `/file` | File put/get operations |
| `/topic` | Topic management |
| `/cancel` | Cancel the current run |

#### Generation-Scoped Indexing

Session and resume indices are scoped by a generation counter. `/new` increments the generation for `{account_id, chat_id, thread_id}`, instantly invalidating stale reply mappings without full-table scans.

#### `/model` Picker Behavior

`/model` uses a reply keyboard (bottom keyboard) flow for per-user selection in a chat/topic: provider -> model -> scope (`This session` or `All future sessions`). `This session` writes the current session override; `All future sessions` writes a chat-wide default even when invoked from a topic. Selection messages are intercepted by transport state and are not routed as normal inbound prompts. Provider/model lists are paginated in-keyboard with `<< Prev` / `Next >>`, plus `< Back` / `Close`. The model step accepts either the exact button label or raw model ids such as `gpt-5.4` and `provider:model_id`.

#### Ownership Note

Telegram transport owns Telegram-specific command UX, buffering, auth, and routing preparation. It does not own pending-compaction prompt mutation; router is the sole owner of rewriting the next inbound prompt for compaction recovery.

#### Delivery Helpers

```elixir
alias LemonChannels.Telegram.Delivery

Delivery.enqueue_send(chat_id, "Hello", thread_id: topic_id)

# With delivery notification
ref = make_ref()
Delivery.enqueue_send(chat_id, "Hello", notify: {self(), ref})
receive do
  {:outbox_delivered, ^ref, result} -> result
end
```

#### Formatter

Avoids fragile MarkdownV2 escaping -- renders markdown to plain text with Telegram entities:

```elixir
{text, opts} = LemonChannels.Telegram.Formatter.prepare_for_telegram(markdown_string)
# opts is nil or %{entities: [...]} suitable for Telegram.API.send_message/4
```

#### TriggerMode

Controls whether the bot responds to all messages or only mentions in a chat/topic:

```elixir
scope = %LemonCore.ChatScope{transport: :telegram, chat_id: 123, topic_id: 456}
LemonChannels.Telegram.TriggerMode.set(scope, account_id, :mentions)

%{mode: :mentions, source: :topic} =
  LemonChannels.Telegram.TriggerMode.resolve(account_id, chat_id, topic_id)
```

#### Voice Transcription

Configured via transport config. Uses OpenAI-compatible API:

```elixir
LemonChannels.Adapters.Telegram.VoiceTranscriber.transcribe(%{
  audio_bytes: binary,
  api_key: key,
  base_url: "https://api.openai.com/v1",
  model: "gpt-4o-mini-transcribe",
  mime_type: "audio/ogg"
})
```

#### Configuration

Add `LemonChannels.Adapters.Telegram` to `config :lemon_channels, :adapters`. Required: Telegram bot token (via `LemonCore.Secrets` or env vars).

### Discord

**Plugin ID**: `"discord"` | **Chunk limit**: 2000

Supports edit, delete, images, files, and threads.

#### Module Layout

| Module | Purpose |
|--------|---------|
| `Discord` (plugin) | Plugin behaviour implementation |
| `Discord.Supervisor` | Starts transport if bot_token is configured |
| `Discord.Transport` | Nostrum consumer, slash command handling, component interactions, and inbound RunRequest submission |
| `Discord.Inbound` | Normalizes Discord message events to `InboundMessage`, handles attachments |
| `Discord.Renderer` | Semantic renderer for status controls, thread-aware replies, and finalize-time auto-send files |
| `Discord.StatusRenderer` | Builds Discord button rows for cancel/keep-waiting UX |
| `Discord.Outbound` | Delivers via `Nostrum.Api.Message` (create, edit, delete, reaction, multipart file upload) |

#### Slash Commands

- `/lemon` -- general interaction
- `/session new` -- start a new session
- `/session info` -- session information
- `/goal status`, `/goal set` with optional `max_continuations`, `/goal pause`, `/goal resume`, `/goal continue`, `/goal loop_once`/`loop_start` with optional `auto`/`loop_status`/`loop_stop`, `/goal clear` -- preview durable goal state
- `/kanban boards`, `/kanban create`, `/kanban show`, `/kanban archive`, `/kanban task_create`, `/kanban task_update`, `/kanban comment`, `/kanban dispatch_start`/`dispatch_status`/`dispatch_stop` -- preview durable kanban state
- `/checkpoint status`, `/checkpoint events limit:<n>`, `/checkpoint diff checkpoint_id:<id>`, `/checkpoint restore checkpoint_id:<id> confirm:true` -- preview checkpoint rollback controls with redacted lifecycle event counts/history, pushed active-run event notices, and redacted chat output
- `/rollback status`, `/rollback events limit:<n>`, `/rollback diff checkpoint_id:<id>`, `/rollback restore checkpoint_id:<id> confirm:true` -- Hermes-style alias for the same preview checkpoint rollback controls
- `/media status` -- preview generated-media job status with redacted type/status/artifact counts and cleanup policy

#### Delivery Notes

- Shared-channel debounce buffering is keyed by channel, thread, and session/user identity so rapid messages from different Discord users do not get merged into one run.
- Discord inbound message dedupe uses the fast ETS table plus a persisted idempotency mark so duplicate `MESSAGE_CREATE` events still suppress a second run after transport ETS state is lost.
- Discord `/trigger all` enables free-response routing for unmentioned group messages in the channel or thread scope; `/trigger mentions` restores the default mention-gated behavior. Thread messages that arrive from Discord without parent-channel context also honor the stored thread trigger key. Live free-response promotion requires Discord's privileged Message Content Intent and now has a passing external-sender proof.
- Discord ignores its own bot messages and webhooks. External bot-authored messages are normalized with sender bot metadata and can route when normal trigger policy allows them, but broad external-bot support still needs live proof before promotion.
- Routed status messages use Discord buttons for cancel and keep-waiting controls.
- Finalized Discord runs can auto-send files generated by the agent as real Discord attachments instead of path notices.
- Generated-file auto-send requires `[gateway.discord.files] enabled = true`
  and `auto_send_generated_files = true` (or legacy
  `auto_send_generated_images = true`), and is bounded by
  `auto_send_generated_max_files` plus `max_download_bytes`. Explicit
  file-send requests still use the normal attachment path.

#### Configuration

Add `LemonChannels.Adapters.Discord` to `config :lemon_channels, :adapters`. Required: Discord bot token. Uses the `nostrum` library (declared as `runtime: false` dep; runtime availability is expected from the deployment environment).

### X (Twitter) API

**Plugin ID**: `"x_api"` | **Chunk limit**: 280 | **Rate limit**: 2400/day

Supports edit, delete, images, threads, mentions, and read-only recent public search. Primarily outbound (posting tweets). Uses X API v2.

#### Module Layout

| Module | Purpose |
|--------|---------|
| `XAPI` (plugin) | Plugin behaviour, config management, auth method detection |
| `XAPI.Client` | HTTP client for API v2: tweet posting/deletion, recent public search, chunked media upload, rate limit handling |
| `XAPI.OAuth1Client` | OAuth 1.0a implementation with HMAC-SHA1 signatures |
| `XAPI.OAuth` | OAuth 2.0 flow helpers (authorization URL, code exchange, PKCE) |
| `XAPI.TokenManager` | GenServer for automatic OAuth 2.0 token refresh |
| `XAPI.OAuthCallbackHandler` | HTTP handler for OAuth 2.0 callbacks |
| `XAPI.GatewayMethods` | Control plane methods: `x_api.post_tweet`, `x_api.get_mentions`, `x_api.reply_to_tweet` |

#### Authentication

The adapter supports two auth methods and auto-detects which to use:

**Read-only search**: `X_API_BEARER_TOKEN` is enough for `x_search`.

**OAuth 2.0**: `X_API_CLIENT_ID`, `X_API_CLIENT_SECRET`, `X_API_ACCESS_TOKEN`, `X_API_REFRESH_TOKEN`, `X_API_BEARER_TOKEN`

**OAuth 1.0a**: `X_API_CONSUMER_KEY`, `X_API_CONSUMER_SECRET`, `X_API_ACCESS_TOKEN`, `X_API_ACCESS_TOKEN_SECRET`

**Common**: `X_DEFAULT_ACCOUNT_ID`, `X_DEFAULT_ACCOUNT_USERNAME`

Config can also be set via `config :lemon_channels, LemonChannels.Adapters.XAPI`. Secrets are resolved through `LemonCore.Secrets` by default.

### XMTP

**Plugin ID**: `"xmtp"` | **Chunk limit**: 2000

Web3 messaging adapter. Supports threads only (no edit, delete, voice, images, files, or reactions).

#### Module Layout

| Module | Purpose |
|--------|---------|
| `XMTP` (plugin) | Plugin behaviour implementation |
| `XMTP.Transport` | GenServer for message send/receive, `normalize_inbound_message/1`, `deliver/1` |
| `XMTP.Bridge` | Communication with the Node.js bridge (connect, poll, send_message) |
| `XMTP.PortServer` | Port process management for the Node.js bridge subprocess |

XMTP uses a Node.js bridge process managed via an Erlang Port. The bridge handles the XMTP protocol specifics while the Elixir side manages lifecycle, message normalization, and delivery through the standard plugin interface.

#### Configuration

Add `LemonChannels.Adapters.Xmtp` to `config :lemon_channels, :adapters`. The XMTP transport still checks `enable_xmtp: true` before starting its bridge.

## Adding a New Channel Adapter

1. **Create the adapter module** in `lib/lemon_channels/adapters/my_channel.ex` implementing all 6 `LemonChannels.Plugin` callbacks.

2. **Create the supervisor and transport** if the adapter needs to receive inbound messages (polling or webhook).

3. **Configure the adapter** in `config :lemon_channels, :adapters`:

```elixir
config :lemon_channels,
  adapters: [
    LemonChannels.Adapters.MyChannel
  ]
```

4. **Add configuration** in gateway config for adapter-specific settings.

5. **Add tests** following the existing adapter test patterns in `test/lemon_channels/adapters/`.

## Configuration

### Gateway Config

Adapter module startup is selected by `config :lemon_channels, :adapters`. Runtime gateway settings still come from `LemonChannels.GatewayConfig`, a thin delegation to `LemonCore.GatewayConfig`.

Common gateway config keys:

| Key | Type | Description |
|-----|------|-------------|
| `enable_xmtp` | boolean | Enable/disable the XMTP bridge after the adapter is configured |
| `default_engine` | string | Default session engine |
| `bindings` | list | Chat scope to project/engine/agent bindings |
| `projects` | map | Project definitions |

### Binding Resolution

`LemonChannels.BindingResolver` maps chat scopes to projects, engines, agents, and working directories. It delegates to `LemonCore.BindingResolver` after converting channels-local structs to core types.

```elixir
scope = %LemonCore.ChatScope{transport: :telegram, chat_id: 123, topic_id: 456}

binding = LemonChannels.BindingResolver.resolve_binding(scope)
# %Binding{project: "my_project", agent_id: "coder", default_engine: "claude", ...}

engine  = LemonChannels.BindingResolver.resolve_engine(scope, engine_hint, resume)
agent   = LemonChannels.BindingResolver.resolve_agent_id(scope)
cwd     = LemonChannels.BindingResolver.resolve_cwd(scope)
mode    = LemonChannels.BindingResolver.resolve_queue_mode(scope)
```

Engine resolution priority: resume token > engine hint > binding default > project default > global default.

### Engine Registry

`LemonCore.EngineCatalog` is the shared validation/normalization boundary for known engine IDs.
`LemonChannels.EngineRegistry` remains only as a compatibility shim for resume parsing that may defer to `LemonGateway.EngineRegistry` when custom engine modules are present.

```elixir
LemonCore.EngineCatalog.known?("claude")  # true
LemonCore.EngineCatalog.normalize(" Claude ") # "claude"

{:ok, %ResumeToken{engine: "claude", value: "abc123"}} =
  LemonChannels.EngineRegistry.extract_resume("claude --resume abc123")

LemonCore.ResumeToken.format_plain(%ResumeToken{engine: "claude", value: "abc123"})
# "claude --resume abc123"
```

Default known engines: `lemon`, `echo`, `codex`, `claude`, `droid`, `opencode`, `pi`, `kimi`. Override the shared list via `config :lemon_core, :known_engines`.

### Runtime Bridge

`LemonChannels.Runtime` provides thin wrappers to interact with router-owned run lifecycle APIs without a hard compile-time dependency. Busy checks go through `LemonCore.RouterBridge.session_busy?/1` rather than reaching into router internals directly:

```elixir
LemonChannels.Runtime.cancel_session(session_key)
LemonChannels.Runtime.cancel_by_run_id(run_id)
LemonChannels.Runtime.cancel_by_progress_msg(session_key, progress_msg_id)
LemonChannels.Runtime.keep_run_alive(run_id, :continue | :cancel)
LemonChannels.Runtime.session_busy?(session_key)
```

## Application Lifecycle

```elixir
# Register and start an adapter (idempotent)
LemonChannels.Application.register_and_start_adapter(MyAdapter)
LemonChannels.Application.register_and_start_adapter(MyAdapter, opts)

# Start/stop without re-registering
LemonChannels.Application.start_adapter(MyAdapter)
LemonChannels.Application.stop_adapter(MyAdapter)
```

Adapters run under `LemonChannels.AdapterSupervisor` (DynamicSupervisor).

## Telemetry Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[:lemon, :channels, :deliver, :start]` | `%{system_time: ...}` | channel_id, account_id, chunk_index |
| `[:lemon, :channels, :deliver, :stop]` | `%{duration: ...}` | channel_id, account_id, ok |
| `[:lemon, :channels, :deliver, :exception]` | `%{duration: ...}` | channel_id, kind, reason, stacktrace |
| `[:lemon, :channels, :outbox, :queue]` | `%{depth: ..., count: 1}` | event, chunk_count |
| `[:lemon, :channels, :outbox, :rejected]` | `%{count: 1, queue_depth: ...}` | reason, channel_id |
| `[:lemon, :channels, :inbound]` | `%{count: 1}` | channel_id |

## Module Inventory

### Top-Level

| Module | Purpose |
|--------|---------|
| `LemonChannels` | Public API: `get_plugin/1`, `list_plugins/0`, `enqueue/1` |
| `LemonChannels.Application` | OTP application, supervision tree, adapter lifecycle |
| `LemonChannels.Dispatcher` | Router-facing semantic delivery entrypoint |
| `LemonChannels.Plugin` | Behaviour definition (6 callbacks) |
| `LemonChannels.Registry` | GenServer plugin registry with status tracking |
| `LemonChannels.Capabilities` | Capability type definitions and defaults |
| `LemonChannels.PresentationState` | Channels-owned message-id/send-vs-edit state per `{route, run, surface}` |
| `LemonChannels.OutboundPayload` | Core delivery struct with constructors |
| `LemonChannels.BindingResolver` | Chat scope to binding resolution (delegates to LemonCore) |
| `LemonChannels.EngineRegistry` | Compatibility resume-token parsing shim for custom gateway engines |
| `LemonChannels.GatewayConfig` | Thin delegation to `LemonCore.GatewayConfig` |
| `LemonChannels.Runtime` | Runtime bridge for session/run cancel, keepalive, and busy checks via `LemonCore.RouterBridge` |
| `LemonChannels.Cwd` | Working directory resolution |
| `LemonChannels.Types` | ChatScope and other shared type definitions |

### Outbox

| Module | Purpose |
|--------|---------|
| `LemonChannels.Outbox` | GenServer delivery queue with retry |
| `LemonChannels.Outbox.Chunker` | Message splitting at sentence/word boundaries |
| `LemonChannels.Outbox.Dedupe` | ETS-based deduplication (1h TTL) |
| `LemonChannels.Outbox.RateLimiter` | Token bucket rate limiter |

### Telegram

| Module | Purpose |
|--------|---------|
| `Adapters.Telegram` | Plugin behaviour implementation |
| `Adapters.Telegram.Supervisor` | Starts AsyncSupervisor and Transport |
| `Adapters.Telegram.Transport` | Long-polling GenServer, command handling |
| `Adapters.Telegram.Transport.Poller` | Poll loop + update dispatch |
| `Adapters.Telegram.Transport.CommandRouter` | Command/message routing tree |
| `Adapters.Telegram.Transport.Commands` | Command detection, scope keys |
| `Adapters.Telegram.Transport.FileOperations` | File put/get, document uploads |
| `Adapters.Telegram.Transport.MediaGroups` | Media group coalescence |
| `Adapters.Telegram.Transport.MessageBuffer` | Debounce buffering |
| `Adapters.Telegram.Renderer` | Telegram semantic renderer for send-vs-edit delivery |
| `Adapters.Telegram.StatusRenderer` | Telegram tool-status controls and text rendering |
| `Adapters.Telegram.FileBatcher` | Telegram-specific file/media batching |
| `Adapters.Telegram.Transport.UpdateProcessor` | Auth, dedup, routing pipeline |
| `Adapters.Telegram.Inbound` | Normalize to InboundMessage |
| `Adapters.Telegram.Outbound` | Deliver via Bot API |
| `Adapters.Telegram.VoiceTranscriber` | Audio transcription |
| `Telegram.API` | Raw Bot API calls |
| `Telegram.Delivery` | High-level enqueue helpers |
| `Telegram.Formatter` | Markdown to entities |
| `Telegram.KnownTargetStore` | Typed wrapper for Telegram known-target chat/topic metadata |
| `Telegram.Markdown` | AST renderer for entities |
| `Telegram.Truncate` | Message truncation |
| `Telegram.TriggerMode` | Per-chat trigger mode |
| `Telegram.OffsetStore` | getUpdates offset persistence |
| `Telegram.PollerLock` | Duplicate poller prevention |
| `Telegram.TransportShared` | Shared dedupe helpers |

### Discord

| Module | Purpose |
|--------|---------|
| `Adapters.Discord` | Plugin behaviour implementation |
| `Adapters.Discord.Supervisor` | Starts transport if configured |
| `Adapters.Discord.Transport` | Nostrum consumer, slash commands, component interactions, debounce buffering |
| `Adapters.Discord.Inbound` | Normalize to InboundMessage |
| `Adapters.Discord.Renderer` | Semantic delivery renderer |
| `Adapters.Discord.StatusRenderer` | Button/control rendering helpers |
| `Adapters.Discord.Outbound` | Deliver via Nostrum API, including multipart file upload |

### X API

| Module | Purpose |
|--------|---------|
| `Adapters.XAPI` | Plugin behaviour, auth detection |
| `XAPI.Client` | HTTP client, tweet operations |
| `XAPI.OAuth1Client` | OAuth 1.0a with HMAC-SHA1 |
| `XAPI.OAuth` | OAuth 2.0 flows, PKCE |
| `XAPI.TokenManager` | Automatic token refresh |
| `XAPI.OAuthCallbackHandler` | OAuth 2.0 callback handler |
| `XAPI.GatewayMethods` | Control plane methods |

### XMTP

| Module | Purpose |
|--------|---------|
| `Adapters.XMTP` | Plugin behaviour implementation |
| `XMTP.Transport` | Message send/receive GenServer |
| `XMTP.Bridge` | Node.js bridge communication |
| `XMTP.PortServer` | Port process management |

## Testing

```bash
# All channel tests
mix test apps/lemon_channels

# Specific adapter tests
mix test apps/lemon_channels/test/lemon_channels/adapters/telegram
mix test apps/lemon_channels/test/lemon_channels/outbox_test.exs
```

### Key Test Files

| Test | Coverage |
|------|----------|
| `outbox_test.exs` | Queue, retry, delivery |
| `outbox_architecture_test.exs` | Per-group ordering, concurrency |
| `outbox_retry_behavior_test.exs` | Retry logic, non-retryable errors |
| `outbox_rate_limiting_test.exs` | Rate limiter |
| `outbox_chunking_test.exs` | Chunking via outbox |
| `chunker_test.exs` | Chunker unit tests |
| `dedupe_test.exs` | Idempotency |
| `telegram/inbound_test.exs` | Inbound normalization |
| `telegram/outbound_test.exs` | Outbound delivery |
| `telegram/voice_transcription_test.exs` | Voice transcription |
| `telegram/delivery_test.exs` | Delivery helper |
| `telegram/markdown_test.exs` | Markdown to entities |
| `telegram/transport_*_test.exs` | Transport behaviors (cancel, offset, auth, dedupe, parallel) |
| `telegram/transport_topic_test.exs` | `/topic` command behavior |
| `telegram/file_transfer_test.exs` | File handling |
| `media_status_message_test.exs` | Telegram `/media` command recognition and redacted status formatting |
| `x_api_test.exs` | X adapter |
| `x_api_client_test.exs` | X API client |
| `x_api_token_manager_test.exs` | Token refresh |

### Mock Adapter Pattern

```elixir
defmodule TestAdapter do
  @behaviour LemonChannels.Plugin
  def id, do: "test"
  def meta, do: %{label: "Test", capabilities: %{chunk_limit: 100}}
  def child_spec(_), do: %{id: __MODULE__, start: {Task, :start_link, [fn -> :ok end]}}
  def normalize_inbound(_), do: {:ok, %LemonCore.InboundMessage{}}
  def deliver(_), do: {:ok, :sent}
  def gateway_methods, do: []
end
```

## Dependencies

| Dependency | Version | Purpose |
|------------|---------|---------|
| `lemon_core` | in_umbrella | Shared primitives: `InboundMessage`, `Store`, `Secrets`, `RouterBridge`, `Dedupe.Ets`, `Telemetry` |
| `jason` | ~> 1.4 | JSON encoding/decoding |
| `earmark_parser` | ~> 1.4 | Markdown parsing (used by `Telegram.Markdown` for rendering to Telegram entities) |
| `req` | ~> 0.5.0 | HTTP client (used by Telegram API, X API, voice transcription) |
| `nostrum` | ~> 0.9 | Discord library (`runtime: false` -- expected from deployment environment) |

## Important Notes

- The Outbox preserves per-delivery-group FIFO ordering; chunked messages from the same payload share a group and are never delivered concurrently
- `GatewayConfig` is a thin delegation to `LemonCore.GatewayConfig`; new code should use the core module directly
- `BindingResolver` delegates to `LemonCore.BindingResolver` after struct conversion
- `Runtime` uses `LemonCore.RouterBridge` for router interaction and returns `:ok`/`false` gracefully when the router is unavailable
- Adapter status is derived from live `DynamicSupervisor` children, not stored state
- The Telegram formatter avoids MarkdownV2 entirely, rendering to plain text + entity arrays instead
- Transport-level known-target indexing throttles writes to 30s per target to avoid Store overload
- Non-retryable delivery errors (`:unknown_channel`, client 4xx except 429, worker exits) are not retried
- `nostrum` is declared `runtime: false` -- the runtime library must be available in the deployment environment for Discord support
