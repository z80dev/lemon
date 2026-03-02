# State Ownership Map

## Overview

Documents every `LemonCore.Store` table and key family, their owning app/module,
access patterns, and migration targets.

`LemonCore.Store` is a GenServer-backed persistent key-value store with pluggable
backends (ETS for dev/test, SQLite for prod). It exposes both **dedicated APIs**
(chat state, run events, progress mappings, policy tables, introspection events)
and a **generic table API** (`put/3`, `get/2`, `delete/2`, `list/1`) that any app
can use with an arbitrary atom table name.

A **ReadCache** (ETS-based) provides fast reads for hot domains: `:chat`, `:runs`,
`:progress`, `:sessions_index`, `:telegram_known_targets`.

---

## Dedicated API Tables

These tables are managed through purpose-built functions on `LemonCore.Store`.

### Table: `:chat`

Chat state with automatic TTL expiry (24h default) and periodic sweep.

| Key Pattern | Owning App | Owning Module(s) | Hot/Cold | Durability | Notes |
|-------------|-----------|-------------------|----------|------------|-------|
| `session_key` (string) | lemon_gateway | `LemonGateway.Run` | Hot | Durable (TTL 24h) | Active conversation state per session |
| `session_key` (string) | lemon_channels | `LemonChannels.Adapters.Telegram.Transport` | Hot | Durable (TTL 24h) | Telegram chat state reads/writes |
| `session_key` (string) | lemon_channels | `LemonChannels.Adapters.Discord.Transport` | Hot | Durable (TTL 24h) | Discord chat state deletes on reset |
| `session_key` (string) | lemon_gateway | `LemonGateway.Scheduler` | Hot | Durable (TTL 24h) | Scheduler reads chat state |
| `session_key` (string) | lemon_router | `LemonRouter.RunProcess.CompactionTrigger` | Hot | Durable (TTL 24h) | Deletes chat state during compaction |

**API**: `put_chat_state/2`, `get_chat_state/1`, `delete_chat_state/1`

### Table: `:runs`

Active run event logs and summaries.

| Key Pattern | Owning App | Owning Module(s) | Hot/Cold | Durability | Notes |
|-------------|-----------|-------------------|----------|------------|-------|
| `run_id` (term) | lemon_gateway | `LemonGateway.Run` | Hot | Durable | Events appended during run, finalized with summary |
| `run_id` (term) | lemon_router | `LemonRouter.AgentDirectory` | Cold | Read-only | Reads run data for directory |
| `run_id` (term) | coding_agent | `CodingAgent.Tools.Agent` | Cold | Read-only | Reads run results for sub-agent coordination |
| `run_id` (term) | lemon_control_plane | Various Methods | Cold | Read-only | UI reads for session detail, run graph, introspection |

**API**: `append_run_event/2`, `finalize_run/2`, `get_run/1`

### Table: `:run_history`

Finalized run history indexed by session key. Written internally by `finalize_run/2`.

| Key Pattern | Owning App | Owning Module(s) | Hot/Cold | Durability | Notes |
|-------------|-----------|-------------------|----------|------------|-------|
| `{session_key, started_at, run_id}` | lemon_core (internal) | `LemonCore.Store` | Cold | Durable | Auto-indexed on finalize_run |
| (read via `get_run_history/2`) | lemon_router | `LemonRouter.Router` | Cold | Read-only | History for context building |
| (read via `get_run_history/2`) | lemon_channels | `LemonChannels.Adapters.Telegram.Transport` | Cold | Read-only | Session history for resume/compaction |
| (read via `get_run_history/2`) | lemon_control_plane | `SessionDetail`, `SessionsPreview`, `ChatHistory` | Cold | Read-only | UI session detail views |
| (delete all) | lemon_control_plane | `SessionsReset`, `SessionsDelete` | Cold | Write | Cleanup on session reset/delete |

**API**: `get_run_history/2`

### Table: `:progress`

Maps progress/status message IDs to run IDs.

