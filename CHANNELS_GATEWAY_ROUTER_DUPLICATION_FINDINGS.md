# Duplication Analysis: lemon_channels, lemon_gateway, lemon_router

## Summary
This report identifies duplicated code patterns across the channels, gateway, and router applications. The patterns are organized by category, severity, and recommended extraction strategy.

---

## 1. INBOUND MESSAGE NORMALIZATION (HIGH SEVERITY)

**Pattern Name:** `normalize/2` and `normalize_message/3` across adapters

**Files affected:**
- `/apps/lemon_channels/lib/lemon_channels/adapters/discord/inbound.ex`
- `/apps/lemon_channels/lib/lemon_channels/adapters/telegram/inbound.ex`
- `/apps/lemon_channels/lib/lemon_channels/adapters/whatsapp/inbound.ex`

**Duplicated Logic:**
All three adapters implement the same pattern:
1. Dispatch on input shape (checking for `message`, `"message"`, etc.)
2. Extract and normalize channel-specific fields into a standard `InboundMessage` struct
3. Extract sender/author information with fallback patterns
4. Handle media/attachment metadata
5. Normalize timestamps to Unix integers

**Code Example - Dispatch pattern (identical across all three):**
```elixir
# Discord
def normalize(%{message: message, account_id: account_id} = raw), do: normalize_message(message, account_id, raw)
def normalize(%{"message" => message, "account_id" => account_id} = raw), do: normalize_message(message, account_id, raw)
def normalize(_), do: {:error, :unsupported_inbound}

# Telegram
def normalize(%{"message" => message} = update), do: normalize_message(message, update)
def normalize(%{"edited_message" => message} = update), do: normalize_message(message, update)
def normalize(%{"channel_post" => message} = update), do: normalize_message(message, update)
def normalize(update) when is_map(update), do: Logger.warning(...); {:error, :unsupported_update_type}

# WhatsApp
def normalize(%{"type" => "message"} = event), do: normalize_message(event)
def normalize(%{"type" => type} = event) when is_binary(type), do: Logger.debug(...); {:error, :unsupported_event_type}
```

**Code Example - Sender extraction (nearly identical):**
```elixir
# Discord
defp to_sender(author) when is_map(author) do
  id = fetch_id(author, :id)
  if is_integer(id) do
    %{id: Integer.to_string(id), username: fetch_binary(author, :username), ...}
  else
    nil
  end
end

# Telegram
sender = if from do
  %{id: to_string(from["id"]), username: from["username"], ...}
else
  nil
end

# WhatsApp
sender = %{
  id: to_string(sender_jid),
  username: phone_from_jid(sender_jid),
  display_name: sender_name
}
```

**Recommendation:**
Extract a shared `LemonChannels.Inbound` module with:
- `normalize_dispatch/2` - handles multiple input shapes with pluggable adapters
- `normalize_sender/2` - generic sender extraction with callback for channel-specific field mapping
- Common field extraction helpers (`fetch_binary`, `fetch_id`, `fetch_map`, `fetch_list`)

---

## 2. OUTBOUND MESSAGE DELIVERY PATTERNS (HIGH SEVERITY)

**Pattern Name:** `deliver/1` and channel-specific delivery logic

**Files affected:**
- `/apps/lemon_channels/lib/lemon_channels/adapters/discord/outbound.ex`
- `/apps/lemon_channels/lib/lemon_channels/adapters/telegram/outbound.ex`
- `/apps/lemon_channels/lib/lemon_channels/adapters/whatsapp/outbound.ex`

**Duplicated Logic:**
1. Dispatch on `OutboundPayload.kind` (:text, :edit, :delete, :reaction, :file)
2. Extract peer/channel IDs with type coercion
3. Error handling with rescue blocks for each delivery type
4. Common pattern: Extract params → Call API → Normalize response

**Code Example - Text delivery rescue pattern (identical structure):**
```elixir
# Discord
def deliver(%OutboundPayload{kind: :text} = payload) do
  with {:ok, channel_id} <- peer_channel_id(payload),
       content when is_binary(content) <- to_string(payload.content),
       params <- text_params(content, payload),
       {:ok, result} <- Message.create(channel_id, params) do
    {:ok, %{message_id: extract_message_id(result)}}
  else
    {:error, reason} -> {:error, reason}
    other -> {:error, {:discord_send_failed, other}}
  end
rescue
  error ->
    Logger.warning("discord outbound text delivery crashed: ...")
    {:error, {:discord_send_crashed, error}}
end

# Telegram - similar structure with try/rescue
# WhatsApp - similar structure with try/rescue
```