| Key Pattern | Owning App | Owning Module(s) | Hot/Cold | Durability | Notes |
|-------------|-----------|-------------------|----------|------------|-------|
| `{scope, progress_msg_id}` | lemon_gateway | `LemonGateway.Run` | Hot | Durable | Written when progress messages are sent |
| `{scope, progress_msg_id}` | lemon_gateway | `LemonGateway.Runtime` | Hot | Read-only | Looked up to find run from progress msg |

**API**: `put_progress_mapping/3`, `get_run_by_progress/2`, `delete_progress_mapping/2`

### Table: `:sessions_index`

Durable session metadata (agent_id, origin, timestamps, run count). Written internally by `finalize_run/2`.

| Key Pattern | Owning App | Owning Module(s) | Hot/Cold | Durability | Notes |
|-------------|-----------|-------------------|----------|------------|-------|
| `session_key` (string) | lemon_core (internal) | `LemonCore.Store` | Hot (cached) | Durable | Auto-updated on finalize_run |
| (read via `list/1`) | lemon_router | `LemonRouter.AgentDirectory` | Cold | Read-only | Lists all sessions |
| (read via `list/1`) | lemon_control_plane | `SessionsList` | Cold | Read-only | UI sessions listing |
| (delete) | lemon_control_plane | `SessionsDelete` | Cold | Write | Cleanup on session delete |

### Table: `:introspection_log`

Canonical introspection events for debugging/observability.

| Key Pattern | Owning App | Owning Module(s) | Hot/Cold | Durability | Notes |
|-------------|-----------|-------------------|----------|------------|-------|
| `{ts_ms, event_id}` | lemon_core | `LemonCore.Introspection` | Cold | Durable (7d retention) | Append-only event log |
| (read via `list_introspection_events/1`) | lemon_control_plane | `RunIntrospectionList` | Cold | Read-only | UI introspection views |

**API**: `append_introspection_event/1`, `list_introspection_events/1`

### Table: `:agent_policies`

Per-agent policy overrides.

| Key Pattern | Owning App | Owning Module(s) | Hot/Cold | Durability | Notes |
|-------------|-----------|-------------------|----------|------------|-------|
| `agent_id` | lemon_router | `LemonRouter.Policy` | Cold | Durable | Read during policy resolution |

**API**: `put_agent_policy/2`, `get_agent_policy/1`, `delete_agent_policy/1`, `list_agent_policies/0`

### Table: `:channel_policies`

Per-channel policy overrides.

| Key Pattern | Owning App | Owning Module(s) | Hot/Cold | Durability | Notes |
|-------------|-----------|-------------------|----------|------------|-------|
| `channel_id` | lemon_router | `LemonRouter.Policy` | Cold | Durable | Read during policy resolution |

**API**: `put_channel_policy/2`, `get_channel_policy/1`, `delete_channel_policy/1`, `list_channel_policies/0`

### Table: `:session_policies`

Per-session policy overrides.

| Key Pattern | Owning App | Owning Module(s) | Hot/Cold | Durability | Notes |
|-------------|-----------|-------------------|----------|------------|-------|
| `session_key` | lemon_router | `LemonRouter.RunOrchestrator` | Cold | Durable | Set/read for session-level overrides |
| `session_key` | lemon_router | `LemonRouter.Policy` | Cold | Read-only | Read during policy resolution |
| `session_key` | lemon_control_plane | `SessionsPatch` | Cold | Write | UI sets session policies |

**API**: `put_session_policy/2`, `get_session_policy/1`, `delete_session_policy/1`, `list_session_policies/0`

### Table: `:runtime_policy`

Global runtime policy overrides (singleton key `:global`).

| Key Pattern | Owning App | Owning Module(s) | Hot/Cold | Durability | Notes |
|-------------|-----------|-------------------|----------|------------|-------|
| `:global` | lemon_router | `LemonRouter.Policy` | Cold | Durable | Global policy fallback |

**API**: `put_runtime_policy/1`, `get_runtime_policy/0`, `delete_runtime_policy/0`, `list_runtime_policies/0`

---

## Generic Table API Tables

These tables are accessed via `Store.put/3`, `Store.get/2`, `Store.delete/2`, `Store.list/1`.

### Core State Tables

#### Table: `:secrets_v1`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `{owner, name}` | lemon_core | `LemonCore.Secrets` | Cold | Durable | Encrypted secrets store; owner is `:global` or agent_id |

#### Table: `:idempotency`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `{namespace, key}` | lemon_core | `LemonCore.Idempotency` | Cold | Durable | Idempotency tokens with TTL |

#### Table: `:project_overrides`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `scope` (string) | lemon_core | `LemonCore.BindingResolver` | Cold | Durable | Maps scope to project_id override |
| `scope` (string) | lemon_channels | `LemonChannels.Adapters.Telegram.Transport` | Cold | Write | Telegram /project command writes; deletes on /project clear |

#### Table: `:projects_dynamic`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `project_id` (string) | lemon_core | `LemonCore.BindingResolver` | Cold | Durable | Dynamic project definitions (root, default_engine) |
| `project_id` (string) | lemon_channels | `LemonChannels.Adapters.Telegram.Transport` | Cold | Write | Written by Telegram /project command |

#### Table: `:agents`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `agent_id` (string) | lemon_control_plane | `AgentIdentityGet` | Cold | Durable | Agent identity/config data |

### Exec Approvals Tables

#### Table: `:exec_approvals_pending`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `approval_id` (string) | lemon_core | `LemonCore.ExecApprovals` | Hot | Durable | Pending approval requests |
| `approval_id` (string) | lemon_control_plane | `ExecApprovalRequest` | Hot | Write | Control plane creates pending approvals |

#### Table: `:exec_approvals_policy`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `{tool, action_hash}` | lemon_core | `LemonCore.ExecApprovals` | Cold | Durable | Global tool+action approval records |
| `{tool, :any}` | lemon_core | `LemonCore.ExecApprovals` | Cold | Durable | Global tool-level wildcard approvals |
| `{tool, action_hash}` | lemon_control_plane | `ExecApprovalsSet` | Cold | Write | Set via control plane |

#### Table: `:exec_approvals_policy_map`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `:global` | lemon_control_plane | `ExecApprovalsSet`, `ExecApprovalsGet` | Cold | Durable | Global policy map (tool -> disposition) |

#### Table: `:exec_approvals_policy_node`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `{node_id, tool, action_hash}` | lemon_core | `LemonCore.ExecApprovals` | Cold | Durable | Node-scoped approval records |
| `{node_id, tool, :any}` | lemon_control_plane | `ExecApprovalsNodeSet` | Cold | Write | Node-level wildcard approvals |

#### Table: `:exec_approvals_policy_node_map`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `node_id` | lemon_control_plane | `ExecApprovalsNodeSet`, `ExecApprovalsNodeGet` | Cold | Durable | Node policy map (tool -> disposition) |

#### Table: `:exec_approvals_policy_agent`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `{agent_id, tool, action_hash}` | lemon_core | `LemonCore.ExecApprovals` | Cold | Durable | Agent-scoped approval records |

#### Table: `:exec_approvals_policy_session`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `{session_key, tool, action_hash}` | lemon_core | `LemonCore.ExecApprovals` | Cold | Durable | Session-scoped approval records |

### Session & Run State Tables

#### Table: `:pending_compaction`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `session_key` (string) | lemon_router | `LemonRouter.RunProcess.CompactionTrigger` | Hot | Durable | Marks sessions needing compaction |
| `session_key` (string) | lemon_router | `LemonRouter.Router` | Hot | Read/Delete | Consumed when building context, deleted after use |

#### Table: `:session_overrides`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `session_key` | lemon_control_plane | `SessionsReset` | Cold | Durable | Deleted on session reset |

### Automation Tables

#### Table: `:cron_jobs`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `job_id` (string) | lemon_automation | `LemonAutomation.CronStore` | Cold | Durable | CronJob definitions |

#### Table: `:cron_runs`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `run_id` (string) | lemon_automation | `LemonAutomation.CronStore` | Cold | Durable | CronRun history records |