**Recommendation:**
Extract `LemonChannels.Outbound` module with:
- `DeliveryHandler` behavior for channel-specific implementations
- Generic `deliver_with_retry/2` wrapper handling rescue/retry logic
- Shared error handling and logging patterns
- Common response normalization

---

## 3. STATUS RENDERER PATTERNS (MEDIUM SEVERITY)

**Pattern Name:** Status/control button rendering across adapters

**Files affected:**
- `/apps/lemon_channels/lib/lemon_channels/adapters/discord/status_renderer.ex` (127 lines)
- `/apps/lemon_channels/lib/lemon_channels/adapters/telegram/status_renderer.ex` (56 lines)
- `/apps/lemon_channels/lib/lemon_channels/adapters/whatsapp/status_renderer.ex` (8 lines)

**Duplicated Logic:**
All renderers implement the same control flow for two intent kinds:
- `:tool_status_snapshot` - renders cancel button if allowed
- `:watchdog_prompt` - renders keep-waiting and stop buttons

**Code Example - Intent matching (identical logic):**
```elixir
# Discord
def components(%LemonCore.DeliveryIntent{kind: :tool_status_snapshot, run_id: run_id, controls: controls})
    when is_binary(run_id) and run_id != "" do
  if allow_cancel?(controls) do
    [action_row([button("Cancel", @cancel_callback_prefix <> ":" <> run_id, style: :danger)])]
  else
    nil
  end
end

# Telegram
def reply_markup(%LemonCore.DeliveryIntent{kind: :tool_status_snapshot, run_id: run_id, controls: controls})
    when is_binary(run_id) and run_id != "" do
  if allow_cancel?(controls) do
    %{"inline_keyboard" => [[%{"text" => "cancel", "callback_data" => @cancel_callback_prefix <> ":" <> run_id}]]}
  else
    nil
  end
end
```

**Recommendation:**
Extract `LemonChannels.StatusRenderer` module with:
- Behavior defining `render/1` callback
- Shared intent matching and control logic
- Adapter-specific formatting (Discord components vs Telegram inline keyboards)

---

## 4. SUPERVISOR PATTERNS (MEDIUM SEVERITY)

**Pattern Name:** Adapter supervisor initialization with token/config resolution

**Files affected:**
- `/apps/lemon_channels/lib/lemon_channels/adapters/discord/supervisor.ex`
- `/apps/lemon_channels/lib/lemon_channels/adapters/telegram/supervisor.ex`
- `/apps/lemon_channels/lib/lemon_channels/adapters/whatsapp/supervisor.ex`

**Duplicated Logic:**
All three supervisors follow identical patterns:
1. Get base config from `LemonChannels.GatewayConfig`
2. Merge with optional runtime config
3. Resolve credentials (token, secret, path) with fallback chain
4. Conditionally start transport if credentials present

**Code Example - Base config merge (identical):**
```elixir
# Discord, Telegram, WhatsApp all use:
base = LemonChannels.GatewayConfig.get(:adapter_name, %{}) || %{}
config = base |> merge_config(Keyword.get(opts, :config))
```

**Code Example - Conditional children (nearly identical):**
```elixir
# Discord
children = if is_binary(token) and String.trim(token) != "" do
  [{LemonChannels.Adapters.Discord.Transport, [config: config]}]
else
  []
end

# Telegram & WhatsApp similar, with additional Task.Supervisor
```

**Recommendation:**
Extract `LemonChannels.AdapterSupervisor` base module with:
- Generic `init/2` accepting adapter name and validation callback
- Shared config resolution pipeline
- Common credential fallback patterns
- Pluggable children configuration

---

## 5. MODEL POLICY ADAPTER (MEDIUM SEVERITY - Already Partially Extracted)

**Pattern Name:** ModelPolicyAdapter across channels