#### Table: `:heartbeat_config`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `agent_id` (string) | lemon_automation | `LemonAutomation.HeartbeatManager` | Cold | Durable | Heartbeat configuration per agent |
| `agent_id` (string) | lemon_automation | `LemonAutomation.CronManager` | Cold | Delete | Cleaned up when heartbeat disabled |
| `agent_id` (string) | lemon_control_plane | `SetHeartbeats`, `LastHeartbeat` | Cold | Read/Write | UI configuration |

#### Table: `:heartbeat_last`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `agent_id` (string) | lemon_automation | `LemonAutomation.HeartbeatManager` | Cold | Durable | Last heartbeat result per agent |
| `agent_id` (string) | lemon_control_plane | `LastHeartbeat` | Cold | Read-only | UI reads last result |

### Control Plane Tables

#### Table: `:session_tokens`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `token` (string) | lemon_control_plane | `LemonControlPlane.Auth.TokenStore` | Hot | Durable | Auth tokens with expiry |

#### Table: `:system_config`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `key` (string) | lemon_control_plane | `ConfigSet`, `ConfigPatch`, `ConfigGet` | Cold | Durable | System-level config key-value pairs |

#### Table: `:update_config`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `:global` | lemon_control_plane | `UpdateRun` | Cold | Durable | Self-update configuration |

#### Table: `:pending_update`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `:current` | lemon_control_plane | `UpdateRun` | Cold | Durable | Current pending update info |

#### Table: `:usage_stats`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `:runs_today` | lemon_control_plane | `UsageStatus` | Cold | Durable | Daily run count |
| `:tokens_today` | lemon_control_plane | `UsageStatus` | Cold | Durable | Daily token count |
| `:cost_today` | lemon_control_plane | `UsageStatus` | Cold | Durable | Daily cost estimate |

#### Table: `:usage_records`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `date_key` (string) | lemon_control_plane | `UsageCost` | Cold | Durable | Per-day usage records |

#### Table: `:usage_data`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `:current` | lemon_control_plane | `UsageCost` | Cold | Durable | Rolling usage summary |

#### Table: `:nodes_registry`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `node_id` (string) | lemon_control_plane | `NodeEvent`, `NodePairApprove`, `NodeList`, `NodeDescribe`, `NodeRename`, `NodeInvoke`, `BrowserRequest` | Cold | Durable | Registered remote nodes |

#### Table: `:nodes_pairing`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `pairing_id` (string) | lemon_control_plane | `NodePairRequest`, `NodePairApprove`, `NodePairReject`, `NodePairVerify`, `NodePairList` | Cold | Durable | Pairing requests by ID |

#### Table: `:nodes_pairing_by_code`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `pairing_code` (string) | lemon_control_plane | `NodePairRequest`, `NodePairApprove`, `NodePairReject`, `NodePairVerify` | Cold | Durable | Pairing code -> pairing_id index |

#### Table: `:node_challenges`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `challenge_token` (string) | lemon_control_plane | `NodePairApprove`, `ConnectChallenge` | Cold | Durable | Node challenge tokens |

#### Table: `:node_invocations`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `invoke_id` (string) | lemon_control_plane | `NodeInvoke`, `NodeInvokeResult`, `BrowserRequest` | Hot | Durable | Pending node invocation state |

#### Table: `:device_pairing`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `pairing_id` (string) | lemon_control_plane | `DevicePairRequest`, `DevicePairApprove`, `DevicePairReject` | Cold | Durable | Device pairing requests |

#### Table: `:devices`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `device_token` (string) | lemon_control_plane | `DevicePairApprove` | Cold | Durable | Approved device tokens |

#### Table: `:device_pairing_challenges`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `challenge_token` (string) | lemon_control_plane | `DevicePairApprove`, `ConnectChallenge` | Cold | Durable | Device challenge tokens |

#### Table: `:wizards`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `wizard_id` (string) | lemon_control_plane | `WizardStart`, `WizardStep`, `WizardCancel` | Cold | Durable | Multi-step wizard state |

#### Table: `:agent_files`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `{agent_id, file_name}` | lemon_control_plane | `AgentsFilesSet`, `AgentsFilesGet` | Cold | Durable | Agent-attached file storage |
| `agent_id` (legacy?) | lemon_control_plane | `AgentsFilesGet`, `AgentsFilesList` | Cold | Read-only | Legacy single-file lookup |

#### Table: `:skills_config`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `{cwd, skill_key, :enabled}` | lemon_control_plane | `SkillsUpdate` | Cold | Durable | Per-project skill enablement |
| `{cwd, skill_key, :env}` | lemon_control_plane | `SkillsUpdate` | Cold | Durable | Per-project skill env config |

#### Table: `:talk_mode`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `session_key` | lemon_control_plane | `TalkMode` | Cold | Durable | Voice talk mode state per session |

#### Table: `:tts_config`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `:global` | lemon_control_plane | `TtsEnable`, `TtsDisable`, `TtsSetProvider`, `TtsStatus`, `TtsConvert` | Cold | Durable | TTS configuration (provider, enabled, voice) |

#### Table: `:voicewake_config`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `:global` | lemon_control_plane | `VoicewakeSet`, `VoicewakeGet` | Cold | Durable | Voice wake word configuration |

### Gateway Tables

#### Table: `:agent_endpoints`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `{agent_id, endpoint_name}` | lemon_router | `LemonRouter.AgentEndpoints` | Cold | Durable | Named agent API endpoints |

#### Table: `:email_message_threads`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `message_id` (string) | lemon_gateway | `LemonGateway.Transports.Email.Outbound`, `...Inbound` | Cold | Durable | Email message -> thread mapping |

#### Table: `:email_thread_state`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `thread_id` (string) | lemon_gateway | `LemonGateway.Transports.Email.Outbound`, `...Inbound` | Cold | Durable | Email thread conversation state |

#### Table: `:farcaster_frame_sessions`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `chat_id` (string) | lemon_gateway | `LemonGateway.Transports.Farcaster.CastHandler` | Cold | Durable | Farcaster frame session state |

#### Table: `:webhook_idempotency`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `{integration_id, idempotency_key}` | lemon_gateway | `LemonGateway.Transports.Webhook` | Cold | Durable | Webhook deduplication |

#### Table: `:sms_inbox`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `message_sid` (string) | lemon_gateway | `LemonGateway.Sms.Inbox` | Cold | Durable | SMS message store |

### Games Tables

#### Table: `:game_matches`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `match_id` (string) | lemon_games | `LemonGames.Matches.Service`, `DeadlineSweeper` | Hot | Durable | Active and completed match state |

#### Table: `:game_match_events`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `{match_id, seq}` | lemon_games | `LemonGames.Matches.EventLog` | Cold | Durable | Match event history |

#### Table: `:game_rate_limits`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `{scope, action}` | lemon_games | `LemonGames.RateLimit` | Hot | Durable | Game API rate limiting |

#### Table: `:game_agent_tokens`

| Key Pattern | Owning App | Owning Module | Hot/Cold | Durability | Notes |
|-------------|-----------|---------------|----------|------------|-------|
| `token_hash` (string) | lemon_games | `LemonGames.Auth` | Hot | Durable | Game agent auth tokens |

---

## Channel-Specific State (Non-Core-Owned)

These keys are **Telegram-specific** and should be owned by `lemon_channels`, not
accessed directly by `lemon_router` or `lemon_gateway`. They represent the primary
candidates for migration to a `LemonChannels.ChannelState` module.

### Table: `:telegram_pending_compaction`

| Key Pattern | Current Writer | Current Reader | Target Owner | Notes |
|-------------|---------------|----------------|--------------|-------|
| `{account_id, chat_id, thread_id}` | lemon_router (`CompactionTrigger`) | lemon_channels (`Telegram.Transport`) | lemon_channels | Marks Telegram threads needing compaction; read and deleted by transport |

### Table: `:telegram_msg_resume`