**Files affected:**
- `/apps/lemon_channels/lib/lemon_channels/adapters/model_policy_shared.ex` (479 lines - shared via macro)
- `/apps/lemon_channels/lib/lemon_channels/adapters/discord/model_policy_adapter.ex` (54 lines)
- `/apps/lemon_channels/lib/lemon_channels/adapters/telegram/model_policy_adapter.ex` (80 lines)
- `/apps/lemon_channels/lib/lemon_channels/adapters/whatsapp/model_policy_adapter.ex` (not found, but likely similar)

**Status:** This pattern is WELL-EXTRACTED via `ModelPolicyShared` macro. No additional extraction needed. The callbacks are:
- `channel_name/0`
- `build_route/3`
- `session_get/1`, `session_put/2`
- `format_source_labels/0`
- Optional: `legacy_model_fallback/3`, `legacy_thinking_fallback/3`

**Verdict:** Keep as-is, this is an exemplary extraction.

---

## 6. SESSION ROUTING PATTERNS (MEDIUM-HIGH SEVERITY)

**Pattern Name:** Session key building and session state management

**Files affected:**
- `/apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/session_routing.ex` (80+ lines)
- `/apps/lemon_channels/lib/lemon_channels/adapters/whatsapp/transport/session_routing.ex` (80+ lines)
- Likely also in Discord transport (not fully inspected)

**Duplicated Logic:**
Both Telegram and WhatsApp have identical:
- `build_session_key/3` - identical implementation
- `maybe_mark_new_session_pending/4` - identical implementation with different param names
- `maybe_mark_fork_when_busy/4` - nearly identical logic with channel-specific field access

**Code Example:**
```elixir
# Telegram
def build_session_key(account_id, inbound, %ChatScope{} = scope) do
  agent_id = inbound.meta[:agent_id] || ... || "default"
  SessionKey.channel_peer(%{
    agent_id: agent_id,
    channel_id: "telegram",
    account_id: account_id || "default",
    peer_kind: inbound.peer.kind || :unknown,
    peer_id: to_string(scope.chat_id),
    thread_id: inbound.peer.thread_id
  })
end

# WhatsApp - identical except channel_id: "whatsapp"
```

**Recommendation:**
Extract `LemonChannels.SessionRouting` module with:
- Generic `build_session_key/3` accepting channel name
- Generic `maybe_mark_new_session_pending/4`
- Generic `maybe_mark_fork_when_busy/4`
- Pluggable channel-specific normalization callbacks

---

## 7. HEALTH CHECK SYSTEM (HIGH SEVERITY - Cross-App)

**Pattern Name:** Health status checking and normalization

**Files affected:**
- `/apps/lemon_gateway/lib/lemon_gateway/health.ex` (194 lines)
- `/apps/lemon_router/lib/lemon_router/health.ex` (121 lines)

**Duplicated Logic (word-for-word identical):**
1. `run_check/1` - takes {name, fun} tuple, times execution, catches exceptions
2. `normalize_check_result/1` - converts :ok/true/false to {:ok, _}/{:error, _}
3. `process_alive_check/1` - verifies named process is alive
4. Dynamic supervisor check pattern
5. Custom checks normalization with flexible input handling

**Code Example - Identical functions:**
```elixir
defp run_check({name, fun}) do
  started_at_ms = System.monotonic_time(:millisecond)
  result = try do
    normalize_check_result(fun.())
  rescue
    exception -> {:error, {:raised, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
  duration_ms = System.monotonic_time(:millisecond) - started_at_ms
  case result do
    {:ok, detail} ->
      %{name: to_string(name), ok: true, duration_ms: duration_ms, detail: detail}
    {:error, reason} ->
      %{name: to_string(name), ok: false, duration_ms: duration_ms, error: inspect(reason)}
  end
end
```

**Recommendation (CRITICAL):**
Extract `LemonCore.HealthCheck` or `Ai.Providers.HealthCheck` module with:
- `status/0` entry point
- `run_check/1` - universal check executor
- `normalize_check_result/1` - result formatting
- `process_alive_check/1` - generic process check
- `dynamic_supervisor_check/1` - supervisor child counting
- Flexible custom checks API
- App-name injection point

---

## 8. COMMAND ROUTERS (MEDIUM SEVERITY)

**Pattern Name:** Message command routing and dispatch

**Files affected:**
- `/apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/command_router.ex`
- `/apps/lemon_channels/lib/lemon_channels/adapters/whatsapp/transport/command_router.ex`

**Status:** Not fully inspected, but likely similar dispatch patterns on message content.

**Recommendation:** Review for extraction if patterns match.

---

## 9. CROSS-APP GAPS (INFORMATIONAL)

### lemon_gateway-to-lemon_router
- **Gateway** has health checks → **Router** has health checks (duplicated)
- **Gateway** has renderers (basic) → **Router** has tool_status_renderer (similar concerns)

### lemon_channels-to-gateway/router
- Adapter patterns don't exist in gateway/router (appropriate separation)
- Health check system is duplicated across apps

---

## EXTRACTION PRIORITIES & COSTS

### TIER 1: CRITICAL (5+ instances, high impact)
1. **Health Check System** (/apps/lemon_gateway & /apps/lemon_router)
   - Effort: 2-4 hours
   - Files to create: 1 new module in lemon_core
   - Files to modify: 2 (gateway, router)
   - Risk: Low (self-contained)
   - Impact: High (eliminates maintenance burden)

### TIER 2: HIGH (3+ instances, high maintenance burden)
2. **Inbound Message Normalization** (discord, telegram, whatsapp)
   - Effort: 4-6 hours
   - Files to create: 1-2 new modules in lemon_channels
   - Files to modify: 3 adapters
   - Risk: Medium (adapter behavior must stay identical)
   - Impact: High (20-30 lines saved per adapter)

3. **Outbound Message Delivery** (discord, telegram, whatsapp)
   - Effort: 4-6 hours
   - Files to create: 1-2 new modules in lemon_channels
   - Files to modify: 3 adapters
   - Risk: Medium (error handling must be preserved)
   - Impact: High (30-50 lines saved per adapter)

4. **Supervisor Patterns** (discord, telegram, whatsapp)
   - Effort: 2-4 hours
   - Files to create: 1 new base module in lemon_channels
   - Files to modify: 3 adapters
   - Risk: Medium (config resolution is critical)
   - Impact: Medium (15-25 lines saved per adapter)

### TIER 3: MEDIUM
5. **Session Routing** (telegram, whatsapp, likely discord)
   - Effort: 2-3 hours
   - Files to create: 1 new module
   - Files to modify: 2-3 adapters
   - Risk: Medium
   - Impact: Medium (10-20 lines per adapter)

6. **Status Renderers** (discord, telegram, whatsapp)
   - Effort: 2-3 hours
   - Files to create: 1 behavior + shared logic
   - Files to modify: 3 adapters
   - Risk: Low (formatting is adapter-specific)
   - Impact: Low-Medium (Discord over-engineered, others simple)

---

## RECOMMENDATIONS

### Immediate Actions
1. **Extract health check system** - Single highest-impact extraction
   - Create `LemonCore.HealthCheck.Status` module
   - Move `run_check`, `normalize_check_result`, `process_alive_check` to shared
   - Create `LemonGateway.HealthChecks` and `LemonRouter.HealthChecks` for app-specific checks

2. **Review command_router patterns** across telegram/whatsapp
   - If duplicated, extract to `LemonChannels.CommandRouter` behavior

### Follow-up Work
3. Extract inbound/outbound normalization after health checks complete
4. Extract supervisor base after confident with shared module patterns
5. Extract session routing after reviewing Discord transport

### Notes for Implementation
- Use behaviors/macros for flexible adapter patterns (see ModelPolicyShared for exemplar)
- Preserve error handling and logging in extracted code
- Create integration tests for extracted modules
- Update this analysis document as extractions complete

---

## APPENDIX: FILES SCANNED

**lemon_channels/adapters:**
- discord/{inbound,outbound,status_renderer,supervisor,model_policy_adapter}.ex
- telegram/{inbound,outbound,status_renderer,supervisor,model_policy_adapter}.ex
- whatsapp/{inbound,outbound,status_renderer,supervisor,model_policy_adapter}.ex
- model_policy_shared.ex
- telegram/transport/{session_routing,command_router,commands}.ex
- whatsapp/transport/{session_routing,command_router,commands}.ex

**lemon_gateway:**
- health.ex
- renderers/basic.ex

**lemon_router:**
- health.ex
- tool_status_renderer.ex