| Key Pattern | Current Writer | Current Reader | Target Owner | Notes |
|-------------|---------------|----------------|--------------|-------|
| `{account_id, chat_id, topic_id, generation, msg_id}` | lemon_core (`Store.finalize_run`), lemon_router (`Telegram` adapter) | lemon_channels (`Telegram.Transport`) | lemon_channels | Maps message IDs to resume tokens for reply-based session switching |

### Table: `:telegram_selected_resume`

| Key Pattern | Current Writer | Current Reader | Target Owner | Notes |
|-------------|---------------|----------------|--------------|-------|
| `{account_id, chat_id, thread_id}` | lemon_channels (`Telegram.Transport`) | lemon_channels (`Telegram.Transport`) | lemon_channels | Currently selected resume token per thread; deleted by compaction trigger in lemon_router |

### Table: `:telegram_msg_session`

| Key Pattern | Current Writer | Current Reader | Target Owner | Notes |
|-------------|---------------|----------------|--------------|-------|
| `{account_id, chat_id, thread_id, generation, msg_id}` | lemon_channels (`Telegram.Transport`) | lemon_channels (`Telegram.Transport`) | lemon_channels | Maps message IDs to session keys; cleared by compaction trigger in lemon_router |

### Table: `:telegram_known_targets`

| Key Pattern | Current Writer | Current Reader | Target Owner | Notes |
|-------------|---------------|----------------|--------------|-------|
| `{account_id, chat_id, topic_id}` | lemon_channels (`UpdateProcessor`) | lemon_router (`AgentDirectory`) | lemon_channels | Known Telegram chat targets; ReadCache-backed (hot) |

### Table: `:telegram_thread_generation`

| Key Pattern | Current Writer | Current Reader | Target Owner | Notes |
|-------------|---------------|----------------|--------------|-------|
| `{account_id, chat_id, thread_id}` | lemon_channels (`Telegram.Transport`) | lemon_channels (`Telegram.Transport`) | lemon_channels | Thread generation counter for session isolation |

### Table: `:telegram_session_model`

| Key Pattern | Current Writer | Current Reader | Target Owner | Notes |
|-------------|---------------|----------------|--------------|-------|
| `session_key` (string) | lemon_channels (`Telegram.Transport`) | lemon_channels (`Telegram.Transport`) | lemon_channels | Per-session model override (via /model command) |

### Table: `:telegram_default_model`

| Key Pattern | Current Writer | Current Reader | Target Owner | Notes |
|-------------|---------------|----------------|--------------|-------|
| `{account_id, chat_id, topic_id}` | lemon_channels (`Telegram.Transport`) | lemon_channels (`Telegram.Transport`) | lemon_channels | Per-chat/topic default model (via /default command) |

### Table: `:telegram_default_thinking`

| Key Pattern | Current Writer | Current Reader | Target Owner | Notes |
|-------------|---------------|----------------|--------------|-------|
| `{account_id, chat_id, topic_id}` | lemon_channels (`Telegram.Transport`) | lemon_channels (`Telegram.Transport`) | lemon_channels | Per-chat/topic default thinking mode |

### Table: `:telegram_chat_trigger_mode`

| Key Pattern | Current Writer | Current Reader | Target Owner | Notes |
|-------------|---------------|----------------|--------------|-------|
| `{account_id, chat_id}` | lemon_channels | `LemonChannels.Telegram.TriggerMode` | lemon_channels | Chat-level trigger mode (always/mention/command) |

### Table: `:telegram_topic_trigger_mode`

| Key Pattern | Current Writer | Current Reader | Target Owner | Notes |
|-------------|---------------|----------------|--------------|-------|
| `{account_id, chat_id, topic_id}` | lemon_channels | `LemonChannels.Telegram.TriggerMode` | lemon_channels | Topic-level trigger mode override |

### Table: `:telegram_offsets`

| Key Pattern | Current Writer | Current Reader | Target Owner | Notes |
|-------------|---------------|----------------|--------------|-------|
| `{account_id, token_hash}` | lemon_channels | `LemonChannels.Telegram.OffsetStore` | lemon_channels | Telegram update offset for long-polling |

---

## Cross-Cutting Boundary Violations

The following Store access patterns cross app boundaries in ways that should be
addressed:

| Table | Violation | Description |
|-------|-----------|-------------|
| `:telegram_pending_compaction` | lemon_router writes, lemon_channels reads/deletes | Compaction trigger in router creates markers consumed by channel transport |
| `:telegram_msg_resume` | lemon_core (Store internals) and lemon_router write, lemon_channels reads | Resume token indexing is embedded in Store.finalize_run and router's Telegram adapter |
| `:telegram_selected_resume` | lemon_router deletes, lemon_channels reads/writes | CompactionTrigger in router deletes selected resume owned by channels |
| `:telegram_msg_session` | lemon_router clears (via CompactionTrigger), lemon_channels writes/reads | Session-message index cleared cross-boundary during compaction |
| `:telegram_known_targets` | lemon_channels writes, lemon_router reads | AgentDirectory reads channel-specific data directly |
| `:project_overrides` | lemon_channels writes, lemon_core reads | Telegram /project command writes directly to core binding resolver table |
| `:projects_dynamic` | lemon_channels writes, lemon_core reads | Telegram /project command writes directly to core binding resolver table |

---

## Migration Targets

### Channel-specific state -> `LemonChannels.ChannelState`

All tables prefixed with `telegram_` should be owned by `lemon_channels`. The
router should interact via a `LemonChannels.ChannelState` API rather than
reaching into Store tables directly. Tables to migrate:

- `:telegram_pending_compaction`
- `:telegram_msg_resume`
- `:telegram_selected_resume`
- `:telegram_msg_session`
- `:telegram_known_targets`
- `:telegram_thread_generation`
- `:telegram_session_model`
- `:telegram_default_model`
- `:telegram_default_thinking`
- `:telegram_chat_trigger_mode`
- `:telegram_topic_trigger_mode`
- `:telegram_offsets`

### Run state -> `LemonCore.RunStore` (future)

Consolidate run-related state into a dedicated module:

- `:runs` (active run events/summaries)
- `:run_history` (finalized run history by session)
- `:progress` (progress message -> run mapping)

### Session state -> `LemonCore.SessionStore` (future)

Consolidate session-related state:

- `:chat` (chat state with TTL)
- `:sessions_index` (session metadata)
- `:session_policies` (session policy overrides)
- `:session_overrides` (session config overrides)
- `:talk_mode` (per-session talk mode)

### Progress/output tracking -> `LemonCore.ProgressStore` (future)

- `:progress` (progress message mappings)
- `:pending_compaction` (compaction markers)

### Policy state -> `LemonCore.PolicyStore` (future)

Consolidate all policy tables:

- `:agent_policies`
- `:channel_policies`
- `:session_policies`
- `:runtime_policy`
- `:exec_approvals_*` (6 tables)

### Gateway transport state -> per-transport modules

- `:email_message_threads`, `:email_thread_state` -> `LemonGateway.Transports.Email.State`
- `:farcaster_frame_sessions` -> `LemonGateway.Transports.Farcaster.State`
- `:webhook_idempotency` -> `LemonGateway.Transports.Webhook.State`
- `:sms_inbox` -> `LemonGateway.Sms.State`

### Automation state -> `LemonAutomation.Store` (already partially exists as `CronStore`)

- `:cron_jobs`, `:cron_runs` (already wrapped by `CronStore`)
- `:heartbeat_config`, `:heartbeat_last`

### Games state -> `LemonGames.Store` (future)

- `:game_matches`
- `:game_match_events`
- `:game_rate_limits`
- `:game_agent_tokens`

### Control plane state -> `LemonControlPlane.Store` (future)

- `:session_tokens` (already wrapped by `TokenStore`)
- `:system_config`
- `:update_config`, `:pending_update`
- `:usage_stats`, `:usage_records`, `:usage_data`
- `:nodes_registry`, `:nodes_pairing`, `:nodes_pairing_by_code`, `:node_challenges`, `:node_invocations`
- `:device_pairing`, `:devices`, `:device_pairing_challenges`
- `:wizards`
- `:agent_files`
- `:skills_config`
- `:tts_config`
- `:voicewake_config`
